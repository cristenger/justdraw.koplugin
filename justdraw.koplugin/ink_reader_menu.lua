--[[--
The reader's JustDraw menu: what a reader does first, then where their ink is,
then everything that is a setting.

It used to be one flat list of fifteen entries -- two pages of menu on a small
screen -- with the advanced settings (input mode, refresh in milliseconds, the
stylus diagnostics) at the same level as Start drawing, and rows that could
never apply on this book greyed out rather than gone (audit UX-3). A greyed row
is a promise about a feature the reader cannot have here; an absent one is
not. So the shape is decided once, here, from what this reader can actually
have: a sheet row only in a reflowable book, page notes only in a fixed layout
on the runtime that has them, the frozen legacy ink only when there is some,
and the settings one level down.

The rows themselves are the plugin's -- `styleItem`, `penItem`, `sideItem`,
`inputModeItem`, `canvasMenu`, `documentInkMenu`, `legacyInkItems` -- because
their state and callbacks are the plugin's. This module owns only the
arrangement, so moving a row is an edit here and nowhere else, and `main.lua`
stops being the place where the menu's shape is read off a 200-line table.
]]

local Capture = require("ink_capture")
local Style = require("ink_style")
local _ = require("ink_i18n")

local ReaderMenu = {}

--- Pen widths, the same three the toolbar's pen palette offers.
ReaderMenu.PEN_THIN, ReaderMenu.PEN_MEDIUM, ReaderMenu.PEN_THICK = 2, 4, 7

local function settingsItems(plugin, labels)
    local marker = plugin:styleItem(_("Marker"), Style.MARKER)
    marker.enabled_func = function() return plugin:markerAvailable() end
    -- Greyed where it cannot draw, with the reason a hold shows: it needs a
    -- surface of this plugin's own to be translucent over.
    marker.help_text = _("The marker needs a drawing sheet or a page note to draw on.")
    local items = {
        {
            text = _("Pen style"),
            sub_item_table = {
                plugin:styleItem(_("Round ink"), Style.ROUND),
                plugin:styleItem(_("Ink pen"), Style.PEN),
                plugin:styleItem(_("Graphite"), Style.GRAPHITE),
                marker,
                plugin:styleItem(_("Highlighter"), Style.HIGHLIGHTER),
                plugin:styleItem(_("Textured graphite"), Style.TEXTURED),
            },
        },
        {
            text = _("Pen width"),
            separator = true,
            sub_item_table = {
                plugin:penItem(_("Thin"), ReaderMenu.PEN_THIN),
                plugin:penItem(_("Medium"), ReaderMenu.PEN_MEDIUM),
                plugin:penItem(_("Thick"), ReaderMenu.PEN_THICK),
            },
        },
        {
            text = _("Toolbar side"),
            help_text = _("Where the reader's toolbar sits. A drawing sheet and a notebook keep their controls above the paper."),
            sub_item_table = {
                plugin:sideItem(_("Left"), "left"),
                plugin:sideItem(_("Right"), "right"),
            },
        },
    }
    -- Only where the selection menu can carry the entry at all.
    local highlight = plugin.ui and plugin.ui.highlight
    if highlight and type(highlight.addToHighlightDialog) == "function" then
        items[#items + 1] = {
            text = _("Show JustDraw when text is selected"),
            checked_func = function() return plugin:selectionEntryWanted() end,
            keep_menu_open = true,
            callback = function()
                plugin:setSelectionEntryWanted(not plugin:selectionEntryWanted())
            end,
            help_text = _("Adds a JustDraw button to the menu that appears when you select text, so drawing can start from there. Turn it off if you never draw."),
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Input mode"),
        help_text = _([[Automatic uses the stylus route on devices that report a pen digitizer, and the finger route everywhere else. On a drawing sheet, finger and palm never draw; touches above the bounded sheet can still turn pages. With direct ink, press Stop to return all touch input to reading.]]),
        sub_item_table = {
            plugin:inputModeItem(_("Automatic"), "auto"),
            plugin:inputModeItem(_("Stylus"), "stylus"),
            plugin:inputModeItem(_("Finger"), "finger"),
        },
    }
    items[#items + 1] = {
        text = _("Drawing refresh"),
        callback = function() plugin:showDrawingRefreshDialog() end,
    }
    items[#items + 1] = {
        text = _("Fast refresh while drawing"),
        checked_func = function() return plugin.live_fast end,
        keep_menu_open = true,
        callback = function() plugin:setLiveFast(not plugin.live_fast) end,
        help_text = _([[On: strokes appear with the fastest screen update — quick, but grainy, with some ghosting until the next page turn. Off: slower, cleaner.]]),
        separator = true,
    }
    -- Not gated on the stylus backend being live: the only person who opens
    -- this is someone whose pen does nothing, and for them it never is.
    items[#items + 1] = {
        text = _("Stylus diagnostics"),
        callback = function() plugin:showDiagnostics() end,
        help_text = _([[Shows why the pen route is or is not running. With confirmation, it writes pen coordinates and decisions to the local log for up to one minute or 8,192 events. No book or notebook identity is logged.]]),
    }
    return items
