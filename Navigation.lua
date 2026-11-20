local _, addon = ...

-- Gamepad navigation: preferred column, wrapping, the bag slot column and Left/Right at row edges
-- (wrapping within the row by default, or reading order when the setting is enabled).
--
-- SmartNavigation has no notion of a preferred column; Up/Down pick the nearest button by raycast.
-- Its static jump overrides (SmartNavigation_AddJumpNavigationOverride with a button, never a
-- function) are stored through SecureHelper without taint and stay usable in combat, but can only
-- be written outside combat restrictions. We keep overrides on the focused button only, pointing
-- at the right neighbour in a model of the layout built from the sections Bags.lua publishes.

local Navigation = {}

local inventory
local settings           -- saved settings; readingOrderNavigation picks the row-edge mode
local tracking = false
local navRows = {}       -- visual item rows, top to bottom, across all bag sections
local navPosition = {}   -- item button -> {row = index into navRows, column = 1-based}
local navGutter = {}     -- bag slot buttons in the left column, top to bottom
local gutterIndex = {}   -- bag slot button -> index into navGutter
local navSequence = {}   -- reading order: each bag slot button followed by its items row by row
local sequenceIndex = {} -- button -> index into navSequence
local overridden = {}    -- button -> {up, down, left, right} targets we have set
local preferredColumn, navCurrent, navUp, navDown
local itemMode = false   -- navCurrent follows item rows (true) or the bag slot column (false)

