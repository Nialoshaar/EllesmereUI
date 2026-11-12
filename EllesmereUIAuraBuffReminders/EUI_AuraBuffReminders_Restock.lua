if EUI_CLIENT_BLOCKED then return end

local _, ns = ...
local I = ns._abrInternals
if not I or I.broken then return end
I.broken = true

local EABR = I.EABR
local KEY = "EABR_Restock"
local FOOD_DRINK = Enum.ItemConsumableSubclass.Fooddrink
local POTION = Enum.ItemConsumableSubclass.Potion
local HEALING_POTION_TIERS = { 45, 35, 21, 12, 3 }
local bagSpace = { key = "bagSpace", minimum = "bagSpaceMinimum", texture = 133633,
    label = function() return EllesmereUI.L("Bag Space") end }
local junk = { key = "junk", texture = 133784, label = function() return EllesmereUI.L("Junk") end }
local reminders = {
    { key = "healthFood", minimum = "healthFoodMinimum", closest = "healthFoodClosestLevel", subclass = FOOD_DRINK,
      spell = EABR.FOREVER and 433 or 1290925, otherSpell = EABR.FOREVER and 1131 or nil,
      texture = 133995, label = function() return EllesmereUI.L("Health Food") end },
    { key = "manaDrink", minimum = "manaDrinkMinimum", closest = "manaDrinkClosestLevel", subclass = FOOD_DRINK,
      spell = EABR.FOREVER and 430 or 1290929, otherSpell = EABR.FOREVER and 1137 or 430,
      texture = 132794, label = function() return EllesmereUI.L("Mana Drink") end },
    { key = "healthPotion", minimum = "healthPotionMinimum", closest = "healthPotionClosestLevel", subclass = POTION,
      spell = EABR.FOREVER and 17534 or 1234768, otherSpell = 439,
      texture = 134829, label = function() return EllesmereUI.L("Health Potions") end },
    bagSpace,
    junk,
}
local db, anchor, appliedPos, panelOpen
local countDirty, bagSpaceDirty, waitingForSpellText, watchItems, watchSupplies, watchLevel, playerLevel
local pendingItems, failedItems, spellRequests, descriptionKinds
local wasResting, sleepingBagRest, lastProfile
local styleDirty

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

local function GetAnchorSize(w, h)
    local p = db.profile
    local count = 0
    for _, reminder in ipairs(reminders) do
        if p.restock[reminder.key] then count = count + 1 end
    end
    count = math.max(count, 1)
    return count * w + (count - 1) * (p.display.iconSpacing or 8), h
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
            getSize = function() return GetAnchorSize(GetIconSize()) end,
            isHidden = function()
                local restock = db.profile.restock
                return not (restock.healthFood or restock.manaDrink or restock.healthPotion or restock.bagSpace or restock.junk)
            end,
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

local function GetSupplyDescription(spellID)
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

local function RequestItemData(id)
    if not pendingItems[id] and not failedItems[id] then
        pendingItems[id] = true
        C_Item.RequestLoadItemDataByID(id)
    end
end

local function CountJunkSlot(info, id)
    if info.hasNoValue then return end
    local quality, hasNoValue = info.quality, info.hasNoValue
    if quality == nil or (quality == Enum.ItemQuality.Poor and hasNoValue == nil) then
        if not C_Item.IsItemDataCachedByID(id) then
            junk.incomplete = true
            RequestItemData(id)
            return
        end
        local _, _, itemQuality, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(id)
        quality, hasNoValue = itemQuality, not sellPrice or sellPrice <= 0
        if quality == nil then junk.incomplete = true end
    end
    if quality == Enum.ItemQuality.Poor and not hasNoValue then
        junk.count = junk.count + 1
    end
end

local function GetMinimumTier(reminder)
    if not reminder.closestLevel or not EABR.FOREVER then return 0 end
    -- Keep the current tier as the minimum even when its bags are empty.
    if reminder.subclass == POTION then
        for _, level in ipairs(HEALING_POTION_TIERS) do
            if playerLevel >= level then return level end
        end
    elseif playerLevel >= 5 then
        return math.min(55, 5 + 10 * math.floor((playerLevel - 5) / 10))
    end
    return 0
end

