if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-- Blocks\Audio.lua
-- Audio volume block factory.

local ADDON_NAME, ns = ...
local L = ns.L
local MEDIA = ns.MEDIA
local K = ns.BlockKit

-- Upvalues
local CreateFrame = CreateFrame
local ipairs      = ipairs
local type        = type
local floor       = math.floor
local max         = math.max

local ICON_GAP             = K.ICON_GAP
local CONTENT_BASE         = K.CONTENT_BASE
local InstKey              = K.InstKey
local MakeEventFrame       = K.MakeEventFrame
local RegisterInstEvents   = K.RegisterInstEvents
local UnregisterInstEvents = K.UnregisterInstEvents
local VSlotW               = K.VSlotW
local MaybeRelayout        = K.MaybeRelayout
local IconColorOf          = K.IconColorOf

-------------------------------------------------------------------------------
--  AUDIO (interactive volume bar; channel picked in block settings)
--  Volume rides the sound CVars, which are unprotected: reads and writes are combat-legal.
-------------------------------------------------------------------------------
local AUDIO_CHANNELS = {
    master   = { cvar = "Sound_MasterVolume",   label = "AUDIO_MASTER" },
    sfx      = { cvar = "Sound_SFXVolume",      label = "AUDIO_SFX" },
    music    = { cvar = "Sound_MusicVolume",    label = "AUDIO_MUSIC" },
    ambience = { cvar = "Sound_AmbienceVolume", label = "AUDIO_AMBIENCE" },
    dialog   = { cvar = "Sound_DialogVolume",   label = "AUDIO_DIALOG" },
}
local AUDIO_CHANNEL_ORDER = { "master", "sfx", "music", "ambience", "dialog" }
ns.AUDIO_CHANNELS = AUDIO_CHANNELS
ns.AUDIO_CHANNEL_ORDER = AUDIO_CHANNEL_ORDER

