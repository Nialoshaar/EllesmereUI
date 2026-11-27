if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EllesmereUIQuestTracker.lua
--
-- Slim loader. Blizzard's ObjectiveTrackerFrame remains the rendering engine;
-- we only skin it, drive its visibility, and layer on the auto-accept /
-- auto-turn-in / quest-item hotkey / SplashFrame QoL features.
--
-- The three feature modules are wired up on PLAYER_LOGIN after
-- Blizzard_ObjectiveTracker has loaded.
-------------------------------------------------------------------------------
local addonName, ns = ...
if not (EllesmereUI and EllesmereUI._ModuleNS and EllesmereUI.NewCombatQueue and EllesmereUI.CharData) then EUI_CLIENT_BLOCKED = true; return end -- stale-parent guard: a partially updated install (old parent, new child) goes dormant via the line-1 failsafe instead of erroring (its per-character data is in the parent's roster: CharData)
EllesmereUI._ModuleNS[addonName] = ns  -- LOD options files read this module ns via the registry
ns.CombatQueue = EllesmereUI.NewCombatQueue(CreateFrame("Frame"))

local EQT = {}
ns.EQT = EQT
_G.EllesmereUIQuestTracker = EQT

-------------------------------------------------------------------------------
-- DB defaults. Legacy keys from the 3807-line custom tracker are intentionally
-- omitted; the migration entry in EllesmereUI_Migration.lua archives any
-- stored values into a _legacy subtable.
-------------------------------------------------------------------------------
local QT_DEFAULTS = {
    profile = {
        questTracker = {
            enabled              = true,
            forceOnScreen        = true,
            visibility           = "always",
            visOnlyInstances     = false,
            visHideHousing       = false,
            visHideMounted       = false,
            visHideNoTarget      = false,
            visHideNoEnemy       = false,

            -- Raid auto-hide mode: "always" hides the tracker the whole time
            -- you are in a raid; "boss" (default) only hides it during boss encounters.
            hideInRaidMode       = "boss",

            -- Style page (reload-gated): Blizzard Style / Classic WoW UI
            useBlizzardStyle     = false,
            useClassicStyle      = false,

            -- Skin toggles
            skinHeaders          = true,
            -- Show Blizzard's native quest type icons/buttons (right side)
            -- instead of our custom classified icons. Off = our icons. Reload-gated.
            showQuestIcons       = false,

            -- Font sizes (single source of truth used by skin code)
            titleFontSize        = 12,
            objectiveFontSize    = 10,
            headerFontSize       = 13,

            -- Background (rendered behind ObjectiveTrackerFrame, our own frame)
            bgR                  = 0.035,
            bgG                  = 0.035,
            bgB                  = 0.035,
            bgAlpha              = 0.75,
            showTopLine          = true,
            trackerBorderTexture = "solid",
            trackerBorderSize    = 0,

            -- Text colors. All apply via SetTextColor on their respective
            -- FontStrings (titles, objective lines, focus override).
            titleR               = 1.000, titleG = 0.910, titleB = 0.471,  -- FFE878
            completedR           = 0.251, completedG = 1.000, completedB = 0.349,  -- 40FF59
            focusR               = 0.871, focusG = 0.251, focusB = 1.000,  -- DE40FF

            -- QoL
            autoAccept           = false,
            autoAcceptPreventMulti = true,
            autoAcceptShiftEnable = false,
            autoAcceptShiftSkip  = true,
            autoAcceptIgnoreTrivial = false,
            autoAcceptIgnoreOldExpansion = false,
            autoTurnIn           = false,
            autoTurnInShiftEnable = false,
            autoTurnInShiftSkip  = true,
            questItemHotkey      = nil,
        },
    },
}
-- WoW Forever's quest tools add their keys to this table at load
-- (EllesmereUIQuestTracker_Forever.lua), before the DB is made.
ns.QT_DEFAULTS = QT_DEFAULTS

local _qtDB
local function EnsureDB()
    if _qtDB then return _qtDB end
    if not EllesmereUI or not EllesmereUI.Lite then return nil end
    _qtDB = EllesmereUI.Lite.NewDB("EllesmereUIQuestTrackerDB", QT_DEFAULTS)
    _G._EQT_DB = _qtDB
    return _qtDB
end

function EQT.DB()
    local d = EnsureDB()
    if d and d.profile and d.profile.questTracker then
        return d.profile.questTracker
    end
    -- Fallback when the persistent DB isn't ready yet (login races, profile
    -- switch windows, spec swaps). Must contain `enabled=true` + a valid
    -- visibility mode, otherwise EvalVisibility returns false and the shared
    -- visibility dispatcher will alpha-0 the tracker whenever an unrelated
    -- event (combat, target change, zone) fires during an unready window.
    if not EQT._tmpDB then
        EQT._tmpDB = { enabled = true, visibility = "always" }
    end
    return EQT._tmpDB
