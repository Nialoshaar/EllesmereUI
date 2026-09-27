if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EllesmereUI_ManaRegenSpark.lua
-- WoW FOREVER ONLY: mana regen spark on mana power bars.
--
-- Mana regenerates in ticks every 2 seconds, and Spirit regen stops when a
-- spell finishes casting, resuming five seconds after the last cast. The
-- spark shows both:
--   * a completed cast of a spell that costs mana starts a 5s sweep
--   * when it ends (or mana starts changing while idle) 2s sweeps run back to
--     back, never reset mid-sweep; a sweep with no mana update during it ends
--     the cycle (mana full, the event only fires on a change)
-- The 2s sweeps estimate the server tick: mana is SECRET, so no tick signal
-- exists, and nothing here reads or compares a mana value. The signals are
-- the cast event, the spell's cost type and UNIT_POWER_UPDATE as a
-- keep-alive. UNIT_POWER_FREQUENT is unusable: it fires many times per tick.
--
-- Hosts ("erb" Resource Bars power bar, "uf" Unit Frames player power bar)
-- Attach their StatusBar while their option is on and the bar can draw, and
-- Detach it otherwise. Attach also lays the spark out, so hosts call it on
-- every rebuild, after the bar's orientation and reverse fill are set.
-- SetMana reports whether the bar shows mana, attached or not. The spark
-- rides an overlay StatusBar, shown only while a sweep draws on it, whose
-- fill the engine animates (SetTimerDuration); one reused animation group
-- times the sweeps, so no Lua runs per frame and no sweep creates a timer.
-- Cost: the events are registered only while an attached host bar is
-- visible (OnShow/OnHide of our own bars). A bar showing Energy or Rage (a
-- druid in a form) keeps them, so a cast there still starts the cycle and
-- the spark joins it on the return to mana. Off, only the unregistered event
-- frame, its animation group and one duration object exist; warriors and
-- rogues, who have no mana, get nothing at all.
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
local _, PLAYER_CLASS = UnitClass("player")
if PLAYER_CLASS == "WARRIOR" or PLAYER_CLASS == "ROGUE" then return end

local MANA = Enum.PowerType.Mana
local WINDOW = 5   -- five second rule
local TICK = 2     -- regen tick interval
local SPARK_W = 8  -- spark thickness along the fill direction
local SPARK_TEX = "Interface\\AddOns\\EllesmereUI\\media\\cast_spark.tga"
local IMMEDIATE = Enum.StatusBarInterpolation.Immediate
local ELAPSED = Enum.StatusBarTimerDirection.ElapsedTime

local hosts = {}   -- key -> host record while attached
local built = {}   -- bar -> host record (kept across detach)
local mana = {}    -- key -> true while that host's bar shows mana
local listening = false
local sweepEnd           -- end time of the running sweep; nil while idle
local inWindow = false   -- true while the 5s sweep runs
local regenSeen = false  -- mana update seen during the current tick sweep
local dur = C_DurationUtil.CreateDuration()
local ev = CreateFrame("Frame")
local timer = ev:CreateAnimationGroup()   -- one-shot, one sweep long
local timerSpan = timer:CreateAnimation("Animation")

-- True when the spell's cost includes mana. A secret amount counts as a cost;
-- only a plain 0 is free.
local function CostsMana(spellID)
    if issecretvalue(spellID) or not spellID then return false end
    local costs = C_Spell.GetSpellPowerCost(spellID)
    if not costs then return false end
    for i = 1, #costs do
        local c = costs[i]
        if not issecretvalue(c.type) and c.type == MANA then
            local amt = c.cost
            return issecretvalue(amt) or (type(amt) == "number" and amt > 0)
        end
    end
    return false
end

-- Lays the spark on the overlay's fill edge in the host bar's orientation.
-- Two points span the bar's thickness, so resizes follow with no Lua. The
-- inputs are the bar's orientation and reverse fill (the overlay's fill
-- texture is set once, at build); while they hold, the anchors stand.
local function Layout(h)
    local bar = h.bar
    local vert = bar:GetOrientation() == "VERTICAL"
    local rev = bar:GetReverseFill() and true or false
    if h.vert == vert and h.rev == rev then return end
    h.vert, h.rev = vert, rev
    local o, s = h.overlay, h.spark
    o:SetOrientation(vert and "VERTICAL" or "HORIZONTAL")
    o:SetReverseFill(rev)
    local ft = o:GetStatusBarTexture()
    s:ClearAllPoints()
    if vert then
        -- The spark texture transposed into a horizontal line.
        s:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
        s:SetPoint("LEFT", ft, rev and "BOTTOMLEFT" or "TOPLEFT")
        s:SetPoint("RIGHT", ft, rev and "BOTTOMRIGHT" or "TOPRIGHT")
        s:SetHeight(SPARK_W)
    else
        s:SetTexCoord(0, 1, 0, 1)
        s:SetPoint("TOP", ft, rev and "TOPLEFT" or "TOPRIGHT")
        s:SetPoint("BOTTOM", ft, rev and "BOTTOMLEFT" or "BOTTOMRIGHT")
        s:SetWidth(SPARK_W)
    end
