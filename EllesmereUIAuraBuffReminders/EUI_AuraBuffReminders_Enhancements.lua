if EUI_CLIENT_BLOCKED then return end
local _, ns = ...
local I = ns._abrInternals
if not I or I.broken or not I.EABR.FOREVER then return end
local EABR = I.EABR

-- Wago DB2, Forever 1.60.1.70790. ItemXItemEffect -> on-use ItemEffect
-- -> SpellEffect 54 (temporary enchant) -> SpellEquippedItems, weapon class.
-- Item ID -> weapon subclass mask, inventory type mask. Zero is unrestricted.
local function BuildRequirements()
    return {
        [2862] = { 33219, 0 }, [2863] = { 33219, 0 }, [2871] = { 33219, 0 },
        [2896] = { 173555, 0 }, [2927] = { 173555, 0 },
        [3239] = { 9264, 0 }, [3240] = { 9264, 0 }, [3241] = { 9264, 0 },
        [3824] = { 173555, 0 }, [3829] = { 173555, 0 }, [6213] = { 33219, 0 },
        [7964] = { 33219, 0 }, [7965] = { 9264, 0 }, [12404] = { 33219, 0 },
        [12643] = { 9264, 0 }, [18262] = { 42483, 0 },
        [20744] = { 0, 6430720 }, [20745] = { 0, 6430720 }, [20746] = { 0, 6430720 },
        [20747] = { 0, 6430720 }, [20748] = { 0, 6430720 }, [20749] = { 0, 6430720 },
        [20750] = { 0, 6430720 }, [23122] = { 1097203, 0 }, [23123] = { 0, 6430720 },
        [202316] = { 173555, 0 }, [211845] = { 42483, 0 }, [211848] = { 42483, 0 },
        [215128] = { 42483, 0 }, [217345] = { 173555, 0 }, [217346] = { 173555, 0 },
        [217347] = { 173555, 0 }, [221362] = { 42483, 0 }, [226374] = { 173555, 0 },
        [233996] = { 0, 6447104 },
        [234444] = { 173555, 0 }, [237810] = { 5474, 0 }, [238234] = { 0, 6447104 },
        [238241] = { 0, 6447104 }, [287978] = { 33219, 0 }, [287979] = { 0, 6430720 },
        [287980] = { 42483, 0 },
    }
end

local requirements, watch, watching, bagItems, bySlot

function EABR.SyncForeverEnhancementWatch(want)
    if want == watching then return end
    watching = want
    if not want then
        if watch then watch:UnregisterAllEvents() end
        bagItems, bySlot = nil, nil
        return
    end
    if not watch then
        requirements = BuildRequirements()
        watch = CreateFrame("Frame")
        watch:SetScript("OnEvent", function(_, event)
            if event == "BAG_UPDATE_DELAYED" then bagItems = nil end
            if _G._EABR_RequestRefresh then _G._EABR_RequestRefresh() end
        end)
    end
    watch:RegisterEvent("BAG_UPDATE_DELAYED")
    watch:RegisterEvent("WEAPON_ENCHANT_CHANGED")
    watch:RegisterEvent("WEAPON_SLOT_CHANGED")
end

function EABR.GetForeverEnhancements(slot)
    if not watching then return end
    local weaponID = GetInventoryItemID("player", slot)
    if not weaponID then return end
    if not bagItems then
        bagItems, bySlot = {}, {}
        for bag = 0, NUM_BAG_SLOTS do
            for index = 1, C_Container.GetContainerNumSlots(bag) do
                local info = C_Container.GetContainerItemInfo(bag, index)
                local id = info and info.itemID
                if id and requirements[id] then
                    bagItems[id] = (bagItems[id] or 0) + info.stackCount
                end
            end
        end
    end
    local cached = bySlot[slot]
    local hasBagItems = next(bagItems) ~= nil
    if cached and cached.weaponID == weaponID then return cached.items, hasBagItems end
    local _, _, _, _, _, classID, subclass = C_Item.GetItemInfoInstant(weaponID)
    if classID ~= Enum.ItemClass.Weapon or subclass == Enum.ItemWeaponSubclass.Fishingpole then return end
    local invType = C_Item.GetItemInventoryTypeByID(weaponID)
    if not invType then return end
    local items = {}
    for id, count in pairs(bagItems) do
        local masks = requirements[id]
        if (masks[1] == 0 or bit.band(masks[1], 2 ^ subclass) ~= 0)
            and (masks[2] == 0 or bit.band(masks[2], 2 ^ invType) ~= 0) then
            items[id] = count
        end
    end
    bySlot[slot] = { weaponID = weaponID, items = items }
    return items, hasBagItems
end

function EABR.ForeverWeaponNeedsEnhancement(slot)
    if not (C_Item.GetWeaponEnchantInfo and Enum.WeaponSlot and Enum.ItemEnchantType) then return false end
    local weaponSlot = slot == INVSLOT_MAINHAND and Enum.WeaponSlot.MainHand or Enum.WeaponSlot.OffHand
    local enchants = C_Item.GetWeaponEnchantInfo(weaponSlot)
    if not enchants then return false end
    for _, enchant in pairs(enchants) do
        if enchant.hasEnchant and enchant.enchantType == Enum.ItemEnchantType.Temporary then return false end
    end
    return true
end
