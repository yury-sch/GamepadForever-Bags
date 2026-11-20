local _, addon = ...
local SETTING_PREFIX = "GAMEPAD_FOREVER_BAGS_"
addon.READING_ORDER_SETTING = SETTING_PREFIX .. "READING_ORDER_NAVIGATION"

function addon.RegisterSettings(localization)
    if type(GamepadForeverBagsSettings) ~= "table" then
        GamepadForeverBagsSettings = {}
    end
    local db = GamepadForeverBagsSettings

    local general = localization.General
    local category = Settings.RegisterVerticalLayoutCategory("Gamepad Forever: Bags")
    local setting = Settings.RegisterAddOnSetting(category, SETTING_PREFIX .. "AUTO_SORT_ON_OPEN",
        "autoSortOnOpen", db, Settings.VarType.Boolean, general.autoSortOnOpen, false)
    Settings.CreateCheckbox(category, setting, general.autoSortOnOpenTooltip)
    local readingOrder = Settings.RegisterAddOnSetting(category, addon.READING_ORDER_SETTING,
        "readingOrderNavigation", db, Settings.VarType.Boolean, general.readingOrderNavigation, false)
    Settings.CreateCheckbox(category, readingOrder, general.readingOrderNavigationTooltip)
    Settings.RegisterAddOnCategory(category)
    return db
end
