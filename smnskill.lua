-- smnskill.lua
-- Author : Kezo
-- Desc   : Repeatedly summons and releases avatars on configurable and random timers.
--          Rotates through up to 7 chosen avatars in any order.
--          MP rest logic uses configurable random timers (v1.0.0).

addon.name    = 'smnskill'
addon.author  = 'Kezo'
addon.version = '1.0.0'
addon.desc    = 'Summoner skill-up helper with avatar rotation and random timed MP rest.'

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
    show_ui  = true,
    quiet    = true,

    -- Random delay between /ja "Release" and the next summon.
    summon_delay_min_sec = 1,
    summon_delay_max_sec = 7,

    -- Random time the avatar stays out before we /ja "Release".
    stay_time_min_sec = 7,
    stay_time_max_sec = 10,

    -- How long to rest after "does not have enough MP":
    -- random value each time we /heal.
    rest_timeout_min_sec = 60,
    rest_timeout_max_sec = 115,

    -- Additional random delay BEFORE actually issuing /heal when out of MP.
    -- Random value between min/max each time the MP error occurs.
    heal_delay_min_sec = 1,
    heal_delay_max_sec = 5,

    rotation = {
        { enabled = true,  avatar_index = 1 },
        { enabled = true,  avatar_index = 2 },
        { enabled = true,  avatar_index = 3 },
        { enabled = true,  avatar_index = 4 },
        { enabled = true,  avatar_index = 5 },
        { enabled = true,  avatar_index = 6 },
        { enabled = true,  avatar_index = 7 },
    },
}

-----------------------------------------------------------------------
-- Runtime state
-----------------------------------------------------------------------
local running           = false
local state             = 'idle'
local next_action_time  = 0
local total_summons     = 0
local total_releases    = 0
local run_start_time    = 0
local cumulative_run    = 0
local rotation_index    = 1
local last_avatar_name  = nil
local last_avatar_slot  = nil

-- MP rest state
local mp_resting        = false
local mp_rest_started   = 0
local mp_rest_target    = 0  -- target duration (seconds) for the current rest

-- Pre-heal delay state
local mp_heal_pending       = false
local mp_heal_start_time    = 0
local mp_heal_delay_target  = 0

-- Last rolled random values (for UI "Current" column)
local last_summon_delay   = 0
local last_stay_time      = 0
local last_rest_duration  = 0
local last_heal_delay     = 0

-- UI state
local window_initialized  = false

-----------------------------------------------------------------------
-- Utility helpers
-----------------------------------------------------------------------
local function msg(s)
    if cfg.quiet then return end
    AshitaCore:GetChatManager():QueueCommand(1, '/echo [smnskill] ' .. tostring(s))
end

-- NOTE: defined here so all other helpers can see it.
local function send_command(cmd)
    AshitaCore:GetChatManager():QueueCommand(1, cmd)
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

local function sanitize_slot(slot)
    if not slot then return end
    if slot.avatar_index < 1 then
        slot.avatar_index = 1
    end
    if slot.avatar_index > #avatar_list then
        slot.avatar_index = #avatar_list
    end
end

