if EUI_CLIENT_BLOCKED then return end

local _, ns = ...
local I = ns._abrInternals
if not I or I.broken then return end
I.broken = true

local EABR = I.EABR
local KEY = "EABR_Restock"
local FOOD_DRINK = Enum.ItemConsumableSubclass.Fooddrink
local POTION = Enum.ItemConsumableSubclass.Potion
local bagSpace = { key = "bagSpace", minimum = "bagSpaceMinimum", texture = 133633,
    label = function() return EllesmereUI.L("Bag Space") end }
local junk = { key = "junk", texture = 133784, label = function() return EllesmereUI.L("Junk") end }
local wellFedFood = { key = "wellFedFood", minimum = "wellFedFoodMinimum", texture = 136000,
    label = function() return EllesmereUI.L("Well Fed Food") end }
local elixirs = { key = "elixirs", closest = "elixirsClosestLevel", texture = 134810,
    groupMinimum = "elixirsMinimum", label = function() return EllesmereUI.L("Elixirs") end }
local potions = { key = "potions", closest = "potionsClosestLevel", texture = 134712,
    groupMinimum = "potionsMinimum", label = function() return EllesmereUI.L("Potions") end }
local ELIXIR_TYPES = {
    { key = "strength", label = "Strength", ids = { 2454, 3391, 250349, 9206 } },
    { key = "agility", label = "Agility", ids = { 2457, 3390, 8949, 9187, 13452 } },
    { key = "intellect", label = "Intellect", ids = { 3383, 250353, 250354, 9179 } },
    { key = "spellPower", label = "Spell Power", ids = { 247754, 250342, 9155, 13454 } },
    { key = "armor", label = "Armor", ids = { 5997, 3389, 8951, 13445 } },
    { key = "fortitude", label = "Max Health", ids = { 2458, 3825, 250334, 250335 } },
    { key = "healthRegen", label = "Health Regen", ids = { 3382, 3388, 3826, 20004 } },
    { key = "spirit", label = "Spirit", ids = { 250344, 250345, 250346, 250347 } },
    { key = "healing", label = "Healing Done", ids = { 250330, 250331, 250332, 250333 } },
    { key = "manaRegen", label = "Mana Regen", ids = { 250339, 250340, 250341, 20007 } },
}
ns.RestockElixirTypes = ELIXIR_TYPES
local POTION_TYPES = {
    { key = "frenzy", label = "Frenzy", ids = { 250938, 250939, 250940, 250941, 250942, 250943 } },
    { key = "spellblasting", label = "Spellblasting", ids = { 250932, 250933, 250934, 250935, 250936, 250937 } },
    { key = "menders", label = "Mender's", ids = { 250944, 250945, 250946, 250947, 250948, 250949 } },
}
ns.RestockPotionTypes = POTION_TYPES
elixirs.families, potions.families = ELIXIR_TYPES, POTION_TYPES
local groups = { elixirs, potions }
local reminders = {
    { key = "healthFood", minimum = "healthFoodMinimum", closest = "healthFoodClosestLevel", subclass = FOOD_DRINK,
      spell = EABR.FOREVER and 433 or 1290925, otherSpell = EABR.FOREVER and 1131 or nil,
      texture = 133995, label = function() return EllesmereUI.L("Health Food") end },
    { key = "manaDrink", minimum = "manaDrinkMinimum", closest = "manaDrinkClosestLevel", subclass = FOOD_DRINK,
      spell = EABR.FOREVER and 430 or 1290929, otherSpell = EABR.FOREVER and 1137 or 430,
      texture = 132794, label = function() return EllesmereUI.L("Mana Drink") end },
    { key = "healthPotion", minimum = "healthPotionMinimum", closest = "healthPotionClosestLevel", subclass = POTION,
      spell = EABR.FOREVER and 17534 or 1234768, otherSpell = 439,
      tiers = { 45, 35, 21, 12, 3 },
      texture = 134829, label = function() return EllesmereUI.L("Health Potions") end },
    { key = "manaPotion", minimum = "manaPotionMinimum", closest = "manaPotionClosestLevel", subclass = POTION,
      spell = EABR.FOREVER and 17531 or 1236648, otherSpell = 437,
      tiers = { 49, 41, 31, 22, 14, 5 },
      texture = 134850, label = function() return EllesmereUI.L("Mana Potions") end },
    wellFedFood,
    elixirs,
    potions,
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

function ns.HasRestockGroupSelection(selection, families)
    if not next(selection) then return false end
    for _, family in ipairs(families) do
        if selection[family.key] == true then return true end
    end
    return false
end

local function IsReminderEnabled(reminder, restock)
    if reminder.families then
        return EABR.FOREVER and ns.HasRestockGroupSelection(restock[reminder.key], reminder.families)
    end
    return (reminder ~= wellFedFood or EABR.FOREVER) and restock[reminder.key] == true
end

local function GetAnchorSize(w, h)
    local p = db.profile
    local count = 0
    for _, reminder in ipairs(reminders) do
        if IsReminderEnabled(reminder, p.restock) then count = count + 1 end
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
                return not (restock.healthFood or restock.manaDrink or restock.healthPotion or restock.manaPotion
                    or (EABR.FOREVER and restock.wellFedFood)
                    or IsReminderEnabled(elixirs, restock) or IsReminderEnabled(potions, restock)
                    or restock.bagSpace or restock.junk)
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

local function AddInventoryCount(reminder, id, count)
    local items = reminder.items
    items[id] = (items[id] or 0) + count
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
        AddInventoryCount(junk, id, info.stackCount)
    end
end

local function PrepareGroupCount(group)
    wipe(group.eligibleItems)
    wipe(group.trackedItems)
    for _, family in ipairs(group.families) do
        if family.enabled then
            local bestLevel = group.closestLevel and -1 or 0
            family.count, family.incomplete = 0, false
            for _, id in ipairs(family.ids) do
                group.trackedItems[id] = true
                if not group.closestLevel then
                    group.eligibleItems[id] = family
                else
                    local level = select(5, C_Item.GetItemInfo(id))
                    if level == nil then
                        if not failedItems[id] then family.incomplete = true end
                        RequestItemData(id)
                    elseif level <= playerLevel and level >= bestLevel then
                        if level > bestLevel then
                            for _, familyID in ipairs(family.ids) do group.eligibleItems[familyID] = nil end
                            bestLevel = level
                        end
                        group.eligibleItems[id] = family
                    end
                end
            end
            family.usable = bestLevel >= 0
        end
    end
end

local function UpdateGroupShortages(group, minimum)
    wipe(group.lines)
    group.lines[1] = group.label()
    for _, family in ipairs(group.families) do
        if family.enabled and family.usable and not family.incomplete and family.count < minimum then
            group.lines[#group.lines + 1] = EllesmereUI.Lf("%1$s (%2$d/%3$d)", EllesmereUI.L(family.label), family.count, minimum)
        end
    end
    group.count = #group.lines - 1
    group.tooltip = table.concat(group.lines, "\n")
    group.badgeDirty = true
    group.lastMinimum = minimum
end

local function GetMinimumTier(reminder)
    if not reminder.closestLevel or not EABR.FOREVER then return 0 end
    -- Keep the current tier as the minimum even when its bags are empty.
    if reminder.tiers then
        for _, level in ipairs(reminder.tiers) do
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
        if reminder.items then wipe(reminder.items) end
        if reminder.enabled and reminder ~= bagSpace and not reminder.items then reminder.items = {} end
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
    local nutritiousName
    if wellFedFood.enabled then
        local spellID = EABR.NutritiousFoodSpellID
        nutritiousName = I.SpellName(spellID)
        wellFedFood.count, wellFedFood.incomplete, wellFedFood.badgeDirty = 0, not nutritiousName, true
        if nutritiousName then
            spellRequests[spellID] = nil
        elseif spellRequests[spellID] == nil then
            spellRequests[spellID] = true
            C_Spell.RequestLoadSpellData(spellID)
        end
    end
    local countSupplies = countFood or countPotions or nutritiousName
    local countGroups = elixirs.enabled or potions.enabled
    if junk.enabled then
        junk.count, junk.incomplete, junk.badgeDirty = 0, false, true
    elseif not countSupplies and not countGroups then
        return
    end
    for _, group in ipairs(groups) do
        if group.enabled then PrepareGroupCount(group) end
    end

    local incompleteFood, incompletePotions = false, false
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and junk.enabled then CountJunkSlot(info, id) end
            if id and countGroups then
                for _, group in ipairs(groups) do
                    if group.enabled then
                        local family = group.eligibleItems[id]
                        if family then family.count = family.count + info.stackCount end
                        if group.trackedItems[id] then AddInventoryCount(group, id, info.stackCount) end
                    end
                end
            end
            if id and countSupplies then
                local class, subclass = select(6, C_Item.GetItemInfoInstant(id))
                local matchDescription = (countFood and subclass == FOOD_DRINK) or (countPotions and subclass == POTION)
                if class == Enum.ItemClass.Consumable and (matchDescription or nutritiousName) then
                    local unresolved = false
                    if not C_Item.IsItemDataCachedByID(id) then
                        if nutritiousName then wellFedFood.incomplete = true end
                        unresolved = matchDescription
                        RequestItemData(id)
                    else
                        local spellName, spellID = C_Item.GetItemSpell(id)
                        local isNutritious = nutritiousName and spellName == nutritiousName
                        if isNutritious then
                            wellFedFood.count = wellFedFood.count + info.stackCount
                            AddInventoryCount(wellFedFood, id, info.stackCount)
                        end
                        local description
                        if matchDescription and not isNutritious then description = GetSupplyDescription(spellID) end
                        local reminder = description and descriptionKinds[description]
                        if reminder and reminder.subclass == subclass then
                            AddInventoryCount(reminder, id, info.stackCount)
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
                        elseif matchDescription and not isNutritious and spellID and not description then
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

local function RestockTooltip(icon)
    local reminder = icon._restockReminder
    local heading = reminder.tooltip or reminder.text
    local items = reminder.items
    if not items then return heading end

    local lines = {}
    for id, count in pairs(items) do
        local name = C_Item.GetItemInfo(id)
        if not name then name = EllesmereUI.Lf("Item #%1$d", id) end
        lines[#lines + 1] = EllesmereUI.Lf("%1$s x%2$d", name, count)
    end
    table.sort(lines)
    if #lines == 0 then lines[1] = EllesmereUI.L("None") end
    return heading .. "\n\n" .. EllesmereUI.L("In Your Bags") .. "\n" .. table.concat(lines, "\n")
end

local function RenderReminder(reminder, p, w, h, x)
    local icon = reminder.icon
    if not icon then
        reminder.text = reminder.label()
        icon = I.BuildVisualIcon(nil, anchor)
        reminder.icon = icon
        icon:SetMouseClickEnabled(false)
        icon._restockReminder = reminder
        EABR.SetIconHighlight(icon, false)
        EABR.ApplyIconTooltipData(icon, { label = RestockTooltip })
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
    local wantSupplies = restock.healthFood or restock.manaDrink or restock.healthPotion or restock.manaPotion
        or (EABR.FOREVER and restock.wellFedFood)
    local wantGroups = IsReminderEnabled(elixirs, restock) or IsReminderEnabled(potions, restock)
    local wantItems = wantSupplies or restock.junk or wantGroups
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
        local enabled = IsReminderEnabled(reminder, restock)
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
    for _, group in ipairs(groups) do
        if group.enabled then
            if not group.eligibleItems then group.eligibleItems, group.trackedItems, group.lines = {}, {}, {} end
            for _, family in ipairs(group.families) do
                local enabled = restock[group.key][family.key] == true
                if enabled ~= family.enabled then
                    family.enabled = enabled
                    countDirty = true
                end
            end
        end
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
    local recounted = countDirty
    if recounted then
        countDirty = false
        if watchItems then CountBagItems() end
    end
    for _, group in ipairs(groups) do
        if group.enabled then
            local minimum = restock[group.groupMinimum]
            if recounted or group.lastMinimum ~= minimum then UpdateGroupShortages(group, minimum) end
        end
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