end

function EQT.Cfg(k) return EQT.DB()[k] end
function EQT.Set(k, v) EQT.DB()[k] = v end

-- Keep the existing tracker usable if only the child addon has been updated.
if EllesmereUI.ApplySecretSafeBorderStyle and EllesmereUI.BorderPx and EllesmereUI.GetClassColor
    and EllesmereUI.GetBorderDefaults and EllesmereUI.GetBorderStyleSelectDefaults and EllesmereUI.GetBorderTextureDropdown then
    if EllesmereUI.RegisterBorderDefaults and EllesmereUI.BORDER_DEFAULTS_FRAMES then
        EllesmereUI.RegisterBorderDefaults("questtracker", EllesmereUI.BORDER_DEFAULTS_FRAMES)
    end
    if EllesmereUI.RoundCorners and EllesmereUI.ApplyBorderStyle then
        ns.TrackerBorderCanRound = EllesmereUI.RoundedStyleOK
    end

    function ns.TrackerBorderBehind(cfg)
        local behind = cfg.trackerBorderBehind
        if behind ~= nil then return behind end
        return cfg.trackerBorderTexture == "shadow"
    end

    local defaultTexture, defaultColor
    function ns.GetTrackerBorderRGB(cfg, mode)
        if mode == "class" then
            local color = EllesmereUI._playerClass and EllesmereUI.GetClassColor(EllesmereUI._playerClass)
            if color then return color.r, color.g, color.b end
            return 1, 1, 1
        end
        local color = mode ~= "default" and cfg.trackerBorderColor
        if not color then
            local texture = cfg.trackerBorderTexture or "solid"
            if defaultTexture ~= texture then
                defaultTexture = texture
                defaultColor = EllesmereUI.GetBorderStyleSelectDefaults(texture)
            end
            color = defaultColor
        end
        return color.r, color.g, color.b
    end

    function ns.ApplyTrackerBorder(owner, cfg, background, tracker)
        local size = cfg.trackerBorderSize or 0
        local border = owner._questBorder
        local radius = cfg.trackerBorderRadius or 0
        if size <= 0 and radius <= 0 and (not border or not (border:IsShown() or border._questRounded)) then return end
        local texture = cfg.trackerBorderTexture or "solid"
        local textured = texture ~= "solid" and texture ~= ""
        local rounded = radius > 0 and cfg.trackerBorderCorners ~= 0
            and ns.TrackerBorderCanRound and ns.TrackerBorderCanRound(texture)
        if size <= 0 and not rounded and (not border or not (border:IsShown() or border._questRounded)) then return end
        local backdrop = textured and size > 0 and EllesmereUI.ApplyBorderStyle ~= nil
        if backdrop or rounded then
            -- BackdropTemplate needs ordinary dimensions, while the rounded
            -- texture path can use secret dimensions but needs readable anchors.
            local ok, w, h = pcall(owner.GetSize, owner)
            if not ok then return end
            backdrop = backdrop and not (issecretvalue and (issecretvalue(w) or issecretvalue(h)))
                and type(w) == "number" and type(h) == "number"
        end
        if not border then
            border = CreateFrame("Frame", nil, owner)
            border:SetAllPoints()
            owner._questBorder = border
        end
        local level = owner:GetFrameLevel()
        local strata = (tracker or owner):GetFrameStrata()
        if textured then
            if ns.TrackerBorderBehind(cfg) then
                -- A level-zero background has no lower level in its own strata.
                if level == 0 then strata = "BACKGROUND" end
                level = math.max(0, level - 1)
            else
                level = (tracker or owner):GetFrameLevel() + 10
            end
        end
        if border:GetFrameStrata() ~= strata then border:SetFrameStrata(strata) end
        if border:GetFrameLevel() ~= level then border:SetFrameLevel(level) end
        local r, g, b = ns.GetTrackerBorderRGB(cfg, cfg.trackerBorderColorMode)
        local alpha = cfg.trackerBorderAlpha or 1
        local px = EllesmereUI.BorderPx(cfg.trackerBorderSizePx, size, texture)
        local ox, oy = cfg.trackerBorderOffsetX, cfg.trackerBorderOffsetY
        local sx, sy = cfg.trackerBorderShiftX, cfg.trackerBorderShiftY
        if border._questRounded and not rounded then
            EllesmereUI.RoundCorners(owner, 0)
        end
        local secretGlow = not backdrop and rounded and textured and size > 0
            and EllesmereUI.ROUND_CORNERS_SECRET_GLOW and EllesmereUI.SecretBorderGeometry ~= nil
        if backdrop then
            if not border._questBackdrop then
                EllesmereUI.ApplySecretSafeBorderStyle(border, border, 0, 0, 0, 0, 1, "solid")
            end
            EllesmereUI.ApplyBorderStyle(border, size, r, g, b, alpha, texture, ox, oy, sx, sy,
                "questtracker", size, nil, px)
        elseif secretGlow then
            if not border._questSecretGlow then
                EllesmereUI.ApplySecretSafeBorderStyle(border, border, 0, 0, 0, 0, 1, "solid")
                border:Show()
            end
        else
            EllesmereUI.ApplySecretSafeBorderStyle(border, border, size, r, g, b, alpha, texture, ox, oy, sx, sy,
                "questtracker", size, nil, px)
        end
        border._questBackdrop = backdrop
        border._questSecretGlow = secretGlow
        border._questRounded = rounded
        if rounded then
            local opts = border._questRoundOpts
            if not opts then
                opts = { border = border, roots = {}, textures = { background } }
                border._questRoundOpts = opts
            end
            opts.style, opts.corners = texture, cfg.trackerBorderCorners
            if secretGlow then
                local glow = border._questGlowSettings
                if not glow then
                    glow = { addonKey = "questtracker" }
                    border._questGlowSettings = glow
                end
                glow.size, glow.style, glow.px = size, texture, px
                glow.offsetX, glow.offsetY, glow.shiftX, glow.shiftY = ox, oy, sx, sy
                glow.r, glow.g, glow.b, glow.a = r, g, b, alpha
                opts.secretGlow = glow
            else
                opts.secretGlow = nil
            end
            EllesmereUI.RoundCorners(owner, radius, opts)
        end
    end
