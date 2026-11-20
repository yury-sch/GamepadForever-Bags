local _, addon = ...

-- Selection memory: reopen the combined inventory on the last focused item slot or bag slot.
--
-- SmartNavigation drops its panel info, including lastButton, when the inventory hides, and the
-- stock SmartNavPanelInfoAdded callback then targets the backpack bag button on every open.
-- We remember the logical bag/slot ourselves (per character, so it survives /reload and relogs)
-- and hand it back through SetTargetButtonForFrame, the wrapped entry point Blizzard intends for
-- addons (it is rejected during combat restrictions, so restoring waits until they end).

local SelectionMemory = {}

local inventory
local lastSelection = {}   -- {bagID, slotID}; slotID is nil for a bag slot button
local restorePending = false
local tracking = false
local bagIDByButton = {}   -- bag slot button -> bag ID, from the latest layout

local function isWholeNumber(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

-- Saved data may be stale or hand-edited: accept only a whole bag ID in the range WoW uses for
-- the inventory and either a sane slot number (an item slot) or no slot (that bag's bag slot
-- button); anything else starts fresh.
local function isValidSelection(selection)
    local lowestBag = math.min(BACKPACK_CONTAINER, KEYRING_CONTAINER or BACKPACK_CONTAINER)
    local highestBag = NUM_TOTAL_BAG_FRAMES or NUM_BAG_FRAMES or 4
    return type(selection) == "table" and isWholeNumber(selection.bagID, lowestBag, highestBag)
        and (selection.slotID == nil or isWholeNumber(selection.slotID, 1, 1000))
end

local function isInventoryItem(button)
    for _, item in inventory:EnumerateValidItems() do
        if item == button then return true end
    end
    return false
end

local scheduleRestore -- defined below tryRestoreSelection

local function onSelectedButtonUpdated()
    if SmartNavigation:GetActiveFrame() ~= inventory then return end
    local button = SmartNavigation:GetCurrentButton()
    if not button then return end
    if isInventoryItem(button) then
        local candidate = {bagID = button:GetBagID(), slotID = button:GetID()}
        if isValidSelection(candidate) then
            lastSelection.bagID, lastSelection.slotID = candidate.bagID, candidate.slotID
        end
        restorePending = false
    elseif restorePending then
        -- Blizzard's initial focus on the backpack bag slot is not saved while a restore is
        -- pending. The inventory may only now have become the active frame (after the bank
        -- or another panel had focus), so try the restore again.
        scheduleRestore()
        return
    elseif bagIDByButton[button] then
        -- A bag slot button is saved as its bag with no slot.
        lastSelection.bagID, lastSelection.slotID = bagIDByButton[button], nil
    else
        -- The player chose the portrait or another control; reopen at the native default.
        lastSelection.bagID, lastSelection.slotID = nil, nil
    end
end

local function findItemButton(bagID, slotID)
    -- Exact slot, or the nearest lower slot of the same bag if that bag shrank.
    local bagButton = GamepadBagBar and GamepadBagBar:GetBagButton(bagID)
    if bagButton and bagButton.isCollapsed then return end
    local fallback, fallbackID
    for _, item in inventory:EnumerateValidItems() do
        if item:GetBagID() == bagID and SmartNavigation:IsButtonValid(item) then
            local id = item:GetID()
            if id == slotID then return item end
            if id < slotID and (not fallbackID or id > fallbackID) then
                fallback, fallbackID = item, id
            end
        end
    end
    return fallback
end

local function tryRestoreSelection()
    if not restorePending or addon.IsLayoutRestricted() then return end
    if not SmartNavigation:GetPanelInfo(inventory, true) then return end

    -- When another panel owns focus (the bank, a merchant ...), the inventory only gets a target
    -- button, and SmartNavigation prefers the panel's own last button (the backpack bag slot)
    -- once the player moves into the inventory. So the restore stays pending until the inventory
    -- is the active frame; onSelectedButtonUpdated then runs it again.
    local active = SmartNavigation:GetActiveFrame() == inventory
    restorePending = not active

    local current = SmartNavigation:GetCurrentButton()
    local nativeDefault = GamepadBagBar and GamepadBagBar:GetBagButton(BACKPACK_CONTAINER)
    if active and current and current ~= nativeDefault then
        return -- The player already moved; never pull the cursor away.
    end

    -- A slot that no longer exists simply finds nothing, leaving WoW's default focus.
    if not isValidSelection(lastSelection) then return end
    local button
    if lastSelection.slotID then
        button = findItemButton(lastSelection.bagID, lastSelection.slotID)
    else
        -- A bag slot: its button, if that bag is still shown in the bag slot column.
        for bagButton, bagID in pairs(bagIDByButton) do
            if bagID == lastSelection.bagID and SmartNavigation:IsButtonValid(bagButton) then
                button = bagButton
            end
        end
    end
    if button and button ~= current then
        SmartNavigation:SetTargetButtonForFrame(inventory, button)
    end
end

-- Restoring is a convenience: any unexpected failure forgets the saved slot and leaves WoW's
-- default focus, instead of raising a Lua error.
local function restoreSafely()
    if not pcall(tryRestoreSelection) then
        restorePending = false
        lastSelection.bagID, lastSelection.slotID = nil, nil
    end
end

-- Runs on the next frame, outside SmartNavigation's own selection callback.
local restoreScheduled = false
function scheduleRestore()
    if restoreScheduled then return end
    restoreScheduled = true
    C_Timer.After(0, function()
        restoreScheduled = false
        restoreSafely()
    end)
end

-- Listener methods (see addon.RegisterBagsListener in Bags.lua)

function SelectionMemory:Init(frame)
    inventory = frame
    if type(GamepadForeverBagsCharacter) ~= "table" then
        GamepadForeverBagsCharacter = {}
    end
    if not isValidSelection(GamepadForeverBagsCharacter.lastSelection) then
        GamepadForeverBagsCharacter.lastSelection = {}
    end
    lastSelection = GamepadForeverBagsCharacter.lastSelection
    -- A saved slot is restored on the first open after loading, like after a normal close.
    restorePending = lastSelection.bagID ~= nil
end

function SelectionMemory:Layout(sections)
    wipe(bagIDByButton)
    for _, section in ipairs(sections) do
        if section.button then bagIDByButton[section.button] = section.id end
    end
    if not tracking and SmartNavigation and SmartNavigation.RegisterCallback then
        tracking = true
        SmartNavigation:RegisterCallback("SelectedButtonUpdated", onSelectedButtonUpdated, self)
    end
end

function SelectionMemory:NavigationRefreshed()
    restoreSafely()
end

function SelectionMemory:Closed()
    restorePending = lastSelection.bagID ~= nil
end

addon.RegisterBagsListener(SelectionMemory)
