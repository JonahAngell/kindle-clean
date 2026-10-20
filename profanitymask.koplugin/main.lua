--[[--
Profanity Mask: draws boxes over listed words while reading.

Book files are never modified. On every repaint of a reflowable document
(EPUB, FB2, HTML...), the visible text is walked word by word, matched against
profanity.txt, and the matching words' screen boxes are painted over as a
ReaderView view module (which is drawn after the page and its highlights).

Fixed-layout documents (PDF/DjVu) are not handled yet.

@module koplugin.ProfanityMask
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Matcher = require("matcher")
local WordList = require("wordlist")

local ok_utf8proc, Utf8Proc = pcall(require, "ffi/utf8proc")
local lower = ok_utf8proc and Utf8Proc.lowercase or string.lower

local SETTINGS_KEY = "profanity_mask"
local BOOK_MODE_KEY = "profanity_mask_mode"
local MAX_TOKENS_PER_PAGE = 3000

local DEFAULTS = {
    enabled = true,
    style = "black",  -- black | gray | asterisks | blank
    plurals = false,
}

local STYLES = {
    { id = "black", text = _("Black box") },
    { id = "gray", text = _("Gray box") },
    { id = "asterisks", text = _("Asterisks") },
    { id = "blank", text = _("Blank") },
}

local ProfanityMask = WidgetContainer:extend{
    name = "profanitymask",
    is_doc_only = true,
}

function ProfanityMask:init()
    self.list_path = DataStorage:getDataDir() .. "/profanity.txt"
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY, {})
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self.generation = 0
    self.cache = nil
    self:loadWordList()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    if self.ui.view then
        self.ui.view:registerViewModule("profanity_mask", self)
    end
    if self.ui.highlight then
        self:addToHighlightDialog()
    end
end

function ProfanityMask:onDispatcherRegisterActions()
    Dispatcher:registerAction("profanity_mask_toggle", {
        category = "none", event = "ToggleProfanityMask",
        title = _("Toggle profanity mask"), reader = true,
    })
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

function ProfanityMask:loadWordList()
    local content = WordList.ensure(self.list_path)
    self.matcher = Matcher.new{
        entries = Matcher.parseEntries(content, lower),
        plurals = self.settings.plurals,
        lower = lower,
    }
    self:invalidate()
end

function ProfanityMask:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function ProfanityMask:getBookMode()
    return self.ui.doc_settings and self.ui.doc_settings:readSetting(BOOK_MODE_KEY) or "global"
end

function ProfanityMask:setBookMode(mode)
    self.ui.doc_settings:saveSetting(BOOK_MODE_KEY, mode)
    self:refresh()
end

function ProfanityMask:isActive()
    local mode = self:getBookMode()
    if mode == "off" then return false end
    if mode == "on" then return true end
    return self.settings.enabled
end

function ProfanityMask:invalidate()
    self.generation = self.generation + 1
    self.cache = nil
end

--- Recompute and repaint the current page (FR-9).
function ProfanityMask:refresh()
    self:invalidate()
    if self.view and self.view.dialog then
        UIManager:setDirty(self.view.dialog, "partial")
    end
end

function ProfanityMask:onUpdatePos() self:invalidate() end
function ProfanityMask:onDocumentRerendered() self:invalidate() end
function ProfanityMask:onSetDimensions() self:invalidate() end

function ProfanityMask:onToggleProfanityMask()
    self.settings.enabled = not self.settings.enabled
    self:saveSettings()
    self:refresh()
    UIManager:show(InfoMessage:new{
        text = self.settings.enabled and _("Profanity mask on") or _("Profanity mask off"),
        timeout = 1,
    })
    return true
end

---------------------------------------------------------------------------
-- Finding words on the current page
---------------------------------------------------------------------------

-- "…/text().12" -> "…/text()", 12
local function splitXPointer(xp)
    local base, off = xp:match("^(.*)%.(%d+)$")
    if base then return base, tonumber(off) end
end

local function utf8Len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- Narrow the token [ws, we] to the characters [s, e] (1-based, inclusive).
-- Falls back to the whole token when the xpointers can't be adjusted safely
-- (e.g. the token spans several text nodes because of inline markup).
local function subRange(ws, we, token, s, e)
    local base0, off0 = splitXPointer(ws)
    local base1, off1 = splitXPointer(we)
    if base0 and base0 == base1 and off1 - off0 == utf8Len(token) then
        return base0 .. "." .. (off0 + s - 1), base0 .. "." .. (off0 + e)
    end
    return ws, we
end

function ProfanityMask:collectBoxes()
    local doc = self.ui.document
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local res = doc:getTextFromPositions({ x = 0, y = 0 }, { x = sw, y = sh }, true)
    if not (res and res.pos0 and res.pos1) then return {} end
    if not self.matcher:textMayMatch(res.text) then return {} end

    local ranges = {}
    local window, starts = {}, {}
    local max_window = self.matcher.max_phrase_len

    local ws = doc:getPrevVisibleWordStart(res.pos0) or res.pos0
    local count = 0
    while ws and count < MAX_TOKENS_PER_PAGE do
        count = count + 1
        local we = doc:getNextVisibleWordEnd(ws)
        if not we then break end
        local token = doc:getTextFromXPointers(ws, we, false)
        if token and token ~= "" then
            local spans, norm = self.matcher:matchToken(token)
            if spans then
                for __, sp in ipairs(spans) do
                    local xs, xe = subRange(ws, we, token, sp[1], sp[2])
                    ranges[#ranges + 1] = { xs, xe }
                end
            end
            if max_window > 1 and norm ~= "" then
                window[#window + 1] = norm
                starts[#starts + 1] = ws
                if #window > max_window then
                    table.remove(window, 1)
                    table.remove(starts, 1)
                end
                local n = self.matcher:matchPhraseEnding(window)
                if n then
                    ranges[#ranges + 1] = { starts[#starts - n + 1], we }
                end
            end
        end
        if doc:compareXPointers(we, res.pos1) ~= 1 then break end
        local next_ws = doc:getNextVisibleWordStart(we)
        if not next_ws or next_ws == ws then break end
        ws = next_ws
    end

    local boxes = {}
    for __, r in ipairs(ranges) do
        for __, b in ipairs(doc:getScreenBoxesFromPositions(r[1], r[2], true)) do
            local x0, y0 = math.max(b.x, 0), math.max(b.y, 0)
            local x1, y1 = math.min(b.x + b.w, sw), math.min(b.y + b.h, sh)
            if x1 > x0 and y1 > y0 then
                boxes[#boxes + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
            end
        end
    end
    return boxes
end

function ProfanityMask:getBoxes()
    local key = table.concat({ self.ui.document:getCurrentPos(), self.generation,
        Screen:getWidth(), Screen:getHeight() }, ":")
    if self.cache and self.cache.key == key then
        return self.cache.boxes
    end
    local ok, boxes = pcall(self.collectBoxes, self)
    if not ok then
        logger.warn("ProfanityMask: failed to collect boxes:", boxes)
        boxes = {}
    end
    self.cache = { key = key, boxes = boxes }
    return boxes
end

---------------------------------------------------------------------------
-- Painting (view module)
---------------------------------------------------------------------------

local function paintAsterisks(bb, b)
    bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
    -- Font:getFace() scales by DPI; undo that so the glyphs fit the box.
    local scale = Screen:scaleBySize(1000) / 1000
    local size = math.max(6, math.floor(b.h * 0.9 / scale))
    local face = Font:getFace("cfont", size)
    local star = TextWidget:new{ text = "*", face = face }
    local sw = star:getSize().w
    local n = math.max(1, math.floor(b.w / math.max(sw, 1)))
    star:free()
    local stars = TextWidget:new{ text = string.rep("*", n), face = face, max_width = b.w }
    local sz = stars:getSize()
    stars:paintTo(bb, b.x + math.floor((b.w - sz.w) / 2), b.y + math.floor((b.h - sz.h) / 2))
    stars:free()
end

function ProfanityMask:paintTo(bb, x, y)
    if not self.ui.rolling or not self:isActive() or self.matcher:isEmpty() then return end
    local style = self.settings.style
    for __, b in ipairs(self:getBoxes()) do
        if style == "gray" then
            bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_DARK_GRAY)
        elseif style == "blank" then
            bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
        elseif style == "asterisks" then
            paintAsterisks(bb, b)
        else
            bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_BLACK)
        end
    end
end

---------------------------------------------------------------------------
-- Word list editing
---------------------------------------------------------------------------

function ProfanityMask:addWord(word)
    local added, err = WordList.add(self.list_path, word, lower)
    if err then
        UIManager:show(InfoMessage:new{ text = T(_("Could not save word list:\n%1"), err) })
        return
    end
    self:loadWordList()
    self:refresh()
    UIManager:show(InfoMessage:new{
        text = added and T(_("Added: %1"), word) or T(_("Already in list: %1"), word),
        timeout = 2,
    })
end

function ProfanityMask:removeWord(word)
    local _removed, err = WordList.remove(self.list_path, word, lower)
    if err then
        UIManager:show(InfoMessage:new{ text = T(_("Could not save word list:\n%1"), err) })
        return
    end
    self:loadWordList()
    self:refresh()
end

function ProfanityMask:showAddWordDialog(prefill)
    local dialog
    dialog = InputDialog:new{
        title = _("Add word or phrase to mask"),
        input = prefill or "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Add"),
                is_enter_default = true,
                callback = function()
                    local word = dialog:getInputText()
                    UIManager:close(dialog)
                    if word and word:match("%S") then
                        self:addWord(word)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ProfanityMask:addToHighlightDialog()
    self.ui.highlight:addToHighlightDialog("12_profanity_mask", function(this)
        return {
            text = _("Mask this word"),
            callback = function()
                local text = this.selected_text and this.selected_text.text
                this:onClose()
                if text then
                    -- Strip surrounding punctuation the selection may include.
                    local __, norm = self.matcher:matchToken(text)
                    self:showAddWordDialog(norm ~= "" and norm or text)
                end
            end,
        }
    end)
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

function ProfanityMask:addToMainMenu(menu_items)
    local book_modes = {
        { id = "global", text = _("Follow global setting") },
        { id = "on", text = _("Always filter this book") },
        { id = "off", text = _("Never filter this book") },
    }
    local mode_items = {}
    for __, m in ipairs(book_modes) do
        mode_items[#mode_items + 1] = {
            text = m.text,
            radio = true,
            checked_func = function() return self:getBookMode() == m.id end,
            callback = function() self:setBookMode(m.id) end,
        }
    end
    local style_items = {}
    for __, s in ipairs(STYLES) do
        style_items[#style_items + 1] = {
            text = s.text,
            radio = true,
            checked_func = function() return self.settings.style == s.id end,
            callback = function()
                self.settings.style = s.id
                self:saveSettings()
                self:refresh()
            end,
        }
    end

    menu_items.profanity_mask = {
        text = _("Profanity filter"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Enable filter"),
                checked_func = function() return self.settings.enabled end,
                callback = function()
                    self.settings.enabled = not self.settings.enabled
                    self:saveSettings()
                    self:refresh()
                end,
            },
            {
                text_func = function()
                    for __, m in ipairs(book_modes) do
                        if m.id == self:getBookMode() then
                            return T(_("This book: %1"), m.text)
                        end
                    end
                end,
                sub_item_table = mode_items,
            },
            {
                text = _("Mask style"),
                sub_item_table = style_items,
            },
            {
                text = _("Also match plurals"),
                checked_func = function() return self.settings.plurals end,
                callback = function()
                    self.settings.plurals = not self.settings.plurals
                    self:saveSettings()
                    self:loadWordList()
                    self:refresh()
                end,
                separator = true,
            },
            {
                text = _("Add word…"),
                keep_menu_open = true,
                callback = function() self:showAddWordDialog() end,
            },
            {
                text = _("Remove word"),
                sub_item_table_func = function()
                    local items = {}
                    local content = WordList.read(self.list_path) or ""
                    for __, entry in ipairs(WordList.entries(content)) do
                        items[#items + 1] = {
                            text = entry,
                            callback = function(touchmenu_instance)
                                self:removeWord(entry)
                                if touchmenu_instance then
                                    touchmenu_instance:backToUpperMenu()
                                end
                            end,
                        }
                    end
                    if #items == 0 then
                        items[1] = { text = _("(word list is empty)"), enabled = false }
                    end
                    return items
                end,
            },
            {
                text = _("Reload word list"),
                callback = function()
                    self:loadWordList()
                    self:refresh()
                end,
            },
            {
                text = _("Word list location"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Edit this file over USB, then use \"Reload word list\":\n\n%1"), self.list_path),
                    })
                end,
            },
        },
    }
end

return ProfanityMask
