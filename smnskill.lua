-- smnskill.lua
-- Author : Kezo
-- Desc   : Repeatedly summons and releases avatars on configurable timers.
--          Rotates through up to 7 chosen avatars in any order.
--          Includes an ImGui UI patterned after the killcounter addon.

addon.name    = 'smnskill'
addon.author  = 'Kezo'
addon.version = '0.3.0'
addon.desc    = 'Summoner skill-up helper with avatar rotation.'

require('common')
local imgui = require('imgui')

-----------------------------------------------------------------------
-- Basic config (in-memory, non-persistent for now)
-----------------------------------------------------------------------
local MAX_ROTATION_SLOTS = 7

local avatar_list = {
    'Carbuncle',
    'Ifrit',
    'Shiva',
    'Garuda',
    'Titan',
    'Ramuh',
    'Leviathan',
    'Fenrir',
    'Diabolos',
}

local cfg = {
    show_ui          = true,
    quiet            = true,
    summon_delay_sec = 5, -- time between summons (approx. recast)
    stay_time_sec    = 7, -- how long avatar stays out before /ja "Release"

    -- Up to 7 rotation slots; order on screen is the order used.
    -- enabled + avatar_index (index into avatar_list).
    rotation = {
        { enabled = true,  avatar_index = 1 }, -- Slot 1: Carbuncle
        { enabled = true,  avatar_index = 2 }, -- Slot 2: Ifrit
        { enabled = true,  avatar_index = 3 }, -- Slot 3: Shiva
        { enabled = true, avatar_index = 4 }, -- Slot 4: Garuda
        { enabled = true, avatar_index = 5 }, -- Slot 5: Titan
        { enabled = true, avatar_index = 6 }, -- Slot 6: Ramuh
        { enabled = true, avatar_index = 7 }, -- Slot 7: Leviathan
    },
}
-----------------------------------------------------------------------
-- Runtime state
-----------------------------------------------------------------------
local running           = false
local state             = 'idle'  -- 'idle', 'summon', 'wait_release', 'release', 'wait_summon'
local next_action_time  = 0       -- os.clock() timestamp for next action
local total_summons     = 0
local total_releases    = 0
local run_start_time    = 0       -- os.time() when we last started running (for runtime display)
local cumulative_run    = 0       -- total run time across starts/stops (seconds)
local rotation_index    = 1       -- current rotation slot pointer (1..MAX_ROTATION_SLOTS)
local last_avatar_name  = nil     -- last avatar actually summoned
local last_avatar_slot  = nil     -- index of slot used for last summon

-- MP rest state
local mp_resting        = false   -- currently in /heal due to low MP
local mp_rest_started   = 0       -- os.time() when resting started (for debug/display)

-----------------------------------------------------------------------
-- Utility helpers
-----------------------------------------------------------------------
local function msg(s)
    if cfg.quiet then return end
    AshitaCore:GetChatManager():QueueCommand(1, '/echo [smnskill] ' .. tostring(s))
end

local function seconds_to_hms(sec)
    if sec < 0 then sec = 0 end
    local h = math.floor(sec / 3600); sec = sec % 3600
    local m = math.floor(sec / 60);  sec = sec % 60
    return h, m, sec
end

local function get_runtime()
    local base = cumulative_run
    if running and run_start_time > 0 then
        base = base + (os.time() - run_start_time)
    end
    return base
end

-- Clamp a slot's avatar_index into a valid range.
local function sanitize_slot(slot)
    if not slot then return end
    if slot.avatar_index == nil then
        slot.avatar_index = 1
    end
    if slot.avatar_index < 1 then
        slot.avatar_index = 1
    end
    if slot.avatar_index > #avatar_list then
        slot.avatar_index = #avatar_list
    end
end

-- Returns rotation summary text like: "1:Carbuncle -> 2:Ifrit -> 4:Garuda"
local function get_rotation_summary()
    local parts = {}
    for i = 1, MAX_ROTATION_SLOTS do
        local slot = cfg.rotation[i]
        if slot and slot.enabled then
            sanitize_slot(slot)
            local name = avatar_list[slot.avatar_index]
            if name and #name > 0 then
                table.insert(parts, string.format('%d:%s', i, name))
            end
        end
    end
    if #parts == 0 then
        return '(none)'
    end
    return table.concat(parts, ' -> ')
end