end

-- Puts an attached host's spark into the running sweep, at its current
-- position, or hides it: it draws only while a sweep runs, the bar shows
-- mana and the bar is visible.
local function Arm(h)
    local o = h.overlay
    if sweepEnd and mana[h.key] and h.bar:IsVisible() then
        o:Show()
        o:SetTimerDuration(dur, IMMEDIATE, ELAPSED)
    else
        o:Hide()
    end
end

local function Idle()
    timer:Stop()
    sweepEnd = nil
    inWindow = false
    regenSeen = false
    for _, h in pairs(hosts) do h.overlay:Hide() end
end

-- Starts a sweep of len seconds on every host. A tick sweep chains from the
-- end of the one before (start), so the cadence does not drift by a frame
-- per hop; a start already a full sweep behind restarts from now.
local function Sweep(len, start)
    local now = GetTime()
    if not start or start + len <= now then start = now end
    sweepEnd = start + len
    dur:SetTimeFromStart(start, len)
    for _, h in pairs(hosts) do Arm(h) end
    timer:Stop()
    timerSpan:SetDuration(sweepEnd - now)
    timer:Play()
end

-- A sweep ended: the window just closing or a mana update during it runs
-- another tick sweep, anything else ends the cycle.
timer:SetScript("OnFinished", function()
    if inWindow or regenSeen then
        inWindow = false
        regenSeen = false
        Sweep(TICK, sweepEnd)
    else
        Idle()
    end
end)

ev:SetScript("OnEvent", function(_, event, _, arg2, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if CostsMana(arg3) then
            inWindow = true
            regenSeen = false
            Sweep(WINDOW)
        end
    elseif arg2 == "MANA" and not inWindow then
        if sweepEnd then regenSeen = true else Sweep(TICK) end
    end
end)

-- Events are heard while at least one attached host bar is visible; when the
-- last one hides or detaches they are dropped and the cycle ends.
local function Listen()
    local on = false
    for _, h in pairs(hosts) do
        if h.bar:IsVisible() then on = true; break end
    end
    if on == listening then return end
    listening = on
    if on then
        ev:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
        ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    else
        ev:UnregisterAllEvents()
        Idle()
    end
end

-- Hooked once on each host bar (our own StatusBars). A bar that is not
-- attached returns at once; a shown bar joins the running sweep.
local function OnHostShow(bar)
    local h = built[bar]
    if hosts[h.key] == h then
        Listen()
        Arm(h)
    end
end

local function OnHostHide(bar)
    local h = built[bar]
    if hosts[h.key] == h then Listen() end
end

local MRS = {}
EllesmereUI.ManaRegenSpark = MRS

-- The host's option is on and its bar can draw. Lays the spark out on every
-- call, so hosts call it on every rebuild.
function MRS.Attach(key, bar)
    local h = built[bar]
    if not h then
        local o = CreateFrame("StatusBar", nil, bar)
        o:SetAllPoints(bar)
        o:SetFrameLevel(bar:GetFrameLevel() + 2)
        o:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        o:GetStatusBarTexture():SetAlpha(0)
        o:SetMinMaxValues(0, 1)
        o:SetValue(0)
        o:Hide()
        local s = o:CreateTexture(nil, "OVERLAY", nil, 1)
        s:SetTexture(SPARK_TEX)
        s:SetBlendMode("ADD")
        h = { bar = bar, overlay = o, spark = s }
        built[bar] = h
        bar:HookScript("OnShow", OnHostShow)
        bar:HookScript("OnHide", OnHostHide)
    end
    Layout(h)
    local old = hosts[key]
    if old == h then return end
    if old then old.overlay:Hide() end
    h.key = key
    hosts[key] = h
    Listen()
    Arm(h)
end

function MRS.Detach(key)
    local h = hosts[key]
    if not h then return end
    hosts[key] = nil
    h.overlay:Hide()
    Listen()
end

-- The host reports whether its bar shows mana. Kept while detached, so an
-- attach starts from the last report; on the edge to mana a running sweep
-- shows at once, at its current position.
function MRS.SetMana(key, isMana)
    if mana[key] == isMana then return end
    mana[key] = isMana
    local h = hosts[key]
    if h then
        if isMana then Layout(h) end
        Arm(h)
    end
end
