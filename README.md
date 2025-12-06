# **smnskill -- Summoner Skill-Up Addon**

Automates safe, human-like Summoner skill-ups on *HorizonXI* by rotating
avatars, releasing them, and resting when MP is low.\
All actions use randomized timing to mimic natural gameplay and avoid
spam.

------------------------------------------------------------------------

## **📁 Installation**

### **1. Locate your HorizonXI addon directory**

Addons for HorizonXI are stored in:

    <Your HorizonXI Folder>\Game\addons\

Example default:

    C:\HorizonXI\Game\addons\

------------------------------------------------------------------------

### **2. Create the addon folder**

Inside `addons`, create:

    smnskill

Full path example:

    C:\HorizonXI\Game\addons\smnskill\

------------------------------------------------------------------------

### **3. Add the Lua file**

Place `smnskill.lua` into the folder:

    C:\HorizonXI\Game\addons\smnskill\smnskill.lua

Folder structure:

    smnskill
     ├── smnskill.lua
     └── README.md   (optional)

------------------------------------------------------------------------

## **🎮 Loading the Addon In-Game**

1.  Launch FFXI
2.  Type:
    /addon load smnskill

You should see:

    [smnskill] Loaded. Use /smnskill on|off|toggle|status.

------------------------------------------------------------------------

## **🔌 Unloading**

    /addon unload smnskill

------------------------------------------------------------------------

## **⚙️ Usage Commands**

### **Start**

    /smnskill on

### **Stop**

    /smnskill off

### **Status**

    /smnskill status

------------------------------------------------------------------------

## **🖥️ UI Tabs**

### **Home**

-   Start/Stop control
-   Current avatar
-   Runtime
-   MP Rest status
-   Rest duration (current or last)

------------------------------------------------------------------------

## **❗ Troubleshooting**

### Addon doesn't load

Check the exact required path:

    <Your HorizonXI Folder>\Game\addons\smnskill\smnskill.lua

### Lua errors

Send: - The line number\
- The error text\
- Screenshot

I'll patch it immediately.

