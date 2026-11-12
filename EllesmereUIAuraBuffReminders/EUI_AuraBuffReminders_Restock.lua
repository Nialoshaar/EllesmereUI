if EUI_CLIENT_BLOCKED then return end

local _, ns = ...
local I = ns._abrInternals
if not I or I.broken then return end
I.broken = true

local EABR = I.EABR
local KEY = "EABR_Restock"
local PLAIN_FOOD = EABR.FOREVER and 433 or 1290925
local SECOND_PLAIN_FOOD = EABR.FOREVER and 1131 or nil
local db, anchor, icon, label, appliedPos
local count, incomplete, waitingForSpellText
local closestLevel, playerLevel
local pendingItems, failedItems, spellRequests
local wasResting, sleepingBagRest, lastProfile
local styleDirty, badgeDirty, iconTexture

I.restockWatching = false
I.dbSetters[#I.dbSetters + 1] = function(v) db = v end

function I.InvalidateRestockStyle()
    styleDirty = true
end

local function GetIconSize()
    local p = db.profile.display
    local size = math.floor(I.ICON_SIZE * (p.scale or 1) + 0.5)
    if p.iconShape and p.iconShape ~= "none" then
        return ns.IconDimensions(size, p)
    end
    return size, size
end

local function ApplyPosition()
    local pos = db.profile.restockPos
    appliedPos = pos
    if EllesmereUI.IsUnlockAnchored(KEY) and anchor:GetNumPoints() > 0 then return end
    anchor:ClearAllPoints()
    if pos then
        anchor:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 130)
    end
end

local function RegisterUnlockElement()
    EllesmereUI:RegisterUnlockElements({
        EllesmereUI.MakeUnlockElement({
            key = KEY,
            label = "Restock",
            group = "AuraBuff Reminders",
            order = 601,
            noResize = true,
            noSizeMatchTarget = true,
            getFrame = function() return anchor end,
            getSize = GetIconSize,
            isHidden = function() return not db.profile.restock.healthFood end,
            savePos = function(_, point, relPoint, x, y)
                db.profile.restockPos = { point = point, relPoint = relPoint, x = x, y = y }
                if not EllesmereUI._unlockActive then ApplyPosition() end
            end,
            loadPos = function() return db.profile.restockPos end,
            clearPos = function() db.profile.restockPos = nil end,
            applyPos = ApplyPosition,
        }),
    }, "EllesmereUIAuraBuffReminders")
end

local function GetFoodDescription(spellID)
    if not spellID then return end
    local description = C_Spell.GetSpellDescription(spellID)
    if issecretvalue(description) then return end
    if description and description ~= "" then
        spellRequests[spellID] = nil
        -- Ignore rank values, but preserve the entire effect text, including any buff or mana clause.
        return (description:gsub("%d[%d.,]*%d", "0"):gsub("%d", "0"):gsub("%s+", " "))
    end
    if spellRequests[spellID] == nil then
        spellRequests[spellID] = true
        C_Spell.RequestLoadSpellData(spellID)
    end
    if spellRequests[spellID] then waitingForSpellText = true end
end

local function CountHealthFood()
    waitingForSpellText = false
    -- The reference spells supply localized wording, not a list of eligible spells or items.
    local plain = GetFoodDescription(PLAIN_FOOD)
    local second = GetFoodDescription(SECOND_PLAIN_FOOD)
    if not plain and not second then
        return 0, true
    end

    local total, incomplete, bestLevel = 0, false, 0
    if closestLevel and EABR.FOREVER and playerLevel >= 5 then
        -- Keep the current tier as the minimum even when its bags are empty.
        bestLevel = math.min(55, 5 + 10 * math.floor((playerLevel - 5) / 10))
    end
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id then
                local class, subclass = select(6, C_Item.GetItemInfoInstant(id))
                if class == Enum.ItemClass.Consumable and subclass == Enum.ItemConsumableSubclass.Fooddrink then
                    if not C_Item.IsItemDataCachedByID(id) then
                        incomplete = true
                        if not pendingItems[id] and not failedItems[id] then
                            pendingItems[id] = true
                            C_Item.RequestLoadItemDataByID(id)
                        end
                    else
                        local _, spellID = C_Item.GetItemSpell(id)
                        local description = GetFoodDescription(spellID)
                        if description and (description == plain or description == second) then
                            local requiredLevel = 0
                            if closestLevel then requiredLevel = select(5, C_Item.GetItemInfo(id)) end
                            if not requiredLevel then
                                incomplete = true
                            elseif requiredLevel >= bestLevel and (not closestLevel or requiredLevel <= playerLevel) then
                                if requiredLevel > bestLevel then
                                    bestLevel, total = requiredLevel, 0
                                end
                                total = total + info.stackCount
                            end
                        elseif spellID and not description then
                            incomplete = true
                        end
                    end
                end
            end
        end
    end
    return total, incomplete
end

local function RetryFailedData()
    wipe(failedItems)
    for spellID, pending in pairs(spellRequests) do
        if pending == false then spellRequests[spellID] = nil end
    end
end

