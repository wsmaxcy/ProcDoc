-- ProcDoc.lua
-- Pulsing proc alerts for World of Warcraft: Forever.

local ADDON_NAME = ...
local IMG = "Interface\\AddOns\\ProcDoc\\img\\"
local ICON = "Interface\\AddOns\\ProcDoc\\ProcDoc_Icon"   -- tools/make_icon.py

-- Forward declarations (assigned further down; referenced by earlier closures)
local Initialize, OpenOptions, RefreshOptions, ToggleOptions
local CheckProcs, CheckAllActionProcs, ExpireActionProc, SampleDuration

-- 1) SavedVariables initialization
--    Defaults for ProcDocDB.globalVars. `G` always points at the live settings
--    table (the defaults until ADDON_LOADED, then ProcDocDB.globalVars itself).
local DEFAULTS = {
    minAlpha            = 0.8,
    maxAlpha            = 1.0,
    minScale            = 0.9,
    maxScale            = 1.0,
    pulseSpeed          = 0.4,
    popEnabled          = true,
    popStrength         = 1.7,
    exitEnabled         = true,
    masterScale         = 1.0,
    topOffset           = 70,
    sideOffset          = 60,
    timerTextAlpha      = 0.85,
    timerTextSize       = 26,
    timerFont           = "FRIZ",
    timerOutline        = "THICKOUTLINE",
    timerColor          = "gold",
    timerLowColor       = "red",
    timerLowThreshold   = 3,
    timerDecimals       = true,
    disableTimers       = false,
    isMuted             = false,
    defaultSound        = "alert1",
    soundChannel        = "Master",
    autoDetect          = true,
    hideBlizzardOverlay = false,
    menuSide            = "LEFT",
    menuScale           = 1.0,
    minimapHide         = false,
    minimapAngle        = 220,
}

local G = {}
for k, v in pairs(DEFAULTS) do G[k] = v end

local playerClass
local PS_EMPTY = {}

local function ProcDoc_EnsureDB()
    if type(ProcDocDB) ~= "table" then ProcDocDB = {} end
    ProcDocDB.globalVars          = ProcDocDB.globalVars or {}
    ProcDocDB.procsEnabled        = ProcDocDB.procsEnabled or {}          -- legacy (pre-4.0), migrated
    ProcDocDB.actionProcDurations = ProcDocDB.actionProcDurations or {}   -- legacy (pre-4.0), migrated
    ProcDocDB.procSettings        = ProcDocDB.procSettings or {}          -- [class][procKey] = {...}
    ProcDocDB.detected            = ProcDocDB.detected or {}              -- [class][spellID] = {...}
    ProcDocDB.custom              = ProcDocDB.custom or {}                -- [class][procKey] = { name, spellID }
    ProcDocDB.learned             = ProcDocDB.learned or {}               -- [class][procKey] = { [spellID] = true }
    ProcDocDB.stackMax            = ProcDocDB.stackMax or {}              -- [class][procKey] = highest stacks seen
    ProcDocDB.seen                = ProcDocDB.seen or {}                  -- [class][procKey] = true once the buff was read
    ProcDocDB.cdmTips             = ProcDocDB.cdmTips or {}               -- [class][procKey] = true once the Cooldown Manager tip was shown
end

local function ProcDoc_LoadGlobalsFromDB()
    ProcDoc_EnsureDB()
    local gv = ProcDocDB.globalVars
    if gv.maxSize and not gv.maxScale then gv.maxScale = gv.maxSize end
    gv.maxSize, gv.soundVolume, gv.alphaStep = nil, nil, nil
    for k, v in pairs(DEFAULTS) do
        if gv[k] == nil then gv[k] = v end
    end
    G = gv
end

-- Per-proc settings live under the player's class so procs that share a name
-- across classes (Clearcasting) can be customised independently.
local function ClassSettings()
    ProcDoc_EnsureDB()
    local t = ProcDocDB.procSettings[playerClass]
    if not t then
        t = {}
        ProcDocDB.procSettings[playerClass] = t
    end
    return t
end

-- Read-only view of a proc's settings (never creates an entry)
local function PS(key)
    local all = ProcDocDB and ProcDocDB.procSettings
    local cls = all and playerClass and all[playerClass]
    return (cls and cls[key]) or PS_EMPTY
end

-- Writable settings for a proc (creates the entry on demand)
local function PSW(key)
    local t = ClassSettings()
    local s = t[key]
    if not s then
        s = {}
        t[key] = s
    end
    return s
end

local initFrame = CreateFrame("Frame", "ProcDocDBInitFrame", UIParent)
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        ProcDoc_LoadGlobalsFromDB()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        ProcDoc_LoadGlobalsFromDB()
        Initialize()
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

-- Debug helper to print current DB values (in-game: /run ProcDoc_DumpDB())
function ProcDoc_DumpDB()
    if not ProcDocDB or not ProcDocDB.globalVars then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ProcDoc|r: DB not initialized yet.")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96ProcDoc DB Dump|r")
    local keys = {}
    for k in pairs(ProcDocDB.globalVars) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. k .. " = " .. tostring(ProcDocDB.globalVars[k]))
    end
    local cls = playerClass and ProcDocDB.procSettings[playerClass]
    if cls then
        for key, s in pairs(cls) do
            local parts = {}
            for k, v in pairs(s) do parts[#parts + 1] = k .. "=" .. tostring(v) end
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. key .. "] " .. table.concat(parts, " "))
        end
    end
end

-- 2) Main addon frame and client API compatibility
--    WoW Forever (TOC 16xxx) runs the modern engine: most legacy globals are gone
--    (UnitBuff, GetSpellInfo, GetSpellName...) and some values can be "secret"
--    in combat. Every client call that moved goes through a shim here.
local ProcDoc = CreateFrame("Frame", "ProcDocAlertFrame", UIParent)

local TOC        = select(4, GetBuildInfo()) or 0
local IS_FOREVER = TOC >= 16000 and TOC < 20000

local issecret = _G.issecretvalue or function() return false end
-- Secret values can't even be compared (== / ~= / truthiness raise errors),
-- so the secret check must come first, before any other use of the value.
local function Readable(v)
    if issecret(v) then return false end
    return v ~= nil
end

-- Returns v, or nil when it's secret
local function Clean(v)
    if issecret(v) then return nil end
    return v
end

local function SafeCall(fn, ...)
    if not fn then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

-- Returns true when the event was registered filtered to `unit`
local function SafeRegister(frame, event, unit)
    if unit and frame.RegisterUnitEvent then
        if pcall(frame.RegisterUnitEvent, frame, event, unit) then return true end
    end
    pcall(frame.RegisterEvent, frame, event)
    return false
end

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
-- The release packager replaces @project-version@ in the TOC with the tag
-- (e.g. "v4.2.0"); a copy that wasn't packaged shows as "dev".
local VERSION = (GetMeta and SafeCall(GetMeta, "ProcDoc", "Version")) or "dev"
if type(VERSION) ~= "string" or VERSION:find("@", 1, true) then VERSION = "dev" end
VERSION = (VERSION:gsub("^[vV]", ""))

local function GetSpellNameCompat(spell)
    if not Readable(spell) then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local n = Clean(SafeCall(C_Spell.GetSpellName, spell))
        if n then return n end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = Clean(SafeCall(C_Spell.GetSpellInfo, spell))
        if type(info) == "table" then
            local n = Clean(info.name)
            if n then return n end
        end
    end
    if _G.GetSpellInfo then
        return Clean((SafeCall(_G.GetSpellInfo, spell)))
    end
end

local function GetSpellIconCompat(spell)
    if not Readable(spell) then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        local t = Clean(SafeCall(C_Spell.GetSpellTexture, spell))
        if t then return t end
    end
    if _G.GetSpellTexture then
        return Clean((SafeCall(_G.GetSpellTexture, spell)))
    end
end

-- True while the client locks aura data (WoW Forever / modern engine, in
-- combat). Touching auras by index then raises "Auras cannot be accessed
-- when secret while tainted", so callers must not scan.
local function AurasRestricted()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, restricted = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and Clean(restricted) then return true end
    end
    return false
end

-- Returns exists, name, icon, count, duration, expirationTime, spellId, auraInstanceID.
-- `exists` is separate so the scan keeps going past auras whose fields are secret.
-- Returns nil, true when the client refused access (restricted).
local function GetPlayerBuff(i)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then return nil, true end
        if issecret(a) then return true end   -- exists, but nothing readable
        if not a then return nil end
        return true, a.name, a.icon, a.applications, a.duration, a.expirationTime, a.spellId, a.auraInstanceID
    end
    if _G.UnitBuff then
        local name, icon, count, _, duration, expirationTime, _, _, _, spellId = _G.UnitBuff("player", i)
        if name == nil then return nil end
        return true, name, icon, count, duration, expirationTime, spellId
    end
end

local function IsSpellUsableCompat(spell)
    if C_Spell and C_Spell.IsSpellUsable then
        return SafeCall(C_Spell.IsSpellUsable, spell)
    end
    if _G.IsUsableSpell then
        return SafeCall(_G.IsUsableSpell, spell)
    end
end

local function GetSpellCooldownCompat(spell)
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = Clean(SafeCall(C_Spell.GetSpellCooldown, spell))
        if type(cd) == "table" then return cd.startTime, cd.duration end
        return nil
    end
    if _G.GetSpellCooldown then
        return SafeCall(_G.GetSpellCooldown, spell)
    end
end

local function SetCVarCompat(name, value)
    if C_CVar and C_CVar.SetCVar then
        return SafeCall(C_CVar.SetCVar, name, value)
    end
    return SafeCall(_G.SetCVar, name, value)
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96ProcDoc|r " .. msg)
end

-- Printable form of a value that may be secret
local function SV(v)
    if issecret(v) then return "<secret>" end
    return tostring(v)
end

