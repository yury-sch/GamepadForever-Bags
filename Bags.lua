local _, addon = ...

-- Layout and SmartNavigation changes must wait while combat restrictions are active.
function addon.IsLayoutRestricted()
    return InCombatLockdown()
        or (C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Combat))
end

-- Extension point for optional modules (SelectionMemory.lua, Navigation.lua). A listener is a table
-- with any of these methods, called with the listener as self:
--   Init(inventory, db)        once, when the bag logic is registered; db is the saved settings
--   Layout(sections, columns)  after each gamepad layout; sections are in display order, each with
--                              id, button (bag slot button or nil) and slots (shown item buttons)
--   NavigationRefreshed()      after SmartNavigation's button groups were rebuilt (out of combat)
--   Closed()                   when the combined inventory hides
--   CombatEnded()              when combat ends while the inventory is shown
-- A listener error is reported through WoW's error handler and never interrupts the layout.
local listeners = {}

function addon.RegisterBagsListener(listener)
    listeners[#listeners + 1] = listener
end

local function notify(event, ...)
    for _, listener in ipairs(listeners) do
        local handler = listener[event]
        if handler then
            local ok, err = pcall(handler, listener, ...)
            if not ok then geterrorhandler()(err) end
        end
    end
end

function addon.RegisterBags(inventory, db)
    -- State
    local slotGap = 5
    local sectionGap = 8
    local labelHeight = 16
    local topPadding = 63
    local nativeMinScale = 0.75
    local labels = {}
    local pendingLayout, navigationQueued
    local wasShown = inventory:IsShown()
    local visibilityCheckQueued = false
    local layoutRestricted = addon.IsLayoutRestricted

    -- Native gamepad navigation
    local function requestNavigationRefresh()
        if navigationQueued or not SmartNavigation then return end
        navigationQueued = true
        -- The stock bag OnShow also schedules navigation setup for the next frame.
        RunNextFrame(function()
            C_Timer.After(0, function()
                navigationQueued = false
                if not inventory:IsVisible() or not InputUtil.IsGamepadUIEnabled() then return end
                if layoutRestricted() then
                    pendingLayout = true
                    return
                end

                local info = SmartNavigation:GetPanelInfo(inventory, true)
                if not info then return end
                if info.useGrid then
                    -- The stock logical grid compacts each column independently.
                    SmartNavigation:SetUseGridNavigation(inventory, false)
                end
                SmartNavigation:RefreshButtonGroups(inventory)
                notify("NavigationRefreshed")
            end)
        end)
    end

    -- Bag sections and layout
    local function getSections(gamepad)
        local sections, byID = {}, {}
        local function getSection(id)
            if not byID[id] then
                byID[id] = {id = id, slots = {}}
                sections[#sections + 1] = byID[id]
            end
            return byID[id]
        end

        if gamepad and GamepadBagBar then
            for id = STARTING_BAG_INDEX, ENDING_BAG_INDEX do
                local button = GamepadBagBar:GetBagButton(id)
                if button and button:IsShown() then getSection(id).button = button end
            end
        end

        for _, item in inventory:EnumerateValidItems() do
            local section = getSection(item:GetBagID())
            if not section.button or not section.button.isCollapsed then
                section.slots[#section.slots + 1] = item
            end
        end

        table.sort(sections, function(a, b)
            -- The optional keyring follows the equipped bags.
            if a.id == KEYRING_CONTAINER then return false end
            if b.id == KEYRING_CONTAINER then return true end
            return a.id < b.id
        end)
        for _, section in ipairs(sections) do
            table.sort(section.slots, function(a, b) return a:GetID() < b:GetID() end)
        end
        return sections
    end

    local function getSectionLabel(id)
        local text
        if id == BACKPACK_CONTAINER then
            text = BAG_NAME_BACKPACK
        elseif id == NUM_TOTAL_BAG_FRAMES and id > NUM_BAG_FRAMES then
            text = BAG_NAME_BAG_REAGENT
        elseif id == KEYRING_CONTAINER then
            text = KEY_RING or C_Container.GetBagName(id)
        end
        if not text or text == "" then return end

        local label = labels[id]
        if not label then
            label = inventory:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labels[id] = label
        end
        label:SetText(text)
        return label
    end

    local function sectionHeight(section, columns, slotHeight)
        local bagHeight = section.button and section.button:GetHeight() or 0
        if #section.slots == 0 then return bagHeight end
        local rows = math.ceil(#section.slots / columns)
        local slotsHeight = rows * (slotHeight + slotGap) - slotGap
        return (section.label and labelHeight or 0) + math.max(bagHeight, slotsHeight)
    end

    local function measureInventory(sections, slotWidth, slotHeight, gutter)
        local columns = inventory:GetColumns()
        local paddingWidth = inventory:GetPaddingWidth() + gutter
        local paddingHeight = inventory:GetPaddingHeight() + inventory:CalculateExtraHeight()
        local pitch = slotWidth + slotGap
        local largestBag = 0
        for _, section in ipairs(sections) do
            largestBag = math.max(largestBag, #section.slots)
        end

        local heightLimit = (GetScreenHeight() - CONTAINER_OFFSET_Y) / nativeMinScale
        local widthLimit = (GetScreenWidth() - 120) / nativeMinScale
        local maxColumns = math.max(columns, math.min(largestBag, math.floor((widthLimit - paddingWidth + slotGap) / pitch)))

        local height
        while true do
            height = paddingHeight + sectionGap * math.max(#sections - 1, 0)
            for _, section in ipairs(sections) do height = height + sectionHeight(section, columns, slotHeight) end
            if height <= heightLimit or columns >= maxColumns then break end
            columns = columns + 1
        end
        return columns, columns * pitch - slotGap + paddingWidth, height
    end

    local function arrangeInventory()
        if not inventory:IsShown() then return end
        for _, label in pairs(labels) do label:Hide() end
        if layoutRestricted() then
            pendingLayout = true
            return
        end
        pendingLayout = false

        local gamepad = InputUtil.IsGamepadUIEnabled()
        local sections = getSections(gamepad)
        local template = C_XMLUtil.GetTemplateInfo(inventory.itemButtonPool:GetTemplate())
        local slotWidth, slotHeight = template.width, template.height
        local gutter = 0
        for _, section in ipairs(sections) do
            section.label = getSectionLabel(section.id)
            if section.button then gutter = math.max(gutter, section.button:GetWidth() + slotGap) end
        end
        local columns, width, height = measureInventory(sections, slotWidth, slotHeight, gutter)
        if inventory:GetWidth() ~= width or inventory:GetHeight() ~= height then
            inventory:SetSize(width, height)
            NineSliceUtil.UpdateCornerCropping(inventory, height)
        end

        local left = inventory:GetPaddingWidth() / 2
        local gridLeft = left + gutter
        local top = topPadding
        for _, section in ipairs(sections) do
            local label = section.label
            local hasSlots = #section.slots > 0
            local firstRow = hasSlots and label and top + labelHeight or top

            if section.button then
                section.button:ClearAllPoints()
                section.button:SetPoint("TOPLEFT", inventory, "TOPLEFT", left, -firstRow)
            end

            if label then
                label:ClearAllPoints()
                if hasSlots then
                    label:SetPoint("TOPLEFT", inventory, "TOPLEFT", gridLeft, -top)
                else
                    label:SetPoint("LEFT", section.button, "RIGHT", slotGap, 0)
                end
                label:Show()
            end

            for index, item in ipairs(section.slots) do
                local column = (index - 1) % columns
                local row = math.floor((index - 1) / columns)
                item:ClearAllPoints()
                item:SetPoint("TOPLEFT", inventory, "TOPLEFT",
                    gridLeft + column * (slotWidth + slotGap), -firstRow - row * (slotHeight + slotGap))
            end
            top = top + sectionHeight(section, columns, slotHeight) + sectionGap
        end

        inventory:LayoutAddSlots()
        if gamepad then
            notify("Layout", sections, columns)
            requestNavigationRefresh()
        end
    end

    -- Automatic sorting
    local function checkBagOpening()
        visibilityCheckQueued = false
        local shown = inventory:IsShown()
        local opened = shown and not wasShown
        wasShown = shown
        if opened and db.autoSortOnOpen == true and inventory:IsVisible() and not layoutRestricted() then
            C_Container.SortBags()
        end
    end

    local function onBagVisibilityChanged(_, bag)
        if bag ~= inventory then return end
        if not inventory:IsShown() then notify("Closed") end
        if visibilityCheckQueued then return end
        visibilityCheckQueued = true
        -- WoW can close and reopen the frame in one update when rebuilding the bags.
        C_Timer.After(0, checkBagOpening)
    end

    local function onInventoryEvent(_, event)
        if pendingLayout or event == "DISPLAY_SIZE_CHANGED" then
            arrangeInventory()
        elseif event == "PLAYER_REGEN_ENABLED" and inventory:IsVisible() then
            notify("CombatEnded")
        end
    end

    -- Event and hook registration
    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:RegisterEvent("DISPLAY_SIZE_CHANGED")
    events:SetScript("OnEvent", onInventoryEvent)
    hooksecurefunc(inventory, "UpdateItemLayout", arrangeInventory)
    EventRegistry:RegisterCallback("ContainerFrame.OpenBag", onBagVisibilityChanged, events)
    EventRegistry:RegisterCallback("ContainerFrame.CloseBag", onBagVisibilityChanged, events)

    notify("Init", inventory, db)
    arrangeInventory()
end