local function OnEvent(_, event, id, success)
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Forever reports the hidden tracking aura through this event.
        if not sleepingBagRest and not I.isSecret(id) and id == EABR.SLEEPING_BAG_TRACKING and IsResting() then
            sleepingBagRest = true
            icon:Hide()
        end
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        sleepingBagRest = nil
        return
    elseif event == "PLAYER_UPDATE_RESTING" then
        if not IsResting() then sleepingBagRest = nil end
        -- Forever's main ABR frame already requests a refresh on this event.
        if not EABR.FOREVER then I.RequestRefresh() end
        return
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        if not pendingItems[id] then return end
        pendingItems[id] = nil
        if not success then failedItems[id] = true end
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        if not spellRequests[id] then return end
        if not success then spellRequests[id] = false end
    elseif event == "SPELL_TEXT_UPDATE" then
        if not waitingForSpellText then return end
    elseif event == "PLAYER_LEVEL_UP" then
        playerLevel = id
    elseif event == "BAG_UPDATE_DELAYED" then
        RetryFailedData()
    end
    count = nil
    I.RequestRefresh()
end

function I.RefreshRestock()
    local profile = db.profile
    if not profile.restock.healthFood then
        if I.restockWatching then
            anchor:UnregisterAllEvents()
            icon:Hide()
            I.restockWatching = false
            count, incomplete, waitingForSpellText = nil, nil, nil
            closestLevel, playerLevel = nil, nil
            wasResting, sleepingBagRest, lastProfile = nil, nil, nil
            wipe(pendingItems)
            wipe(failedItems)
            wipe(spellRequests)
        end
        return
    end

    local w, h = GetIconSize()
    if not anchor then
        pendingItems, failedItems, spellRequests = {}, {}, {}
        label = EllesmereUI.L("Health Food")
        anchor = CreateFrame("Frame", "EABR_RestockAnchor", UIParent)
        anchor:SetSize(w, h)
        icon = I.BuildVisualIcon(nil, anchor)
        icon:SetAllPoints(anchor)
        icon:SetMouseClickEnabled(false)
        EABR.SetIconHighlight(icon, false)
        EABR.ApplyIconTooltipData(icon, { label = label })
        anchor:SetScript("OnEvent", OnEvent)
        ApplyPosition()
        RegisterUnlockElement()
        if EllesmereUI.IsUnlockAnchored(KEY) then
            EllesmereUI.ReapplyOwnAnchor(KEY)
        end
    elseif not EllesmereUI._unlockActive and appliedPos ~= profile.restockPos then
        ApplyPosition()
    end
    if not I.restockWatching then
        I.restockWatching = true
        anchor:RegisterEvent("BAG_UPDATE_DELAYED")
        anchor:RegisterEvent("ITEM_DATA_LOAD_RESULT")
        anchor:RegisterEvent("SPELL_DATA_LOAD_RESULT")
        anchor:RegisterEvent("SPELL_TEXT_UPDATE")
        anchor:RegisterEvent("PLAYER_UPDATE_RESTING")
        if EABR.FOREVER then
            anchor:RegisterEvent("SPELL_UPDATE_COOLDOWN")
            anchor:RegisterEvent("PLAYER_ENTERING_WORLD")
        end
    end

    if profile ~= lastProfile then
        lastProfile = profile
        styleDirty = true
        count = nil
    end
    if anchor:GetWidth() ~= w or anchor:GetHeight() ~= h then
        anchor:SetSize(w, h)
        styleDirty = true
    end
    local wantClosest = profile.restock.healthFoodClosestLevel ~= false
    if wantClosest ~= closestLevel then
        closestLevel = wantClosest
        count = nil
        if wantClosest then
            playerLevel = UnitLevel("player")
            anchor:RegisterEvent("PLAYER_LEVEL_UP")
        else
            anchor:UnregisterEvent("PLAYER_LEVEL_UP")
        end
    end
    local resting = IsResting()
    if not resting or sleepingBagRest then
        wasResting = false
        if icon:IsShown() then icon:Hide() end
        return
    end
    if wasResting == false then
        RetryFailedData()
        count = nil
    end
    wasResting = true
    if count == nil then
        count, incomplete = CountHealthFood()
        badgeDirty = true
        local texture = I.Tex(PLAIN_FOOD) or 133995
        if texture ~= iconTexture then
            iconTexture = texture
            icon._icon:SetTexture(texture)
        end
    end
    if count >= profile.restock.healthFoodMinimum then
        if icon:IsShown() then icon:Hide() end
        return
    end

    local p = profile.display
    if styleDirty then
        icon:SetFrameStrata(I.GetStrata())
        icon:SetAlpha(p.opacity or 1)
        I.SetVisualIconText(icon, label)
        EABR.ApplyIconBorder(icon, false)
        I.ApplyGlow(icon, p)
        styleDirty, badgeDirty = false, true
    end
    if badgeDirty then
        local badge
        if incomplete and p.showCount ~= false then
            badge = count > 0 and (count .. "+") or "?"
        end
        EABR.ApplyIconBagCount(icon, count, not incomplete and count == 0, nil, badge)
        badgeDirty = false
    end
    if not icon:IsShown() then icon:Show() end
end

I.broken = false