local function get_rotation_summary()
    local parts = {}
    for i = 1, MAX_ROTATION_SLOTS do
        local slot = cfg.rotation[i]
        if slot and slot.enabled then
            sanitize_slot(slot)
            table.insert(parts, string.format('%d:%s', i, avatar_list[slot.avatar_index]))
        end
    end
    return (#parts == 0) and '(none)' or table.concat(parts, ' -> ')
end

local function get_next_avatar_in_rotation()
    local count = MAX_ROTATION_SLOTS
    if rotation_index < 1 or rotation_index > count then
        rotation_index = 1
    end

    local attempts = 0
    local idx = rotation_index

    while attempts < count do
        local slot = cfg.rotation[idx]
        if slot and slot.enabled then
            sanitize_slot(slot)
            local name = avatar_list[slot.avatar_index]
            rotation_index = (idx % count) + 1
            return name, idx
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
-- Random timing helpers
-----------------------------------------------------------------------
local function roll_summon_delay()
    local min = cfg.summon_delay_min_sec or 5
    local max = cfg.summon_delay_max_sec or min

    if min < 1 then min = 1 end
    if max < min then max = min end
    if max > 60 then max = 60 end

    cfg.summon_delay_min_sec = min
    cfg.summon_delay_max_sec = max

    local value = math.random(min, max)
    last_summon_delay = value
    return value
end

local function roll_stay_time()
    local min = cfg.stay_time_min_sec or 7
    local max = cfg.stay_time_max_sec or min

    if min < 1 then min = 1 end
    if max < min then max = min end
    if max > 60 then max = 60 end

    cfg.stay_time_min_sec = min
    cfg.stay_time_max_sec = max

    local value = math.random(min, max)
    last_stay_time = value
    return value
end

-----------------------------------------------------------------------
-- MP Rest helpers (Random Timer)
-----------------------------------------------------------------------
local function normalize_rest_range()
    local min = cfg.rest_timeout_min_sec or 60
    local max = cfg.rest_timeout_max_sec or 120

    if min < 10 then min = 10 end
    if max < min then max = min end
    if max > 600 then max = 600 end

    cfg.rest_timeout_min_sec = min
    cfg.rest_timeout_max_sec = max
    return min, max
end

local function begin_mp_rest()
    -- Called once we actually decide to /heal.
    local min, max = normalize_rest_range()
    mp_rest_target  = math.random(min, max)
    mp_resting      = true
    mp_rest_started = os.time()
    last_rest_duration = mp_rest_target

    msg(string.format(
        'Not enough MP; starting /heal for about %d seconds (rest %d–%d).',
        mp_rest_target, min, max
    ))

    send_command('/heal')
    -- Pause the normal state machine while resting.
    state = 'idle'
    next_action_time = 0
end

local function check_mp_rest()
    if not mp_resting then
        return
    end

    if mp_rest_target <= 0 then
        local min, max = normalize_rest_range()
        mp_rest_target = math.random(min, max)
        last_rest_duration = mp_rest_target
    end

    local rest_dur = os.time() - (mp_rest_started or os.time())

    if rest_dur >= mp_rest_target then
        msg(string.format(
            'Rest timer done (%ds / %ds). Stopping /heal and resuming.',
            rest_dur,
            mp_rest_target
        ))
        -- Toggle /heal off.
        send_command('/heal')

        mp_resting      = false
        mp_rest_started = 0
        mp_rest_target  = 0

        -- Resume using the Cast Summon random timer.
        local delay = roll_summon_delay()
        schedule_next(delay, 'wait_summon')
    end
end

-----------------------------------------------------------------------
-- Pre-heal delay helpers (Random Timer)
-----------------------------------------------------------------------
local function normalize_heal_delay_range()
    local min = cfg.heal_delay_min_sec or 0
    local max = cfg.heal_delay_max_sec or 0

    if min < 0 then min = 0 end
    if max < min then max = min end
    if max > 60 then max = 60 end  -- pre-heal delay capped at 60s

    cfg.heal_delay_min_sec = min
    cfg.heal_delay_max_sec = max
    return min, max
end

local function begin_mp_heal_delay()
    if mp_resting or mp_heal_pending then
        return
    end

    local min, max = normalize_heal_delay_range()

    -- If no delay configured (0–0), just go straight into rest.
    if max <= 0 then
        last_heal_delay = 0
        begin_mp_rest()
        return
    end

    mp_heal_delay_target = math.random(min, max)
    mp_heal_pending      = true
    mp_heal_start_time   = os.time()
    last_heal_delay      = mp_heal_delay_target

    msg(string.format(
        'Not enough MP; waiting about %d seconds before /heal (delay %d–%d).',
        mp_heal_delay_target, min, max
    ))
end

local function check_mp_heal_delay()
    if not mp_heal_pending then
        return
    end

    if mp_heal_delay_target <= 0 then
        local min, max = normalize_heal_delay_range()
        if max <= 0 then
            mp_heal_pending = false
            last_heal_delay = 0
            begin_mp_rest()
            return
        end
        mp_heal_delay_target = math.random(min, max)
        last_heal_delay      = mp_heal_delay_target
    end

    local elapsed = os.time() - (mp_heal_start_time or os.time())
    if elapsed >= mp_heal_delay_target then
        mp_heal_pending      = false
        mp_heal_start_time   = 0
        -- Now actually go into /heal + rest timer.
        begin_mp_rest()
    end
end

-----------------------------------------------------------------------
-- Processing logic
-----------------------------------------------------------------------
local function start_running()
    if running then return end
    running = true
    run_start_time = os.time()
    rotation_index = 1
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

local function process_logic()
    -- Pre-heal delay first.
    if mp_heal_pending then
        check_mp_heal_delay()
        return
    end

    -- Then rest timer.
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

    if state == 'summon' then
        local avatar_name, slot_index = get_next_avatar_in_rotation()
        if not avatar_name then
            msg('No valid avatars in rotation; stopping.')
            stop_running()
            return
        end

        last_avatar_name = avatar_name
        last_avatar_slot = slot_index
        send_command(string.format('/ma "%s" <me>', avatar_name))
        total_summons = total_summons + 1

        local stay_time = roll_stay_time()
        schedule_next(stay_time, 'wait_release')

    elseif state == 'wait_release' then
        schedule_next(0.5, 'release')

    elseif state == 'release' then
        send_command('/ja "Release" <me>')
        total_releases = total_releases + 1

        local delay = roll_summon_delay()
        schedule_next(delay, 'wait_summon')

    elseif state == 'wait_summon' then
        schedule_next(0.5, 'summon')

    else
        schedule_next(0.5, 'summon')
    end
end

-----------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------
ashita.events.register('load', 'smnskill_load', function()
    -- Light seeding to avoid totally deterministic rest patterns.
    math.randomseed(os.time() % 100000)
    msg('Loaded. Use /smnskill on|off|toggle|status.')
end)

ashita.events.register('unload', 'smnskill_unload', function()
    if running and run_start_time > 0 then
        cumulative_run = cumulative_run + (os.time() - run_start_time)
    end
end)

ashita.events.register('command', 'smnskill_command', function(e)
    local args = e.command:args()
    if args[1] ~= '/smnskill' then
        return
    end
    e.blocked = true

    local sub = (args[2] or ''):lower()

    if sub == 'on' or sub == 'start' then
        start_running()
    elseif sub == 'off' or sub == 'stop' then
        stop_running()
    elseif sub == 'toggle' or sub == '' then
        if running then
            stop_running()
        else
            start_running()
        end
    elseif sub == 'status' then
        local rt = get_runtime()
        local h, m, s = seconds_to_hms(rt)
        msg(string.format(
            'Status: %s | Last=%s | Runtime=%02dh%02dm%02ds',
            running and 'RUNNING' or 'paused',
            last_avatar_name or 'n/a',
            h, m, s
        ))
    else
        msg('Usage: /smnskill [on|off|toggle|status]')
    end
end)

-- Listen for MP errors
ashita.events.register('text_in', 'smn_text_in', function(e)
    if e.blocked then
        return
    end
    local msg_clean = e.message:gsub('\030.', ''):gsub('\031.', '')
    if msg_clean:find('does not have enough MP', 1, true) then
        begin_mp_heal_delay()
    end
end)

-----------------------------------------------------------------------
-- UI + render loop
-----------------------------------------------------------------------
ashita.events.register('d3d_present', 'smn_present', function()
    process_logic()
    if not cfg.show_ui then
        return
    end

    local ok, io = pcall(imgui.GetIO)
    if ok and io then
        io.MouseDrawCursor = true
    end

    -- Only set the default size on first open; let user resizing stick.
    if not window_initialized then
        imgui.SetNextWindowSize({ 500, 480 })
        window_initialized = true
    end

    if imgui.Begin('SMN Skill-Up', true) then
        if imgui.BeginTabBar('tabs') then

            ----------------------------------------------------------
            -- HOME TAB
            ----------------------------------------------------------
            if imgui.BeginTabItem('Home##home') then
                imgui.Separator()
                imgui.Text('Run Control')
                if imgui.Button(running and 'Stop' or 'Start') then
                    if running then
                        stop_running()
                    else
                        start_running()
                    end
                end

                imgui.Separator()
                imgui.Text('Status')
                local rt = get_runtime()
                local h, m, s = seconds_to_hms(rt)
                imgui.Text('State: ' .. (running and 'RUNNING' or 'Paused'))
                imgui.Text('Current Avatar: ' .. (last_avatar_name or 'n/a'))
                imgui.Text(string.format('Runtime: %02dh %02dm %02ds', h, m, s))
                imgui.Text('MP Resting: ' .. (mp_resting and 'YES' or 'NO'))

                -- Rest duration status on Home tab
                local rest_status
                if mp_resting then
                    local elapsed = os.time() - (mp_rest_started or os.time())
                    if mp_rest_target > 0 then
                        rest_status = string.format('%ds / %ds (resting)', elapsed, mp_rest_target)
                    else
                        rest_status = string.format('%ds (resting)', elapsed)
                    end
                elseif last_rest_duration > 0 then
                    rest_status = string.format('%ds (last)', last_rest_duration)
                else
                    rest_status = '—'
                end
                imgui.Text('Rest duration: ' .. rest_status)

                imgui.EndTabItem()
            end

            ----------------------------------------------------------
            -- AVATAR TAB
            ----------------------------------------------------------
            if imgui.BeginTabItem('Avatar##avatar') then
                imgui.Separator()
                imgui.Text('Avatar Rotation')
                imgui.Text('Enable / configure up to 7 avatars in the order you want them summoned.')

                for i = 1, MAX_ROTATION_SLOTS do
                    local slot = cfg.rotation[i]
                    imgui.PushID(i)

                    local enabled = { slot.enabled }
                    if imgui.Checkbox(string.format('Slot %d', i), enabled) then
                        slot.enabled = enabled[1]
                    end

                    imgui.SameLine()
                    imgui.SetNextItemWidth(150)
                    if imgui.BeginCombo('##avatar' .. i, avatar_list[slot.avatar_index]) then
                        for j, name in ipairs(avatar_list) do
                            if imgui.Selectable(name, slot.avatar_index == j) then
                                slot.avatar_index = j
                            end
                        end
                        imgui.EndCombo()
                    end

                    imgui.PopID()
                end
            
                imgui.EndTabItem()
            end

            ----------------------------------------------------------
            -- TIMER TAB
            ----------------------------------------------------------
            if imgui.BeginTabItem('Timer##timer') then
                imgui.Separator()
                imgui.Text('Random Timers')
                imgui.TextWrapped(
                    'Each timer rolls a random value between Min and Max (seconds). ' ..
                    'Current shows the value in use or last used for that action.'
                )
                imgui.Dummy({ 0, 4 })

                -- 4-column table:  Timer | Min | Max | Current
                if imgui.BeginTable('timer_table', 4) then
                    imgui.TableSetupColumn('Timer')
                    imgui.TableSetupColumn('Min (s)')
                    imgui.TableSetupColumn('Max (s)')
                    imgui.TableSetupColumn('Current')
                    imgui.TableHeadersRow()

                    local function timer_row(label, min_key, max_key, def_min, def_max, clamp_min, clamp_max, current_text)
                        imgui.TableNextRow()

                        -- Column 0: label
                        imgui.TableSetColumnIndex(0)
                        imgui.Text(label)

                        -- Column 1: Min
                        imgui.TableSetColumnIndex(1)
                        local minv = { cfg[min_key] or def_min }
                        imgui.SetNextItemWidth(80)
                        if imgui.InputInt('##' .. min_key, minv) then
                            if minv[1] < clamp_min then minv[1] = clamp_min end
                            if minv[1] > clamp_max then minv[1] = clamp_max end
                            cfg[min_key] = minv[1]
                            if not cfg[max_key] or cfg[max_key] < cfg[min_key] then
                                cfg[max_key] = cfg[min_key]
                            end
                        end

                        -- Column 2: Max
                        imgui.TableSetColumnIndex(2)
                        local maxv = { cfg[max_key] or def_max }
                        imgui.SetNextItemWidth(80)
                        if imgui.InputInt('##' .. max_key, maxv) then
                            if maxv[1] < clamp_min then maxv[1] = clamp_min end
                            if maxv[1] > clamp_max then maxv[1] = clamp_max end
                            cfg[max_key] = maxv[1]
                            if cfg[max_key] < cfg[min_key] then
                                cfg[min_key] = cfg[max_key]
                            end
                        end

                        -- Column 3: Current info
                        imgui.TableSetColumnIndex(3)
                        imgui.Text(current_text)
                    end

                    -- Row 1: Summon delay
                    local summon_current = (last_summon_delay > 0)
                        and string.format('%ds (last)', last_summon_delay)
                        or '—'

                    timer_row(
                        'Cast Summon',
                        'summon_delay_min_sec', 'summon_delay_max_sec',
                        1, 7,                   -- defaults
                        1, 60,                  -- clamp range
                        summon_current
                    )

                    -- Row 2: Avatar stay time
                    local stay_current = (last_stay_time > 0)
                        and string.format('%ds (last)', last_stay_time)
                        or '—'

                    timer_row(
                        'Avatar release',
                        'stay_time_min_sec', 'stay_time_max_sec',
                        7, 10,                  -- defaults
                        1, 60,                 -- clamp range
                        stay_current
                    )

                    -- Row 3: Delay before /heal
                    local heal_current
                    if (cfg.heal_delay_min_sec or 0) == 0 and (cfg.heal_delay_max_sec or 0) == 0 then
                        heal_current = 'off'
                    elseif mp_heal_pending then
                        heal_current = string.format('%ds (pending)', mp_heal_delay_target or last_heal_delay or 0)
                    elseif last_heal_delay > 0 then
                        heal_current = string.format('%ds (last)', last_heal_delay)
                    else
                        heal_current = '—'
                    end

                    timer_row(
                        'Pre rest delay',
                        'heal_delay_min_sec', 'heal_delay_max_sec',
                        1, 5,                  -- defaults
                        0, 60,                 -- clamp range
                        heal_current
                    )

                    -- Row 4: Rest duration while /heal
                    local rest_current
                    if mp_resting then
                        rest_current = string.format('%ds (target)', mp_rest_target or last_rest_duration or 0)
                    elseif last_rest_duration > 0 then
                        rest_current = string.format('%ds (last)', last_rest_duration)
                    else
                        rest_current = '—'
                    end

                    timer_row(
                        'Rest duration',
                        'rest_timeout_min_sec', 'rest_timeout_max_sec',
                        60, 115,               -- defaults
                        10, 600,               -- clamp range
                        rest_current
                    )

                    imgui.EndTable()
                end

                imgui.EndTabItem()
            end

            ----------------------------------------------------------
            -- CONFIG TAB
            ----------------------------------------------------------
            if imgui.BeginTabItem('Config##cfg') then
                local ui = { cfg.show_ui }
                if imgui.Checkbox('Show UI', ui) then
                    cfg.show_ui = ui[1]
                end

                local q = { cfg.quiet }
                if imgui.Checkbox('Quiet Mode (suppress /echo)', q) then
                    cfg.quiet = q[1]
                end

                imgui.Text('Version: ' .. addon.version)

                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end

        imgui.End()
    end
end)