end

--[[--
The menu for a reader with a document open.

  labels.justdraw        the top entry's label (shared with refusal sentences)
  labels.drawing_sheet   the sheet row's label (likewise)
]]
function ReaderMenu.add(plugin, menu_items, labels)
    local items = {
        {
            -- Deliberately closes the menu: turning drawing on swallows
            -- single-finger taps, so an open menu would be unusable. In a
            -- reflowable book this opens the sheet here and draws on it.
            text = _("Start drawing"),
            enabled_func = function() return not plugin.drawing end,
            callback = function() plugin:setDrawing(true) end,
            help_text = _([[Press Stop on the toolbar to switch drawing off again. Two fingers also work as usual while drawing is on.]]),
        },
        {
            text = _("Show toolbar"),
            checked_func = function() return plugin.bar ~= nil end,
            check_callback_updates_menu = true,
            callback = function(touchmenu_instance)
                plugin:setBarShown(plugin.bar == nil)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            separator = true,
        },
    }

    -- Where the ink lives, which depends on the book.
    if plugin.ui.rolling then
        items[#items + 1] = {
            text = labels.drawing_sheet,
            enabled_func = function()
                return plugin.session ~= nil and plugin.session:isAvailable()
            end,
            -- Greyed only while the book's sheets cannot be reached, and then
            -- a hold says why: the reason is no longer announced as the book
            -- opens (ADR-62).
            help_text_func = function()
                return plugin:canvasRefusalMessage()
                    or _([[Blank sheets anchored to a position in a reflowable book.]])
            end,
            sub_item_table_func = function() return plugin:canvasMenu() end,
        }
    end
    if plugin.ui.paging and Capture:supportsStylus() then
        items[#items + 1] = {
            text = _("Page notes"),
            enabled_func = function() return plugin.document_session ~= nil end,
            help_text_func = function()
                return plugin:documentRefusalMessage()
                    or _([[Ink drawn on the pages of a PDF or another fixed layout, stored in the page's own units so it follows zoom and panning.]])
            end,
            sub_item_table_func = function() return plugin:documentInkMenu() end,
        }
    end
    -- On the runtime where direct ink is the only ink there is, its two
    -- deletions are first-class actions; frozen, they are housekeeping.
    if not plugin:legacyInkFrozen() then
        local clear_page, clear_all = plugin:legacyInkItems()
        items[#items + 1] = clear_page
        items[#items + 1] = clear_all
    end
    items[#items].separator = true

    items[#items + 1] = {
        text = _("Document notes"),
        help_text = _("Browse every JustDraw note in this book, read it at full size, go to its location, or export a selection."),
        callback = function() plugin:onShowDocumentNotes() end,
    }
    items[#items + 1] = {
        text = _("Notebooks"),
        callback = function() plugin:openNotebookLibrary() end,
    }
    items[#items + 1] = {
        -- Deliberately closes the menu: the export dialog is a modal, and
        -- arranging one underneath an open menu leaves two window stacks
        -- competing for the same taps.
        text = _("Export…"),
        enabled_func = function() return plugin:canExport() end,
        callback = function() plugin:showExportDialog() end,
        help_text = _([[Writes what you have drawn to a PDF, PNG or JPEG in a folder of your choosing. Exports the page you are reading, the sheet that is open, or every sheet in this book. Nothing in the book itself is changed.]]),
        separator = true,
    }

    items[#items + 1] = {
        text = _("Settings"),
        sub_item_table = settingsItems(plugin, labels),
    }
    -- Frozen ink left by an older version: present only when there is some,
    -- since a reader who never had any has nothing to manage (ADR-39).
    if plugin:legacyInkFrozen() and not plugin.legacy:isEmpty() then
        local clear_page, clear_all = plugin:legacyInkItems()
        items[#items + 1] = {
            text = _("Legacy ink"),
            help_text = _([[Ink drawn by an older JustDraw or FingerInk, in screen pixels. It is shown and exported as it was stored, and these are the only things that can change it.]]),
            sub_item_table = { clear_page, clear_all },
        }
    end

    menu_items.justdraw = {
        text = labels.justdraw,
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

return ReaderMenu