local function CountBagItems()
    waitingForSpellText = false
    wipe(descriptionKinds)
    local countFood, countPotions = false, false
    for _, reminder in ipairs(reminders) do
        if reminder.spell and reminder.enabled then
            -- Reference spells supply the localized wording for the whole effect.
            local plain = GetSupplyDescription(reminder.spell)
            local second = GetSupplyDescription(reminder.otherSpell)
            if plain then descriptionKinds[plain] = reminder end
            if second then descriptionKinds[second] = reminder end
            local hasReference = plain ~= nil or second ~= nil
            if hasReference then
                if reminder.subclass == POTION then countPotions = true else countFood = true end
            end
            reminder.count, reminder.incomplete, reminder.bestLevel = 0, not hasReference, GetMinimumTier(reminder)
            reminder.badgeDirty = true
        end
    end
    local countSupplies = countFood or countPotions
    if junk.enabled then
        junk.count, junk.incomplete, junk.badgeDirty = 0, false, true
    elseif not countSupplies then
        return
    end

    local incompleteFood, incompletePotions = false, false
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and junk.enabled then CountJunkSlot(info, id) end
            if id and countSupplies then
                local class, subclass = select(6, C_Item.GetItemInfoInstant(id))
                if class == Enum.ItemClass.Consumable
                    and ((countFood and subclass == FOOD_DRINK) or (countPotions and subclass == POTION)) then
                    local unresolved = false
                    if not C_Item.IsItemDataCachedByID(id) then
                        unresolved = true
                        RequestItemData(id)
                    else
                        local _, spellID = C_Item.GetItemSpell(id)
                        local description = GetSupplyDescription(spellID)
                        local reminder = description and descriptionKinds[description]
                        if reminder and reminder.subclass == subclass then
                            local requiredLevel = 0
                            if reminder.closestLevel then requiredLevel = select(5, C_Item.GetItemInfo(id)) end
                            if not requiredLevel then
                                reminder.incomplete = true
                            elseif requiredLevel >= reminder.bestLevel
                                and (not reminder.closestLevel or requiredLevel <= playerLevel) then
                                if requiredLevel > reminder.bestLevel then
                                    reminder.bestLevel, reminder.count = requiredLevel, 0
                                end
                                reminder.count = reminder.count + info.stackCount
                            end
                        elseif spellID and not description then
                            unresolved = true
                        end
                    end
                    if unresolved then
                        if subclass == POTION then incompletePotions = true else incompleteFood = true end
                    end
                end
            end
        end
    end
    if incompleteFood or incompletePotions then
        for _, reminder in ipairs(reminders) do
            if reminder.enabled and ((incompleteFood and reminder.subclass == FOOD_DRINK)
                or (incompletePotions and reminder.subclass == POTION)) then
                reminder.incomplete = true
            end
        end
    end
end

local function CountFreeSlots()
    local free = 0
    for bag = 0, NUM_BAG_SLOTS do
        local slots, family = C_Container.GetContainerNumFreeSlots(bag)
        if not family or family == 0 then free = free + (slots or 0) end
    end
    if bagSpace.count ~= free then
        bagSpace.count = free
        bagSpace.badgeDirty = true
    end
end

local function HideIcons()
    for _, reminder in ipairs(reminders) do
        local icon = reminder.icon
        if icon and icon:IsShown() then icon:Hide() end
    end
end