end

-- The style this module RENDERS this session: "eui" | "blizzard" | "classic".
-- Read from the real profile once and latched for the session (a live profile
-- switch prompts for a reload instead). Creates the DB itself: its first
-- caller is the parent's PLAYER_LOGIN font pass, which runs before TryInit.
-- Never reads EQT.DB(), whose stand-in table would latch "eui" too early.
-- The style a profile's saved flags ask for.
local function StyleOf(qt)
    return (qt.useClassicStyle and "classic") or (qt.useBlizzardStyle and "blizzard") or "eui"
end

function ns.QT_Style()
    local v = ns._qtStyle
    if v == nil then
        local d = EnsureDB()
        local qt = d and d.profile and d.profile.questTracker
        if not qt then return "eui" end
        v = StyleOf(qt)
        ns._qtStyle = v
    end
    return v
end

-- WoW Forever: whether a profile asks for our own tracker in place of
-- Blizzard's. Its own pick decides (customTrackerPick, saved only where it
-- differs from the style's answer); with no pick the tracker is on under the
-- EllesmereUI style alone, so a stock style keeps Blizzard's tracker. A false
-- in the older customTracker key is a pick as well: that key read on for
-- everyone who had not turned it off, so a true in it never was one and is
-- not read.
function ns.CustomTrackerWanted(qt)
    if EllesmereUI.IS_FOREVER ~= true then return false end
    local pick = qt.customTrackerPick
    if pick == nil and qt.customTracker == false then pick = false end
    if pick ~= nil then return pick end
    return StyleOf(qt) == "eui"
end

-- The options toggle's pick (the tracker in use is latched until a reload).
function ns.SetCustomTrackerWanted(qt, on)
    on = on and true or false
    qt.customTracker = nil
    if on == (StyleOf(qt) == "eui") then
        qt.customTrackerPick = nil
    else
        qt.customTrackerPick = on
    end
end