-- Detection trace (/procdoc trace): lines go to a ring buffer saved in
-- ProcDocDB.trace, so a missed proc can be diagnosed from the SavedVariables
-- file after a /reload. Identical consecutive lines are collapsed.
local traceState = { last = nil, count = 0 }
local function Trace(fmt, ...)
    if not G.trace then return end
    local log = ProcDocDB and ProcDocDB.trace
    if not log then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    if msg == traceState.last and #log > 0 then
        traceState.count = traceState.count + 1
        log[#log] = string.format("%.1f %s (x%d)", GetTime(), msg, traceState.count)
        return
    end
    traceState.last, traceState.count = msg, 1
    log[#log + 1] = string.format("%.1f %s", GetTime(), msg)
    if #log > 400 then table.remove(log, 1) end
    if G.traceEcho then Print("|cff999999" .. msg .. "|r") end
end

-- 3) Proc data tables
--
-- PROC_DATA    -- buff-based. Matched against the player's buffs by spell ID
--                 (`spellIDs`, locale independent) or by exact aura name
--                 (`buffName`). `minStacks` requires that many stacks.
-- ACTION_PROCS -- reaction abilities (usable only after a dodge/parry/block).
--                 `spellID` resolves the localized spell name; readiness comes
--                 from the spell's usability, so it does NOT need to be on an
--                 action bar (a bar slot is used when present). When Forever
--                 hides usability in combat, `reactOn` (UNIT_COMBAT unit ->
--                 actions) opens the window instead, and `cooldown` (seconds)
--                 stops false alerts right after a cast.
--
-- Forever hides the whole buff list from addons in combat (and gives addons
-- no combat log), so a buff proc that starts mid-fight can't be seen until
-- combat ends. Procs with a trigger the client does show in combat set
-- `predictOn` ("KILL": your killing blow on a non-trivial enemy;
-- "CRIT_TAKEN": you were crit) and `predictDuration`; they light up at the
-- trigger if the player
-- has the talent (`talent` name / `talentIDs`), and the first readable scan
-- after combat confirms or clears them.
--
-- These are the talent/ability reaction procs built into ProcDoc for WoW
-- Forever. Anything else Forever flags with a proc glow is caught at
-- runtime by "Auto-detect" (Blizzard's proc overlay events), and players can
-- track any other buff with "Add a proc" in the options (ProcDocDB.custom).
local PROC_DATA = {
    ["WARLOCK"] = {
        {
            buffName         = "Shadow Trance",   -- Nightfall
            spellIDs         = { 17941 },
            texture          = "Interface\\Icons\\Spell_Shadow_Twilight",
            alertTexturePath = IMG .. "FelOoze.tga",
            alertStyle       = "SIDES",
            consumedBy       = { "Shadow Bolt" },
            talent           = "Nightfall",
            talentIDs        = { 18094, 18095 }, -- the Cooldown Manager may list the talent
        },
    },
    ["MAGE"] = {
        {
            buffName         = "Clearcasting",    -- Arcane Concentration
            spellIDs         = { 12536 },
            texture          = "Interface\\Icons\\Spell_Shadow_ManaBurn",
            alertTexturePath = IMG .. "WhiteStarburst.tga",
            alertStyle       = "TOP",
            consumedBy       = "ANY",
        },
    },
    ["DRUID"] = {
        {
            buffName         = "Clearcasting",    -- Omen of Clarity
            spellIDs         = { 16870 },
            texture          = "Interface\\Icons\\Spell_Shadow_ManaBurn",
            alertTexturePath = IMG .. "WhiteStarburst.tga",
            alertStyle       = "TOP",
            consumedBy       = "ANY",
        },
        {
            buffName         = "Nature's Grace",
            spellIDs         = { 16886 },
            texture          = "Interface\\Icons\\Spell_Nature_NaturesBlessing",
            alertTexturePath = IMG .. "GreenVines.tga",
            alertStyle       = "SIDES",
            consumedBy       = "ANY",
        },
    },
    ["SHAMAN"] = {
        {
            buffName         = "Clearcasting",    -- Elemental Focus
            spellIDs         = { 16246 },
            texture          = "Interface\\Icons\\Spell_Shadow_ManaBurn",
            alertTexturePath = IMG .. "StormStones.tga",
            alertStyle       = "TOP",
            consumedBy       = "ANY",
        },
        {
            buffName         = "Flurry",
            spellIDs         = { 16257, 16277, 16278, 16279, 16280 },
            texture          = "Interface\\Icons\\Ability_GhoulFrenzy",
            alertTexturePath = IMG .. "DarkRedStreaks.tga",
            alertStyle       = "SIDES2",
        },
    },
    ["HUNTER"] = {
        {
            buffName         = "Quick Shots",     -- Improved Aspect of the Hawk
            spellIDs         = { 6150 },
            texture          = "Interface\\Icons\\Ability_Warrior_InnerRage",
            alertTexturePath = IMG .. "GoldenArrows.tga",
            alertStyle       = "SIDES",
        },
    },
    ["WARRIOR"] = {
        {
            buffName         = "Enrage",
            spellIDs         = { 12880, 14201, 14202, 14203, 14204 },
            texture          = "Interface\\Icons\\Spell_Shadow_UnholyFrenzy",
            alertTexturePath = IMG .. "BloodOrbs.tga",
            alertStyle       = "SIDES",
            talent           = "Enrage",
            talentIDs        = { 12317, 13045, 13046, 13047, 13048 },
            predictOn        = "CRIT_TAKEN",     -- every crit you take enrages you
            predictDuration  = 12,
        },
    },
    ["PRIEST"] = {
        -- No built-in reaction procs on Forever; auto-detect / "Add a proc" cover it.
    },
    ["PALADIN"] = {
        -- No built-in reaction procs on Forever; auto-detect / "Add a proc" cover it.
    },
    ["ROGUE"] = {
        {
            buffName         = "Remorseless",     -- Remorseless Attacks
            spellIDs         = { 14143, 14149 },
            texture          = "Interface\\Icons\\Ability_FeignDeath",
            alertTexturePath = IMG .. "SmallRedSlash.tga",
            alertStyle       = "SIDES",
            consumedBy       = { "Sinister Strike", "Backstab", "Hemorrhage", "Ambush", "Riposte", "Ghostly Strike" },
            talent           = "Remorseless Attacks",
            talentIDs        = { 14144, 14148 },
            predictOn        = "KILL",           -- your killing blow on a non-trivial enemy
            predictDuration  = 20,
        },
    },
}

local ACTION_PROCS = {
    ["ROGUE"] = {
        {
            buffName         = "Riposte",         -- after a parry
            spellName        = "Riposte",
            spellID          = 14251,
            reactOn          = { player = { PARRY = true } },
            cooldown         = 6,
            alertTexturePath = IMG .. "FlamingDagger.tga",
            alertStyle       = "LEFT",
        },
    },
    ["WARRIOR"] = {
        {
            buffName         = "Overpower",       -- after the target dodges
            spellName        = "Overpower",
            spellID          = 7384,
            reactOn          = { target = { DODGE = true } },
            cooldown         = 5,
            alertTexturePath = IMG .. "GlowingEyes.tga",
            alertStyle       = "TOP",
        },
        {
            buffName         = "Revenge",         -- after a block/dodge/parry
            spellName        = "Revenge",
            spellID          = 6572,
            reactOn          = { player = { BLOCK = true, DODGE = true, PARRY = true } },
            cooldown         = 5,
            alertTexturePath = IMG .. "GoldenFlameCrescent.tga",
            alertStyle       = "RIGHT",
        },
    },
    ["HUNTER"] = {
        {
            buffName         = "Counterattack",   -- after a parry (Survival talent)
            spellName        = "Counterattack",
            spellID          = 19306,
            reactOn          = { player = { PARRY = true } },
            cooldown         = 5,
            alertTexturePath = IMG .. "GoldenCrosshair.tga",
            alertStyle       = "TOP2",
        },
        {
            buffName         = "Mongoose Bite",   -- after a dodge
            spellName        = "Mongoose Bite",
            spellID          = 1495,
            reactOn          = { target = { DODGE = true } },
            cooldown         = 5,
            alertTexturePath = IMG .. "DarkRedStreaks.tga",
            alertStyle       = "RIGHT",
        },
    },
}

-- Fixed windows (seconds) for action procs; the alert clears when the window
-- elapses even if the ability is still usable. Overridable per proc in the UI.
local ACTION_PROC_DEFAULT_DURATIONS = {
    ["Overpower"]     = 5,
    ["Riposte"]       = 5,
    ["Revenge"]       = 5,
    ["Counterattack"] = 5,
    ["Mongoose Bite"] = 5,
}

-- Every alert image in img/ with its native size, offered in the per-proc
-- image picker. Generated from the folder: keep it in sync with the files
-- (a listed file that is missing shows blank).
local IMAGE_LIST = {
    { "ArcaneRunes", 256, 128 },          { "AutumnVines", 128, 256 },
    { "BloodOrbs", 128, 256 },            { "BrightGoldBlade", 128, 256 },
    { "CrescentMoon", 128, 128 },         { "CrescentMoonGlow", 128, 256 },
    { "CrimsonClaws", 128, 256 },         { "CrimsonStreakArc", 64, 128 },
    { "DarkRedStreaks", 128, 256 },       { "DivineRays", 256, 128 },
    { "EmberArc", 128, 256 },             { "EmberCrown", 256, 128 },
    { "FelFlame", 128, 256 },             { "FelOoze", 128, 256 },
    { "FireBand", 256, 128 },             { "FireBurst", 256, 128 },
    { "FireSwoosh", 256, 128 },           { "FlameStreaks", 128, 256 },
    { "FlamingDagger", 128, 256 },        { "FrostBand", 256, 128 },
    { "FrostFireArc", 128, 256 },         { "FrostShards", 128, 256 },
    { "GlowingEyes", 256, 128 },          { "GoldenArrows", 128, 256 },
    { "GoldenCrosshair", 256, 128 },      { "GoldenFlameCrescent", 128, 256 },
    { "GoldenLightningArc", 128, 256 },   { "GoldenRunes", 256, 128 },
    { "GoldenShield", 128, 256 },         { "GoldenSunArc", 128, 256 },
    { "GoldenSword", 128, 256 },          { "GoldenWingedEmblem", 256, 128 },
    { "GreenGlowArch", 256, 128 },        { "GreenMist", 128, 256 },
    { "GreenVines", 128, 256 },           { "IceWallArc", 128, 256 },
    { "IcyBlueArc", 128, 256 },           { "LightningStage1", 256, 128 },
    { "LightningStage2", 256, 128 },      { "LightningStage3", 256, 128 },
    { "LightningStage4", 256, 128 },      { "LightningWings", 256, 128 },
    { "OrangeStreakArc", 128, 256 },      { "PaleGoldBlade", 128, 256 },
    { "PinkRuneArc", 128, 256 },          { "PurpleComet", 256, 128 },
    { "PurpleFlameBand", 256, 128 },      { "PurpleThornBand", 256, 128 },
    { "RedBoltSlash", 256, 128 },         { "RedFlameCrescent", 128, 256 },
    { "RedShield", 128, 256 },            { "RedSlash", 256, 128 },
    { "RunePlate", 256, 128 },            { "ShadowStar", 128, 256 },
    { "ShadowWisps", 128, 256 },          { "SilverEmblem", 128, 128 },
    { "SmallRedSlash", 128, 256 },        { "StormArc", 256, 128 },
    { "StormStones", 256, 128 },          { "SunOrb", 128, 128 },
    { "WhiteArch", 256, 128 },            { "WhiteArcSoft", 128, 256 },
    { "WhiteCrescent", 128, 256 },        { "WhiteDoubleArch", 256, 128 },
    { "WhiteDoubleCrescent", 128, 256 },  { "WhiteFlareArc", 128, 256 },
    { "WhiteRuneArc", 128, 256 },         { "WhiteSparkArc", 128, 256 },
    { "WhiteStarburst", 256, 128 },
}
local IMAGE_SIZE = {}
for _, e in ipairs(IMAGE_LIST) do
    e.path  = IMG .. e[1] .. ".tga"
    e.label = (e[1]:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"))
    IMAGE_SIZE[e.path:lower()] = { e[2], e[3] }
end

local DEFAULT_ALERT_TEXTURE = IMG .. "GoldenWingedEmblem.tga"

local SOUNDS = {
    { value = "none",        label = "No sound" },
    { value = "alert1",      label = "ProcDoc chime",   file = IMG .. "SpellAlert.ogg" },
    { value = "alert2",      label = "ProcDoc chime 2", file = IMG .. "SpellAlert2.ogg" },
    { value = "raidwarning", label = "Raid warning",    kitName = "RAID_WARNING",          kit = 8959 },
    { value = "readycheck",  label = "Ready check",     kitName = "READY_CHECK",           kit = 8960 },
    { value = "alarm",       label = "Alarm clock",     kitName = "ALARM_CLOCK_WARNING_3", kit = 12889 },
    { value = "ping",        label = "Map ping",        kitName = "MAP_PING",              kit = 3175 },
}
local SOUND_BY_KEY = {}
for _, s in ipairs(SOUNDS) do SOUND_BY_KEY[s.value] = s end

local SOUND_CHANNELS = {
    { value = "Master",   label = "Master" },
    { value = "SFX",      label = "Effects" },
    { value = "Dialog",   label = "Dialog" },
    { value = "Ambience", label = "Ambience" },
}

-- 4) Alert frames and layout
--    Every proc owns one alert object (created lazily), made of 1-2 "pieces"
--    (a mirrored left/right pair when "Both sides" is on). A piece is a Frame
--    holding the pulsing texture, a draggable countdown and edit handles.
--
--    Position: each proc has a free position (px, py = centre of its first
--    piece, relative to the screen centre) that the player sets by dragging
--    the alert. With "Both sides" the second piece mirrors it at (-px, py).
--    Until moved, a proc sits where its data `alertStyle` preset puts it.
--
--    Edit mode (options window open, or unlocked) makes alerts take the
--    mouse: drag to move, Shift+wheel to resize, drag the countdown to move
--    it, Shift+wheel over the countdown to resize it, right-click to edit.
local HORIZONTAL_STYLES = { TOP = true, TOP2 = true, CENTER = true, BOTTOM = true, BOTTOM2 = true }

-- Preset positions (only used for defaults and migrating old settings)
local function StyleAnchors(style)
    local t, s = G.topOffset or 70, G.sideOffset or 60
    local sideY = t - 150
    if style == "TOP" then
        return { { x = 0, y = t } }
    elseif style == "TOP2" then
        return { { x = 0, y = t + 50 } }
    elseif style == "CENTER" then
        return { { x = 0, y = 0 } }
    elseif style == "BOTTOM" then
        return { { x = 0, y = -(t + 120) } }
    elseif style == "BOTTOM2" then
        return { { x = 0, y = -(t + 170) } }
    elseif style == "SIDES2" then
        return { { x = -(s + 50), y = sideY, pair = -1 }, { x = s + 50, y = sideY, pair = 1, flip = true } }
    elseif style == "SIDES3" then
        return { { x = -(s + 100), y = sideY, pair = -1 }, { x = s + 100, y = sideY, pair = 1, flip = true } }
    elseif style == "LEFT" then
        return { { x = -(s + 50), y = sideY } }
    elseif style == "RIGHT" then
        return { { x = s + 50, y = sideY, flip = true } }
    elseif style == "LEFT_INNER" then
        return { { x = -s, y = sideY } }
    elseif style == "RIGHT_INNER" then
        return { { x = s, y = sideY, flip = true } }
    end
    -- SIDES (default)
    return { { x = -s, y = sideY, pair = -1 }, { x = s, y = sideY, pair = 1, flip = true } }
end

local alerts      = {}      -- procKey -> alert object
local unlockMode  = false
local optionsOpen = false   -- set by the options window (section 13)

local function EditMode()
    return unlockMode or optionsOpen
end

-- Class colors for chat messages / UI accent / "Class color" timer option
local CLASS_COLORS = {
    ["WARRIOR"] = "ffc79c6e", ["PALADIN"] = "fff58cba", ["HUNTER"]  = "ffabd473",
    ["ROGUE"]   = "fffff569", ["PRIEST"]  = "ffffffff", ["SHAMAN"]  = "ff0070de",
    ["MAGE"]    = "ff69ccf0", ["WARLOCK"] = "ff9482c9", ["DRUID"]   = "ffff7d0a",
}
local classColor = "ffffffff"
local accentR, accentG, accentB = 1, 0.82, 0

local function ComputeAccent()
    classColor = CLASS_COLORS[playerClass] or "ffffffff"
    local c = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[playerClass]
    if c then
        accentR, accentG, accentB = c.r, c.g, c.b
    else
        accentR = tonumber(classColor:sub(3, 4), 16) / 255
        accentG = tonumber(classColor:sub(5, 6), 16) / 255
        accentB = tonumber(classColor:sub(7, 8), 16) / 255
    end
end

local function IsProcEnabled(proc)
    if proc.auto and not G.autoDetect then return false end
    return PS(proc.key).enabled ~= false
end

-- Reminders: a buff set to "remind me when it's missing" (per-proc setting
-- remind = "missing") shows its alert while the buff is NOT there, in and out
-- of combat alike. Detection is unchanged: sources still mean "the buff is
-- there", only the alert flips. Grouped in one table to spare main-chunk locals.
local Remind = { quietUntil = math.huge }

function Remind.Is(proc)
    return not proc.isAction and PS(proc.key).remind == "missing"
end

-- Not while dead or a ghost, and not in the first seconds after zoning
function Remind.ConditionOK()
    if GetTime() < Remind.quietUntil then return false end
    local dead = SafeCall(UnitIsDeadOrGhost, "player")
    return not (Readable(dead) and dead)
end

-- Whether an alert should be up: normally while any source says the proc is
-- on; for a reminder, while nothing says the buff is there
function Remind.WantLive(a)
    if not IsProcEnabled(a.proc) then return false end
    local any = next(a.sources) ~= nil
    if not Remind.Is(a.proc) then return any end
    return (not any) and Remind.ConditionOK()
end

local function ProcIcon(proc)
    local icon
    if proc.spellID then icon = GetSpellIconCompat(proc.spellID) end
    if not icon and proc.spellIDs then icon = GetSpellIconCompat(proc.spellIDs[1]) end
    if not icon then icon = GetSpellIconCompat(proc.spellName or proc.buffName) end
    if not icon then icon = proc.seenIcon or proc.texture end
    return icon
end

-- Resolves the texture for a proc: returns texture, width, height, isIcon
local function ResolveImage(proc)
    local img = PS(proc.key).image
    if img == "ICON" then
        local icon = ProcIcon(proc)
        if icon then return icon, 96, 96, true end
        img = nil
    elseif img == "BLIZZARD" then
        img = proc.blizzardArt
    end
    if img == nil then img = proc.alertTexturePath or proc.blizzardArt or DEFAULT_ALERT_TEXTURE end
    local size = type(img) == "string" and IMAGE_SIZE[img:lower()]
    if size then return img, size[1], size[2], false end
    return img, nil, nil, false
end

-- Sets tex coords for a clockwise rotation (0/90/180/270) followed by an
-- optional on-screen horizontal mirror.
local function ApplyTexCoord(tex, flip, isIcon, rotation)
    local l, r, t, b = 0, 1, 0, 1
    if isIcon then l, r, t, b = 0.08, 0.92, 0.08, 0.92 end
    local UL, LL, UR, LR = { l, t }, { l, b }, { r, t }, { r, b }
    for _ = 1, math.floor(((rotation or 0) % 360) / 90) do
        UL, UR, LR, LL = LL, UL, UR, LR
    end
    if flip then
        UL, UR = UR, UL
        LL, LR = LR, LL
    end
    tex:SetTexCoord(UL[1], UL[2], LL[1], LL[2], UR[1], UR[2], LR[1], LR[2])
end

local ROTATION_OPTIONS = {
    { value = "auto", label = "Auto (face outward)" },
    { value = 0,      label = "None" },
    { value = 90,     label = "90° clockwise" },
    { value = 180,    label = "180°" },
    { value = 270,    label = "90° counter-clockwise" },
}

-- Where a proc sits: x, y of its first piece, whether it's a mirrored pair,
-- and its region ("SIDE" art faces left/right, "TB" art faces up/down),
-- which drives Auto rotation and mirroring.
local function ProcPlacement(proc)
    local s = PS(proc.key)
    local style = proc.alertStyle or "SIDES"
    local anchors = StyleAnchors(style)
    local base = anchors[1]
    local both = s.both
    if both == nil then both = (#anchors == 2) end
    local region = s.region or ((both or not HORIZONTAL_STYLES[style]) and "SIDE" or "TB")
    return s.px or base.x, s.py or base.y, both, region
end

-- Works out how one piece is drawn: rotation, mirror, and on-screen
-- width/height (swapped for 90/270). "Auto" turns art so its top faces away
-- from the screen centre -- a wide banner stands up on the sides, a tall arc
-- lies down on top, bottom art faces downward -- and side art on the right
-- half of the screen is mirrored so it faces outward.
local function PieceOrientation(region, x, y, w, h, s)
    local rot, extraFlip = s.rotation, false
    local autoFlip = (region == "SIDE") and x > 2
    if rot == nil then
        rot = 0
        local isBottom = (region ~= "SIDE") and y < -60
        if region == "SIDE" then
            if w > h then rot = 270 end
        elseif h > w then
            rot = isBottom and 270 or 90
        elseif w > h and isBottom then
            rot, extraFlip = 180, true      -- 180 + mirror = vertical flip
        end
    end
    local flip = (autoFlip ~= (s.flip and true or false)) ~= extraFlip
    if rot == 90 or rot == 270 then w, h = h, w end
    return rot, flip, w, h
end

-- Countdown styling ------------------------------------------------------
local FONT_CHOICES = {
    { value = "FRIZ",     label = "Friz Quadrata (default)", path = "Fonts\\FRIZQT__.TTF" },
    { value = "ARIALN",   label = "Arial Narrow",            path = "Fonts\\ARIALN.TTF" },
    { value = "SKURRI",   label = "Skurri",                  path = "Fonts\\skurri.ttf" },
    { value = "MORPHEUS", label = "Morpheus",                path = "Fonts\\MORPHEUS.TTF" },
}
local FONT_PATH = {}
for _, f in ipairs(FONT_CHOICES) do FONT_PATH[f.value] = f.path end

local OUTLINE_CHOICES = {
    { value = "THICKOUTLINE", label = "Thick outline" },
    { value = "OUTLINE",      label = "Thin outline" },
    { value = "NONE",         label = "No outline" },
}

local COLOR_CHOICES = {
    { value = "gold",   label = "Gold",        rgb = { 1, 0.92, 0.55 } },
    { value = "white",  label = "White",       rgb = { 1, 1, 1 } },
    { value = "yellow", label = "Yellow",      rgb = { 1, 0.85, 0 } },
    { value = "orange", label = "Orange",      rgb = { 1, 0.55, 0.1 } },
    { value = "red",    label = "Red",         rgb = { 1, 0.3, 0.25 } },
    { value = "green",  label = "Green",       rgb = { 0.35, 1, 0.35 } },
    { value = "blue",   label = "Blue",        rgb = { 0.4, 0.75, 1 } },
    { value = "purple", label = "Purple",      rgb = { 0.8, 0.5, 1 } },
    { value = "class",  label = "Class color" },
}
local COLOR_BY_KEY = {}
for _, c in ipairs(COLOR_CHOICES) do COLOR_BY_KEY[c.value] = c end

local function ColorRGB(key)
    if key == "class" then return accentR, accentG, accentB end
    local c = (COLOR_BY_KEY[key] or COLOR_BY_KEY.gold).rgb
    return c[1], c[2], c[3]
end

-- UI units per physical screen pixel for frames parented to UIParent.
-- Alert sizes are multiplied by this so 1.00x draws an image at its real
-- pixel size (WoW's UI units are larger than a pixel on most screens, which
-- used to stretch the art, e.g. 256px -> ~480px at 1440p).
local REF_PIXEL_FACTOR = 768 / 1080      -- 1080p at UI scale 1, for font sizing
local function PixelFactor()
    local _, physH = SafeCall(GetPhysicalScreenSize)
    physH = Clean(physH)
    local scale = UIParent:GetEffectiveScale()
    if type(physH) ~= "number" or physH <= 0 or not scale or scale <= 0 then return 1 end
    return 768 / (physH * scale)
end

-- Font path, size and outline for a proc's countdown. A per-proc size is
-- used as-is; otherwise the global size scales with the alert's on-screen
-- size (normalised so it looks the same at every resolution).
local function TimerFont(proc, scale)
    local s = PS(proc.key)
    local size = s.timerSize
    if not size then
        local f = (scale or 1) * PixelFactor() / REF_PIXEL_FACTOR
        size = math.floor((G.timerTextSize or 26) * math.min(math.max(f, 0.5), 1.6) + 0.5)
    end
    local outline = G.timerOutline or "THICKOUTLINE"
    if outline == "NONE" then outline = "" end
    return FONT_PATH[G.timerFont] or FONT_PATH.FRIZ, math.max(6, size), outline
end

local function RoundTo(v, step)
    return math.floor(v / step + 0.5) * step
end

-- Stack dots ---------------------------------------------------------------
-- Buff procs with stacks get a row of dots (filled = stacks you have, dim =
-- the rest up to "Number of dots" or the most seen). Grouped in one table to
-- spare main-chunk locals.
local Pips = { TEX = "Interface\\AddOns\\ProcDoc\\ProcDoc_Pip" }   -- tools/make_icon.py

function Pips.Enabled(proc)
    return not proc.isAction and not Remind.Is(proc) and PS(proc.key).stackDots ~= false
end

-- Dot size: per-proc if set, else scales with the alert like the countdown
function Pips.Size(proc, scale)
    local s = PS(proc.key)
    if s.pipSize then return s.pipSize end
    local f = (scale or 1) * PixelFactor() / REF_PIXEL_FACTOR
    return math.floor(11 * math.min(math.max(f, 0.6), 1.6) + 0.5)
end

-- Lays out `slots` dots with `filled` lit; the newest dot pops for 0.3s
function Pips.Draw(pf, filled, slots, r, g, b, sinceGain, alpha)
    local size = pf.size or 11
    local gap = size * 0.35
    local total = slots * size + (slots - 1) * gap
    pf:SetSize(math.max(total, 16), size + 6)
    for k = 1, slots do
        local d = pf.dots[k]
        if not d then
            d = pf:CreateTexture(nil, "ARTWORK")
            d:SetTexture(Pips.TEX)
            pf.dots[k] = d
        end
        d:ClearAllPoints()
        d:SetPoint("CENTER", pf, "CENTER", -total / 2 + size / 2 + (k - 1) * (size + gap), 0)
        local sz = size
        if k == filled and sinceGain < 0.3 then sz = size * (1 + 0.8 * (1 - sinceGain / 0.3)) end
        d:SetSize(sz, sz)
        if k <= filled then
            d:SetVertexColor(r, g, b, alpha)
        else
            d:SetVertexColor(0.5, 0.5, 0.55, 0.35 * alpha)
        end
        d:Show()
    end
    for k = slots + 1, #pf.dots do pf.dots[k]:Hide() end
end

local LayoutAlert -- forward

-- Edit-mode hover help
local function ShowEditTip(owner, title, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:SetText(title, 1, 1, 1)
    for i = 1, select("#", ...) do
        GameTooltip:AddLine((select(i, ...)), 0.85, 0.85, 0.85)
    end
    GameTooltip:Show()
end

local function PieceTip(p)
    local s = PS(p.alert.proc.key)
    ShowEditTip(p, p.alert.proc.buffName,
        "Drag: move",
        string.format("Shift + mouse wheel: size (%.2fx)", s.scale or 1),
        "Right-click: settings")
end

local function TimerTip(tf)
    local p = tf:GetParent()
    local _, size = TimerFont(p.alert.proc, (PS(p.alert.proc.key).scale or 1) * (G.masterScale or 1))
    ShowEditTip(tf, "Countdown",
        "Drag: move it on the alert",
        string.format("Shift + mouse wheel: text size (%d)", size))
end

-- While a pair is dragged, keep its mirror in step
local function PieceDragUpdate(self)
    local a = self.alert
    if a.numPieces < 2 then return end
    local other = a.pieces[3 - self.index]
    local cx, cy = self:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not cx or not ux or not other then return end
    other:ClearAllPoints()
    other:SetPoint("CENTER", UIParent, "CENTER", -(cx - ux), cy - uy)
end

local function OnPieceDragStop(p)
    p:StopMovingOrSizing()
    p:SetScript("OnUpdate", nil)
    local a = p.alert
    local cx, cy = p:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not cx or not ux then return end
    local x, y = cx - ux, cy - uy
    if p.index == 2 then x = -x end
    if math.abs(x) < 8 then x = 0 end          -- snap to the centre lines
    if math.abs(y) < 8 then y = 0 end
    local s = PSW(a.proc.key)
    s.px, s.py = math.floor(x + 0.5), math.floor(y + 0.5)
    LayoutAlert(a)
    if RefreshOptions then RefreshOptions() end
end

local function OnTimerDragStop(tf)
    tf:StopMovingOrSizing()
    local p = tf:GetParent()
    local a = p.alert
    local tx, ty = tf:GetCenter()
    local cx, cy = p:GetCenter()
    if not tx or not cx or not p.baseW or p.baseW == 0 then return end
    local ox, oy = (tx - cx) / p.baseW, (ty - cy) / p.baseH
    if p.index == 2 then ox = -ox end
    if math.abs(ox) < 0.04 then ox = 0 end
    if math.abs(oy) < 0.04 then oy = 0 end
    local s = PSW(a.proc.key)
    s.timerX = (ox ~= 0) and RoundTo(ox, 0.01) or nil
    s.timerY = (oy ~= 0) and RoundTo(oy, 0.01) or nil
    LayoutAlert(a)
    if RefreshOptions then RefreshOptions() end
end

local function OnPieceWheel(p, delta)
    if not EditMode() or not (IsShiftKeyDown and IsShiftKeyDown()) then return end
    local s = PSW(p.alert.proc.key)
    local v = RoundTo(math.min(4, math.max(0.25, (s.scale or 1) + delta * 0.05)), 0.01)
    s.scale = (math.abs(v - 1) > 0.001) and v or nil
    LayoutAlert(p.alert)
    PieceTip(p)
    if RefreshOptions then RefreshOptions() end
end

local function OnTimerWheel(tf, delta)
    if not EditMode() or not (IsShiftKeyDown and IsShiftKeyDown()) then return end
    local p = tf:GetParent()
    local proc = p.alert.proc
    local _, size = TimerFont(proc, (PS(proc.key).scale or 1) * (G.masterScale or 1))
    PSW(proc.key).timerSize = math.min(80, math.max(6, size + delta))
    LayoutAlert(p.alert)
    TimerTip(tf)
    if RefreshOptions then RefreshOptions() end
end

function Pips.Tip(pf)
    local p = pf:GetParent()
    local size = Pips.Size(p.alert.proc, (PS(p.alert.proc.key).scale or 1) * (G.masterScale or 1))
    ShowEditTip(pf, "Stack dots", "Drag: move them on the alert",
        string.format("Shift + mouse wheel: size (%d)", size))
end

function Pips.OnDragStop(pf)
    pf:StopMovingOrSizing()
    local p = pf:GetParent()
    local tx, ty = pf:GetCenter()
    local cx, cy = p:GetCenter()
    if not tx or not cx or not p.baseW or p.baseW == 0 then return end
    local ox, oy = (tx - cx) / p.baseW, (ty - cy) / p.baseH
    if p.index == 2 then ox = -ox end
    if math.abs(ox) < 0.04 then ox = 0 end
    local s = PSW(p.alert.proc.key)
    s.pipX = (ox ~= 0) and RoundTo(ox, 0.01) or nil
    s.pipY = RoundTo(oy, 0.01)
    LayoutAlert(p.alert)
    if RefreshOptions then RefreshOptions() end
end

function Pips.OnWheel(pf, delta)
    if not EditMode() or not (IsShiftKeyDown and IsShiftKeyDown()) then return end
    local p = pf:GetParent()
    local proc = p.alert.proc
    local size = Pips.Size(proc, (PS(proc.key).scale or 1) * (G.masterScale or 1))
    PSW(proc.key).pipSize = math.min(40, math.max(4, size + delta))
    LayoutAlert(p.alert)
    Pips.Tip(pf)
    if RefreshOptions then RefreshOptions() end
end

local function CreatePiece(a, index)
    local p = CreateFrame("Frame", nil, UIParent)
    p:SetFrameStrata("MEDIUM")
    p:SetMovable(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(false)
    p:EnableMouseWheel(false)
    p:RegisterForDrag("LeftButton")
    p.alert, p.index = a, index

    p.bounds = p:CreateTexture(nil, "BACKGROUND")
    p.bounds:SetAllPoints()
    p.bounds:SetColorTexture(0.2, 0.7, 1, 0.12)
    p.bounds:Hide()

    p.tex = p:CreateTexture(nil, "ARTWORK")
    p.tex:SetPoint("CENTER")

    -- Additive copy of the art used for the pop-in flash
    p.flash = p:CreateTexture(nil, "OVERLAY")
    p.flash:SetPoint("CENTER")
    p.flash:SetBlendMode("ADD")
    p.flash:Hide()

    -- The countdown lives in its own small frame so it can be dragged
    local tf = CreateFrame("Frame", nil, p)
    tf:SetSize(40, 30)
    tf:SetFrameLevel(p:GetFrameLevel() + 5)
    tf:SetMovable(true)
    tf:SetClampedToScreen(true)
    tf:EnableMouse(false)
    tf:EnableMouseWheel(false)
    tf:RegisterForDrag("LeftButton")
    tf.bg = tf:CreateTexture(nil, "BACKGROUND")
    tf.bg:SetAllPoints()
    tf.bg:SetColorTexture(1, 0.85, 0.2, 0.14)
    tf.bg:Hide()
    p.timer = tf:CreateFontString(nil, "OVERLAY")
    p.timer:SetFont(FONT_PATH.FRIZ, G.timerTextSize or 26, "THICKOUTLINE")
    p.timer:SetPoint("CENTER")
    p.timerFrame = tf
    tf:Hide()

    -- Stack dots: another draggable child frame
    local pf = CreateFrame("Frame", nil, p)
    pf:SetSize(40, 14)
    pf:SetFrameLevel(p:GetFrameLevel() + 6)
    pf:SetMovable(true)
    pf:SetClampedToScreen(true)
    pf:EnableMouse(false)
    pf:EnableMouseWheel(false)
    pf:RegisterForDrag("LeftButton")
    pf.bg = pf:CreateTexture(nil, "BACKGROUND")
    pf.bg:SetAllPoints()
    pf.bg:SetColorTexture(0.4, 1, 0.5, 0.14)
    pf.bg:Hide()
    pf.dots = {}
    p.pipFrame = pf
    pf:Hide()
    pf:SetScript("OnDragStart", function(self) if EditMode() then self:StartMoving() end end)
    pf:SetScript("OnDragStop", Pips.OnDragStop)
    pf:SetScript("OnMouseWheel", Pips.OnWheel)
    pf:SetScript("OnEnter", function(self) if EditMode() then Pips.Tip(self) end end)
    pf:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.label = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.label:SetPoint("BOTTOM", p, "TOP", 0, 2)
    p.label:Hide()

    p:SetScript("OnDragStart", function(self)
        if not EditMode() then return end
        self:StartMoving()
        self:SetScript("OnUpdate", PieceDragUpdate)
    end)
    p:SetScript("OnDragStop", OnPieceDragStop)
    p:SetScript("OnMouseUp", function(self, button)
        if EditMode() and button == "RightButton" and OpenOptions then
            OpenOptions(self.alert.proc.key)
        end
    end)
    p:SetScript("OnMouseWheel", OnPieceWheel)
    p:SetScript("OnEnter", function(self) if EditMode() then PieceTip(self) end end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)

    tf:SetScript("OnDragStart", function(self) if EditMode() then self:StartMoving() end end)
    tf:SetScript("OnDragStop", OnTimerDragStop)
    tf:SetScript("OnMouseWheel", OnTimerWheel)
    tf:SetScript("OnEnter", function(self) if EditMode() then TimerTip(self) end end)
    tf:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p:Hide()
    a.pieces[index] = p
    return p
end

LayoutAlert = function(a)
    local proc = a.proc
    local s    = PS(proc.key)
    local x, y, both, region = ProcPlacement(proc)
    local img, w, h, isIcon = ResolveImage(proc)
    if not w then
        if region == "TB" then w, h = 256, 128 else w, h = 128, 256 end
    end
    local scale = (s.scale or 1) * (G.masterScale or 1)
    local fontPath, fontSize, outline = TimerFont(proc, scale)
    local pixelScale = scale * PixelFactor()
    local pipSize = Pips.Size(proc, scale)
    local fontKey = fontPath .. fontSize .. outline
    local count = both and 2 or 1

    for i = 1, count do
        local p = a.pieces[i] or CreatePiece(a, i)
        local px = (i == 2) and -x or x
        local rot, flip, dw, dh = PieceOrientation(region, px, y, w, h, s)
        p:ClearAllPoints()
        p:SetPoint("CENTER", UIParent, "CENTER", px, y)
        p.baseW, p.baseH = dw * pixelScale, dh * pixelScale
        p:SetSize(p.baseW, p.baseH)
        p.tex:SetTexture(img)
        ApplyTexCoord(p.tex, flip, isIcon, rot)
        p.flash:SetTexture(img)
        ApplyTexCoord(p.flash, flip, isIcon, rot)
        if p.fontKey ~= fontKey then
            p.timer:SetFont(fontPath, fontSize, outline)
            p.fontKey = fontKey
        end
        local tf = p.timerFrame
        tf:SetSize(math.max(28, fontSize * 2.6), math.max(18, fontSize * 1.5))
        tf:ClearAllPoints()
        tf:SetPoint("CENTER", p, "CENTER",
            (s.timerX or 0) * p.baseW * ((i == 2) and -1 or 1), (s.timerY or 0) * p.baseH)
        local pf = p.pipFrame
        pf.size = pipSize
        pf:ClearAllPoints()
        pf:SetPoint("CENTER", p, "CENTER",
            (s.pipX or 0) * p.baseW * ((i == 2) and -1 or 1), (s.pipY or -0.6) * p.baseH)
    end
    for i = count + 1, #a.pieces do
        a.pieces[i]:Hide()
    end
    a.numPieces = count
end

local function GetAlert(proc)
    local a = alerts[proc.key]
    if not a then
        a = { proc = proc, pieces = {}, sources = {}, phase = 0, numPieces = 0 }
        alerts[proc.key] = a
    end
    a.proc = proc
    return a
end

local function HideAlertNow(a)
    for _, p in ipairs(a.pieces) do
        p.exiting = nil
        p:Hide()
    end
    a.shown, a.exitStart = false, nil
end

-- Shows or hides an alert. Hiding plays the quick shrink-away (section 5)
-- unless it's turned off; the alert counts as shown until that finishes, and
-- coming back mid-shrink simply cancels it.
local function RefreshAlert(a)
    local want = a.test or a.live or (unlockMode and IsProcEnabled(a.proc))
    if want then
        if not a.shown then a.phase = 0 end
        a.exitStart = nil
        LayoutAlert(a)
        local edit = EditMode()
        for i = 1, a.numPieces do
            local p = a.pieces[i]
            p.exiting = nil
            p:EnableMouse(edit)
            p:EnableMouseWheel(edit)
            p.timerFrame:EnableMouse(edit)
            p.timerFrame:EnableMouseWheel(edit)
            p.timerFrame.bg:SetShown(unlockMode)
            p.pipFrame:EnableMouse(edit)
            p.pipFrame:EnableMouseWheel(edit)
            p.pipFrame.bg:SetShown(unlockMode)
            p.bounds:SetShown(unlockMode)
            p.label:SetText(a.proc.buffName)
            p.label:SetShown(unlockMode and i == 1)
            p:Show()
        end
        a.shown = true
    elseif a.shown and G.exitEnabled ~= false then
        if not a.exitStart then
            a.exitStart = GetTime()
            for i = 1, a.numPieces do
                local p = a.pieces[i]
                p.exiting = true
                p:EnableMouse(false)
                p:EnableMouseWheel(false)
                p.timerFrame:Hide()
                p.pipFrame:Hide()
                p.bounds:Hide()
                p.label:Hide()
            end
        end
    else
        HideAlertNow(a)
    end
end

local function RefreshAllAlerts()
    for _, a in pairs(alerts) do
        if a.shown or a.test or a.live then RefreshAlert(a) end
    end
end

--------------------------------------------
-- HELPER: Play proc sound
--------------------------------------------
local lastSoundTime = 0

local function PlaySoundKey(key)
    local def = SOUND_BY_KEY[key]
    if not def or key == "none" then return end
    local channel = G.soundChannel or "Master"
    if def.file then
        SafeCall(PlaySoundFile, def.file, channel)
    else
        local kit = (_G.SOUNDKIT and def.kitName and _G.SOUNDKIT[def.kitName]) or def.kit
        if kit then SafeCall(PlaySound, kit, channel) end
    end
end

local function ProcDoc_PlayAlertSound(proc)
    if G.isMuted then return end
    local now = GetTime()
    if now - lastSoundTime < 0.25 then return end
    local key = PS(proc.key).sound or G.defaultSound
    if key == "none" then return end
    lastSoundTime = now
    PlaySoundKey(key)
end

-- Recomputes whether an alert is up; going up pops it and plays its sound
function Remind.UpdateLive(a, why)
    local live = Remind.WantLive(a)
    if live and not a.live then
        a.phase = 0
        a.liveSince = GetTime()
        a.popStart = a.liveSince
        ProcDoc_PlayAlertSound(a.proc)
    end
    if live ~= a.live then
        a.live = live
        Trace("%s %s (via %s%s)", live and "SHOW" or "HIDE", a.proc.key, why,
            Remind.Is(a.proc) and ", reminder" or "")
        RefreshAlert(a)
    end
end

-- Marks a detection source ("aura", "overlay", "action", "cdm", "sim") on/off
-- for a proc. `info` may carry exp (absolute expiration time) and dur for the
-- countdown.
local function SetLive(proc, source, info)
    local a = GetAlert(proc)
    a.sources[source] = info or nil
    if info and info.exp then
        a.expiration, a.duration = info.exp, info.dur
    end
    if next(a.sources) == nil then a.expiration, a.duration = nil, nil end
    Remind.UpdateLive(a, source)
end

-- Re-evaluates enabled state for every alert (after toggles in the options)
local function ReevaluateAll()
    for _, a in pairs(alerts) do
        a.live = Remind.WantLive(a)
        RefreshAlert(a)
    end
    if Remind.RefreshAll then Remind.RefreshAll() end
end

local function TimerEnabled(proc)
    if Remind.Is(proc) then return false end     -- nothing to count down
    local t = PS(proc.key).timer
    if t == "on" then return true end
    if t == "off" then return false end
    return not G.disableTimers
end

-- 5) OnUpdate pulse logic (frame-rate independent sine pulse + countdown text)
--    Previews and unlock mode show a looping sample countdown so the timer
--    can be styled and placed.
local PULSE_RATE = 8          -- radians per second per unit of pulseSpeed
local POP_TIME   = 0.5        -- seconds for the pop-in animation
local POP_FROM   = 0.45       -- pop-in starts at this fraction of full size
local POP_RISE   = 0.35       -- share of POP_TIME spent growing to the peak
local EXIT_TIME  = 0.18       -- seconds for the shrink-away (much quicker than the pop)
local EXIT_SWELL = 0.25       -- share of EXIT_TIME spent on a tiny swell first
local EXIT_PEAK  = 1.08       -- size at the top of that swell
local EXIT_TO    = 0.15       -- size it shrinks down to before disappearing

-- Shrink-away: a tiny swell, then an accelerating shrink and fade, with a
-- short flash that shrinks along with it. Starts from the size and opacity
-- the alert had when the proc ended, so there's no jump.
local function AnimateExit(a, now)
    local t = (now - a.exitStart) / EXIT_TIME
    if t >= 1 then
        HideAlertNow(a)
        return
    end
    local size
    if t < EXIT_SWELL then
        local x = 1 - t / EXIT_SWELL
        size = 1 + (EXIT_PEAK - 1) * (1 - x * x)
    else
        local x = (t - EXIT_SWELL) / (1 - EXIT_SWELL)
        size = EXIT_PEAK + (EXIT_TO - EXIT_PEAK) * x * x
    end
    size = size * (a.lastSize or 1)
    local fade = (t < 0.3) and 1 or (1 - (t - 0.3) / 0.7)
    local alpha = (a.lastAlpha or 1) * fade
    local flashA = math.max(0, 1 - t / 0.6) * 0.7 * (PS(a.proc.key).alpha or 1)
    for i = 1, a.numPieces do
        local p = a.pieces[i]
        p.tex:SetAlpha(alpha)
        p.tex:SetSize(p.baseW * size, p.baseH * size)
        if flashA > 0.01 then
            p.flash:SetAlpha(flashA)
            p.flash:SetSize(p.baseW * size * 1.1, p.baseH * size * 1.1)
            p.flash:Show()
        else
            p.flash:Hide()
        end
    end
end
local hasActionProcs = false
local actionPollElapsed = 0
local unlockStart = 0

local function OnUpdateHandler(self, elapsed)
    local now  = GetTime()
    local minA = G.minAlpha or 0.8
    local maxA = math.max(G.maxAlpha or 1, minA)
    local minS = G.minScale or 0.9
    local maxS = math.max(G.maxScale or 1, minS)
    local rate = (G.pulseSpeed or 0.4) * PULSE_RATE
    local threshold = G.timerLowThreshold or 3
    local lowR, lowG, lowB = ColorRGB(G.timerLowColor or "red")
    local popOn   = G.popEnabled ~= false
    local popPeak = 1 + 0.15 * (G.popStrength or 1.7)   -- 1.7 -> ~25% overshoot

    for _, a in pairs(alerts) do
        -- Buff expired while aura data was locked (no scan to notice it).
        -- Checked for every alert: a reminder is hidden while its buff is up.
        local aura = a.sources.aura
        if aura and aura.exp and now >= aura.exp then
            SetLive(a.proc, "aura", nil)
        end
        if a.exitStart then
            AnimateExit(a, now)
        elseif a.shown then
            local s = PS(a.proc.key)
            a.phase = a.phase + elapsed * rate
            local frac  = (1 - math.cos(a.phase)) * 0.5
            local alpha = (minA + (maxA - minA) * frac) * (s.alpha or 1)
            local pulse = minS + (maxS - minS) * frac

            local remaining
            if a.live and a.expiration then
                remaining = a.expiration - now
            elseif a.test then
                local d = a.testDuration or 10
                remaining = d - ((now - (a.testStart or now)) % d)
            elseif unlockMode then
                local d = SampleDuration(a.proc)
                remaining = d - ((now - unlockStart) % d)
            end
            local text, r, g, b
            if remaining and TimerEnabled(a.proc) then
                if remaining < 0 then remaining = 0 end
                if remaining < threshold then
                    r, g, b = lowR, lowG, lowB
                    if G.timerDecimals ~= false then
                        text = string.format("%.1f", remaining)
                    else
                        text = tostring(math.floor(remaining))
                    end
                else
                    r, g, b = ColorRGB(s.timerColor or G.timerColor or "gold")
                    text = tostring(math.floor(remaining))
                end
            end

            -- Pop-in: springs out from small past full size and settles, plus a
            -- bright additive flash of the same art that expands and fades
            local pop, popAlpha, flashA, flashGrow = 1, 1, 0, 1
            if a.popStart then
                local t = (now - a.popStart) / POP_TIME
                if t >= 1 or not popOn then
                    a.popStart = nil
                else
                    -- grow quickly to a peak past full size, then ease back
                    if t < POP_RISE then
                        local x = 1 - t / POP_RISE
                        pop = POP_FROM + (popPeak - POP_FROM) * (1 - x * x)
                    else
                        local x = (t - POP_RISE) / (1 - POP_RISE)
                        pop = popPeak + (1 - popPeak) * (x * x * (3 - 2 * x))
                    end
                    popAlpha = math.min(1, t / 0.2)
                    flashA = (1 - t) * (1 - t) * 0.9
                    flashGrow = 1 + 0.45 * t
                end
            end

            a.lastAlpha, a.lastSize = alpha * popAlpha, pulse * pop

            -- Stacks: live count from the buff, or a counting sample in previews
            local stacks, slots
            if Pips.Enabled(a.proc) then
                if a.live then
                    local src = a.sources.aura or a.sources.sim
                    stacks = src and src.stacks
                    if stacks then
                        slots = s.maxStacks or math.max(stacks, (src.slots or 0), a.proc.maxSeen or 0)
                    end
                elseif a.test or unlockMode then
                    local m = s.maxStacks or a.proc.maxSeen or 0
                    if m >= 2 then
                        slots = m
                        stacks = math.floor((now - (a.testStart or unlockStart)) * 1.25) % m + 1
                    end
                end
            end
            if stacks ~= a.lastStacks then
                if stacks and stacks > (a.lastStacks or 0) then a.stackGainAt = now end
                a.lastStacks = stacks
            end
            local pr, pg, pb = ColorRGB(s.pipColor or "gold")
            for i = 1, a.numPieces do
                local p = a.pieces[i]
                p.tex:SetAlpha(alpha * popAlpha)
                p.tex:SetSize(p.baseW * pulse * pop, p.baseH * pulse * pop)
                if flashA > 0.01 then
                    p.flash:SetAlpha(flashA * (s.alpha or 1))
                    p.flash:SetSize(p.baseW * pop * flashGrow, p.baseH * pop * flashGrow)
                    p.flash:Show()
                else
                    p.flash:Hide()
                end
                if stacks and slots and not (i == 2 and s.pipOneSide) then
                    Pips.Draw(p.pipFrame, stacks, math.max(slots, stacks), pr, pg, pb,
                        now - (a.stackGainAt or 0), s.alpha or 1)
                    p.pipFrame:Show()
                else
                    p.pipFrame:Hide()
                end
                if text and not (i == 2 and s.timerOneSide) then
                    p.timer:SetText(text)
                    p.timer:SetTextColor(r, g, b)
                    p.timer:SetAlpha(G.timerTextAlpha or 0.85)
                    p.timerFrame:Show()
                else
                    p.timerFrame:Hide()
                end
            end

            if a.test and a.testUntil and now >= a.testUntil then
                a.test, a.testUntil = false, nil
                RefreshAlert(a)
            end
            if a.live and a.sources.action and a.expiration and now >= a.expiration then
                ExpireActionProc(a.proc)
            end
        end
    end

    if hasActionProcs then
        actionPollElapsed = actionPollElapsed + elapsed
        if actionPollElapsed >= 0.1 then
            actionPollElapsed = 0
            CheckAllActionProcs()
        end
    end
end

ProcDoc:SetScript("OnUpdate", OnUpdateHandler)
ProcDoc:SetWidth(1)
ProcDoc:SetHeight(1)
ProcDoc:SetPoint("CENTER", UIParent, "CENTER")

-- 6) Merge buff & action proc definitions for the player's class
--    Also restores procs auto-detected in earlier sessions and the player's
--    own custom procs, so they can be customised before they fire again.
local classProcs, buffProcs, actionProcs = {}, {}, {}
local procByKey, buffBySpellID, buffByName, actionByName = {}, {}, {}, {}

local function RegisterProc(proc, isAction)
    proc.key = proc.key or proc.buffName
    proc.isAction = isAction or nil
    classProcs[#classProcs + 1] = proc
    procByKey[proc.key] = proc
    if isAction then
        proc.localName = (proc.spellID and GetSpellNameCompat(proc.spellID)) or proc.spellName
        actionProcs[#actionProcs + 1] = proc
        if proc.spellName then actionByName[proc.spellName] = proc end
        if proc.localName then actionByName[proc.localName] = proc end
    else
        buffProcs[#buffProcs + 1] = proc
        if not proc.auto then buffByName[proc.buffName] = proc end
        local learned = ProcDocDB.learned and ProcDocDB.learned[playerClass]
        proc.learnedIDs = learned and learned[proc.key] or nil
        local seen = ProcDocDB.stackMax and ProcDocDB.stackMax[playerClass]
        proc.maxSeen = seen and seen[proc.key] or proc.maxSeen
        for id in pairs(proc.learnedIDs or {}) do
            if not buffBySpellID[id] then buffBySpellID[id] = proc end
        end
        if type(proc.consumedBy) == "table" then
            proc.consumeSet = {}
            for _, n in ipairs(proc.consumedBy) do proc.consumeSet[n] = true end
        end
        for _, id in ipairs(proc.spellIDs or {}) do
            buffBySpellID[id] = proc
            if not proc.auto then
                local n = GetSpellNameCompat(id)
                if n then buffByName[n] = proc end
            end
        end
    end
end

local LOCATION_STYLES = {
    ["LEFT + RIGHT (FLIPPED)"] = "SIDES",
    ["TOP + BOTTOM (FLIPPED)"] = "TOP",
    ["LEFT"] = "LEFT", ["RIGHT"] = "RIGHT", ["TOP"] = "TOP", ["BOTTOM"] = "BOTTOM",
    ["LEFTOUTSIDE"] = "LEFT", ["RIGHTOUTSIDE"] = "RIGHT",
    ["TOPLEFT"] = "LEFT", ["TOPRIGHT"] = "RIGHT",
}

local function MakeDetectedProc(spellID, info)
    return {
        key         = "AUTO:" .. spellID,
        buffName    = info.name or ("Spell " .. spellID),
        spellID     = spellID,
        spellIDs    = { spellID },
        blizzardArt = info.art,
        alertStyle  = info.style or "TOP",
        auto        = true,
    }
end

local function MakeCustomProc(key, info)
    return {
        key              = key,
        buffName         = info.name,
        spellID          = info.spellID,
        spellIDs         = info.spellID and { info.spellID } or nil,
        alertTexturePath = DEFAULT_ALERT_TEXTURE,
        alertStyle       = "TOP",
        custom           = true,
    }
end

local function BuildClassProcs()
    wipe(classProcs); wipe(buffProcs); wipe(actionProcs)
    wipe(procByKey); wipe(buffBySpellID); wipe(buffByName); wipe(actionByName)
    for _, p in ipairs(PROC_DATA[playerClass] or {}) do RegisterProc(p, false) end
    for _, p in ipairs(ACTION_PROCS[playerClass] or {}) do RegisterProc(p, true) end
    local custom = ProcDocDB.custom[playerClass]
    if custom then
        for key, info in pairs(custom) do
            if not procByKey[key] then RegisterProc(MakeCustomProc(key, info), false) end
        end
    end
    local detected = ProcDocDB.detected[playerClass]
    if detected then
        for spellID, info in pairs(detected) do
            if not buffBySpellID[spellID] then
                RegisterProc(MakeDetectedProc(spellID, info), false)
            end
        end
    end
    hasActionProcs = #actionProcs > 0
end

-- Track any buff as a proc: a spell ID (number or numeric text) or an exact
-- buff name. Returns the new proc, or nil and a message.
local function AddCustomProc(input)
    if type(input) == "string" then input = input:match("^%s*(.-)%s*$") end
    if input == nil or input == "" then return nil, "Type a buff name or spell ID first." end
    local id = tonumber(input)
    local name = id and GetSpellNameCompat(id) or (not id and input) or nil
    if not name then return nil, "No spell found with ID " .. tostring(input) .. "." end
    if (id and buffBySpellID[id]) or buffByName[name] or actionByName[name] then
        return nil, name .. " is already in your list."
    end
    local key = "CUSTOM:" .. (id and tostring(id) or name:lower())
    ProcDocDB.custom[playerClass] = ProcDocDB.custom[playerClass] or {}
    local info = { name = name, spellID = id }
    ProcDocDB.custom[playerClass][key] = info
    local proc = MakeCustomProc(key, info)
    RegisterProc(proc, false)
    if CheckProcs then CheckProcs() end
    return proc
end

-- Every buff read this session (name -> { id, t }), filled by CheckProcs.
-- The game hides buffs in combat, so the "Add a proc" picker and
-- /procdoc buffs fall back to these then.
local recentBuffs = {}

-- Untracked buffs the player has right now (or had recently, while the game
-- is hiding them), for the "Add a proc" picker
local function CurrentBuffOptions()
    local out, seen, locked = {}, {}, 0
    local function Offer(name, id, note)
        if seen[name] then return end
        seen[name] = true
        if (id and buffBySpellID[id]) or buffByName[name] then return end
        out[#out + 1] = { value = id or name,
            label = name .. (id and ("  |cff777777" .. id .. "|r") or "") .. (note or "") }
    end
    for i = 1, 40 do
        local exists, name, _, _, _, _, spellId = GetPlayerBuff(i)
        if not exists and name ~= true then break end
        if not exists or not Readable(name) then locked = locked + 1 end
        if exists and Readable(name) then Offer(name, Readable(spellId) and spellId or nil) end
    end
    if locked > 0 then
        local names = {}
        for name in pairs(recentBuffs) do names[#names + 1] = name end
        table.sort(names, function(x, y) return recentBuffs[x].t > recentBuffs[y].t end)
        for i = 1, math.min(#names, 25) do
            Offer(names[i], recentBuffs[names[i]].id, "  |cff777777(seen earlier)|r")
        end
    end
    if #out == 0 then
        out[1] = { value = "none", label = locked > 0 and "Buffs are hidden in combat: type a name or ID"
            or "No untracked buffs right now" }
    end
    return out
end

-- Removes a custom or auto-detected proc (built-in ones can only be disabled)
local function RemoveListedProc(proc)
    if proc.custom then
        if ProcDocDB.custom[playerClass] then ProcDocDB.custom[playerClass][proc.key] = nil end
    elseif proc.auto then
        if ProcDocDB.detected[playerClass] then ProcDocDB.detected[playerClass][proc.spellID] = nil end
    else
        return
    end
    ClassSettings()[proc.key] = nil
    local a = alerts[proc.key]
    if a then
        for _, p in ipairs(a.pieces) do p:Hide() end
        alerts[proc.key] = nil
    end
    BuildClassProcs()
    if CheckProcs then CheckProcs() end
end

-- Migrates older saved settings:
--   pre-4.0: procsEnabled / actionProcDurations tables
--   4.0 presets: style + x/y nudges  ->  free position (px, py) + both
local function MigrateLegacySettings()
    local legacyEnabled   = ProcDocDB.procsEnabled
    local legacyDurations = ProcDocDB.actionProcDurations
    for _, proc in ipairs(classProcs) do
        if legacyEnabled[proc.buffName] == false and PS(proc.key).enabled == nil then
            PSW(proc.key).enabled = false
        end
        local d = proc.spellName and legacyDurations[proc.spellName]
        if d and d > 0 and PS(proc.key).duration == nil then
            PSW(proc.key).duration = d
        end
    end
    for key, s in pairs(ClassSettings()) do
        if s.style or s.x or s.y then
            local proc = procByKey[key]
            local style = s.style or (proc and proc.alertStyle) or "SIDES"
            local anchors = StyleAnchors(style)
            local anc = anchors[1]
            local nx, ny = s.x or 0, s.y or 0
            s.px = anc.pair and (anc.pair * (math.abs(anc.x) + nx)) or (anc.x + nx)
            s.py = anc.y + ny
            if s.style then s.both = (#anchors == 2) end
            s.style, s.x, s.y = nil, nil, nil
        end
    end
end

-- 7) Buff-based detection
--    One pass over the player's buffs; a proc matches by spell ID or name.
--    Secret (combat-restricted) fields are skipped. When the client locks aura
--    access entirely, CheckProcsRestricted takes over: per-spell lookups where
--    allowed, known expirations are kept, and the Blizzard overlay events in
--    section 9 cover the rest. A full rescan runs when combat ends.
local function LookupPlayerAuraBySpellID(id)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
        local ok, secretAura = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
        if not ok or issecret(secretAura) or secretAura then return nil end
    end
    local ok, a = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
    if not ok or issecret(a) then return nil end
    return true, a
end

--
--    Knowing when a proc is SPENT (so its alert disappears right away):
--      * unlocked: every UNIT_AURA rescans, so a consumed buff drops at once.
--      * locked: (a) the auraInstanceID of each proc buff is remembered and
--        UNIT_AURA's removedAuraInstanceIDs clears it the moment it's gone;
--        (b) casting one of the proc's `consumedBy` spells ("ANY" = any
--        spell) spends a charge; (c) Blizzard's overlay-hide event.
local procByInstance = {}    -- auraInstanceID -> procKey
local auraLocked     = false -- last scan couldn't read auras
local removalReadable = false -- saw a readable removed instance ID while locked

local function MakeAuraInfo(proc, count, duration, expirationTime, instanceID, now)
    local stacks = Readable(count) and count or 0
    local need = PS(proc.key).minStacks or proc.minStacks
    if need and need > 1 and Readable(count) and stacks < need then return nil end
    local info = {}
    if stacks > 0 then
        info.stacks = stacks
        if stacks > (proc.maxSeen or 0) then
            proc.maxSeen = stacks
            local byClass = ProcDocDB.stackMax[playerClass] or {}
            ProcDocDB.stackMax[playerClass] = byClass
            byClass[proc.key] = stacks
        end
    end
    if Readable(duration) and Readable(expirationTime) and duration > 0 and expirationTime > now then
        info.exp, info.dur = expirationTime, duration
        proc.lastDuration = duration
    end
    if Readable(instanceID) then
        info.inst = instanceID
        procByInstance[instanceID] = proc.key
    end
    info.charges = (proc.charges and stacks > 0 and stacks) or proc.charges or 1
    return info
end

local function ClearAuraSource(proc)
    local a = alerts[proc.key]
    local cur = a and a.sources.aura
    if cur and cur.inst then procByInstance[cur.inst] = nil end
    SetLive(proc, "aura", nil)
end

-- Remembers the real spell ID a proc's buff uses on this client (Forever's
-- IDs can differ from the ones in the tables above), so it can be looked up directly later
-- while the buff list is locked.
local function LearnProcID(proc, id)
    if not Readable(id) or type(id) ~= "number" then return end
    for _, known in ipairs(proc.spellIDs or {}) do
        if known == id then return end
    end
    if proc.learnedIDs and proc.learnedIDs[id] then return end
    local byClass = ProcDocDB.learned[playerClass] or {}
    ProcDocDB.learned[playerClass] = byClass
    byClass[proc.key] = byClass[proc.key] or {}
    byClass[proc.key][id] = true
    proc.learnedIDs = byClass[proc.key]
    if not buffBySpellID[id] then buffBySpellID[id] = proc end
    Trace("learned spell ID %d for %s", id, proc.key)
end

-- The buff was really read: the player can get this proc (used when the
-- talent APIs can't answer; see Predict.HasTalent). Predicted-proc helpers
-- live in one table to spare main-chunk locals (Lua 5.1 allows 200).
local Predict = {}
function Predict.MarkSeen(proc)
    proc.hasTalent = true
    if proc.everSeen then return end
    proc.everSeen = true
    local byClass = ProcDocDB.seen[playerClass] or {}
    ProcDocDB.seen[playerClass] = byClass
    byClass[proc.key] = true
end

-- A proc that wasn't among the readable buffs while some buffs were locked:
-- ask for it directly (spell IDs, learned IDs, then its name). A found buff
-- or an allowed "not there" answer is authoritative; otherwise keep what we
-- had until its known expiry (spending casts / overlay hides clear it sooner).
local function CheckHiddenProc(proc, now)
    local known, aura = false, nil
    for _, id in ipairs(proc.spellIDs or {}) do
        if aura then break end
        local ok, a = LookupPlayerAuraBySpellID(id)
        if ok then known = true; aura = a end
    end
    for id in pairs(proc.learnedIDs or {}) do
        if aura then break end
        local ok, a = LookupPlayerAuraBySpellID(id)
        if ok then known = true; aura = a end
    end
    if not aura and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
        -- only a hit is trusted here: a nil could just mean "hidden"
        local ok, a = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", proc.buffName, "HELPFUL")
        if ok and not issecret(a) and type(a) == "table" then aura = a end
    end
    local alert = alerts[proc.key]
    if aura then
        if alert then alert.pendingConsume = nil end
        local wasLive = alert and alert.live
        Predict.MarkSeen(proc)
        SetLive(proc, "aura", MakeAuraInfo(proc, aura.applications, aura.duration,
            aura.expirationTime, aura.auraInstanceID, now))
        if not wasLive then Trace("%s found by direct lookup while buffs are locked", proc.key) end
        return
    end
    if known then
        if alert then alert.pendingConsume = nil end   -- lookup allowed: it's not there
        ClearAuraSource(proc)
        return
    end
    local cur = alert and alert.sources.aura
    if cur then
        -- Try asking about the exact buff instance we saw earlier
        local gone, present = false, false
        if cur.inst and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
            local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", cur.inst)
            if ok and not issecret(data) then
                if data == nil then gone = true else present = true end
            end
        end
        if gone then
            ClearAuraSource(proc)
        elseif present then
            alert.pendingConsume = nil
        elseif not (cur.inst and removalReadable) and not (cur.exp and cur.exp > now)
            and not Remind.Is(proc) then
            -- (a reminder's buff counts as there until its known expiry, or
            -- for good if it has none, so no false "missing" mid-fight)
            SetLive(proc, "aura", nil)
        end
    end
end

local function CheckProcsRestricted()
    auraLocked = true
    local now = GetTime()
    for _, proc in ipairs(buffProcs) do
        CheckHiddenProc(proc, now)
    end
end

-- Scans every buff slot. Forever locks some buffs in combat (reading one
-- raises an error, or its fields come back secret): those count as hidden
-- and the scan keeps going, so readable procs are still seen right away.
-- With nothing hidden the scan is authoritative; otherwise procs that
-- weren't seen go through CheckHiddenProc -- except procs already seen
-- readable under a partial lock, for which "not seen" means gone as long as
-- this scan could read something (i.e. it isn't a total lock).
CheckProcs = function()
    local now   = GetTime()
    local found = {}
    local seenInstances = {}
    local hidden, readable = 0, 0
    local other = {}   -- readable buffs that matched no proc (trace only)
    for i = 1, 40 do
        local exists, name, icon, count, duration, expirationTime, spellId, instanceID = GetPlayerBuff(i)
        if not exists then
            if name ~= true then break end     -- end of the list
            hidden = hidden + 1                -- this one is locked: keep looking
        elseif not Readable(name) and not Readable(spellId) then
            hidden = hidden + 1
        else
            readable = readable + 1
            if Readable(name) then
                local r = recentBuffs[name]
                if not r then r = {}; recentBuffs[name] = r end
                if Readable(spellId) then r.id = spellId end
                r.t = now
            end
            local proc
            if Readable(spellId) then proc = buffBySpellID[spellId] end
            if not proc and Readable(name) then proc = buffByName[name] end
            if not proc and G.trace then
                other[#other + 1] = string.format("%s#%s", Readable(name) and tostring(name) or "?",
                    Readable(spellId) and tostring(spellId) or "?")
            end
            if proc and not found[proc.key] then
                Predict.MarkSeen(proc)
                local info = MakeAuraInfo(proc, count, duration, expirationTime, instanceID, now)
                if info then
                    found[proc.key] = info
                    if info.inst then seenInstances[info.inst] = true end
                    if Readable(icon) then proc.seenIcon = icon end
                end
                LearnProcID(proc, spellId)
            end
        end
    end
    -- an empty list isn't proof of anything while the game says buffs are secret
    auraLocked = hidden > 0 or (readable == 0 and AurasRestricted())
    if not auraLocked then
        for id in pairs(procByInstance) do
            if not seenInstances[id] then procByInstance[id] = nil end
        end
    end
    for _, proc in ipairs(buffProcs) do
        if found[proc.key] then
            if auraLocked then proc.seenWhileLocked = true end
            SetLive(proc, "aura", found[proc.key])
        elseif not auraLocked or (proc.seenWhileLocked and readable > 0) then
            -- readable scan (or a partial lock that has shown this proc
            -- before): not seen means gone. With nothing readable at all the
            -- whole list may be locked, so ask directly instead.
            ClearAuraSource(proc)
        else
            CheckHiddenProc(proc, now)
        end
    end
    if G.trace then
        local names = {}
        for key in pairs(found) do names[#names + 1] = key end
        Trace("buff scan: %d readable, %d locked%s%s", readable, hidden,
            #names > 0 and (" - found " .. table.concat(names, ", ")) or "",
            #other > 0 and (" - other buffs: " .. table.concat(other, ", ")) or "")
    end
end

-- Incremental UNIT_AURA payload: catches removals/additions even while the
-- full buff list is locked
local function HandleAuraUpdate(updateInfo)
    local removed = Clean(updateInfo.removedAuraInstanceIDs)
    if type(removed) == "table" then
        for _, id in ipairs(removed) do
            if Readable(id) then
                if auraLocked then removalReadable = true end
                local key = procByInstance[id]
                if key then
                    procByInstance[id] = nil
                    local proc = procByKey[key]
                    if proc then SetLive(proc, "aura", nil) end
                end
            end
        end
    end
    local added = Clean(updateInfo.addedAuras)
    if type(added) == "table" then
        local now = GetTime()
        for _, aura in ipairs(added) do
            aura = Clean(aura)
            if type(aura) == "table" then
                local proc = (Readable(aura.spellId) and buffBySpellID[aura.spellId])
                    or (Readable(aura.name) and buffByName[aura.name])
                if proc then
                    Predict.MarkSeen(proc)
                    local info = MakeAuraInfo(proc, aura.applications, aura.duration,
                        aura.expirationTime, aura.auraInstanceID, now)
                    if info then SetLive(proc, "aura", info) end
                    LearnProcID(proc, aura.spellId)
                end
            end
        end
    end
end

-- Spending casts. A cast of one of a proc's `consumedBy` spells marks it
-- "pending"; the pending cast is then resolved against the best information
-- available: a readable scan is authoritative (the buff is either gone or
-- really still there), while a locked scan means the cast is trusted and a
-- charge is spent. Resolution runs right away and again shortly after the
-- cast (ResolvePendingConsumes(true)), because the cast event can arrive
-- just before combat locks the buff data -- e.g. opening on a new target
-- with Remorseless up.
local function ResolvePendingConsumes(final)
    local anyPending = false
    for _, proc in ipairs(buffProcs) do
        local a = alerts[proc.key]
        if a and a.pendingConsume then anyPending = true break end
    end
    if not anyPending then return end
    CheckProcs()
    for _, proc in ipairs(buffProcs) do
        local a = alerts[proc.key]
        if a and a.pendingConsume then
            local cur = a.sources.aura
            if not cur then
                a.pendingConsume = nil                     -- already gone
            elseif auraLocked and not proc.seenWhileLocked then
                if not (cur.inst and removalReadable) then
                    cur.charges = (cur.charges or 1) - a.pendingConsume
                    if cur.charges <= 0 then ClearAuraSource(proc) end
                end
                a.pendingConsume = nil
            elseif final then
                a.pendingConsume = nil                     -- readable: still there
            end
        end
    end
end

-- castName is nil when the cast's spell ID was secret: then only procs spent
-- by "ANY" spell can be matched. Returns true if something is pending.
local function ConsumeBuffProcs(castName)
    local now = GetTime()
    local pending = false
    for _, proc in ipairs(buffProcs) do
        local a = alerts[proc.key]
        local by = proc.consumedBy
        if a and a.sources.aura and by
            and (castName == nil or castName ~= proc.buffName)
            and (now - (a.liveSince or 0)) > 0.25
            and (by == "ANY" or (castName and proc.consumeSet and proc.consumeSet[castName])) then
            a.pendingConsume = (a.pendingConsume or 0) + 1
            pending = true
        end
    end
    if pending then ResolvePendingConsumes(false) end
    return pending
end

-- Reminders: re-check every one (combat, death and zoning change whether
-- they should show). Also updates alerts switched back to normal procs.
function Remind.RefreshAll()
    for _, proc in ipairs(buffProcs) do
        if Remind.Is(proc) or alerts[proc.key] then
            Remind.UpdateLive(GetAlert(proc), "reminder check")
        end
    end
end

-- Your own recast of a reminder buff while buffs are hidden: count it as
-- back for as long as it lasted last time (the scan after combat corrects it)
function Remind.OnCast(castName)
    local proc = castName and buffByName[castName]
    if not (proc and auraLocked and Remind.Is(proc)) then return end
    local dur = proc.lastDuration or 600
    SetLive(proc, "aura", { exp = GetTime() + dur, dur = dur })
    Trace("%s recast while buffs are hidden: counted as back for %ds", proc.key, dur)
end

-- Predicted procs (`predictOn` in section 3). Forever hides every buff in
-- combat, so a proc whose trigger the client does show lights up at that
-- trigger for its known duration. Spending casts still clear it, and the
-- first readable scan after combat confirms it or clears it.
function Predict.HasTalent(proc)
    if proc.hasTalent ~= nil then return proc.hasTalent end
    local answer
    if proc.talentIDs and IsPlayerSpell then
        for _, id in ipairs(proc.talentIDs) do
            local ok, known = pcall(IsPlayerSpell, id)
            if ok and Readable(known) and known then answer = true break end
        end
    end
    if answer == nil and proc.talent and GetNumTalentTabs and GetNumTalents and GetTalentInfo then
        local okT, tabs = pcall(GetNumTalentTabs)
        tabs = okT and Readable(tabs) and tonumber(tabs) or 0
        for t = 1, tabs do
            local okN, n = pcall(GetNumTalents, t)
            n = okN and Readable(n) and tonumber(n) or 0
            for i = 1, n do
                local ok, name, _, _, _, rank = pcall(GetTalentInfo, t, i)
                if ok and Readable(name) and name == proc.talent then
                    answer = Readable(rank) and type(rank) == "number" and rank > 0
                    break
                end
            end
            if answer ~= nil then break end
        end
    end
    if answer == nil then
        -- neither API could tell: trust having read the buff before
        local seen = ProcDocDB.seen[playerClass]
        answer = (seen and seen[proc.key]) and true or false
    end
    proc.hasTalent = answer
    Trace("%s talent check: %s", proc.key, answer and "yes" or "no")
    return answer
end

function Predict.ResetTalents()
    for _, proc in ipairs(buffProcs) do proc.hasTalent = nil end
end

function Predict.Run(trigger, why)
    local list
    for _, proc in ipairs(buffProcs) do
        if proc.predictOn == trigger and IsProcEnabled(proc) and Predict.HasTalent(proc) then
            list = list or {}
            list[#list + 1] = proc
        end
    end
    if not list then return end
    CheckProcs()                       -- buffs readable: that scan is the truth
    if not auraLocked then return end
    local now = GetTime()
    for _, proc in ipairs(list) do
        local dur = proc.predictDuration or 10
        SetLive(proc, "aura", { exp = now + dur, dur = dur, charges = proc.charges or 1, predicted = true })
        local a = alerts[proc.key]
        -- the killing blow's own cast can land just after the reward
        a.pendingConsume, a.liveSince = nil, now
        Trace("%s predicted from %s (buffs are hidden)", proc.key, why)
    end
end

-- "KILL" procs come from YOUR killing blow on an enemy that isn't trivial.
-- Addons get no combat log on Forever, so a killing blow is recognised as
-- two things landing together: an enemy dying (your target, a nameplate, or
-- an XP/honor reward) and a buff change on you (UNIT_AURA; which buff is
-- hidden in combat). A death with no buff change was someone else's kill or
-- a trivial enemy; a buff change with no death is just some other buff.
local kill = { WINDOW = 0.5, death = -1000, aura = -2000, fired = -1000, targetDead = true }

function kill.Try()
    if math.abs(kill.death - kill.aura) > kill.WINDOW then return end
    local why = kill.why
    kill.death, kill.aura, kill.fired = -1000, -2000, GetTime()
    Predict.Run("KILL", "your killing blow (" .. why .. " + a buff arrived)")
end

function kill.NoteDeath(why)
    local now = GetTime()
    if now - kill.fired < 1 then return end   -- more signals from the same kill
    kill.death, kill.why = now, why
    Trace("enemy died (%s)", why)
    kill.Try()
end

function kill.NoteAura()
    kill.aura = GetTime()
    kill.Try()
end

function kill.ReadXP()
    local xp = UnitXP and SafeCall(UnitXP, "player")
    if Readable(xp) and type(xp) == "number" then return xp end
end

-- Readable yes/no from a unit query, or nil when the game hides it
function kill.UnitFlag(fn, ...)
    if not fn then return nil end
    local v = SafeCall(fn, ...)
    if Readable(v) then return v and true or false end
end

function kill.IsDeadEnemy(unit)
    if kill.UnitFlag(UnitIsDead, unit) ~= true then return false end
    return kill.UnitFlag(UnitIsFriend, "player", unit) == false
end

-- Highest enemy level that's grey to a player of this level (the classic
-- rule; at 60 it's 9 levels below you). Grey kills never proc these.
function kill.GrayLevel(level)
    if level <= 5 then return 0 end
    if level <= 39 then return level - 5 - math.floor(level / 10) end
    if level <= 59 then return level - 1 - math.floor(level / 5) end
    return level - 9
end

function kill.IsGrey(unit)
    local trivial = kill.UnitFlag(UnitIsTrivial, unit)
    if trivial ~= nil then return trivial end
    local mob, me = SafeCall(UnitLevel, unit), SafeCall(UnitLevel, "player")
    if not (Readable(mob) and Readable(me)) or type(mob) ~= "number" or type(me) ~= "number" then return false end
    return mob >= 1 and mob <= kill.GrayLevel(me)      -- -1 = "??", never grey
end

-- Your target or a nameplate enemy just died: grey ones don't count
function kill.UnitDied(unit, why)
    if kill.IsGrey(unit) then
        Trace("enemy died (%s) but it was grey: no killing-blow proc", why)
        return
    end
    kill.NoteDeath(why)
end

-- XP and honor rewards only say an enemy died; they happen in groups
-- too when a party member lands the blow
function kill.OnEvent(event, unit)
    if event == "PLAYER_XP_UPDATE" then
        local xp = kill.ReadXP()
        local changed = xp and kill.xp and xp ~= kill.xp
        kill.xp = xp or kill.xp
        if changed then kill.NoteDeath("XP") end
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        kill.NoteDeath("XP")
    elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        kill.NoteDeath("honor")
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        -- a corpse you click on isn't a fresh death (hidden counts as dead)
        kill.targetDead = kill.UnitFlag(UnitIsDead, "target") ~= false
        if event == "PLAYER_ENTERING_WORLD" then kill.xp = kill.ReadXP() end
    elseif event == "UNIT_HEALTH" or event == "UNIT_FLAGS" then
        if not (Readable(unit) and unit == "target") then return end
        local dead = kill.UnitFlag(UnitIsDead, "target")
        if dead == nil then return end
        if dead and not kill.targetDead and kill.IsDeadEnemy("target") then kill.UnitDied("target", "your target") end
        kill.targetDead = dead
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if Readable(unit) and type(unit) == "string" and kill.IsDeadEnemy(unit) then kill.UnitDied(unit, "a nameplate") end
    end
end

-- 8) Action-based detection (reaction abilities)
--    Ready = usable (action-bar slot if the spell is on a bar, else the spell
--    API) and not on a real cooldown (GCD ignored). A rising edge starts the
--    alert + window timer; after the window or a cast, the proc stays
--    suppressed until the ability stops being usable.
local actionState       = {}   -- procKey -> { active, suppressed }
local actionSlotByName  = {}   -- localized spell name -> action slot
local glowActive        = {}   -- localized spell name -> true (Blizzard button glow)

local function RebuildActionSlots()
    wipe(actionSlotByName)
    if not GetActionInfo then return end
    for slot = 1, 180 do
        local actionType, id = SafeCall(GetActionInfo, slot)
        if Readable(actionType) and actionType == "spell" and Readable(id) then
            local n = GetSpellNameCompat(id)
            if n and not actionSlotByName[n] then actionSlotByName[n] = slot end
        end
    end
end

local function GetActionProcDuration(proc)
    local d = PS(proc.key).duration
    if d and d > 0 then return d end
    return ACTION_PROC_DEFAULT_DURATIONS[proc.spellName or ""]
end

-- Returns ready, how (a short note for the trace). Usability comes from the
-- action bar slot or the spell API; if Forever hides both (secret in combat),
-- fall back to the dodge/parry/block we saw (UNIT_COMBAT, `reactOn`) within
-- the reaction window, and not within the ability's own cooldown after a cast.
local function IsActionProcReady(proc)
    local name = proc.localName
    if not name then return false, "unknown spell" end
    local st = actionState[proc.key] or {}
    local now = GetTime()
    local usable, how
    local slot = actionSlotByName[name]
    if slot and IsUsableAction then
        local u = SafeCall(IsUsableAction, slot)
        if issecret(u) then
            how = "bar:secret"
        elseif u ~= nil then
            usable, how = u and true or false, "bar"
        end
    end
    if usable == nil then
        local u = IsSpellUsableCompat(name)
        if issecret(u) then
            how = (how and (how .. ", ") or "") .. "spell:secret"
        elseif u ~= nil then
            usable, how = u and true or false, "spell"
        end
    end
    if glowActive[name] then usable, how = true, "glow" end
    if usable == nil then
        usable = (st.reactUntil or 0) > now and (now - (st.lastCast or -1000)) >= (proc.cooldown or 0)
        how = (how and (how .. ", ") or "") .. "react"
    end
    if not usable then return false, how end

    local start, duration = GetSpellCooldownCompat(name)
    if Readable(start) and Readable(duration) and start and duration
        and duration > 1.5 and start > 0 and (start + duration - now) > 0.1 then
        return false, how .. ", cooldown"
    end
    return true, how
end

local function CheckActionProc(proc)
    local st = actionState[proc.key]
    if not st then
        st = {}
        actionState[proc.key] = st
    end
    local ready, how = false, "disabled"
    if IsProcEnabled(proc) then ready, how = IsActionProcReady(proc) end
    if G.trace then
        local state = (ready and "ready" or "not ready") .. " (" .. tostring(how) .. ")"
        if st.lastState ~= state then
            st.lastState = state
            Trace("%s %s", proc.key, state)
        end
    end
    if ready then
        if not st.active and not st.suppressed then
            st.active = true
            local dur = GetActionProcDuration(proc)
            SetLive(proc, "action", { exp = dur and (GetTime() + dur), dur = dur })
        end
    else
        st.suppressed = false
        if st.active then
            st.active = false
            SetLive(proc, "action", nil)
        end
    end
end

CheckAllActionProcs = function()
    for _, proc in ipairs(actionProcs) do
        CheckActionProc(proc)
    end
end

ExpireActionProc = function(proc)
    local st = actionState[proc.key]
    if st then
        st.active = false
        st.suppressed = true
    end
    SetLive(proc, "action", nil)
end

-- 9) Event frame for action-based procs, Blizzard proc overlays and login
local initialized = false
local debugOverlays = false

local function ProcForSpell(spellID)
    if not Readable(spellID) then return nil end
    local proc = buffBySpellID[spellID]
    if proc then return proc end
    local n = GetSpellNameCompat(spellID)
    if n then return buffByName[n] or actionByName[n], n end
    return nil
end

local function AddDetectedProc(spellID, art, location)
    local name = GetSpellNameCompat(spellID) or ("Spell " .. spellID)
    location = Clean(location)
    local style = (type(location) == "string" and LOCATION_STYLES[location:upper()]) or "TOP"
    local info = { name = name, art = Readable(art) and art or nil, style = style }
    ProcDocDB.detected[playerClass] = ProcDocDB.detected[playerClass] or {}
    ProcDocDB.detected[playerClass][spellID] = info
    local proc = MakeDetectedProc(spellID, info)
    RegisterProc(proc, false)
    Print("detected a new proc: |cffffd100" .. name .. "|r. Customise it in |cff00ffff/procdoc|r.")
    if RefreshOptions then RefreshOptions(true) end
    return proc
end

local function OnOverlayShow(spellID, art, location)
    Trace("Blizzard proc overlay SHOW %s", SV(spellID))
    if not Readable(spellID) then return end
    local proc, name = ProcForSpell(spellID)
    if debugOverlays then
        Print(string.format("overlay SHOW %s (%s) art=%s loc=%s", tostring(spellID),
            tostring(name or GetSpellNameCompat(spellID)), tostring(art), tostring(location)))
    end
    if proc then
        if Readable(art) and not proc.blizzardArt then proc.blizzardArt = art end
        if proc.isAction then
            glowActive[proc.localName or proc.spellName] = true
            CheckActionProc(proc)
        else
            SetLive(proc, "overlay", {})
        end
        return
    end
    if not G.autoDetect then return end
    SetLive(AddDetectedProc(spellID, art, location), "overlay", {})
end

local function OnOverlayHide(spellID)
    -- the client fires HIDE with no spell constantly; only log real ones
    if issecret(spellID) or spellID ~= nil then Trace("Blizzard proc overlay HIDE %s", SV(spellID)) end
    if issecret(spellID) then return end
    if spellID == nil then
        for _, proc in ipairs(buffProcs) do SetLive(proc, "overlay", nil) end
        return
    end
    local proc = ProcForSpell(spellID)
    if proc and not proc.isAction then
        -- While auras are locked, Blizzard hiding its overlay is our best
        -- signal the proc was spent: drop an aura state we can't verify.
        local a = alerts[proc.key]
        local cur = a and a.sources.aura
        if auraLocked and cur and not (cur.inst and removalReadable) then
            ClearAuraSource(proc)
        end
        SetLive(proc, "overlay", nil)
    end
end

local function OnGlow(spellID, on)
    Trace("action button glow %s %s", on and "ON" or "OFF", SV(spellID))
    if not Readable(spellID) then return end
    local n = GetSpellNameCompat(spellID)
    local proc = n and actionByName[n]
    if proc then
        glowActive[proc.localName or n] = on or nil
        CheckActionProc(proc)
    end
end

local function ApplyBlizzardOverlaySetting()
    if G.hideBlizzardOverlay then
        SetCVarCompat("displaySpellActivationOverlays", "0")
    end
end

-- Safety net for event handlers: the modern client can hand us "secret"
-- values we didn't anticipate, and touching one raises an error. Record it
-- (shown by /procdoc debug) and mention it once, instead of spamming errors.
ProcDoc_LastError = nil
local errorNoticeShown = false
local function GuardedHandler(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            ProcDoc_LastError = tostring(err)
            if debugOverlays then
                Print("|cffff5555error:|r " .. ProcDoc_LastError)
            elseif not errorNoticeShown then
                errorNoticeShown = true
                Print("hit a value the game keeps hidden in combat and skipped it. Type |cff00ffff/procdoc debug|r to see details.")
            end
        end
    end
end

local actionFrame = CreateFrame("Frame", "ProcDocActionFrame", UIParent)
for _, ev in ipairs({
    "PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_USABLE",
    "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
    "UPDATE_SHAPESHIFT_FORM", "SPELL_UPDATE_USABLE", "SPELLS_CHANGED",
    "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
    "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "SPELL_ACTIVATION_OVERLAY_SHOW", "SPELL_ACTIVATION_OVERLAY_HIDE",
    "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
    "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE",   -- talent checks (predicted procs)
}) do
    SafeRegister(actionFrame, ev)
end
local castEventPlayerOnly = SafeRegister(actionFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
-- Your dodges/parries/blocks (and the target's dodges): the fallback trigger
-- for reaction abilities when their usability is hidden in combat
if not pcall(actionFrame.RegisterUnitEvent, actionFrame, "UNIT_COMBAT", "player", "target") then
    SafeRegister(actionFrame, "UNIT_COMBAT")
end

actionFrame:SetScript("OnEvent", GuardedHandler(function(self, event, arg1, arg2, arg3)
    if not initialized then return end
    if event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" or event == "ACTIONBAR_SLOT_CHANGED" then
        if event == "SPELLS_CHANGED" then
            for _, proc in ipairs(actionProcs) do
                proc.localName = (proc.spellID and GetSpellNameCompat(proc.spellID)) or proc.spellName
                if proc.localName then actionByName[proc.localName] = proc end
            end
            Predict.ResetTalents()
        end
        RebuildActionSlots()
        CheckAllActionProcs()
        CheckProcs()
    elseif event == "SPELL_ACTIVATION_OVERLAY_SHOW" then
        OnOverlayShow(arg1, arg2, arg3)
    elseif event == "SPELL_ACTIVATION_OVERLAY_HIDE" then
        OnOverlayHide(arg1)
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        OnGlow(arg1, true)
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        OnGlow(arg1, false)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1=unit, arg2=castGUID, arg3=spellID (either may be secret)
        local isPlayer = (Readable(arg1) and arg1 == "player") or (issecret(arg1) and castEventPlayerOnly)
        if isPlayer then
            local castName = Readable(arg3) and GetSpellNameCompat(arg3) or nil
            Trace("cast %s", castName or "<secret spell>")
            if ConsumeBuffProcs(castName) then
                C_Timer.After(0.3, GuardedHandler(function() ResolvePendingConsumes(true) end))
            end
            Remind.OnCast(castName)
            local proc = castName and actionByName[castName]
            if proc then
                local st = actionState[proc.key] or {}
                actionState[proc.key] = st
                st.lastCast, st.reactUntil = GetTime(), nil
                if st.active then ExpireActionProc(proc) end
            end
        end
        CheckAllActionProcs()
    elseif event == "UNIT_COMBAT" then
        -- arg1 = unit, arg2 = action ("PARRY", "DODGE", "BLOCK", "WOUND"...),
        -- arg3 = flag text (e.g. "BLOCK" on a partial block)
        if Readable(arg1) and Readable(arg2) then
            local flag = Readable(arg3) and arg3 or nil
            local now = GetTime()
            for _, proc in ipairs(actionProcs) do
                local on = proc.reactOn and proc.reactOn[arg1]
                if on and (on[arg2] or (flag and on[flag])) then
                    local st = actionState[proc.key] or {}
                    actionState[proc.key] = st
                    st.reactUntil = now + (GetActionProcDuration(proc) or 5)
                    Trace("%s %s -> %s window open", arg1, flag and on[flag] and flag or arg2, proc.key)
                end
            end
            if arg1 == "player" and arg2 == "WOUND" and flag == "CRITICAL" then
                Predict.Run("CRIT_TAKEN", "a crit you took")
            end
            CheckAllActionProcs()
        end
    elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
        Predict.ResetTalents()
    elseif event == "PLAYER_REGEN_DISABLED" then
        Trace("entered combat")
        CheckAllActionProcs()
    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        RefreshAllAlerts()     -- real-pixel sizing depends on both
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Aura data unlocks after combat: resync everything
        Trace("left combat")
        CheckProcs()
        CheckAllActionProcs()
    else
        CheckAllActionProcs()
    end
end))

-- Enemy deaths, for killing-blow procs (section 7)
do
local killFrame = CreateFrame("Frame", "ProcDocKillFrame", UIParent)
for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_XP_UPDATE",
    "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_COMBAT_HONOR_GAIN", "NAME_PLATE_UNIT_REMOVED" }) do
    SafeRegister(killFrame, ev)
end
SafeRegister(killFrame, "UNIT_HEALTH", "target")
SafeRegister(killFrame, "UNIT_FLAGS", "target")
killFrame:SetScript("OnEvent", GuardedHandler(function(self, event, unit)
    if initialized then kill.OnEvent(event, unit) end
end))
end

-- Blizzard's Cooldown Manager can see your buffs in combat, which addons
-- can't. When a proc is in its Tracked Buffs, ProcDoc follows the icon
-- Blizzard shows for it: while buffs are hidden, an active icon turns the
-- proc on (source "cdm") and an inactive one turns it off. Once buffs are
-- readable again the normal scan is the truth and the "cdm" source is
-- dropped. How an icon says "active" isn't documented for this client, so
-- CDM.Active tries several signals and `/procdoc cdm` shows what it finds.
local CDM = {
    VIEWERS  = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" },
    byID     = {},                           -- cooldownID -> proc, or false
    live     = {},                           -- procKey -> true while its icon is active
    sawAura  = setmetatable({}, { __mode = "k" }),  -- icon -> true once it had an aura
    elapsed  = 0,
    wiped    = 0,
    wasLocked = false,
}

function CDM.Items()
    local out = {}
    for _, name in ipairs(CDM.VIEWERS) do
        local viewer = _G[name]
        if type(viewer) == "table" and type(viewer.GetChildren) == "function" then
            for _, f in ipairs({ viewer:GetChildren() }) do out[#out + 1] = f end
        end
    end
    return out
end

function CDM.CooldownID(f)
    local id = Clean(f.cooldownID)
    if id == nil and type(f.GetCooldownID) == "function" then id = Clean(SafeCall(f.GetCooldownID, f)) end
    if type(id) == "number" then return id end
end

-- Every spell ID Blizzard ties to a Cooldown Manager entry
function CDM.SpellIDs(cooldownID, f)
    local ids = {}
    local function Add(v)
        v = Clean(v)
        if type(v) == "number" then ids[#ids + 1] = v end
    end
    local info = Clean(SafeCall(C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID))
    if type(info) == "table" then
        Add(info.spellID); Add(info.overrideSpellID); Add(info.overrideTooltipSpellID)
        local linked = Clean(info.linkedSpellIDs)
        if type(linked) == "table" then
            for _, v in ipairs(linked) do Add(v) end
        end
    end
    if f then
        for _, m in ipairs({ "GetSpellID", "GetBaseSpellID", "GetAuraSpellID" }) do
            if type(f[m]) == "function" then Add(SafeCall(f[m], f)) end
        end
    end
    return ids
end

function CDM.ProcFor(cooldownID, f)
    if not cooldownID then return nil end
    local cached = CDM.byID[cooldownID]
    if cached ~= nil then return cached or nil end
    local ids = CDM.SpellIDs(cooldownID, f)
    local proc
    for _, id in ipairs(ids) do
        proc = buffBySpellID[id]
        if not proc then
            for _, p in ipairs(buffProcs) do
                for _, t in ipairs(p.talentIDs or {}) do
                    if t == id then proc = p end
                end
            end
        end
        if not proc then
            local n = GetSpellNameCompat(id)
            proc = n and (buffByName[n] or nil)
        end
        if proc then break end
    end
    if #ids > 0 then CDM.byID[cooldownID] = proc or false end
    return proc
end

-- true / false, or nil when the icon gives nothing readable; plus how
function CDM.Active(f)
    local shown = SafeCall(f.IsShown, f)
    if Readable(shown) and not shown then return false, "hidden" end
    if type(f.IsActive) == "function" then
        local v = SafeCall(f.IsActive, f)
        if Readable(v) and type(v) == "boolean" then return v, "IsActive" end
    end
    local v = f.isActive
    if Readable(v) and type(v) == "boolean" then return v, "isActive" end
    local inst = f.auraInstanceID
    if issecret(inst) or inst ~= nil then           -- a hidden value still means "there is one"
        CDM.sawAura[f] = true
        return true, "aura"
    end
    if CDM.sawAura[f] then return false, "aura gone" end
    if Readable(shown) then return true, "shown" end
    return nil, "unknown"
end

function CDM.Poll()
    local now = GetTime()
    if not auraLocked then
        if CDM.wasLocked then
            -- buffs readable again: say whether the icons were right, then let the scan rule
            for key in pairs(CDM.live) do
                local a = alerts[key]
                Trace("after combat: Cooldown Manager said %s was up; the buff check %s", key,
                    (a and a.sources.aura) and "agrees" or "does NOT find it")
                local proc = procByKey[key]
                if proc then SetLive(proc, "cdm", nil) end
            end
            wipe(CDM.live)
        end
        CDM.wasLocked = false
        if now - CDM.wiped > 10 then wipe(CDM.byID); CDM.wiped = now end   -- pick up setting changes
        return
    end
    CDM.wasLocked = true
    local want, how = {}, {}
    for _, f in ipairs(CDM.Items()) do
        local proc = CDM.ProcFor(CDM.CooldownID(f), f)
        if proc and IsProcEnabled(proc) then
            local active, why = CDM.Active(f)
            if active then want[proc.key], how[proc.key] = proc, why end
        end
    end
    for key, proc in pairs(want) do
        if not CDM.live[key] then
            CDM.live[key] = true
            local dur = proc.lastDuration or proc.predictDuration or 10
            SetLive(proc, "cdm", { exp = now + dur, dur = dur })
            Trace("%s is up in the Cooldown Manager (%s)", key, how[key])
        end
    end
    for key in pairs(CDM.live) do
        if not want[key] then
            CDM.live[key] = nil
            local proc = procByKey[key]
            if proc then SetLive(proc, "cdm", nil) end
            Trace("%s went away in the Cooldown Manager", key)
        end
    end
end

-- One-time tip per proc: it's offered in the Cooldown Manager but not tracked
function CDM.Tip()
    local api, cats = C_CooldownViewer, Enum and Enum.CooldownViewerCategory
    if not (api and api.GetCooldownViewerCategorySet and cats) then return end
    local tracked = {}
    for _, f in ipairs(CDM.Items()) do
        local p = CDM.ProcFor(CDM.CooldownID(f), f)
        if p then tracked[p.key] = true end
    end
    local told = ProcDocDB.cdmTips[playerClass] or {}
    ProcDocDB.cdmTips[playerClass] = told
    for _, cat in ipairs({ cats.TrackedBuff, cats.TrackedBar }) do
        local ids = Clean(SafeCall(api.GetCooldownViewerCategorySet, cat, true))
        if type(ids) == "table" then
            for _, cid in ipairs(ids) do
                local p = CDM.ProcFor(Clean(cid))
                if p and not tracked[p.key] and not told[p.key] and IsProcEnabled(p) then
                    told[p.key] = true
                    Print("tip: the game hides buffs from addons in combat. Add |cffffd100" .. p.buffName ..
                        "|r to Blizzard's Cooldown Manager (Tracked Buffs) and ProcDoc will catch it mid-fight too.")
                end
            end
        end
    end
end

-- /procdoc cdm: what the Cooldown Manager is tracking and what ProcDoc reads from it
function CDM.Report()
    wipe(CDM.byID)
    local keysShown = false
    for _, name in ipairs(CDM.VIEWERS) do
        local viewer = _G[name]
        if type(viewer) ~= "table" or type(viewer.GetChildren) ~= "function" then
            Print(name .. ": not found")
        else
            local kids = { viewer:GetChildren() }
            Print(string.format("%s: %d icon(s)", name, #kids))
            for _, f in ipairs(kids) do
                local cid = CDM.CooldownID(f)
                if cid then
                    local names = {}
                    for _, id in ipairs(CDM.SpellIDs(cid, f)) do
                        names[#names + 1] = (GetSpellNameCompat(id) or "?") .. " " .. id
                    end
                    local proc = CDM.ProcFor(cid, f)
                    local active, why = CDM.Active(f)
                    local state = (active == nil and "unknown") or (active and "active") or "inactive"
                    DEFAULT_CHAT_FRAME:AddMessage(string.format("  #%d %s -> %s, %s (%s)", cid,
                        #names > 0 and table.concat(names, ", ") or "no spell info",
                        proc and ("|cff00ff96" .. proc.buffName .. "|r") or "not a ProcDoc proc", state, why))
                    if not keysShown then
                        -- the icon's own fields, to see which ones say "active" on this client
                        keysShown = true
                        local keys = {}
                        for k in pairs(f) do
                            if type(k) == "string" and (k:lower():find("aura") or k:lower():find("active")
                                or k:lower():find("spell") or k:lower():find("cooldown")) then
                                keys[#keys + 1] = k
                            end
                        end
                        table.sort(keys)
                        Print("icon fields: " .. (#keys > 0 and table.concat(keys, ", ") or "none"))
                        Trace("Cooldown Manager icon fields: %s", table.concat(keys, ", "))
                    end
                end
            end
        end
    end
end

do
local cdmFrame = CreateFrame("Frame", "ProcDocCooldownManagerFrame", UIParent)
SafeRegister(cdmFrame, "PLAYER_ENTERING_WORLD")
cdmFrame:SetScript("OnEvent", GuardedHandler(function()
    C_Timer.After(5, GuardedHandler(function() if initialized then CDM.Tip() end end))
end))
cdmFrame:SetScript("OnUpdate", GuardedHandler(function(self, dt)
    CDM.elapsed = CDM.elapsed + dt
    if CDM.elapsed < 0.1 or not initialized then return end
    CDM.elapsed = 0
    CDM.Poll()
end))
end

-- Reminders re-check on death and coming back, and a few seconds after
-- zoning (buffs can read empty for a moment then)
do
local remindFrame = CreateFrame("Frame", "ProcDocReminderFrame", UIParent)
for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
    SafeRegister(remindFrame, ev)
end
remindFrame:SetScript("OnEvent", GuardedHandler(function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        Remind.quietUntil = GetTime() + 3
        C_Timer.After(3.1, GuardedHandler(function()
            if initialized then CheckProcs(); Remind.RefreshAll() end
        end))
        return
    end
    if initialized then Remind.RefreshAll() end
end))
end

-- 10) Aura change event (buff-based proc refresh)
--    While buffs are hidden the payload can't say which buff changed, but a
--    change that isn't purely a removal still marks "a buff arrived" for
--    killing-blow procs.
function kill.AuraChangeKind(updateInfo)
    if type(updateInfo) ~= "table" then return "hidden" end
    local full, added, updated = updateInfo.isFullUpdate, updateInfo.addedAuras, updateInfo.updatedAuraInstanceIDs
    if issecret(full) or issecret(added) or issecret(updated) then return "hidden" end
    if full == true then return "full" end
    if type(added) == "table" and #added > 0 then return "added" end
    if type(updated) == "table" and #updated > 0 then return "updated" end
    return nil                                    -- removals only
end

local auraFrame = CreateFrame("Frame", "ProcDocAuraFrame", UIParent)
SafeRegister(auraFrame, "UNIT_AURA", "player")
auraFrame:SetScript("OnEvent", GuardedHandler(function(self, event, unit, updateInfo)
    if not initialized or not Readable(unit) or unit ~= "player" then return end
    updateInfo = Clean(updateInfo)
    if type(updateInfo) == "table" then
        local full = Clean(updateInfo.isFullUpdate)
        if full ~= true then
            HandleAuraUpdate(updateInfo)
        end
    end
    CheckProcs()
    local kind = kill.AuraChangeKind(updateInfo)
    if kind and auraLocked then
        Trace("buff change while hidden (%s)", kind)
        kill.NoteAura()
    end
end))

-- 11) Test proc + unlock (arrange) mode
--    Previews stay up until hidden (or the options window closes) unless a
--    duration is given; they show a looping sample countdown.

-- Length of the sample countdown for a proc
SampleDuration = function(proc)
    if proc.isAction then return GetActionProcDuration(proc) or 5 end
    local d = proc.lastDuration
    if d and d >= 2 and d <= 60 then return d end
    return 10
end

local function TestProc(proc, seconds, silent)
    local a = GetAlert(proc)
    local now = GetTime()
    if not a.test then a.testStart = now end
    a.popStart = now
    a.test = true
    a.testDuration = SampleDuration(proc)
    a.testUntil = seconds and (now + seconds) or nil
    if not a.shown then a.phase = 0 end
    RefreshAlert(a)
    if not silent and not G.isMuted then
        PlaySoundKey(PS(proc.key).sound or G.defaultSound)
    end
end

local function StopTests()
    for _, a in pairs(alerts) do
        if a.test then
            a.test, a.testUntil = false, nil
            RefreshAlert(a)
        end
    end
end

local function TestAll(seconds)
    local first = true
    for _, proc in ipairs(classProcs) do
        if IsProcEnabled(proc) then
            TestProc(proc, seconds, not first)
            first = false
        end
    end
    if first then Print("no enabled procs to preview for this class.") end
end

local function AnyAlertShown()
    for _, a in pairs(alerts) do
        if a.shown then return true end
    end
    return false
end

-- Replays the pop-in on every visible alert (previewing the pop settings)
local function PopAll()
    local now = GetTime()
    for _, a in pairs(alerts) do
        if a.shown then a.popStart = now end
    end
end

-- Called by the options window when it opens/closes: alerts take the mouse
-- (drag / Shift+wheel) only while editing.
-- Stack test (/procdoc stacktest [name], or "Test stacks" on a proc page):
-- feeds a pretend stacking buff through the real alert path -- the "show at
-- N stacks" threshold, the dots and their pops, the countdown and the
-- shrink-away -- so stack visuals can be checked without a stacking buff.
local stackTest
local STACK_TEST_STEPS = { 1, 2, 3, 4, 5, 4, 3, 0 }

local function RunStackTest(proc)
    if not proc or proc.isAction then return false end
    local run = { proc = proc, i = 0, t0 = GetTime() }
    if stackTest and stackTest.proc ~= proc then SetLive(stackTest.proc, "sim", nil) end
    stackTest = run
    local function step()
        if stackTest ~= run then return end                  -- a newer test took over
        run.i = run.i + 1
        local n = STACK_TEST_STEPS[run.i]
        if not n or n == 0 then
            SetLive(proc, "sim", nil)
            stackTest = nil
            return
        end
        local need = PS(proc.key).minStacks or proc.minStacks
        if need and need > 1 and n < need then
            SetLive(proc, "sim", nil)                         -- below the threshold: hidden
        else
            SetLive(proc, "sim", { stacks = n, slots = 5, exp = run.t0 + 9, dur = 9 })
        end
        C_Timer.After(0.9, step)
    end
    step()
    return true
end

local function SetOptionsOpen(open)
    optionsOpen = open and true or false
    RefreshAllAlerts()
end

local unlockBar, centerGuide
local function SetUnlocked(on)
    unlockMode = on and true or false
    unlockStart = GetTime()
    for _, proc in ipairs(classProcs) do
        RefreshAlert(GetAlert(proc))
    end
    if unlockMode and not unlockBar then
        unlockBar = CreateFrame("Frame", "ProcDocUnlockBar", UIParent, "BackdropTemplate")
        unlockBar:SetSize(560, 40)
        unlockBar:SetPoint("TOP", UIParent, "TOP", 0, -90)
        unlockBar:SetFrameStrata("DIALOG")
        unlockBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        unlockBar:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
        unlockBar:SetBackdropBorderColor(accentR, accentG, accentB, 1)
        local txt = unlockBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        txt:SetPoint("LEFT", 14, 0)
        txt:SetText("|cff00ff96ProcDoc|r  Drag to move  ·  Shift + wheel to resize  ·  Right-click to edit")
        local lock = CreateFrame("Button", nil, unlockBar, "UIPanelButtonTemplate")
        lock:SetSize(70, 22)
        lock:SetPoint("RIGHT", -10, 0)
        lock:SetText("Lock")
        lock:SetScript("OnClick", function() SetUnlocked(false) end)

        -- Faint crosshair through the screen centre to line alerts up
        centerGuide = CreateFrame("Frame", nil, UIParent)
        centerGuide:SetAllPoints(UIParent)
        centerGuide:SetFrameStrata("LOW")
        local v = centerGuide:CreateTexture(nil, "ARTWORK")
        v:SetColorTexture(1, 1, 1, 0.18)
        v:SetWidth(1)
        v:SetPoint("TOP")
        v:SetPoint("BOTTOM")
        local h = centerGuide:CreateTexture(nil, "ARTWORK")
        h:SetColorTexture(1, 1, 1, 0.18)
        h:SetHeight(1)
        h:SetPoint("LEFT")
        h:SetPoint("RIGHT")
    end
    if unlockBar then
        unlockBar:SetShown(unlockMode)
        centerGuide:SetShown(unlockMode)
    end
    if RefreshOptions then RefreshOptions() end
end

-- Minimap button (part of 11: quick access to the options / arrange mode).
-- Self-contained (no LibDBIcon). Left-click: options. Right-click: arrange
-- mode. Drag: slide it around the minimap edge (angle in G.minimapAngle).
local MINIMAP_SHAPES = {     -- which quadrants are rounded, per GetMinimapShape()
    ["ROUND"]                 = { true,  true,  true,  true  },
    ["SQUARE"]                = { false, false, false, false },
    ["CORNER-TOPLEFT"]        = { false, false, false, true  },
    ["CORNER-TOPRIGHT"]       = { false, false, true,  false },
    ["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
    ["CORNER-BOTTOMRIGHT"]    = { true,  false, false, false },
    ["SIDE-LEFT"]             = { false, true,  false, true  },
    ["SIDE-RIGHT"]            = { true,  false, true,  false },
    ["SIDE-TOP"]              = { false, false, true,  true  },
    ["SIDE-BOTTOM"]           = { true,  true,  false, false },
    ["TRICORNER-TOPLEFT"]     = { false, true,  true,  true  },
    ["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true  },
    ["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true  },
    ["TRICORNER-BOTTOMRIGHT"] = { true,  true,  true,  false },
}
local minimapButton

local function UpdateMinimapButtonPosition()
    if not minimapButton or not Minimap then return end
    local angle = math.rad(G.minimapAngle or 220)
    local x, y = math.cos(angle), math.sin(angle)
    local quadrant = 1
    if x < 0 then quadrant = quadrant + 1 end
    if y > 0 then quadrant = quadrant + 2 end
    local shape = (GetMinimapShape and SafeCall(GetMinimapShape)) or "ROUND"
    local rounded = (MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND)[quadrant]
    local w = (Minimap:GetWidth() / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5
    if rounded then
        x, y = x * w, y * h
    else
        local diagW = math.sqrt(2 * w * w) - 10
        local diagH = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * diagW, w))
        y = math.max(-h, math.min(y * diagH, h))
    end
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function MinimapButtonDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not mx or not px or not scale or scale == 0 then return end
    px, py = px / scale, py / scale
    G.minimapAngle = math.floor(math.deg(atan2(py - my, px - mx)) % 360 + 0.5)
    UpdateMinimapButtonPosition()
end

local function MinimapButtonTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("ProcDoc", 1, 1, 1)
    GameTooltip:AddLine("|cffffd100Left-click|r  Open / close options", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("|cffffd100Right-click|r  " .. (unlockMode and "Done arranging alerts" or "Arrange alerts on screen"), 0.85, 0.85, 0.85)
    GameTooltip:AddLine("|cffffd100Drag|r  Move this button", 0.85, 0.85, 0.85)
    GameTooltip:Show()
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then return end
    local b = CreateFrame("Button", "ProcDocMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexture(ICON)
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER")
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            SetUnlocked(not unlockMode)
        elseif ToggleOptions then
            ToggleOptions()
        end
        if GameTooltip:GetOwner() == self then MinimapButtonTooltip(self) end
    end)
    b:SetScript("OnMouseDown", function(self) self.icon:SetTexCoord(0.14, 0.86, 0.14, 0.86) end)
    b:SetScript("OnMouseUp", function(self) self.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", MinimapButtonDragUpdate)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end)
    b:SetScript("OnEnter", MinimapButtonTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapButton = b
    UpdateMinimapButtonPosition()
end

local function SetMinimapButtonShown(show)
    G.minimapHide = not show
    if show then CreateMinimapButton() end
    if minimapButton then minimapButton:SetShown(show and true or false) end
end

-- Everything the options UI needs from the core, handed over in one table:
-- Lua 5.1 allows at most 60 upvalues per function, and BuildOptionsModule
-- would otherwise capture ~60. Only values that change at runtime (G,
-- unlockMode, accent colors, playerClass, ...) stay real upvalues.
local API = {
    GetAlert = GetAlert,
    RefreshAlert = RefreshAlert,
    TestProc = TestProc,
    AnyAlertShown = AnyAlertShown,
    RefreshAllAlerts = RefreshAllAlerts,
    TestAll = TestAll,
    SOUND_BY_KEY = SOUND_BY_KEY,
    SOUNDS = SOUNDS,
    ResolveImage = ResolveImage,
    PS = PS,
    ProcPlacement = ProcPlacement,
    PieceOrientation = PieceOrientation,
    ApplyTexCoord = ApplyTexCoord,
    IsProcEnabled = IsProcEnabled,
    PSW = PSW,
    alerts = alerts,
    ReevaluateAll = ReevaluateAll,
    ProcIcon = ProcIcon,
    classProcs = classProcs,
    Print = Print,
    AddCustomProc = AddCustomProc,
    CurrentBuffOptions = CurrentBuffOptions,
    ClassSettings = ClassSettings,
    SetUnlocked = SetUnlocked,
    SetMinimapButtonShown = SetMinimapButtonShown,
    RunStackTest = RunStackTest,
    StyleAnchors = StyleAnchors,
    ROTATION_OPTIONS = ROTATION_OPTIONS,
    PlaySoundKey = PlaySoundKey,
    TimerFont = TimerFont,
    COLOR_BY_KEY = COLOR_BY_KEY,
    COLOR_CHOICES = COLOR_CHOICES,
    GetActionProcDuration = GetActionProcDuration,
    RemoveListedProc = RemoveListedProc,
    FONT_CHOICES = FONT_CHOICES,
    OUTLINE_CHOICES = OUTLINE_CHOICES,
    SOUND_CHANNELS = SOUND_CHANNELS,
    SetCVarCompat = SetCVarCompat,
    ProcDoc_LoadGlobalsFromDB = ProcDoc_LoadGlobalsFromDB,
    IMG = IMG,
    ICON = ICON,
    DEFAULT_ALERT_TEXTURE = DEFAULT_ALERT_TEXTURE,
    IMAGE_LIST = IMAGE_LIST,
    IMAGE_SIZE = IMAGE_SIZE,
    procByKey = procByKey,
    SetOptionsOpen = SetOptionsOpen,
    StopTests = StopTests,
    PopAll = PopAll,
    VERSION = VERSION,
    IS_FOREVER = IS_FOREVER,
    Remind = Remind,
}

-- Sections 12-13 live inside BuildOptionsModule (run once, right below) so
-- their locals don't count toward Lua's 200-locals limit for the main chunk.
-- They export OpenOptions / RefreshOptions / ToggleOptions through the
-- forward-declared locals.
local function BuildOptionsModule()
    local SetMinimapButtonShown = API.SetMinimapButtonShown
    local ICON = API.ICON
    local RunStackTest = API.RunStackTest
    local PopAll = API.PopAll
    local GetAlert, RefreshAlert, TestProc, AnyAlertShown, RefreshAllAlerts, TestAll, SOUND_BY_KEY, SOUNDS =
        API.GetAlert, API.RefreshAlert, API.TestProc, API.AnyAlertShown, API.RefreshAllAlerts, API.TestAll, API.SOUND_BY_KEY, API.SOUNDS
    local ResolveImage, PS, ProcPlacement, PieceOrientation, ApplyTexCoord, IsProcEnabled, PSW, alerts =
        API.ResolveImage, API.PS, API.ProcPlacement, API.PieceOrientation, API.ApplyTexCoord, API.IsProcEnabled, API.PSW, API.alerts
    local ReevaluateAll, ProcIcon, classProcs, Print, AddCustomProc, CurrentBuffOptions, ClassSettings, SetUnlocked =
        API.ReevaluateAll, API.ProcIcon, API.classProcs, API.Print, API.AddCustomProc, API.CurrentBuffOptions, API.ClassSettings, API.SetUnlocked
    local StyleAnchors, ROTATION_OPTIONS, PlaySoundKey, TimerFont, COLOR_BY_KEY, COLOR_CHOICES, GetActionProcDuration, RemoveListedProc =
        API.StyleAnchors, API.ROTATION_OPTIONS, API.PlaySoundKey, API.TimerFont, API.COLOR_BY_KEY, API.COLOR_CHOICES, API.GetActionProcDuration, API.RemoveListedProc
    local FONT_CHOICES, OUTLINE_CHOICES, SOUND_CHANNELS, SetCVarCompat, ProcDoc_LoadGlobalsFromDB, IMG, DEFAULT_ALERT_TEXTURE, IMAGE_LIST =
        API.FONT_CHOICES, API.OUTLINE_CHOICES, API.SOUND_CHANNELS, API.SetCVarCompat, API.ProcDoc_LoadGlobalsFromDB, API.IMG, API.DEFAULT_ALERT_TEXTURE, API.IMAGE_LIST
    local IMAGE_SIZE, procByKey, SetOptionsOpen, StopTests, VERSION, IS_FOREVER, Remind =
        API.IMAGE_SIZE, API.procByKey, API.SetOptionsOpen, API.StopTests, API.VERSION, API.IS_FOREVER, API.Remind

-- 12) GUI widget helpers (flat, self-contained: no dependency on Blizzard
--     dropdown/slider templates, which differ between clients)
local WHITE = "Interface\\Buttons\\WHITE8x8"
local FLAT_BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }
local BORDER_R, BORDER_G, BORDER_B = 0.24, 0.24, 0.28

local function Skin(frame, r, g, b, a)
    frame:SetBackdrop(FLAT_BACKDROP)
    frame:SetBackdropColor(r or 0.1, g or 0.1, b or 0.12, a or 1)
    frame:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 1)
end

local function FS(parent, template, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    if text then fs:SetText(text) end
    return fs
end

local function AttachTooltip(frame, title, body)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if body then GameTooltip:AddLine(body, 0.85, 0.85, 0.85, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateFlatButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, height or 24)
    Skin(b, 0.15, 0.15, 0.18, 1)
    b.text = FS(b, "GameFontHighlight", text)
    b.text:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(accentR, accentG, accentB, 1) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 1) end)
    b:SetScript("OnMouseDown", function(self) self:SetBackdropColor(0.1, 0.1, 0.12, 1) end)
    b:SetScript("OnMouseUp", function(self) self:SetBackdropColor(0.15, 0.15, 0.18, 1) end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function CreateHeader(parent, text, width)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(width or 250, 18)
    h.text = FS(h, "GameFontNormal", text)
    h.text:SetPoint("LEFT")
    local line = h:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.08)
    line:SetHeight(1)
    line:SetPoint("LEFT", h.text, "RIGHT", 8, 0)
    line:SetPoint("RIGHT")
    return h
end

local function CreateCheck(parent, label, get, set, tip)
    local c = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    c:SetSize(16, 16)
    Skin(c, 0.06, 0.06, 0.08, 1)
    local ck = c:CreateTexture(nil, "OVERLAY")
    ck:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    ck:SetSize(22, 22)
    ck:SetPoint("CENTER")
    c:SetCheckedTexture(ck)
    if label then
        c.label = FS(c, "GameFontHighlight", label)
        c.label:SetPoint("LEFT", c, "RIGHT", 6, 0)
        local w = c.label:GetStringWidth()
        c:SetHitRectInsets(0, -((w and w > 0 and w or 150) + 8), -3, -3)
    end
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(accentR, accentG, accentB, 1) end)
    c:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 1) end)
    c.Refresh = function(self) self:SetChecked(get() and true or false) end
    if tip then AttachTooltip(c, label or "", tip) end
    return c
end

local function CreateSlider(parent, label, minV, maxV, step, fmt, get, set, width)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(width or 240, 38)
    h.label = FS(h, "GameFontHighlightSmall", label)
    h.label:SetPoint("TOPLEFT")
    h.value = FS(h, "GameFontNormalSmall")
    h.value:SetPoint("TOPRIGHT")

    local s = CreateFrame("Slider", nil, h)
    s:SetOrientation("HORIZONTAL")
    s:SetHeight(16)
    s:SetPoint("TOPLEFT", 0, -16)
    s:SetPoint("TOPRIGHT", 0, -16)
    s:EnableMouse(true)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0.14, 0.14, 0.17, 1)
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")

    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.95, 0.95, 0.95, 1)
    thumb:SetSize(8, 14)
    s:SetThumbTexture(thumb)

    local fill = s:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(accentR, accentG, accentB, 0.9)
    fill:SetHeight(4)
    fill:SetPoint("LEFT", track, "LEFT")
    fill:SetPoint("RIGHT", thumb, "CENTER")

    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        h.value:SetText(fmt(v))
        if not h.updating then set(v) end
    end)
    h.Refresh = function(self)
        self.updating = true
        local v = get() or minV
        s:SetValue(v)
        self.value:SetText(fmt(v))
        self.updating = false
    end
    h.slider = s
    return h
end

local menuFrame, menuCatcher
local menuButtons = {}

local function CloseMenu()
    if menuFrame then
        menuFrame:Hide()
        menuCatcher:Hide()
    end
end

local function OpenMenu(owner, options, current, onPick)
    if not menuFrame then
        menuCatcher = CreateFrame("Button", nil, UIParent)
        menuCatcher:SetAllPoints(UIParent)
        menuCatcher:SetFrameStrata("FULLSCREEN")
        menuCatcher:RegisterForClicks("AnyUp")
        menuCatcher:SetScript("OnClick", CloseMenu)
        menuFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        menuFrame:SetClampedToScreen(true)
        menuFrame:EnableMouse(true)
        Skin(menuFrame, 0.08, 0.08, 0.1, 0.98)
    end
    for i, opt in ipairs(options) do
        local b = menuButtons[i]
        if not b then
            b = CreateFrame("Button", nil, menuFrame)
            b:SetHeight(20)
            b.text = FS(b, "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 10, 0)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetColorTexture(1, 1, 1, 0.08)
            hl:SetAllPoints()
            b.mark = b:CreateTexture(nil, "OVERLAY")
            b.mark:SetSize(3, 14)
            b.mark:SetPoint("LEFT", 3, 0)
            menuButtons[i] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 1, -1 - (i - 1) * 20)
        b:SetPoint("RIGHT", menuFrame, "RIGHT", -1, 0)
        b.text:SetText(opt.label)
        b.mark:SetColorTexture(accentR, accentG, accentB, 1)
        b.mark:SetShown(opt.value == current)
        b:SetScript("OnClick", function()
            CloseMenu()
            onPick(opt.value)
        end)
        b:Show()
    end
    for i = #options + 1, #menuButtons do menuButtons[i]:Hide() end
    menuFrame:SetSize(math.max(owner:GetWidth(), 150), #options * 20 + 2)
    menuFrame:ClearAllPoints()
    menuFrame:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menuCatcher:Show()
    menuFrame:Show()
end

local function CreateDropdown(parent, width, getOptions, get, set)
    local d = CreateFlatButton(parent, "", width, 22)
    d.text:ClearAllPoints()
    d.text:SetPoint("LEFT", 8, 0)
    d.text:SetPoint("RIGHT", -22, 0)
    d.text:SetJustifyH("LEFT")
    local arrow = d:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    arrow:SetSize(18, 18)
    arrow:SetPoint("RIGHT", -2, 0)
    d:SetScript("OnClick", function(self)
        if menuFrame and menuFrame:IsShown() then CloseMenu() return end
        OpenMenu(self, getOptions(), get(), function(v)
            set(v)
            self:Refresh()
        end)
    end)
    d.Refresh = function(self)
        local cur = get()
        for _, o in ipairs(getOptions()) do
            if o.value == cur then
                self.text:SetText(o.label)
                return
            end
        end
        self.text:SetText(tostring(cur or ""))
    end
    return d
end

-- Fits a texture of native size w x h into a box, preserving aspect ratio
local function FitTexture(tex, w, h, box)
    w, h = w or 256, h or 128
    local f = math.min(box / w, box / h)
    tex:SetSize(w * f, h * f)
end

-- 13) Options UI
--     A narrow, tall panel docked to the left or right screen edge so the
--     alerts in the middle of the screen stay visible while editing.
--     Tabs: "Procs" (list -> per-proc page) and "General". Every page is a
--     single scrolling column. Changes apply live and pop a short preview.
local optionsFrame
local listPage, procPage, generalPage, imagePicker
local tabProcs, tabGeneral, unlockButton, dockButton
local listRows, listHeaders = {}, {}
local currentView = "LIST"      -- LIST | PROC | GENERAL
local pageProc
local generalWidgets, procWidgets = {}, {}
local SelectView                -- forward

local PANEL_W = 340
local PAD     = 14
local CHILD_W = PANEL_W - 14    -- scroll child width (room for the scrollbar)
local COL     = CHILD_W - 2 * PAD

local function PreviewAfterChange(proc)
    if proc then
        local a = GetAlert(proc)
        if a.test or a.live or unlockMode then
            RefreshAlert(a)
        else
            TestProc(proc, nil, true)
        end
    else
        if AnyAlertShown() then RefreshAllAlerts() else TestAll(nil) end
    end
end

local function ProcKindText(proc)
    if Remind.Is(proc) then return "Reminder: shows when " .. proc.buffName .. " is missing" end
    if proc.auto then return "Detected from Blizzard's proc overlay" end
    if proc.custom then return "Your own buff proc" .. (proc.spellID and (" (spell " .. proc.spellID .. ")") or "") end
    if proc.isAction then
        return "Reaction ability: lights up when " .. (proc.localName or proc.spellName) .. " becomes usable"
    end
    local t = "Buff proc"
    if proc.minStacks then t = t .. " (at " .. proc.minStacks .. " stacks)" end
    return t
end

local function SoundOptions(withDefault)
    local out = {}
    if withDefault then
        local def = SOUND_BY_KEY[G.defaultSound]
        out[1] = { value = "default", label = "Default (" .. (def and def.label or "?") .. ")" }
    end
    for _, s in ipairs(SOUNDS) do out[#out + 1] = { value = s.value, label = s.label } end
    return out
end

local TIMER_OPTIONS = {
    { value = "default", label = "Use global setting" },
    { value = "on",      label = "Always show" },
    { value = "off",     label = "Never show" },
}

local function UpdatePreviewBox()
    if not procPage or not pageProc then return end
    local img, w, h, isIcon = ResolveImage(pageProc)
    local s = PS(pageProc.key)
    local x, y, _, region = ProcPlacement(pageProc)
    if not w then
        if region == "TB" then w, h = 256, 128 else w, h = 128, 256 end
    end
    local rot, flip, dw, dh = PieceOrientation(region, x, y, w, h, s)
    procPage.previewTex:SetTexture(img)
    FitTexture(procPage.previewTex, dw, dh, 84)
    ApplyTexCoord(procPage.previewTex, flip, isIcon, rot)
end

-- Layout helpers ---------------------------------------------------------
-- A page that scrolls vertically, with a thin draggable scrollbar
local function CreateScrollPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local scroll = CreateFrame("ScrollFrame", nil, page)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -12, 0)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CHILD_W, 10)
    scroll:SetScrollChild(child)

    local bar = CreateFrame("Slider", nil, page)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(6)
    bar:SetPoint("TOPRIGHT", -4, -4)
    bar:SetPoint("BOTTOMRIGHT", -4, 4)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.04)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.28)
    thumb:SetSize(6, 40)
    bar:SetThumbTexture(thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(self, v) scroll:SetVerticalScroll(v) end)

    local function Update()
        local maxScroll = math.max(0, child:GetHeight() - (scroll:GetHeight() or 0))
        bar:SetMinMaxValues(0, maxScroll)
        bar:SetShown(maxScroll > 0)
        if (bar:GetValue() or 0) > maxScroll then bar:SetValue(maxScroll) end
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local _, maxScroll = bar:GetMinMaxValues()
        local v = (bar:GetValue() or 0) - delta * 40
        if v < 0 then v = 0 elseif v > (maxScroll or 0) then v = maxScroll or 0 end
        bar:SetValue(v)
    end)
    scroll:SetScript("OnSizeChanged", Update)

    page.child, page.scroll, page.bar = child, scroll, bar
    page.SetContentHeight = function(self, h)
        child:SetHeight(h)
        Update()
    end
    page.ScrollToTop = function(self)
        bar:SetValue(0)
        scroll:SetVerticalScroll(0)
    end
    return page
end

-- Stacks widgets top-to-bottom in a scroll page's child
local function Stack(page, widgetList)
    local st = { y = -10 }
    function st:Add(widget, height, x, gap)
        widget:SetPoint("TOPLEFT", page.child, "TOPLEFT", x or PAD, self.y)
        if widgetList and widget.Refresh then widgetList[#widgetList + 1] = widget end
        self.y = self.y - height - (gap or 6)
        return widget
    end
    function st:Space(h) self.y = self.y - h end
    function st:Finish() page:SetContentHeight(-self.y + 12) end
    return st
end

local function Label(parent, text)
    return FS(parent, "GameFontHighlightSmall", text)
end

-- Procs tab: list -------------------------------------------------------
local function CreateListRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(CHILD_W - 12, 28)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetColorTexture(1, 1, 1, 0.05)
    hl:SetAllPoints()
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(1, 1, 1, 0.025)
    bg:SetAllPoints()

    row.check = CreateCheck(row, nil,
        function() return row.proc and IsProcEnabled(row.proc) end,
        function(v)
            if not row.proc then return end
            if v then PSW(row.proc.key).enabled = nil else PSW(row.proc.key).enabled = false end
            if not v then
                local a = alerts[row.proc.key]
                if a then a.test = false end
            end
            ReevaluateAll()
            row.name:SetAlpha(v and 1 or 0.45)
            row.icon:SetDesaturated(not v)
        end)
    row.check:SetPoint("LEFT", 8, 0)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row.check, "RIGHT", 8, 0)
    row.chevron = FS(row, "GameFontDisable", ">")
    row.chevron:SetPoint("RIGHT", -10, 0)
    row.tag = FS(row, "GameFontDisableSmall")
    row.tag:SetPoint("RIGHT", row.chevron, "LEFT", -8, 0)
    row.name = FS(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row:SetScript("OnClick", function(self) if self.proc then SelectView("PROC", self.proc.key) end end)
    return row
end

local function BindListRow(row, proc)
    row.proc = proc
    row.name:SetText(proc.buffName)
    local icon = ProcIcon(proc)
    if icon then
        row.icon:SetTexture(icon)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        row.icon:SetTexture((ResolveImage(proc)))
        row.icon:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    end
    local enabled = IsProcEnabled(proc)
    row.name:SetAlpha(enabled and 1 or 0.45)
    row.icon:SetDesaturated(not enabled)
    row.tag:SetText(proc.auto and "auto" or (proc.custom and "custom" or (proc.isAction and "react" or "")))
    row.check:Refresh()
    row:Show()
end

local function RebuildProcList()
    if not listPage then return end
    local child = listPage.child
    for _, row in ipairs(listRows) do row:Hide() end
    for _, h in ipairs(listHeaders) do h:Hide() end
    local y, rowIndex, headerIndex = -8, 0, 0

    local function Header(text)
        headerIndex = headerIndex + 1
        local h = listHeaders[headerIndex]
        if not h then
            h = FS(child, "GameFontDisableSmall")
            h:SetJustifyH("LEFT")
            h:SetWidth(COL)
            listHeaders[headerIndex] = h
        end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", PAD, y - 6)
        h:SetText(text)
        h:Show()
        y = y - 24
    end
    local function Row(proc)
        rowIndex = rowIndex + 1
        local row = listRows[rowIndex]
        if not row then
            row = CreateListRow(child)
            listRows[rowIndex] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 6, y)
        BindListRow(row, proc)
        y = y - 30
    end

    local className = UnitClass("player") or playerClass or ""
    Header(string.upper(className) .. " PROCS")
    local anyAuto = false
    for _, proc in ipairs(classProcs) do
        if proc.auto then anyAuto = true else Row(proc) end
    end
    if #classProcs == 0 then Header("None built in. Auto-detect will add them.") end
    if anyAuto then
        Header("AUTO-DETECTED")
        for _, proc in ipairs(classProcs) do
            if proc.auto then Row(proc) end
        end
    end
    Header("Click a proc to customise it.")

    -- Add your own proc
    local add = listPage.addBox
    if not add then
        add = CreateFrame("Frame", nil, child)
        add:SetSize(COL, 112)
        CreateHeader(add, "Add a proc", COL):SetPoint("TOPLEFT")
        local tip = Label(add, "Track any buff: type its exact name or spell ID,\nor pick one you have right now. On its page, pick\nwhether it alerts when it shows up or goes missing.")
        tip:SetPoint("TOPLEFT", 0, -22)
        tip:SetJustifyH("LEFT")
        local function Added(proc, err)
            if not proc then
                Print(err)
                return
            end
            Print("added |cffffd100" .. proc.buffName .. "|r. Drag it on screen to place it.")
            SelectView("PROC", proc.key)
            PreviewAfterChange(proc)
        end
        local edit = CreateFrame("EditBox", nil, add, "InputBoxTemplate")
        edit:SetSize(COL - 72, 22)
        edit:SetPoint("TOPLEFT", 6, -62)
        edit:SetAutoFocus(false)
        local function Submit()
            edit:ClearFocus()
            local proc, err = AddCustomProc(edit:GetText())
            if proc then edit:SetText("") end
            Added(proc, err)
        end
        edit:SetScript("OnEnterPressed", Submit)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        local addBtn = CreateFlatButton(add, "Add", 60, 22, Submit)
        addBtn:SetPoint("LEFT", edit, "RIGHT", 8, 0)
        local pick = CreateDropdown(add, COL, CurrentBuffOptions,
            function() return nil end,
            function(v)
                if v == nil or v == "none" then return end
                Added(AddCustomProc(v))
            end)
        pick:SetPoint("TOPLEFT", 0, -90)
        pick.Refresh = function(self) self.text:SetText("Pick from my current buffs...") end
        pick:Refresh()
        listPage.addBox = add
    end
    add:ClearAllPoints()
    add:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, y - 8)
    y = y - 8 - add:GetHeight() - 12
    listPage:SetContentHeight(-y + 8)
end

-- Procs tab: detail page -------------------------------------------------
local function StepProc(dir)
    if #classProcs == 0 then return end
    local idx = 1
    for i, p in ipairs(classProcs) do
        if p == pageProc then idx = i break end
    end
    idx = ((idx - 1 + dir) % #classProcs) + 1
    SelectView("PROC", classProcs[idx].key)
end

local function BuildProcPage(parent)
    local page = CreateScrollPage(parent)
    page:Hide()
    local child = page.child
    local st = Stack(page, procWidgets)

    local function Changed()
        UpdatePreviewBox()
        PreviewAfterChange(pageProc)
    end
    local function PSlider(label, key, default, minV, maxV, step, fmt)
        return st:Add(CreateSlider(child, label, minV, maxV, step, fmt,
            function() return pageProc and PS(pageProc.key)[key] or default end,
            function(v)
                if not pageProc then return end
                PSW(pageProc.key)[key] = (v ~= default) and v or nil
                Changed()
            end, COL), 38)
    end

    -- Navigation row
    st:Add(CreateFlatButton(child, "< All procs", 96, 22, function() SelectView("LIST") end), 22, nil, 10)
    local nextB = CreateFlatButton(child, ">", 26, 22, function() StepProc(1) end)
    nextB:SetPoint("TOPRIGHT", child, "TOPRIGHT", -PAD, -10)
    AttachTooltip(nextB, "Next proc")
    local prevB = CreateFlatButton(child, "<", 26, 22, function() StepProc(-1) end)
    prevB:SetPoint("RIGHT", nextB, "LEFT", -4, 0)
    AttachTooltip(prevB, "Previous proc")

    -- Identity
    local box = CreateFrame("Button", nil, child, "BackdropTemplate")
    box:SetSize(92, 92)
    Skin(box, 0.03, 0.03, 0.04, 1)
    st:Add(box, 92, nil, 10)
    page.previewTex = box:CreateTexture(nil, "ARTWORK")
    page.previewTex:SetPoint("CENTER")
    box:SetScript("OnClick", function() imagePicker:Open() end)
    box:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(accentR, accentG, accentB, 1) end)
    box:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 1) end)
    AttachTooltip(box, "Click to change image")

    page.name = FS(child, "GameFontNormalLarge")
    page.name:SetPoint("TOPLEFT", box, "TOPRIGHT", 12, -2)
    page.name:SetPoint("RIGHT", child, "RIGHT", -PAD, 0)
    page.name:SetJustifyH("LEFT")
    page.kind = FS(child, "GameFontHighlightSmall")
    page.kind:SetPoint("TOPLEFT", page.name, "BOTTOMLEFT", 0, -4)
    page.kind:SetPoint("RIGHT", child, "RIGHT", -PAD, 0)
    page.kind:SetJustifyH("LEFT")
    local enable = CreateCheck(child, "Enabled",
        function() return pageProc and IsProcEnabled(pageProc) end,
        function(v)
            if not pageProc then return end
            if v then PSW(pageProc.key).enabled = nil else PSW(pageProc.key).enabled = false end
            ReevaluateAll()
        end)
    enable:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 12, 2)
    procWidgets[#procWidgets + 1] = enable

    -- Actions
    local bw = math.floor((COL - 12) / 3)
    local test = st:Add(CreateFlatButton(child, "Preview", bw, 24, function()
        if pageProc then TestProc(pageProc, 8) end
    end), 24, nil, 14)
    local changeImg = CreateFlatButton(child, "Image...", bw, 24, function() imagePicker:Open() end)
    changeImg:SetPoint("LEFT", test, "RIGHT", 6, 0)
    local resetProc = CreateFlatButton(child, "Reset", bw, 24, function()
        if not pageProc then return end
        ClassSettings()[pageProc.key] = nil
        ReevaluateAll()
        for _, w in ipairs(procWidgets) do w:Refresh() end
        Changed()
    end)
    resetProc:SetPoint("LEFT", changeImg, "RIGHT", 6, 0)
    AttachTooltip(resetProc, "Reset this proc", "Puts every setting for this proc back to ProcDoc's default.")

    -- Position: drag and drop on screen
    st:Add(CreateHeader(child, "Position", COL), 18)
    local how = st:Add(Label(child,
        "Drag the alert on screen to move it.\nShift + mouse wheel over it to resize.\nRight-click any alert to open its settings."), 38, nil, 8)
    how:SetJustifyH("LEFT")
    local half = math.floor((COL - 6) / 2)
    page.arrangeButton = st:Add(CreateFlatButton(child, "Show all to arrange", half, 24, function()
        SetUnlocked(not unlockMode)
    end), 24, nil, 10)
    AttachTooltip(page.arrangeButton, "Show all alerts",
        "Shows every enabled alert (with a centre guide) so you can drag them into place together.")
    local resetPos = CreateFlatButton(child, "Reset position", half, 24, function()
        if not pageProc then return end
        local s = PSW(pageProc.key)
        s.px, s.py, s.both, s.region = nil, nil, nil, nil
        for _, w in ipairs(procWidgets) do w:Refresh() end
        Changed()
    end)
    resetPos:SetPoint("LEFT", page.arrangeButton, "RIGHT", 6, 0)

    -- Snap buttons: jump to a standard spot (then drag to fine-tune).
    -- The spot also decides which way Auto rotation turns the art.
    local function Snap(where)
        if not pageProc then return end
        local ps = PSW(pageProc.key)
        local t, sd = G.topOffset or 70, G.sideOffset or 60
        if where == "TOP" then
            ps.px, ps.py, ps.both, ps.region = 0, t, false, "TB"
        elseif where == "BOTTOM" then
            ps.px, ps.py, ps.both, ps.region = 0, -(t + 120), false, "TB"
        elseif where == "LEFT" then
            ps.px, ps.py, ps.both, ps.region = -(sd + 50), t - 150, false, "SIDE"
        elseif where == "RIGHT" then
            ps.px, ps.py, ps.both, ps.region = sd + 50, t - 150, false, "SIDE"
        else
            ps.px, ps.py, ps.both, ps.region = -(sd + 50), t - 150, true, "SIDE"
        end
        for _, w in ipairs(procWidgets) do w:Refresh() end
        Changed()
    end
    st:Add(Label(child, "Snap to"), 12, nil, 4)
    local snapW = math.floor((COL - 16) / 5)
    local prevSnap
    for _, spec in ipairs({ { "TOP", "Top", "Above your character" }, { "BOTTOM", "Bottom", "Below your character" },
                            { "LEFT", "Left", "Left side" }, { "RIGHT", "Right", "Right side (mirrored to face outward)" },
                            { "SIDES", "Sides", "Both sides: a mirrored left + right pair" } }) do
        local b = CreateFlatButton(child, spec[2], snapW, 22, function() Snap(spec[1]) end)
        AttachTooltip(b, "Snap: " .. spec[2], spec[3])
        if prevSnap then b:SetPoint("LEFT", prevSnap, "RIGHT", 4, 0) else st:Add(b, 22, nil, 10) end
        prevSnap = b
    end
    st:Add(CreateCheck(child, "Both sides (mirrored left + right)",
        function() return pageProc and select(3, ProcPlacement(pageProc)) end,
        function(v)
            if not pageProc then return end
            local defaultBoth = #StyleAnchors(pageProc.alertStyle or "SIDES") == 2
            -- (not "cond and v or nil": that stores nil when v is false)
            if v == defaultBoth then PSW(pageProc.key).both = nil else PSW(pageProc.key).both = v end
            Changed()
        end, "Shows the alert as a mirrored pair, one on each side of the screen. Dragging either one moves both."), 16, nil, 10)
    st:Add(CreateCheck(child, "Mirror image",
        function() return pageProc and PS(pageProc.key).flip end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).flip = v or nil
            Changed()
        end), 16, nil, 10)
    st:Add(Label(child, "Rotation"), 12, nil, 4)
    st:Add(CreateDropdown(child, COL, function() return ROTATION_OPTIONS end,
        function() return pageProc and PS(pageProc.key).rotation or "auto" end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).rotation = (v ~= "auto") and v or nil
            Changed()
        end), 22, nil, 14)

    -- Look
    st:Add(CreateHeader(child, "Look", COL), 18)
    PSlider("Size: 1.00x = real image size (or Shift + wheel)", "scale", 1, 0.25, 4, 0.05,
        function(v) return string.format("%.2fx", v) end)
    PSlider("Opacity", "alpha", 1, 0.1, 1, 0.05,
        function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end)
    st:Space(8)

    -- Sound
    st:Add(CreateHeader(child, "Sound", COL), 18)
    local soundDD = st:Add(CreateDropdown(child, COL - 30, function() return SoundOptions(true) end,
        function() return pageProc and PS(pageProc.key).sound or "default" end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).sound = (v ~= "default") and v or nil
            PlaySoundKey(v == "default" and G.defaultSound or v)
        end), 22, nil, 14)
    local play = CreateFlatButton(child, ">", 24, 22, function()
        if pageProc then PlaySoundKey(PS(pageProc.key).sound or G.defaultSound) end
    end)
    play:SetPoint("LEFT", soundDD, "RIGHT", 6, 0)
    AttachTooltip(play, "Play sound")

    -- Countdown
    st:Add(CreateHeader(child, "Countdown", COL), 18)
    local thow = st:Add(Label(child,
        "Drag the number on screen to move it.\nShift + mouse wheel over it to resize it."), 26, nil, 8)
    thow:SetJustifyH("LEFT")
    st:Add(Label(child, "Show countdown"), 12, nil, 4)
    st:Add(CreateDropdown(child, COL, function() return TIMER_OPTIONS end,
        function() return pageProc and PS(pageProc.key).timer or "default" end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).timer = (v ~= "default") and v or nil
            Changed()
        end), 22, nil, 10)
    st:Add(CreateSlider(child, "Text size", 6, 80, 1,
        function(v) return string.format("%d", math.floor(v + 0.5)) end,
        function()
            if not pageProc then return 26 end
            local _, size = TimerFont(pageProc, (PS(pageProc.key).scale or 1) * (G.masterScale or 1))
            return size
        end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).timerSize = math.floor(v + 0.5)
            Changed()
        end, COL), 38)
    st:Add(Label(child, "Color"), 12, nil, 4)
    st:Add(CreateDropdown(child, COL, function()
            local def = COLOR_BY_KEY[G.timerColor] or COLOR_BY_KEY.gold
            local out = { { value = "default", label = "Default (" .. def.label .. ")" } }
            for _, c in ipairs(COLOR_CHOICES) do out[#out + 1] = { value = c.value, label = c.label } end
            return out
        end,
        function() return pageProc and PS(pageProc.key).timerColor or "default" end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).timerColor = (v ~= "default") and v or nil
            Changed()
        end), 22, nil, 10)
    st:Add(CreateCheck(child, "On one side only (for pairs)",
        function() return pageProc and PS(pageProc.key).timerOneSide end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).timerOneSide = v or nil
            Changed()
        end), 16, nil, 10)
    st:Add(CreateFlatButton(child, "Reset countdown", 130, 24, function()
        if not pageProc then return end
        local s = PSW(pageProc.key)
        s.timerX, s.timerY, s.timerSize, s.timerColor, s.timerOneSide = nil, nil, nil, nil, nil
        for _, w in ipairs(procWidgets) do w:Refresh() end
        Changed()
    end), 24, nil, 10)
    -- Buff procs get a Stacks section; reaction abilities get the reaction
    -- window slider in the same spot (BindProcPage shows the one that fits).
    local slotY = st.y
    page.stackWidgets = {}
    local function S(widget, height, x, gap)
        page.stackWidgets[#page.stackWidgets + 1] = widget
        return st:Add(widget, height, x, gap)
    end
    -- Proc or reminder: alert when the buff shows up, or when it's missing
    S(CreateHeader(child, "Alert me when", COL), 18)
    S(CreateDropdown(child, COL, function()
            return { { value = "up", label = "It shows up (a proc)" },
                     { value = "missing", label = "It's missing (a reminder to put it back)" } }
        end,
        function() return pageProc and PS(pageProc.key).remind or "up" end,
        function(v)
            if not pageProc then return end
            if v == "missing" then PSW(pageProc.key).remind = "missing" else PSW(pageProc.key).remind = nil end
            procPage.kind:SetText(ProcKindText(pageProc))
            ReevaluateAll()
        end), 22, nil, 14)

    S(CreateHeader(child, "Stacks", COL), 18)
    local show = S(Label(child, "For buffs that stack. Dots show how many stacks you\nhave; drag them on screen, Shift + wheel to resize."), 26, nil, 8)
    show:SetJustifyH("LEFT")
    S(CreateCheck(child, "Show stack dots",
        function() return pageProc and PS(pageProc.key).stackDots ~= false end,
        function(v)
            if not pageProc then return end
            if v then PSW(pageProc.key).stackDots = nil else PSW(pageProc.key).stackDots = false end
            Changed()
        end), 16, nil, 10)
    S(CreateSlider(child, "Show the alert at (stacks)", 1, 20, 1,
        function(v) v = math.floor(v + 0.5); return v <= 1 and "any" or tostring(v) end,
        function() return pageProc and (PS(pageProc.key).minStacks or pageProc.minStacks) or 1 end,
        function(v)
            if not pageProc then return end
            v = math.floor(v + 0.5)
            PSW(pageProc.key).minStacks = (v > 1) and v or nil
            if CheckProcs then CheckProcs() end
        end, COL), 38)
    S(CreateSlider(child, "Number of dots (0 = most stacks seen)", 0, 20, 1,
        function(v) v = math.floor(v + 0.5); return v == 0 and ("auto" .. ((pageProc and pageProc.maxSeen) and (" (" .. pageProc.maxSeen .. ")") or "")) or tostring(v) end,
        function() return pageProc and PS(pageProc.key).maxStacks or 0 end,
        function(v)
            if not pageProc then return end
            v = math.floor(v + 0.5)
            PSW(pageProc.key).maxStacks = (v > 0) and v or nil
            Changed()
        end, COL), 38)
    S(Label(child, "Dot color"), 12, nil, 4)
    S(CreateDropdown(child, COL, function()
            local out = {}
            for _, c in ipairs(COLOR_CHOICES) do out[#out + 1] = { value = c.value, label = c.label } end
            return out
        end,
        function() return pageProc and PS(pageProc.key).pipColor or "gold" end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).pipColor = (v ~= "gold") and v or nil
            Changed()
        end), 22, nil, 10)
    S(CreateCheck(child, "Dots on one side only (for pairs)",
        function() return pageProc and PS(pageProc.key).pipOneSide end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).pipOneSide = v or nil
            Changed()
        end), 16, nil, 10)
    local testStacks = S(CreateFlatButton(child, "Test stacks", 110, 24, function()
        if pageProc then RunStackTest(pageProc) end
    end), 24, nil, 10)
    AttachTooltip(testStacks, "Test stacks",
        "Plays a pretend stacking buff through this alert: 1, 2, 3, 4, 5 stacks, down to 3, then it ends.")
    local resetDots = CreateFlatButton(child, "Reset dots", 110, 24, function()
        if not pageProc then return end
        local ps = PSW(pageProc.key)
        ps.pipX, ps.pipY, ps.pipSize, ps.pipColor, ps.pipOneSide = nil, nil, nil, nil, nil
        for _, w in ipairs(procWidgets) do w:Refresh() end
        Changed()
    end)
    resetDots:SetPoint("LEFT", testStacks, "RIGHT", 6, 0)
    page.stackWidgets[#page.stackWidgets + 1] = resetDots
    page.yStacksEnd = st.y

    st.y = slotY
    page.durationSlider = st:Add(CreateSlider(child, "Reaction window (seconds)", 1, 20, 0.5,
        function(v) return string.format("%.1fs", v) end,
        function() return pageProc and GetActionProcDuration(pageProc) or 5 end,
        function(v)
            if not pageProc then return end
            PSW(pageProc.key).duration = v
        end, COL), 38)
    page.yWithDuration = st.y

    -- Only for custom / auto-detected procs; placed at the end in BindProcPage
    page.removeButton = CreateFlatButton(child, "Remove from list", 140, 24, function()
        if not pageProc or not (pageProc.custom or pageProc.auto) then return end
        local name = pageProc.buffName
        RemoveListedProc(pageProc)
        pageProc = nil
        Print("removed " .. name .. " from your procs.")
        SelectView("LIST")
    end)
    return page
end

local function BindProcPage(scrollTop)
    if not pageProc then return end
    procPage.name:SetText(pageProc.buffName)
    procPage.kind:SetText(ProcKindText(pageProc))
    local isAction = pageProc.isAction and true or false
    procPage.durationSlider:SetShown(isAction)
    for _, w in ipairs(procPage.stackWidgets) do w:SetShown(not isAction) end
    local y = isAction and procPage.yWithDuration or procPage.yStacksEnd
    local removable = (pageProc.custom or pageProc.auto) and true or false
    procPage.removeButton:SetShown(removable)
    if removable then
        procPage.removeButton:ClearAllPoints()
        procPage.removeButton:SetPoint("TOPLEFT", procPage.child, "TOPLEFT", PAD, y - 4)
        y = y - 34
    end
    procPage.arrangeButton.text:SetText(unlockMode and "Done arranging" or "Show all to arrange")
    procPage:SetContentHeight(-y + 12)
    for _, w in ipairs(procWidgets) do w:Refresh() end
    UpdatePreviewBox()
    if scrollTop then procPage:ScrollToTop() end
end

-- General tab -------------------------------------------------------------
local ApplyPanelGeometry -- forward

local function BuildGeneralPage(parent)
    local page = CreateScrollPage(parent)
    page:Hide()
    local child = page.child
    local st = Stack(page, generalWidgets)

    local function GSlider(label, key, minV, maxV, step, fmt, after, noPreview)
        return st:Add(CreateSlider(child, label, minV, maxV, step, fmt,
            function() return G[key] end,
            function(v)
                G[key] = v
                if after then after(v) end
                if not noPreview then PreviewAfterChange(nil) end
            end, COL), 38)
    end
    local pct  = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
    local mult = function(v) return string.format("%.2fx", v) end
    local px   = function(v) return string.format("%d", math.floor(v + 0.5)) end

    st:Add(CreateHeader(child, "Pulse animation", COL), 18)
    GSlider("Faintest opacity", "minAlpha", 0, 1, 0.05, pct,
        function(v) if G.maxAlpha < v then G.maxAlpha = v end end)
    GSlider("Brightest opacity", "maxAlpha", 0, 1, 0.05, pct,
        function(v) if G.minAlpha > v then G.minAlpha = v end end)
    GSlider("Smallest size", "minScale", 0.5, 2, 0.05, mult,
        function(v) if G.maxScale < v then G.maxScale = v end end)
    GSlider("Largest size", "maxScale", 0.5, 2, 0.05, mult,
        function(v) if G.minScale > v then G.minScale = v end end)
    GSlider("Pulse speed", "pulseSpeed", 0.1, 3, 0.1, function(v) return string.format("%.1f", v) end)
    st:Add(CreateCheck(child, "Pop in when a proc starts",
        function() return G.popEnabled ~= false end,
        function(v)
            G.popEnabled = v
            if v then PreviewAfterChange(nil); PopAll() end
        end,
        "The alert springs out with a bright flash the moment a proc happens, then settles into its pulse."), 16, nil, 10)
    GSlider("Pop strength", "popStrength", 0, 4, 0.1, function(v) return string.format("%.1f", v) end,
        function() PopAll() end)
    st:Add(CreateCheck(child, "Shrink away when a proc ends",
        function() return G.exitEnabled ~= false end,
        function(v) G.exitEnabled = v end,
        "When a proc is used or runs out, the alert quickly shrinks away instead of just vanishing."), 16, nil, 10)
    st:Add(CreateFlatButton(child, "Replay animation", 150, 24, function() TestAll(0.9) end), 24, nil, 14)
    st:Space(8)

    st:Add(CreateHeader(child, "Alerts", COL), 18)
    GSlider("Scale of every alert", "masterScale", 0.5, 2, 0.05, mult)
    local where = st:Add(Label(child,
        "Move and resize alerts right on screen: drag them, and\nShift + mouse wheel over one to resize it."), 26, nil, 8)
    where:SetJustifyH("LEFT")
    local arrange
    arrange = st:Add(CreateFlatButton(child, "Show all to arrange", 150, 24, function()
        SetUnlocked(not unlockMode)
        arrange.text:SetText(unlockMode and "Done arranging" or "Show all to arrange")
    end), 24, nil, 14)

    local function GDropdown(label, key, choices, after)
        st:Add(Label(child, label), 12, nil, 4)
        return st:Add(CreateDropdown(child, COL, function() return choices end,
            function() return G[key] end,
            function(v)
                G[key] = v
                if after then after(v) end
                RefreshAllAlerts()
                PreviewAfterChange(nil)
            end), 22, nil, 10)
    end

    st:Add(CreateHeader(child, "Countdown timers", COL), 18)
    st:Add(CreateCheck(child, "Show countdown timers",
        function() return not G.disableTimers end,
        function(v) G.disableTimers = not v; PreviewAfterChange(nil) end,
        "Shows the seconds left on each proc. Individual procs can override this."), 16, nil, 10)
    GDropdown("Font", "timerFont", FONT_CHOICES)
    GDropdown("Outline", "timerOutline", OUTLINE_CHOICES)
    GSlider("Text size (per proc: Shift + wheel over the number)", "timerTextSize", 8, 60, 1, px,
        function() RefreshAllAlerts() end)
    GSlider("Opacity", "timerTextAlpha", 0, 1, 0.05, pct)
    GDropdown("Color", "timerColor", COLOR_CHOICES)
    GDropdown("Color when time is running out", "timerLowColor", COLOR_CHOICES)
    GSlider("Running out below (seconds)", "timerLowThreshold", 0, 10, 0.5,
        function(v) return string.format("%.1fs", v) end)
    st:Add(CreateCheck(child, "Show tenths of a second when running out",
        function() return G.timerDecimals ~= false end,
        function(v) G.timerDecimals = v end), 16, nil, 14)

    st:Add(CreateHeader(child, "Sound", COL), 18)
    st:Add(CreateCheck(child, "Mute all proc sounds",
        function() return G.isMuted end,
        function(v) G.isMuted = v end), 16, nil, 10)
    st:Add(Label(child, "Default sound"), 12, nil, 4)
    local soundDD = st:Add(CreateDropdown(child, COL - 30, function() return SoundOptions(false) end,
        function() return G.defaultSound end,
        function(v) G.defaultSound = v; PlaySoundKey(v) end), 22, nil, 10)
    local play = CreateFlatButton(child, ">", 24, 22, function() PlaySoundKey(G.defaultSound) end)
    play:SetPoint("LEFT", soundDD, "RIGHT", 6, 0)
    AttachTooltip(play, "Play sound")
    st:Add(Label(child, "Volume follows this game sound channel"), 12, nil, 4)
    st:Add(CreateDropdown(child, COL, function() return SOUND_CHANNELS end,
        function() return G.soundChannel end,
        function(v) G.soundChannel = v; PlaySoundKey(G.defaultSound) end), 22, nil, 14)

    st:Add(CreateHeader(child, "Detection", COL), 18)
    st:Add(CreateCheck(child, "Auto-detect other procs",
        function() return G.autoDetect end,
        function(v) G.autoDetect = v; ReevaluateAll() end,
        "Also alerts on any proc the game flags with its built-in spell overlay, even if ProcDoc doesn't know it yet. New ones are added to the Procs list so you can customise them."), 16, nil, 10)
    st:Add(CreateCheck(child, "Hide Blizzard's own proc overlay",
        function() return G.hideBlizzardOverlay end,
        function(v)
            G.hideBlizzardOverlay = v
            SetCVarCompat("displaySpellActivationOverlays", v and "0" or "1")
        end,
        "Turns off the game's built-in proc art so only ProcDoc's alerts show."), 16, nil, 14)

    st:Add(CreateHeader(child, "Window & minimap", COL), 18)
    st:Add(CreateCheck(child, "Show minimap button",
        function() return not G.minimapHide end,
        function(v) SetMinimapButtonShown(v) end,
        "Left-click it for these options, right-click to arrange alerts, drag it around the minimap. Also: /procdoc minimap"), 16, nil, 10)
    local menuScale = GSlider("Window scale", "menuScale", 0.6, 1.3, 0.05, mult, nil, true)
    menuScale.slider:HookScript("OnMouseUp", function() ApplyPanelGeometry() end)
    st:Add(Label(child, "Drag the title bar to move this window; it remembers\nwhere you leave it. The dock button snaps it to an\nedge. Scale applies when you release the slider."), 38, nil, 14)

    local reset
    reset = st:Add(CreateFlatButton(child, "Reset all settings", 150, 24, function()
        if not reset.armed then
            reset.armed = true
            reset.text:SetText("|cffff5555Click to confirm|r")
            C_Timer.After(3, function()
                reset.armed = false
                reset.text:SetText("Reset all settings")
            end)
            return
        end
        reset.armed = false
        reset.text:SetText("Reset all settings")
        wipe(ProcDocDB.globalVars)
        ProcDocDB.procSettings[playerClass] = nil
        ProcDoc_LoadGlobalsFromDB()
        ReevaluateAll()
        ApplyPanelGeometry()
        for _, w in ipairs(generalWidgets) do w:Refresh() end
        Print("all settings reset to defaults.")
    end), 24)
    st:Finish()
    return page
end

-- Image picker ----------------------------------------------------------
local function ParseCustomImage(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    local n = tonumber(text)
    if n then return n end
    text = text:gsub("/", "\\")
    if not text:find("\\", 1, true) then text = IMG .. text end
    return text
end

local function BuildImagePicker(parent)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetAllPoints()
    p:SetFrameLevel(parent:GetFrameLevel() + 20)
    Skin(p, 0.055, 0.055, 0.07, 0.99)
    p:EnableMouse(true)
    p:Hide()

    local back = CreateFlatButton(p, "< Back", 70, 22, function() p:Hide() end)
    back:SetPoint("TOPLEFT", PAD, -10)
    p.title = FS(p, "GameFontNormal")
    p.title:SetPoint("LEFT", back, "RIGHT", 10, 0)
    p.title:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    p.title:SetJustifyH("LEFT")
    p.title:SetWordWrap(false)

    local area = CreateFrame("Frame", nil, p)
    area:SetPoint("TOPLEFT", 0, -40)
    area:SetPoint("BOTTOMRIGHT", 0, 84)
    local page = CreateScrollPage(area)
    local child = page.child

    local tiles = {}
    local TILE, STEP = 54, 58
    local perRow = math.floor((COL + 4) / STEP)
    local y, col = -4, 0
    local function Section(text)
        if col > 0 then y = y - STEP end
        col = 0
        local h = CreateHeader(child, text, COL)
        h:SetPoint("TOPLEFT", PAD, y)
        y = y - 24
    end
    local function Choose(value, custom)
        if not pageProc then return end
        PSW(pageProc.key).image = value
        PSW(pageProc.key).imageCustom = custom or nil
        p:Hide()
        UpdatePreviewBox()
        if RefreshOptions then RefreshOptions() end
        PreviewAfterChange(pageProc)
    end
    local function MakeTile(label, texture, w, h, value, texCoord)
        local t = CreateFrame("Button", nil, child, "BackdropTemplate")
        t:SetSize(TILE, TILE)
        Skin(t, 0.1, 0.1, 0.12, 1)
        if col >= perRow then
            col = 0
            y = y - STEP
        end
        t:SetPoint("TOPLEFT", PAD + col * STEP, y)
        col = col + 1
        t.tex = t:CreateTexture(nil, "ARTWORK")
        t.tex:SetPoint("CENTER")
        t.tex:SetTexture(texture)
        if texCoord then t.tex:SetTexCoord(unpack(texCoord)) end
        FitTexture(t.tex, w, h, TILE - 6)
        t.value = value
        t:SetScript("OnClick", function() Choose(value) end)
        t:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(accentR, accentG, accentB, 1)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function(self)
            if self.isSelected then
                self:SetBackdropBorderColor(accentR, accentG, accentB, 1)
            else
                self:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 1)
            end
            GameTooltip:Hide()
        end)
        tiles[#tiles + 1] = t
        return t
    end
    Section("For this proc")
    p.defaultTile = MakeTile("ProcDoc default for this proc", DEFAULT_ALERT_TEXTURE, 256, 128, nil)
    p.iconTile = MakeTile("Spell icon", "Interface\\Icons\\INV_Misc_QuestionMark", 64, 64, "ICON", { 0.08, 0.92, 0.08, 0.92 })
    p.blizzTile = MakeTile("Blizzard's proc art for this spell", "Interface\\Icons\\INV_Misc_QuestionMark", 128, 256, "BLIZZARD")
    Section("Alert art")
    for _, e in ipairs(IMAGE_LIST) do
        MakeTile(e.label, e.path, e[2], e[3], e.path)
    end
    page:SetContentHeight(-y + STEP + 8)

    local hint = FS(p, "GameFontHighlightSmall", "Custom image: a file in ProcDoc\\img\\ (e.g. MyProc.tga), a texture path, or a file ID")
    hint:SetPoint("BOTTOMLEFT", PAD, 46)
    hint:SetWidth(COL)
    hint:SetJustifyH("LEFT")
    local edit = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    edit:SetSize(COL - 76, 22)
    edit:SetPoint("BOTTOMLEFT", PAD + 6, 14)
    edit:SetAutoFocus(false)
    local use = CreateFlatButton(p, "Use", 60, 22, function()
        local v = ParseCustomImage(edit:GetText())
        if v then Choose(v, true) end
    end)
    use:SetPoint("LEFT", edit, "RIGHT", 8, 0)
    edit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local v = ParseCustomImage(self:GetText())
        if v then Choose(v, true) end
    end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    p.Open = function(self)
        if not pageProc then return end
        self.title:SetText("Image for " .. pageProc.buffName)
        local icon = ProcIcon(pageProc)
        self.iconTile.tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        self.blizzTile:SetShown(pageProc.blizzardArt ~= nil)
        if pageProc.blizzardArt then self.blizzTile.tex:SetTexture(pageProc.blizzardArt) end
        local defImg = pageProc.alertTexturePath or pageProc.blizzardArt or DEFAULT_ALERT_TEXTURE
        self.defaultTile.tex:SetTexture(defImg)
        local size = type(defImg) == "string" and IMAGE_SIZE[defImg:lower()]
        FitTexture(self.defaultTile.tex, size and size[1] or 128, size and size[2] or 256, TILE - 6)
        local cur = PS(pageProc.key).image
        for _, t in ipairs(tiles) do
            t.isSelected = (t.value == cur)
            if t.isSelected then
                t:SetBackdropBorderColor(accentR, accentG, accentB, 1)
            else
                t:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 1)
            end
        end
        edit:SetText((type(cur) == "string" and cur ~= "ICON" and cur ~= "BLIZZARD" and not IMAGE_SIZE[cur:lower()] and cur)
            or (type(cur) == "number" and tostring(cur)) or "")
        page:ScrollToTop()
        self:Show()
    end
    return p