-- Pick the next enabled avatar from the rotation.
-- Advances rotation_index for the subsequent summon.
local function get_next_avatar_in_rotation()
    if not cfg.rotation then
        return nil, nil
    end

    local count = MAX_ROTATION_SLOTS
    if count <= 0 then
        return nil, nil
    end

    if rotation_index < 1 or rotation_index > count then
        rotation_index = 1
    end

    local attempts = 0
    local idx = rotation_index

    while attempts < count do
        local slot = cfg.rotation[idx]
        if slot then
            sanitize_slot(slot)
            if slot.enabled then
                local name = avatar_list[slot.avatar_index]
                if name and #name > 0 then
                    rotation_index = (idx % count) + 1 -- advance pointer
                    return name, idx
                end
            end
        end
        idx = (idx % count) + 1
        attempts = attempts + 1
    end

    return nil, nil
end

local function schedule_next(delay_sec, new_state)
    next_action_time = os.clock() + (delay_sec or 0)
    state = new_state
end

-----------------------------------------------------------------------
-- Core automation logic
-----------------------------------------------------------------------
local function send_command(cmd)
    AshitaCore:GetChatManager():QueueCommand(1, cmd)
end

local function start_running()
    if running then return end
    running = true
    run_start_time = os.time()
    total_summons  = total_summons or 0
    total_releases = total_releases or 0

    rotation_index   = 1
    last_avatar_name = nil
    last_avatar_slot = nil

    schedule_next(0.5, 'summon')
    msg('Summoner skill-up: ON.')
end

local function stop_running()
    if not running then return end
    running = false
    if run_start_time > 0 then
        cumulative_run = cumulative_run + (os.time() - run_start_time)
    end
    run_start_time = 0
    state = 'idle'
    msg('Summoner skill-up: OFF.')
end

-----------------------------------------------------------------------
-- MP Rest helpers
-----------------------------------------------------------------------
local function begin_mp_rest()
    if mp_resting then
        return
    end
    mp_resting      = true
    mp_rest_started = os.time()

    msg('Not enough MP; starting /heal until MP is full.')
    send_command('/heal')

    -- Pause the skill-up state machine; it will resume after resting.
    state            = 'idle'
    next_action_time = 0
end

local function check_mp_rest()
    if not mp_resting then
        return
    end

    local mm = AshitaCore:GetMemoryManager()
    if not mm then return end

    local player = mm:GetPlayer()
    if not player then return end

    local curMP  = player:GetMP()
    local maxMP  = player:GetMaxMP()
    if maxMP <= 0 then
        return
    end

    -- Full MP (or very close) -> stand up and resume.
    if curMP >= maxMP then
        msg('MP full; stopping /heal and resuming skill-up.')
        send_command('/heal')   -- /heal toggled off
        mp_resting      = false
        mp_rest_started = 0
        schedule_next(1.0, 'summon')
    end
end

local function process_logic()
    -- If we are resting for MP, only check whether to stand up.
    if mp_resting then
        check_mp_rest()
        return
    end

    if not running then
        return
    end

    local now = os.clock()
    if next_action_time == 0 or now < next_action_time then
        return
    end

    -- State machine:
    -- summon       -> /ma "<Avatar>" <me> -> wait_release
    -- wait_release -> after stay_time     -> release
    -- release      -> /ja "Release" <me>  -> wait_summon
    -- wait_summon  -> after summon_delay  -> summon
    if state == 'summon' then
        local avatar_name, slot_index = get_next_avatar_in_rotation()
        if avatar_name and #avatar_name > 0 then
            last_avatar_name = avatar_name
            last_avatar_slot = slot_index
            send_command(string.format('/ma "%s" <me>', avatar_name))
            total_summons = total_summons + 1
            schedule_next(cfg.stay_time_sec or 10, 'wait_release')
        else
            msg('No valid avatars in rotation; stopping.')
            stop_running()
        end

    elseif state == 'wait_release' then
        schedule_next(0.5, 'release')

    elseif state == 'release' then
        send_command('/ja "Release" <me>')
        total_releases = total_releases + 1
        schedule_next(cfg.summon_delay_sec or 45, 'wait_summon')

    elseif state == 'wait_summon' then
        schedule_next(0.5, 'summon')

    else
        schedule_next(0.5, 'summon')
    end
end

-----------------------------------------------------------------------
-- Events: load / unload / command / text_in
-----------------------------------------------------------------------
ashita.events.register('load', 'smnskill_load', function()
    msg('Loaded. Use /smnskill on|off|toggle|status|ui on|off.')
end)

