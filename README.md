# Gamepad Forever: Bags

Gamepad Forever: Bags stacks each bag in its own section inside the combined inventory in WoW Forever. The sections use WoW's item slots and bag buttons. In gamepad mode, the combined bag icon opens the menu with WoW's sort command.

## Installation

The addon works in combined bags mode. After installing, restart WoW and enable **Gamepad Forever: Bags** under **Gamepad Forever** in the AddOns list.

## Settings

Open **Settings → AddOns → Gamepad Forever: Bags** to change these options. Both are off by default.

- **Sort bags on open:** WoW sorts the combined bags each time you open them out of combat.
- **Continue to next/previous row at row edges:** Left and Right at the ends of a row continue through the items in reading order instead of wrapping within the row. See *Row edges* below.

## Gamepad navigation

In gamepad mode, the addon extends WoW's controller navigation inside the combined bags:

- **Cursor memory:** the inventory reopens on the item slot or bag slot you last focused. The position is saved per character, so it survives `/reload` and logging out. This also works when the bank or another window opens the bags: the saved slot is restored when you move into the inventory. If that bag shrank, focus goes to the nearest slot in it; if the bag is gone or collapsed, WoW's default focus is used.
- **Preferred column:** Up and Down keep the column you were heading for across bags of different sizes. From cell 9, Down into a 6-slot bag lands on cell 6, and Down again returns to cell 9. Moving Left or Right sets a new column.
- **Wrapping:** Down from the bottom row returns to the top row in your column, and Up from the top row goes to the bottom row. Empty and collapsed bag slots are part of the rows, so Up and Down stop on them.
- **Bag slot column:** in the bag slot column, Up and Down move between bag slots. A bag slot reached from the items keeps following the item rows; one reached along the column follows the column.
- **Row edges:** by default, Right from the last item in a row returns to the first item in the same row, and Left from the first item goes to the last one. The first item of each bag is the exception: Left from it goes to the bag's bag slot, so the bag slots stay reachable from the items. With **Continue to next/previous row at row edges** enabled, Left and Right at the ends of a row instead move through the bags in reading order: each bag slot, then its items row by row, then the next bag slot. Changing the option applies right away, or when combat ends.
- **Bag slot Left/Right:** on a bag slot, Right goes to that bag's first item and Left to the previous bag's last item, in both modes.

Everything works in combat without blocked-action messages, and no key bindings are added. The navigation uses SmartNavigation's own jump overrides (`SmartNavigation_AddJumpNavigationOverride`, with static buttons only) on the focused button, and the cursor is restored through `SmartNavigation:SetTargetButtonForFrame`. Both are only changed outside combat restrictions.

## Addon structure

- `Addon.lua` selects the interface language and initializes settings before registering the bag logic.
- `Settings.lua` registers the options in WoW and returns the saved settings table.
- `Bags.lua` lays out the bag sections, updates gamepad navigation, and handles automatic sorting. `addon.RegisterBagsListener` lets the modules below follow each layout, navigation refresh, close and the end of combat.
- `SelectionMemory.lua` remembers the last focused item slot or bag slot per character (`GamepadForeverBagsCharacter`) and restores it when the inventory opens.
- `Navigation.lua` adds the preferred column, wrapping, the bag slot column and Left/Right at row edges.
- `Localization/` contains English, French, German, Portuguese, Russian, and Spanish translations. WoW's interface language selects the translation, with English as the fallback.