end

-- Window ------------------------------------------------------------------
local function CreateTab(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(30)
    b.text = FS(b, "GameFontNormal", text)
    b.text:SetPoint("CENTER", 0, 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetColorTexture(1, 1, 1, 0.04)
    hl:SetAllPoints()
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetColorTexture(accentR, accentG, accentB, 1)
    b.line:SetHeight(2)
    b.line:SetPoint("BOTTOMLEFT")
    b.line:SetPoint("BOTTOMRIGHT")
    b.SetActive = function(self, on)
        self.line:SetShown(on)
        self.text:SetFontObject(on and "GameFontHighlight" or "GameFontDisable")
    end
    b:SetScript("OnClick", onClick)
    return b
end

-- Is the window on the right half (saved spot) or docked right?
local function PanelOnRight()
    if G.menuX then return G.menuX > 0 end
    return G.menuSide == "RIGHT"
end

-- Size and place the window: about two-thirds of the screen tall, and either
-- where the player last dragged it (G.menuX/menuY = centre offset from the
-- screen centre in UIParent units, so it survives scale changes) or docked a
-- little in from the chosen edge.
ApplyPanelGeometry = function()
    if not optionsFrame then return end
    local f = optionsFrame
    local scale = G.menuScale or 1
    f:SetScale(scale)
    local h = math.max(400, math.min(620, (UIParent:GetHeight() or 768) * 0.68 / scale))
    f:SetHeight(h)
    f:ClearAllPoints()
    if G.menuX and G.menuY then
        f:SetPoint("CENTER", UIParent, "CENTER", G.menuX / scale, G.menuY / scale)
    else
        local side = (G.menuSide == "RIGHT") and "RIGHT" or "LEFT"
        local inset = math.floor((UIParent:GetWidth() or 1024) * 0.07)
        f:SetPoint(side, UIParent, side, (side == "LEFT" and inset or -inset) / scale, 0)
    end
    if dockButton then
        dockButton.text:SetText(PanelOnRight() and "<" or ">")
    end
end

local function SavePanelPosition(f)
    local cx, cy = f:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not cx or not ux then return end
    local k = (f:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    G.menuX = math.floor(cx * k - ux + 0.5)
    G.menuY = math.floor(cy * k - uy + 0.5)
end

SelectView = function(view, key)
    if imagePicker then imagePicker:Hide() end
    CloseMenu()
    local changedProc = false
    if view == "PROC" then
        local proc = (key and procByKey[key]) or pageProc
        if proc then
            changedProc = (proc ~= pageProc) or currentView ~= "PROC"
            pageProc = proc
        else
            view = "LIST"
        end
    end
    currentView = view
    listPage:SetShown(view == "LIST")
    procPage:SetShown(view == "PROC")
    generalPage:SetShown(view == "GENERAL")
    tabProcs:SetActive(view ~= "GENERAL")
    tabGeneral:SetActive(view == "GENERAL")
    if view == "LIST" then
        RebuildProcList()
    elseif view == "PROC" then
        BindProcPage(changedProc)
    else
        for _, w in ipairs(generalWidgets) do w:Refresh() end
    end
end

local function BuildOptionsFrame()
    local f = CreateFrame("Frame", "ProcDocOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame = f
    f:SetWidth(PANEL_W)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetBackdrop(FLAT_BACKDROP)
    f:SetBackdropColor(0.055, 0.055, 0.07, 0.96)
    f:SetBackdropBorderColor(0, 0, 0, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()
    table.insert(UISpecialFrames, "ProcDocOptionsFrame")
    f:SetScript("OnShow", function() SetOptionsOpen(true) end)
    f:SetScript("OnHide", function()
        CloseMenu()
        StopTests()
        SetOptionsOpen(false)
    end)

    -- Header
    local header = CreateFrame("Frame", nil, f, "BackdropTemplate")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(44)
    header:SetBackdrop({ bgFile = WHITE })
    header:SetBackdropColor(0.085, 0.085, 0.11, 1)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        if f.SetUserPlaced then f:SetUserPlaced(false) end   -- we save it ourselves
        SavePanelPosition(f)
    end)
    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetSize(28, 28)
    logo:SetPoint("LEFT", 10, 0)
    logo:SetTexture(ICON)
    logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local title = FS(header, "GameFontNormalLarge", "ProcDoc")
    title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 8, 0)
    local sub = FS(header, "GameFontHighlightSmall",
        "|c" .. classColor .. (UnitClass("player") or "") .. "|r  |cff777777" .. (VERSION == "dev" and "dev build" or ("v" .. VERSION)) ..
        (IS_FOREVER and " · Forever" or "") .. "|r")
    sub:SetPoint("BOTTOMLEFT", logo, "BOTTOMRIGHT", 8, 0)
    local ok, close = pcall(CreateFrame, "Button", nil, header, "UIPanelCloseButton")
    if not ok then close = CreateFlatButton(header, "X", 24, 24) end
    close:SetPoint("RIGHT", -4, 0)
    close:SetScript("OnClick", function() f:Hide() end)
    dockButton = CreateFlatButton(header, ">", 24, 22, function()
        G.menuSide = PanelOnRight() and "LEFT" or "RIGHT"
        G.menuX, G.menuY = nil, nil
        ApplyPanelGeometry()
    end)
    dockButton:SetPoint("RIGHT", close, "LEFT", -4, 0)
    AttachTooltip(dockButton, "Dock to the other side", "Snaps this window to the other edge of the screen. Drag the title bar to put it anywhere; it remembers the spot.")

    -- Tabs
    local tabs = CreateFrame("Frame", nil, f, "BackdropTemplate")
    tabs:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    tabs:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    tabs:SetHeight(30)
    tabs:SetBackdrop({ bgFile = WHITE })
    tabs:SetBackdropColor(0.07, 0.07, 0.09, 1)
    tabProcs = CreateTab(tabs, "Procs", function()
        SelectView(currentView == "PROC" and "LIST" or (currentView == "GENERAL" and (pageProc and "PROC" or "LIST") or "LIST"))
    end)
    tabProcs:SetPoint("TOPLEFT")
    tabProcs:SetPoint("BOTTOMRIGHT", tabs, "BOTTOM", 0, 0)
    tabGeneral = CreateTab(tabs, "General", function() SelectView("GENERAL") end)
    tabGeneral:SetPoint("TOPLEFT", tabs, "TOP", 0, 0)
    tabGeneral:SetPoint("BOTTOMRIGHT")

    -- Footer
    local footer = CreateFrame("Frame", nil, f, "BackdropTemplate")
    footer:SetPoint("BOTTOMLEFT", 1, 1)
    footer:SetPoint("BOTTOMRIGHT", -1, 1)
    footer:SetHeight(40)
    footer:SetBackdrop({ bgFile = WHITE })
    footer:SetBackdropColor(0.085, 0.085, 0.11, 1)
    local fw = math.floor((PANEL_W - 2 - 20 - 12) / 3)
    local testAll = CreateFlatButton(footer, "Preview all", fw, 26, function() TestAll(nil) end)
    testAll:SetPoint("LEFT", 10, 0)
    local hideAll = CreateFlatButton(footer, "Hide", fw, 26, function() StopTests() end)
    hideAll:SetPoint("LEFT", testAll, "RIGHT", 6, 0)
    AttachTooltip(hideAll, "Hide previews")
    unlockButton = CreateFlatButton(footer, "Unlock", fw, 26, function() SetUnlocked(not unlockMode) end)
    unlockButton:SetPoint("LEFT", hideAll, "RIGHT", 6, 0)
    AttachTooltip(unlockButton, "Unlock alerts", "Shows every enabled alert so you can drag them into place. Right-click an alert to edit it.")

    -- Content
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", tabs, "BOTTOMLEFT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 0)
    listPage    = CreateScrollPage(content)
    procPage    = BuildProcPage(content)
    generalPage = BuildGeneralPage(content)
    imagePicker = BuildImagePicker(content)

    ApplyPanelGeometry()
end

RefreshOptions = function(rebuildList)
    if not optionsFrame or not optionsFrame:IsShown() then return end
    if unlockButton then unlockButton.text:SetText(unlockMode and "Lock" or "Unlock") end
    if currentView == "LIST" then
        RebuildProcList()
    elseif currentView == "PROC" and pageProc then
        for _, w in ipairs(procWidgets) do w:Refresh() end
        UpdatePreviewBox()
    elseif currentView == "GENERAL" then
        for _, w in ipairs(generalWidgets) do w:Refresh() end
    end
end

OpenOptions = function(selectKey)
    if not initialized then return end
    if not optionsFrame then BuildOptionsFrame() end
    ApplyPanelGeometry()
    optionsFrame:Show()
    if selectKey == "GENERAL" then
        SelectView("GENERAL")
    elseif selectKey and procByKey[selectKey] then
        SelectView("PROC", selectKey)
    else
        SelectView(currentView)
    end
    RefreshOptions()
end

ToggleOptions = function()
    if optionsFrame and optionsFrame:IsShown() then
        optionsFrame:Hide()
    else
        OpenOptions()
    end
end

end -- sections 12-13
BuildOptionsModule()

-- Addon compartment (minimap addon menu) / TOC hook
function ProcDoc_OnAddonCompartmentClick()
    ToggleOptions()
end

-- 14) Slash command, Settings panel entry and initialization
local function PrintBuffs()
    Print("current buffs (name - spell ID - stacks):")
    local locked = 0
    for i = 1, 40 do
        local exists, name, _, count, _, _, spellId = GetPlayerBuff(i)
        if not exists and name ~= true then break end
        if not exists then
            locked = locked + 1
        else
            local n = Readable(name) and name or "<hidden>"
            local id = Readable(spellId) and tostring(spellId) or "?"
            local c = Readable(count) and tostring(count) or "?"
            local proc = (Readable(spellId) and buffBySpellID[spellId]) or (Readable(name) and buffByName[name])
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s - %s - %s%s", n, id, c, proc and "  |cff00ff96(tracked)|r" or ""))
        end
    end
    if locked > 0 then
        Print(locked .. " buff(s) are hidden by the game right now (it does this in combat).")
        local names = {}
        for name in pairs(recentBuffs) do names[#names + 1] = name end
        if #names > 0 then
            table.sort(names, function(x, y) return recentBuffs[x].t > recentBuffs[y].t end)
            Print("buffs seen earlier this session:")
            for i = 1, math.min(#names, 15) do
                local id = recentBuffs[names[i]].id
                DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s - %s", names[i], id and tostring(id) or "?"))
            end
        end
    end
end

SLASH_PROCDOC1 = "/procdoc"
SLASH_PROCDOC2 = "/pd"
SlashCmdList["PROCDOC"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    if cmd == "unlock" or cmd == "move" then
        SetUnlocked(true)
    elseif cmd == "lock" then
        SetUnlocked(false)
    elseif cmd == "test" or cmd == "preview" then
        TestAll(30)
    elseif cmd == "hide" then
        StopTests()
    elseif cmd == "buffs" then
        PrintBuffs()
    elseif cmd == "cdm" then
        CDM.Report()
    elseif cmd == "stacktest" then
        local want = (msg or ""):lower():match("^%s*%S+%s+(.-)%s*$")
        local pick
        for _, proc in ipairs(classProcs) do
            if not proc.isAction then
                if want and want ~= "" then
                    if proc.buffName:lower():find(want, 1, true) then pick = proc break end
                elseif not pick then
                    pick = proc
                end
            end
        end
        if pick and RunStackTest(pick) then
            Print("stack test on |cffffd100" .. pick.buffName .. "|r: 1 to 5 stacks, down to 3, then it ends.")
        elseif want and want ~= "" then
            Print("no buff proc named \"" .. want .. "\" in your list.")
        else
            Print("no buff procs to test yet. Add one in the options (Procs tab, Add a proc).")
        end
    elseif cmd == "trace" then
        local sub = (msg or ""):lower():match("^%s*%S+%s+(%S+)")
        if sub == "show" then
            local log = ProcDocDB.trace or {}
            Print("last trace lines:")
            for i = math.max(1, #log - 24), #log do DEFAULT_CHAT_FRAME:AddMessage("  " .. log[i]) end
        elseif sub == "echo" then
            G.traceEcho = not G.traceEcho
            Print("trace echo " .. (G.traceEcho and "on (lines also print in chat)." or "off."))
        elseif G.trace then
            G.trace = false
            Print("trace OFF. The log stays in your saved settings until you start a new one.")
        else
            ProcDocDB.trace = {}
            G.trace = true
            traceState.last = nil
            Trace("trace start: v%s, %s, TOC %s, C_Secrets=%s, BySpellName=%s, ByInstanceID=%s, UNIT_COMBAT hooked",
                VERSION, playerClass or "?", tostring(TOC), tostring(C_Secrets ~= nil),
                tostring(C_UnitAuras ~= nil and C_UnitAuras.GetAuraDataBySpellName ~= nil),
                tostring(C_UnitAuras ~= nil and C_UnitAuras.GetAuraDataByAuraInstanceID ~= nil))
            for _, proc in ipairs(classProcs) do
                local ids = {}
                for _, id in ipairs(proc.spellIDs or {}) do ids[#ids + 1] = tostring(id) end
                for id in pairs(proc.learnedIDs or {}) do ids[#ids + 1] = id .. "(learned)" end
                Trace("tracking %s [%s] ids: %s", proc.key, proc.isAction and "reaction" or "buff",
                    #ids > 0 and table.concat(ids, " ") or (proc.spellID and tostring(proc.spellID)) or "name only")
            end
            CheckProcs()
            CheckAllActionProcs()
            Print("trace ON. Play until a proc is missed, then type |cff00ffff/reload|r so the log is saved. "
                .. "|cff00ffff/procdoc trace show|r prints the latest lines, |cff00ffff/procdoc trace|r again stops it.")
        end
    elseif cmd == "debug" then
        debugOverlays = not debugOverlays
        Print("overlay debug " .. (debugOverlays and "on: Blizzard proc events will be printed." or "off."))
        if ProcDoc_LastError then Print("last skipped error: " .. ProcDoc_LastError) end
    elseif cmd == "minimap" then
        SetMinimapButtonShown(G.minimapHide)
        Print("minimap button " .. (G.minimapHide and "hidden." or "shown."))
    elseif cmd == "help" then
        Print("commands: |cff00ffff/procdoc|r (options), unlock, lock, test, hide, stacktest [name], minimap, buffs, cdm, trace, debug")
    else
        ToggleOptions()
    end
end

local function RegisterSettingsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "ProcDoc"
    local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetText("ProcDoc")
    t:SetPoint("TOPLEFT", 16, -16)
    local d = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d:SetText("Pulsing proc alerts. All options live in ProcDoc's own window.")
    d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -8)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(160, 26)
    b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -14)
    b:SetText("Open ProcDoc")
    b:SetScript("OnClick", function()
        if _G.SettingsPanel and _G.SettingsPanel:IsShown() then HideUIPanel(_G.SettingsPanel) end
        if _G.InterfaceOptionsFrame and _G.InterfaceOptionsFrame:IsShown() then HideUIPanel(_G.InterfaceOptionsFrame) end
        OpenOptions()
    end)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "ProcDoc")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

Initialize = function()
    local _, cls = UnitClass("player")
    playerClass = cls
    ComputeAccent()
    BuildClassProcs()
    MigrateLegacySettings()
    -- Saved images that aren't in img\ any more (renamed or removed) fall back to
    -- the proc's default. Images typed into the picker's custom box are the
    -- player's own files (imageCustom) and are always kept.
    local imgPrefix = IMG:lower()
    for _, cls in pairs(ProcDocDB.procSettings) do
        for _, ps in pairs(cls) do
            if type(ps.image) == "string" and not ps.imageCustom then
                local img = ps.image:lower()
                if img:sub(1, #imgPrefix) == imgPrefix and not IMAGE_SIZE[img] then ps.image = nil end
            end
        end
    end
    -- Sizes used to be relative to UI units; 1.00x now means real pixel size.
    -- Convert sizes players already chose so their alerts look the same.
    if not G.sizeModel or G.sizeModel < 2 then
        local pf = PixelFactor()
        for _, cls in pairs(ProcDocDB.procSettings) do
            for _, ps in pairs(cls) do
                if ps.scale then ps.scale = RoundTo(math.min(4, math.max(0.25, ps.scale / pf)), 0.01) end
            end
        end
        G.sizeModel = 2
    end
    ApplyBlizzardOverlaySetting()
    pcall(RegisterSettingsPanel)
    if not G.minimapHide then pcall(CreateMinimapButton) end
    initialized = true
    RebuildActionSlots()
    CheckProcs()
    CheckAllActionProcs()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96ProcDoc|r loaded. Tracking " .. #classProcs .. (#classProcs == 1 and " proc" or " procs") .. " for |c" .. classColor ..
        (UnitClass("player") or "?") .. "|r. Type |cff00ffff/procdoc|r for options.")
end