-- Stock mode: true for both stock styles (Blizzard's own tracker art and text).
-- WoW Forever: our own tracker replaces Blizzard's. Latched like the style.
function ns.UseCustomTracker()
    local v = ns._customTracker
    if v == nil then
        local d = EnsureDB()
        local qt = d and d.profile and d.profile.questTracker
        if not qt then return false end
        v = ns.CustomTrackerWanted(qt)
        ns._customTracker = v
    end
    return v
end

function EQT.Blizz() return ns.QT_Style() ~= "eui" end
function EQT.Classic() return ns.QT_Style() == "classic" end

-------------------------------------------------------------------------------
-- Cross-module suppression API. Other EUI modules (e.g. M+ Timer preview
-- mode) can call _EQT_SetSuppressed(key, true) to temporarily hide our
-- tracker. Suppression stacks across callers.
--
-- Top-level only: never walk into the frame's children. We reparent the
-- ObjectiveTrackerFrame to a hidden container; mouse state is implicit.
-------------------------------------------------------------------------------
local _qtSuppressors = {}
function _G._EQT_SetSuppressed(key, on)
    if not key then return end
    _qtSuppressors[key] = on and true or nil
    if EQT.ApplySuppression then EQT.ApplySuppression(next(_qtSuppressors) ~= nil) end
end
function EQT.IsSuppressed() return next(_qtSuppressors) ~= nil end

-------------------------------------------------------------------------------
-- Loader
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")

-- Blizzard_ObjectiveTracker is part of the base Midnight UI and is loaded
-- before our addon, so ADDON_LOADED for it never fires. Seed _sawOT from
-- IsAddOnLoaded (or the frame's existence) so init still triggers.
local _sawSelf, _sawOT, _loggedIn = false, false, false
if C_AddOns.IsAddOnLoaded("Blizzard_ObjectiveTracker") or _G.ObjectiveTrackerFrame then
    _sawOT = true
end

local function TryInit()
    if not (_sawSelf and _sawOT and _loggedIn) then return end
    EnsureDB()
    if ns.UseCustomTracker() then
        EQT.InitCustom()
    else
        if EQT.InitSkin       then EQT.InitSkin()       end
        if EQT.InitVisibility then EQT.InitVisibility() end
    end
    if EQT.InitQoL        then EQT.InitQoL()        end
    -- The custom tracker has its own mover; this one drives Blizzard's frame.
    if EQT.InitPosition and not ns.UseCustomTracker() then EQT.InitPosition() end
    loader:UnregisterAllEvents()
end

loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then _sawSelf = true end
        if arg1 == "Blizzard_ObjectiveTracker" then _sawOT = true end
    elseif event == "PLAYER_LOGIN" then
        _loggedIn = true
    end
    TryInit()
end)

-- Profile-swap refresh: called from EllesmereUI.RefreshAllAddons to re-read
-- DB and refresh all visuals after a profile switch without /reload.
_G._EQT_RefreshAll = function()
    if EQT.RefreshFonts then EQT.RefreshFonts() end
    if EQT.UpdateVisibility then EQT.UpdateVisibility() end
    if EQT.RestyleAll then EQT.RestyleAll() end
    -- Before ApplyBackground: the BG's top anchor depends on whether the
    -- master header is suppressed.
    if EQT.ApplyMasterHeaderVisibility then EQT.ApplyMasterHeaderVisibility() end
    if EQT.ApplyBackground then
        -- The custom restyle has already reapplied its border.
        EQT.ApplyBackground(ns.UseCustomTracker() and EQT.RestyleAll ~= nil)
    end
    if EQT.ApplyForceOnScreen then EQT.ApplyForceOnScreen() end
    if EQT.SyncPosition then EQT.SyncPosition() end
    -- The hotkey is a per-profile setting backed by an override binding, so a
    -- profile or spec swap has to re-point it. Without this the outgoing
    -- profile's key stays overridden -- taken from whatever the player really
    -- has bound there -- and the incoming profile's key is never laid down.
    if EQT.ApplyQuestItemHotkey then EQT.ApplyQuestItemHotkey() end
    if EQT.SyncAutoQuests then EQT.SyncAutoQuests() end
    -- WoW Forever's quest tools (nil on retail).
    if EQT.ApplyQuestWatches then EQT.ApplyQuestWatches() end
    if EQT.ApplyQuestProgress then EQT.ApplyQuestProgress() end
    if EQT.ApplyQuestLinks then EQT.ApplyQuestLinks() end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_EQT1 = "/eqt"
SlashCmdList.EQT = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "show" then
        EQT.Set("enabled", true)
        if EQT.UpdateVisibility then EQT.UpdateVisibility() end
    elseif msg == "hide" then
        EQT.Set("enabled", false)
        if EQT.UpdateVisibility then EQT.UpdateVisibility() end
    elseif msg == "toggle" then
        EQT.Set("enabled", not EQT.Cfg("enabled"))
        if EQT.UpdateVisibility then EQT.UpdateVisibility() end
    else
        if InCombatLockdown and InCombatLockdown() then return end
        EllesmereUI:ShowModule("EllesmereUIQuestTracker")
    end
end