I.panelOpenSetters[#I.panelOpenSetters + 1] = function(open)
    panelOpen = open
    if open and I.restockWatching then HideIcons() end
end

local function RetryFailedData()
    if not watchItems then return end
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
            HideIcons()
        end
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        sleepingBagRest = nil
        countDirty, bagSpaceDirty = true, true
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
        bagSpaceDirty = true
        RetryFailedData()
    end
    countDirty = true
    I.RequestRefresh()
end

local function RenderReminder(reminder, p, w, h, x)
    local icon = reminder.icon
    if not icon then
        reminder.text = reminder.label()
        icon = I.BuildVisualIcon(nil, anchor)
        reminder.icon = icon
        icon:SetMouseClickEnabled(false)
        EABR.SetIconHighlight(icon, false)
        EABR.ApplyIconTooltipData(icon, { label = reminder.text })
    end
    if reminder.x ~= x then
        reminder.x = x
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", anchor, "CENTER", x, 0)
    end
    if styleDirty or not icon:IsShown() then
        icon:SetSize(w, h)
        icon:SetFrameStrata(I.GetStrata())
        icon:SetAlpha(p.opacity or 1)
        I.SetVisualIconText(icon, reminder.text)
        EABR.ApplyIconBorder(icon, false)
        I.ApplyGlow(icon, p)
        reminder.badgeDirty = true
    end
    if reminder.badgeDirty then
        local texture = (reminder.subclass == FOOD_DRINK and I.Tex(reminder.spell)) or reminder.texture
        if texture ~= reminder.iconTexture then
            reminder.iconTexture = texture
            icon._icon:SetTexture(texture)
            if reminder == junk then icon._icon:SetDesaturated(true) end
        end
        local count, incomplete = reminder.count, reminder.incomplete
        local badge
        if reminder == bagSpace or reminder == junk then
            badge = incomplete and (count .. "+") or tostring(count)
        elseif incomplete and p.showCount ~= false then
            badge = count > 0 and (count .. "+") or "?"
        end
        EABR.ApplyIconBagCount(icon, count, not incomplete and count == 0, nil, badge)
        reminder.badgeDirty = false
    end
    if not icon:IsShown() then icon:Show() end
end

function I.RefreshRestock()
    local profile = db.profile
    local restock = profile.restock
    local wantSupplies = restock.healthFood or restock.manaDrink or restock.healthPotion
    local wantItems = wantSupplies or restock.junk
    if not (wantItems or restock.bagSpace) then
        if I.restockWatching then
            anchor:UnregisterAllEvents()
            HideIcons()
            I.restockWatching = false
            countDirty, bagSpaceDirty, waitingForSpellText = true, true, nil
            watchItems, watchSupplies, watchLevel, playerLevel = nil, nil, nil, nil
            wasResting, sleepingBagRest, lastProfile = nil, nil, nil
            wipe(pendingItems)
            wipe(failedItems)
            wipe(spellRequests)
        end
        return
    end

    local w, h = GetIconSize()
    local anchorWidth = GetAnchorSize(w, h)
    if not anchor then
        pendingItems, failedItems, spellRequests, descriptionKinds = {}, {}, {}, {}
        anchor = CreateFrame("Frame", "EABR_RestockAnchor", UIParent)
        anchor:SetSize(anchorWidth, h)
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
        anchor:RegisterEvent("PLAYER_UPDATE_RESTING")
        anchor:RegisterEvent("PLAYER_ENTERING_WORLD")
        if EABR.FOREVER then
            anchor:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        end
    end
    if wantItems and not watchItems then
        watchItems = true
        anchor:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    elseif watchItems and not wantItems then
        watchItems = nil
        anchor:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
        wipe(pendingItems)
        wipe(failedItems)
    end
    if wantSupplies and not watchSupplies then
        watchSupplies = true
        anchor:RegisterEvent("SPELL_DATA_LOAD_RESULT")
        anchor:RegisterEvent("SPELL_TEXT_UPDATE")
    elseif watchSupplies and not wantSupplies then
        watchSupplies, waitingForSpellText = nil, nil
        anchor:UnregisterEvent("SPELL_DATA_LOAD_RESULT")
        anchor:UnregisterEvent("SPELL_TEXT_UPDATE")
        wipe(spellRequests)
    end

    if profile ~= lastProfile then
        lastProfile = profile
        styleDirty = true
        countDirty = true
    end
    if anchor:GetWidth() ~= anchorWidth or anchor:GetHeight() ~= h then
        anchor:SetSize(anchorWidth, h)
        styleDirty = true
    end
    local wantLevel = false
    for _, reminder in ipairs(reminders) do
        local enabled = restock[reminder.key] == true
        local closest = enabled and reminder.closest ~= nil and restock[reminder.closest] ~= false
        if enabled ~= reminder.enabled or closest ~= reminder.closestLevel then
            reminder.enabled, reminder.closestLevel = enabled, closest
            if reminder == bagSpace then
                bagSpaceDirty = true
            else
                countDirty = true
            end
        end
        if closest then wantLevel = true end
    end
    if wantLevel ~= watchLevel then
        watchLevel = wantLevel
        if wantLevel then
            playerLevel = UnitLevel("player")
            anchor:RegisterEvent("PLAYER_LEVEL_UP")
        else
            anchor:UnregisterEvent("PLAYER_LEVEL_UP")
        end
    end
    local resting = IsResting()
    if not resting or sleepingBagRest then
        wasResting = false
        HideIcons()
        return
    end
    if wasResting == false then
        RetryFailedData()
        countDirty = true
    end
    wasResting = true
    if panelOpen then return end
    if countDirty then
        if watchItems then CountBagItems() end
        countDirty = false
    end
    if bagSpaceDirty and bagSpace.enabled then
        CountFreeSlots()
        bagSpaceDirty = false
    end
    local visible = 0
    for _, reminder in ipairs(reminders) do
        local minimum = reminder.minimum
        reminder.visible = reminder.enabled and ((minimum and reminder.count < restock[minimum])
            or (not minimum and reminder.count > 0))
        if reminder.visible then
            visible = visible + 1
        elseif reminder.icon and reminder.icon:IsShown() then
            reminder.icon:Hide()
        end
    end
    if visible == 0 then return end
    local p = profile.display
    local step = w + (p.iconSpacing or 8)
    local x = -(visible - 1) * step / 2
    for _, reminder in ipairs(reminders) do
        if reminder.visible then
            RenderReminder(reminder, p, w, h, x)
            x = x + step
        end
    end
    styleDirty = false
end

I.broken = false