ashita.events.register('unload', 'smnskill_unload', function()
    if running and run_start_time > 0 then
        cumulative_run = cumulative_run + (os.time() - run_start_time)
    end
    running = false
end)

ashita.events.register('command', 'smnskill_command', function(e)
    local args = e.command and e.command:args() or {}
    if #args == 0 then return end

    local cmd = args[1]:lower()
    if cmd ~= '/smnskill' then
        return
    end
    e.blocked = true

    local sub = (args[2] or ''):lower()

    if sub == 'on' or sub == 'start' then
        start_running()
        return
    elseif sub == 'off' or sub == 'stop' then
        stop_running()
        return
    elseif sub == 'toggle' or sub == '' then
        if running then
            stop_running()
        else
            start_running()
        end
        return
    elseif sub == 'status' then
        local rt = get_runtime()
        local h, m, s = seconds_to_hms(rt)
        local rot = get_rotation_summary()
        msg(string.format(
            'Status: %s | Last Avatar=%s | Summons=%d, Releases=%d | Runtime=%02dh %02dm %02ds | Rotation=%s',
            (running and 'RUNNING' or 'paused'),
            last_avatar_name or 'n/a',
            total_summons or 0,
            total_releases or 0,
            h, m, s,
            rot
        ))
        return
    elseif sub == 'ui' and args[3] ~= nil then
        cfg.show_ui = (args[3]:lower() == 'on' or args[3]:lower() == 'true')
        msg('UI: ' .. (cfg.show_ui and 'ON' or 'OFF'))
        return
    elseif sub == 'quiet' and args[3] ~= nil then
        cfg.quiet = (args[3]:lower() == 'on' or args[3]:lower() == 'true')
        if not cfg.quiet then msg('quiet: OFF') end
        return
    end

    msg('Usage: /smnskill on|off|toggle|status|ui on|off|quiet on|off')
end)

-- Watch incoming chat for low-MP message.
ashita.events.register('text_in', 'smnskill_text_in', function(e)
    if e.blocked then
        return
    end

    local msg_raw = e.message or ''
    if msg_raw == '' then
        return
    end

    -- Strip color codes.
    local text = msg_raw:gsub('\030.', ''):gsub('\031.', '')

    -- Example line: "<Name> does not have enough MP to cast <Spell>."
    if text:find('does not have enough MP', 1, true) then
        begin_mp_rest()
    end
end)

-----------------------------------------------------------------------
-- ImGui UI helpers
-----------------------------------------------------------------------
local _ImGuiCond_Once              = _G.ImGuiCond_Once or 0
local _ImGuiWindowFlags_NoCollapse = _G.ImGuiWindowFlags_NoCollapse or 0

local function feature_header(text)
    imgui.Separator()
    imgui.Text(text)
end

local function feature_footer()
    imgui.Separator()
end

