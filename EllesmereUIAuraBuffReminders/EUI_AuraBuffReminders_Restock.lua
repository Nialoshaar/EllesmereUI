if EUI_CLIENT_BLOCKED then return end

local _, ns = ...
local I = ns._abrInternals
if not I or I.broken then return end
I.broken = true

local EABR = I.EABR
local KEY = "EABR_Restock"
local reminders = {
    { key = "healthFood", minimum = "healthFoodMinimum", closest = "healthFoodClosestLevel",
      spell = EABR.FOREVER and 433 or 1290925, otherSpell = EABR.FOREVER and 1131 or nil,
      texture = 133995, label = function() return EllesmereUI.L("Health Food") end },
    { key = "manaDrink", minimum = "manaDrinkMinimum", closest = "manaDrinkClosestLevel",
      spell = EABR.FOREVER and 430 or 1290929, otherSpell = EABR.FOREVER and 1137 or 430,
      texture = 132794, label = function() return EllesmereUI.L("Mana Drink") end },
}
local db, anchor, appliedPos, panelOpen
local countDirty, waitingForSpellText, watchLevel, playerLevel
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
    if p.restock.healthFood and p.restock.manaDrink then
        w = w * 2 + (p.display.iconSpacing or 8)
    end
    return w, h
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
                return not (restock.healthFood or restock.manaDrink)
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

local function CountSupplies()
    waitingForSpellText = false
    wipe(descriptionKinds)
    for _, reminder in ipairs(reminders) do
        if reminder.enabled then
            -- Reference spells supply the localized wording for the whole effect.
            local plain = GetFoodDescription(reminder.spell)
            local second = GetFoodDescription(reminder.otherSpell)
            if plain then descriptionKinds[plain] = reminder end
            if second then descriptionKinds[second] = reminder end
            reminder.count, reminder.incomplete, reminder.bestLevel = 0, not (plain or second), 0
            reminder.badgeDirty = true
            if reminder.closestLevel and EABR.FOREVER and playerLevel >= 5 then
                -- Keep the current tier as the minimum even when its bags are empty.
                reminder.bestLevel = math.min(55, 5 + 10 * math.floor((playerLevel - 5) / 10))
            end
        end
    end
    if not next(descriptionKinds) then return end

    local incomplete = false
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
                        local reminder = description and descriptionKinds[description]
                        if reminder then
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
                            incomplete = true
                        end
                    end
                end
            end
        end
    end
    if incomplete then
        for _, reminder in ipairs(reminders) do
            if reminder.enabled then reminder.incomplete = true end
        end
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
        local texture = I.Tex(reminder.spell) or reminder.texture
        if texture ~= reminder.iconTexture then
            reminder.iconTexture = texture
            icon._icon:SetTexture(texture)
        end
        local count, incomplete = reminder.count, reminder.incomplete
        local badge
        if incomplete and p.showCount ~= false then
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
    if not (restock.healthFood or restock.manaDrink) then
        if I.restockWatching then
            anchor:UnregisterAllEvents()
            HideIcons()
            I.restockWatching = false
            countDirty, waitingForSpellText = true, nil
            watchLevel, playerLevel = nil, nil
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
        countDirty = true
    end
    if anchor:GetWidth() ~= anchorWidth or anchor:GetHeight() ~= h then
        anchor:SetSize(anchorWidth, h)
        styleDirty = true
    end
    local wantLevel = false
    for _, reminder in ipairs(reminders) do
        local enabled = restock[reminder.key] == true
        local closest = enabled and restock[reminder.closest] ~= false
        if enabled ~= reminder.enabled or closest ~= reminder.closestLevel then
            reminder.enabled, reminder.closestLevel = enabled, closest
            countDirty = true
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
        CountSupplies()
        countDirty = false
    end
    local visible = 0
    for _, reminder in ipairs(reminders) do
        reminder.visible = reminder.enabled and reminder.count < restock[reminder.minimum]
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