ns.BlockFactories.audio = function(blockCfg, slot, content, barCtx)
    local inst = { cfg = blockCfg, slot = slot, content = content, ctx = barCtx }
    inst.key = InstKey(barCtx, blockCfg)
    inst.events = { "CVAR_UPDATE", "PLAYER_ENTERING_WORLD" }

    local AUDIO_TEX = MEDIA .. "audio.png"
    local mouseOver = false
    local dragging = false

    local function D() return blockCfg.settings or {} end
    local function BC() return barCtx.cfg end

    local function Chan()
        return AUDIO_CHANNELS[D().channel] or AUDIO_CHANNELS.master
    end
    local function GetVol()
        local v = tonumber(GetCVar(Chan().cvar)) or 1
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        return v
    end
    local function SetVol(v)
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        SetCVar(Chan().cvar, v)
    end

    local audioButton = CreateFrame("Button", nil, content)
    audioButton:SetAllPoints()
    audioButton:EnableMouse(true)
    audioButton:EnableMouseWheel(true)

    local audioIcon = audioButton:CreateTexture(nil, "OVERLAY")
    audioIcon:SetTexture(AUDIO_TEX)

    -- Volume bar: flat fill + dark track, same visual recipe as the profession skill bars.
    local volTrack = audioButton:CreateTexture(nil, "BACKGROUND")
    volTrack:SetColorTexture(0.15, 0.15, 0.15, 0.6)
    local volBar = CreateFrame("StatusBar", nil, audioButton)
    volBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    volBar:SetMinMaxValues(0, 1)

    -- Drag hit frame: covers the track plus 4px above/below so the thin bar is easy to grab; clicks on the icon never set the volume.
    local hit = CreateFrame("Button", nil, audioButton)
    hit:EnableMouse(true)

    local function SetFromCursor()
        local left = volTrack:GetLeft()
        local w = volTrack:GetWidth()
        if not left or not w or w <= 0 then return end
        local scale = volTrack:GetEffectiveScale()
        if not scale or scale == 0 then scale = 1 end
        local cx = GetCursorPosition() / scale
        local frac = (cx - left) / w
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        SetVol(frac)
        -- Direct paint for zero-lag feedback; the CVAR_UPDATE refresh reconciles anything else (tooltip, other blocks).
        volBar:SetValue(frac)
    end

    hit:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        dragging = true
        SetFromCursor()
        -- OnUpdate lives only for the duration of the drag.
        hit:SetScript("OnUpdate", SetFromCursor)
    end)
    hit:SetScript("OnMouseUp", function()
        if not dragging then return end
        dragging = false
        hit:SetScript("OnUpdate", nil)
        inst:Refresh()
    end)

    audioButton:SetScript("OnMouseWheel", function(_, delta)
        SetVol(GetVol() + delta * 0.05)
        inst:Refresh()
    end)

    -- Right-click: exact-value entry through the house input popup (never StaticPopup). Accepts 0-100; non-numbers are ignored.
    local function OpenVolumeInput()
        local ch = Chan()
        local cur = floor(GetVol() * 100 + 0.5)
        EllesmereUI:ShowInputPopup({
            title = "Set Volume",
            message = EllesmereUI.Lf("Enter a volume from 0 to 100 for %1$s:", L[ch.label]),
            placeholder = tostring(cur),
            confirmText = "Apply",
            cancelText = "Cancel",
            onConfirm = function(text)
                local n = tonumber(text)
                if not n then return end
                SetVol(n / 100)
                inst:Refresh()
            end,
        })
    end
    audioButton:RegisterForClicks("AnyUp")
    audioButton:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then OpenVolumeInput() end
    end)
    hit:RegisterForClicks("AnyUp")
    hit:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then OpenVolumeInput() end
    end)

    local function AudioTooltip()
        ns.Tip_Begin(audioButton)
        ns.Tip_AddLine("|cFFFFFFFF[|r" .. L["AUDIO"] .. "|cFFFFFFFF]|r", 1, 1, 1)
        ns.Tip_AddLine(" ")
        local selected = D().channel or "master"
        for _, key in ipairs(AUDIO_CHANNEL_ORDER) do
            local ch = AUDIO_CHANNELS[key]
            local pct = floor((tonumber(GetCVar(ch.cvar)) or 0) * 100 + 0.5)
            local lr, lg, lb = 0.65, 0.65, 0.65
            if key == selected then lr, lg, lb = 1, 1, 1 end
            ns.Tip_AddDouble(L[ch.label], pct .. "%", lr, lg, lb, 1, 1, 1)
        end
        ns.Tip_AddLine(" ")
        ns.Tip_AddDouble(L["LEFT_CLICK"], L["AUDIO_SET_HINT"], 1, 1, 1, 1, 1, 1)
        ns.Tip_AddDouble(L["RIGHT_CLICK"], L["AUDIO_INPUT_HINT"], 1, 1, 1, 1, 1, 1)
        ns.Tip_AddDouble(L["SCROLL_WHEEL"], L["AUDIO_SCROLL_HINT"], 1, 1, 1, 1, 1, 1)
        ns.Tip_Show()
    end

    audioButton:SetScript("OnEnter", function()
        mouseOver = true
        inst:Refresh()
        AudioTooltip()
    end)
    audioButton:SetScript("OnLeave", function()
        mouseOver = false
        inst:Refresh()
        ns.Tip_HideUnlessInteractive(audioButton)
    end)
    hit:SetScript("OnEnter", function()
        mouseOver = true
        inst:Refresh()
        AudioTooltip()
    end)
    hit:SetScript("OnLeave", function()
        mouseOver = false
        inst:Refresh()
        ns.Tip_HideUnlessInteractive(audioButton)
    end)

    function inst:Refresh()
        local barCfg = BC()
        local barH = barCtx.GetThickness()
        local fontSize = max(9, floor(CONTENT_BASE * 0.4333 + 0.5))
        local isSide = barCtx.IsVertical()
        local iconSz = fontSize + 4
        local barW = max(40, floor(CONTENT_BASE * 2 + 0.5))
        local bH = 5

        -- Show Icon (default ON): hidden drops the icon and its gap entirely.
        local showIcon = D().showIcon ~= false
        if showIcon then audioIcon:Show() else audioIcon:Hide(); iconSz = 0 end

        -- Icon color follows the Icon Color row; hover sweeps to accent.
        local ar, ag, ab = ns.GetAccent()
        if mouseOver then
            audioIcon:SetVertexColor(ar, ag, ab, 1)
        else
            local ir, ig, ib = IconColorOf(blockCfg)
            audioIcon:SetVertexColor(ir, ig, ib, 1)
        end
        -- Accent fill, like the profession bars.
        volBar:SetStatusBarColor(ar, ag, ab, 1)
        volBar:SetValue(GetVol())

        if showIcon then audioIcon:SetSize(iconSz, iconSz) end
        local effGap = showIcon and ICON_GAP or 0
        if isSide then
            local slotW = VSlotW(inst)
            local innerW = max(30, slotW - 8)
            audioIcon:ClearAllPoints()
            audioIcon:SetPoint("TOP", audioButton, "TOP", 0, -4)
            volTrack:ClearAllPoints()
            volTrack:SetSize(innerW, bH)
            if showIcon then
                volTrack:SetPoint("TOP", audioIcon, "BOTTOM", 0, -4)
            else
                volTrack:SetPoint("TOP", audioButton, "TOP", 0, -6)
            end
            content:SetSize(slotW, max(4 + iconSz + 4 + bH + 4, 40))
        else
            audioIcon:ClearAllPoints()
            audioIcon:SetPoint("LEFT", audioButton, "LEFT", 0, 0)
            volTrack:ClearAllPoints()
            volTrack:SetSize(barW, bH)
            volTrack:SetPoint("LEFT", audioButton, "LEFT", iconSz + effGap, 0)
            content:SetSize(iconSz + effGap + barW, barH)
        end
        volBar:ClearAllPoints()
        volBar:SetAllPoints(volTrack)
        hit:ClearAllPoints()
        hit:SetPoint("TOPLEFT", volTrack, "TOPLEFT", 0, 4)
        hit:SetPoint("BOTTOMRIGHT", volTrack, "BOTTOMRIGHT", 0, -4)
        audioButton:ClearAllPoints()
        audioButton:SetAllPoints(content)

        if mouseOver and not dragging then AudioTooltip() end
        MaybeRelayout(inst)
    end

    inst.eventFrame = MakeEventFrame(inst, function(self, event, cvar)
        -- Only sound CVar flips (ours or Blizzard's own panel) repaint.
        if event == "CVAR_UPDATE" and type(cvar) == "string"
           and not cvar:find("^Sound_") then
            return
        end
        self:Refresh()
    end)

    function inst:Enable()
        content:Show()
        RegisterInstEvents(self)
    end

    function inst:Disable()
        UnregisterInstEvents(self)
        content:Hide()
    end

    function inst:GetAutoLength()
        local fontSize = max(9, floor(CONTENT_BASE * 0.4333 + 0.5))
        if barCtx.IsVertical() then
            return max(content:GetHeight() or 40, 40)
        end
        local iconPart = 0
        if D().showIcon ~= false then iconPart = (fontSize + 4) + ICON_GAP end
        return iconPart + max(40, floor(CONTENT_BASE * 2 + 0.5))
    end

    function inst:Destroy()
        self._dead = true
        UnregisterInstEvents(self)
        content:Hide()
    end

    inst:Refresh()
    return inst
end