-----------------------------------------------------------------------
-- d3d_present: drive both logic and UI
-----------------------------------------------------------------------
ashita.events.register('d3d_present', 'smnskill_present', function()
    -- Drive the automation state machine (and MP rest check).
    process_logic()

    if not cfg.show_ui then
        return
    end

    -- Cursor fix so ImGui can draw its own cursor.
    do
        local ok, io = pcall(imgui.GetIO)
        if ok and io then
            pcall(function()
                io.MouseDrawCursor = true
                local NO_CURSOR_CHANGE = _G.ImGuiConfigFlags_NoMouseCursorChange
                    or (bit and bit.lshift and bit.lshift(1, 5))
                    or 32
                if io.ConfigFlags and bit and bit.band and bit.bnot then
                    io.ConfigFlags = bit.band(io.ConfigFlags, bit.bnot(NO_CURSOR_CHANGE))
                end
            end)
        end
    end

    imgui.SetNextWindowSize({ 480, 440 }, _ImGuiCond_Once)
    if imgui.Begin('SMN Skill-Up', true, _ImGuiWindowFlags_NoCollapse or 0) then
        if imgui.BeginTabBar('smnskillTabs') then

            ------------------------------------------------------------------
            -- HOME TAB
            ------------------------------------------------------------------
            if imgui.BeginTabItem('Home##smn_home') then
                feature_header('Run Control')
                if imgui.Button(running and 'Stop##smn_stop' or 'Start##smn_start') then
                    if running then
                        stop_running()
                    else
                        start_running()
                    end
                end
                imgui.SameLine()
                local qv = { cfg.quiet }
                if imgui.Checkbox('Quiet (suppress /echo)', qv) then
                    cfg.quiet = qv[1]
                end
                feature_footer()

                ------------------------------------------------------------------
                -- AVATAR ROTATION CONFIG
                ------------------------------------------------------------------
                feature_header('Avatar Selection (Rotation)')
                imgui.Text('Configure up to 7 avatars in the order you want them summoned.')
                imgui.Text('Only enabled slots are used; order is Slot 1 → Slot 7, then wrap.')
                imgui.Separator()

                for slot_idx = 1, MAX_ROTATION_SLOTS do
                    local slot = cfg.rotation[slot_idx]
                    if not slot then
                        slot = { enabled = false, avatar_index = 1 }
                        cfg.rotation[slot_idx] = slot
                    end
                    sanitize_slot(slot)

                    imgui.PushID(slot_idx)

                    local enabled = { slot.enabled }
                    if imgui.Checkbox(string.format('Slot %d##smn_slot_enabled_%d', slot_idx, slot_idx), enabled) then
                        slot.enabled = enabled[1]
                    end
                    imgui.SameLine()

                    local avatar_name = avatar_list[slot.avatar_index] or 'Select...'
                    if imgui.BeginCombo(string.format('##smn_slot_avatar_%d', slot_idx), avatar_name) then
                        for i, name in ipairs(avatar_list) do
                            local is_selected = (i == slot.avatar_index)
                            if imgui.Selectable(string.format('%s##smn_avatar_%d_%d', name, slot_idx, i), is_selected) then
                                slot.avatar_index = i
                            end
                            if is_selected then
                                imgui.SetItemDefaultFocus()
                            end
                        end
                        imgui.EndCombo()
                    end

                    imgui.PopID()
                end
                feature_footer()

                ------------------------------------------------------------------
                -- TIMING
                ------------------------------------------------------------------
                feature_header('Timing')
                local summon_delay = { cfg.summon_delay_sec or 45 }
                if imgui.InputInt('Delay between summons (sec)##smn_summon_delay', summon_delay) then
                    if summon_delay[1] < 5 then summon_delay[1] = 5 end
                    if summon_delay[1] > 600 then summon_delay[1] = 600 end
                    cfg.summon_delay_sec = summon_delay[1]
                end

                local stay_time = { cfg.stay_time_sec or 10 }
                if imgui.InputInt('Avatar stay time before Release (sec)##smn_stay_time', stay_time) then
                    if stay_time[1] < 1 then stay_time[1] = 1 end
                    if stay_time[1] > 300 then stay_time[1] = 300 end
                    cfg.stay_time_sec = stay_time[1]
                end
                feature_footer()

                ------------------------------------------------------------------
                -- STATUS
                ------------------------------------------------------------------
                feature_header('Status')
                local rt = get_runtime()
                local h, m, s = seconds_to_hms(rt)
                imgui.Text(string.format('State: %s', running and 'RUNNING' or 'Paused'))
                imgui.Text(string.format('Last avatar summoned: %s (slot %s)',
                    last_avatar_name or 'n/a',
                    last_avatar_slot and tostring(last_avatar_slot) or 'n/a'))
                imgui.Text(string.format('Rotation: %s', get_rotation_summary()))
                imgui.Text(string.format('Summons cast this session: %d', total_summons or 0))
                imgui.Text(string.format('Releases this session: %d', total_releases or 0))
                imgui.Text(string.format('Runtime: %02dh %02dm %02ds', h, m, s))

                if mp_resting then
                    local rest_dur = os.time() - (mp_rest_started or os.time())
                    imgui.Text(string.format('MP Resting: YES (%ds so far)', rest_dur))
                else
                    imgui.Text('MP Resting: NO')
                end
                feature_footer()

                imgui.EndTabItem()
            end

            ------------------------------------------------------------------
            -- CONFIG TAB
            ------------------------------------------------------------------
            if imgui.BeginTabItem('Config##smn_config') then
                feature_header('UI')
                local show = { cfg.show_ui }
                if imgui.Checkbox('Show SMN Skill-Up UI', show) then
                    cfg.show_ui = show[1]
                end
                feature_footer()

                feature_header('Chat')
                local qv2 = { cfg.quiet }
                if imgui.Checkbox('Quiet (suppress /echo messages)', qv2) then
                    cfg.quiet = qv2[1]
                end
                feature_footer()

                imgui.TextDisabled(string.format('Addon version: %s', addon.version or 'n/a'))
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
    end
    imgui.End()
end)