local function targetInRow(rowIndex, column)
    local row = navRows[rowIndex]
    return row and row[math.min(column, #row)]
end

local function setOverride(button, direction, target)
    if target then
        SmartNavigation_AddJumpNavigationOverride(button, direction, target)
    else
        SmartNavigation_ClearJumpNavigationOverridesInDirection(button, direction)
    end
end

-- Resolved at use time; the SmartNavigation globals load with the gamepad UI.
local directions = {up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT"}
local noTargets = {}

local function applyOverrides(button, targets)
    -- Only directions we set ourselves are ever cleared, so Blizzard's own overrides (such as
    -- the backpack bag button's Up to the portrait) are never touched as long as we pass nil.
    -- Compare against the value actually stored on the button, not only our cache, so a
    -- missing or replaced override is always rewritten.
    local state = overridden[button] or noTargets
    local any = false
    for key, direction in pairs(directions) do
        local new = targets[key]
        local stored = button["smartNavigationOverride-" .. key]
        if new then
            if stored ~= new then setOverride(button, SMART_NAV_INPUT_DIRECTION[direction], new) end
        elseif state[key] and stored ~= nil then
            setOverride(button, SMART_NAV_INPUT_DIRECTION[direction], nil)
        end
        any = any or new ~= nil
    end
    overridden[button] = any and targets or nil
end

local function clearOverrides(except)
    for button in pairs(overridden) do
        if button ~= except then applyOverrides(button, noTargets) end
    end
end

-- Reading order: bag slot button, its items row by row, next bag slot button ... wrapping at both
-- ends. Left/Right on bag slot buttons (and at row ends with the reading-order setting) step
-- through it, so a bag slot's Left reaches the previous bag's last item and a bag slot's Right
-- reaches its first item.
local function sequenceNeighbour(button, step)
    local index = sequenceIndex[button]
    if not index or #navSequence < 2 then return end
    return navSequence[(index - 1 + step) % #navSequence + 1]
end

local function update()
    if not SmartNavigation or not SmartNavigation_AddJumpNavigationOverride or addon.IsLayoutRestricted() then return end
    local inventoryActive = SmartNavigation:GetActiveFrame() == inventory
    local button = inventoryActive and SmartNavigation:GetCurrentButton()
    local gutter = button and gutterIndex[button]
    if gutter then
        -- An empty or collapsed bag's button reached by Up/Down from the item rows keeps
        -- following the rows; otherwise the bag slot column moves between bag slot buttons.
        local arrivedFromRows = button == navCurrent or button == navUp or button == navDown
        gutter = not (navPosition[button] and itemMode and arrivedFromRows) and gutter
    end
    if gutter then
        -- The first (backpack) button gets no Up target, so Blizzard's jump to the portrait stays.
        itemMode = false
        navCurrent = button
        navUp = navGutter[gutter - 1]
        navDown = navGutter[gutter + 1] or (gutter > 1 and navGutter[1] or nil)
        clearOverrides(button)
        applyOverrides(button, {
            up = navUp, down = navDown,
            left = sequenceNeighbour(button, -1), right = sequenceNeighbour(button, 1),
        })
        return
    end

    local position = button and navPosition[button]
    if not position then
        if inventoryActive and button then navCurrent, itemMode = nil, false end -- E.g. the portrait.
        clearOverrides()
        return
    end

    -- Arriving through our own Up/Down target (or reselecting the same button) keeps the intent;
    -- any other arrival, such as Left/Right, a restore or a click, sets it from the new cell.
    -- A bag-button row has no column of its own and keeps the current preference.
    if position.column and (button ~= navCurrent and button ~= navUp and button ~= navDown) then
        preferredColumn = position.column
    end
    preferredColumn = preferredColumn or position.column or 1
    navCurrent = button
    itemMode = true
    -- Up from the first row wraps to the last row (mirroring Down), so arriving at the bottom
    -- stays an item move; SmartNavigation's own wrap lands there as an untracked jump.
    navUp = targetInRow(position.row - 1, preferredColumn)
    if not navUp and position.row < #navRows then navUp = targetInRow(#navRows, preferredColumn) end
    -- Down from the last row wraps to the first row; the native wrap search can land on
    -- frames outside the grid.
    navDown = targetInRow(position.row + 1, preferredColumn)
    if not navDown and position.row > 1 then navDown = targetInRow(1, preferredColumn) end

    -- Left/Right at the ends of a row wrap within the row (default) or follow reading order
    -- (setting); mid-row moves stay native. Either way a bag's first item keeps Left to its bag
    -- slot button (its reading-order neighbour), so the bag slot column stays reachable.
    local left, right
    if position.column then
        local row = navRows[position.row]
        local readingOrder = settings and settings.readingOrderNavigation
        if position.column == 1 then
            local previous = sequenceNeighbour(button, -1)
            left = (readingOrder or (previous and gutterIndex[previous])) and previous or row[#row]
        end
        if position.column == #row then
            right = readingOrder and sequenceNeighbour(button, 1) or row[1]
        end
    else
        left, right = sequenceNeighbour(button, -1), sequenceNeighbour(button, 1)
    end
    clearOverrides(button)
    applyOverrides(button, {up = navUp, down = navDown, left = left, right = right})
end

-- Rebuilds the layout model: the same rows and columns Bags.lua used to place the item buttons.
local function buildModel(sections, columns)
    wipe(navRows)
    wipe(navPosition)
    wipe(navGutter)
    wipe(gutterIndex)
    wipe(navSequence)
    wipe(sequenceIndex)
    local function addToSequence(button)
        navSequence[#navSequence + 1] = button
        sequenceIndex[button] = #navSequence
    end

    for _, section in ipairs(sections) do
        if section.button then
            navGutter[#navGutter + 1] = section.button
            gutterIndex[section.button] = #navGutter
            addToSequence(section.button)
        end

        local rowOffset = #navRows
        if #section.slots == 0 and section.button and section.id ~= BACKPACK_CONTAINER then
            -- An empty or collapsed bag is a one-button row, so Up/Down stop on its bag button.
            -- The backpack button is excluded: Blizzard owns its Up override to the portrait.
            navRows[rowOffset + 1] = {section.button}
            navPosition[section.button] = {row = rowOffset + 1}
        end
        for index, item in ipairs(section.slots) do
            local column = (index - 1) % columns
            local rowIndex = rowOffset + math.floor((index - 1) / columns) + 1
            navRows[rowIndex] = navRows[rowIndex] or {}
            navRows[rowIndex][column + 1] = item
            addToSequence(item)
            navPosition[item] = {row = rowIndex, column = column + 1}
        end
    end
end

-- Listener methods (see addon.RegisterBagsListener in Bags.lua)

function Navigation:Init(frame, db)
    inventory = frame
    settings = db
    -- Switching the row-edge mode applies to the focused button right away (out of combat;
    -- otherwise when combat ends).
    if Settings and Settings.SetOnValueChangedCallback and addon.READING_ORDER_SETTING then
        Settings.SetOnValueChangedCallback(addon.READING_ORDER_SETTING, function() update() end)
    end
end

function Navigation:Layout(sections, columns)
    buildModel(sections, columns)
    if not tracking and SmartNavigation and SmartNavigation.RegisterCallback then
        tracking = true
        SmartNavigation:RegisterCallback("SelectedButtonUpdated", update, self)
    end
end

-- The layout may have moved the focused button.
function Navigation:NavigationRefreshed()
    update()
end

function Navigation:Closed()
    navCurrent = nil
    if SmartNavigation_AddJumpNavigationOverride and not addon.IsLayoutRestricted() then clearOverrides() end
end

-- Overrides could not follow the cursor during combat.
function Navigation:CombatEnded()
    update()
end

addon.RegisterBagsListener(Navigation)
