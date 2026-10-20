--[[--
Profanity Mask: draws boxes over listed words while reading.

Book files are never modified. On every repaint of a reflowable document
(EPUB, FB2, HTML...), the visible text is walked word by word, matched against
profanity.txt, and the matching words' screen boxes are painted over as a
ReaderView view module (which is drawn after the page and its highlights).

For fixed-layout documents (PDF, DjVu, CBZ with text layer) the page's word
boxes from the text layer are matched instead, in page coordinates, and
transformed to the screen the same way KOReader draws saved highlights.

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
local Profiles = require("profiles")
local WordList = require("wordlist")

local ok_utf8proc, Utf8Proc = pcall(require, "ffi/utf8proc")
local lower = ok_utf8proc and Utf8Proc.lowercase or string.lower

local SETTINGS_KEY = "profanity_mask"
local BOOK_MODE_KEY = "profanity_mask_mode"
local BOOK_PROFILE_KEY = "profanity_mask_profile"
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
    Profiles.normalize(self.settings)
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
    local entries = Matcher.parseEntries(content, lower)
    self.categories = Matcher.categories(entries)
    self.matcher = Matcher.new{
        entries = entries,
        plurals = self.settings.plurals,
        lower = lower,
        disabled_categories = Profiles.disabled(self.settings, self:getProfile()),
    }
    self:invalidate()
end

--- Rebuild the matcher after a settings change and repaint.
function ProfanityMask:reload()
    self:saveSettings()
    self:loadWordList()
    self:refresh()
end

--- Profile in effect for this book.
function ProfanityMask:getProfile()
    local book = self.ui.doc_settings and self.ui.doc_settings:readSetting(BOOK_PROFILE_KEY)
    return Profiles.resolve(self.settings, book)
end

function ProfanityMask:getBookProfile()
    local book = self.ui.doc_settings and self.ui.doc_settings:readSetting(BOOK_PROFILE_KEY)
    if book and self.settings.profiles[book] then return book end
end

function ProfanityMask:setBookProfile(name)
    if name then
        self.ui.doc_settings:saveSetting(BOOK_PROFILE_KEY, name)
    else
        self.ui.doc_settings:delSetting(BOOK_PROFILE_KEY)
    end
    self:reload()
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
    self.page_cache = {}
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
-- Finding words on fixed-layout pages (PDF/DjVu)
---------------------------------------------------------------------------

-- Rects (page coordinates) to mask on `page`.
function ProfanityMask:collectPageRects(page)
    local doc = self.ui.document
    local lines = doc:getTextBoxes(page)
    if type(lines) ~= "table" then return {} end
    local words, texts = {}, {}
    for __, line in ipairs(lines) do
        for __, w in ipairs(line) do
            if w.word and w.word ~= "" and w.x1 and w.x0 then
                words[#words + 1] = w
                texts[#texts + 1] = w.word
            end
        end
    end
    if not self.matcher:textMayMatch(table.concat(texts, " ")) then return {} end

    local reflow = doc.configurable and doc.configurable.text_wrap == 1
    local rects = {}
    for __, h in ipairs(self.matcher:matchSequence(texts)) do
        for i = h.first, h.last do
            local w = words[i]
            local x0, x1 = w.x0, w.x1
            if h.s and h.n and h.n > 0 then
                -- No per-character boxes: approximate the sub-span by its
                -- share of the word's width (keeps "damn's" -> "damn").
                local cw = (w.x1 - w.x0) / h.n
                x0, x1 = w.x0 + cw * (h.s - 1), w.x0 + cw * h.e
            end
            if reflow then
                -- Map the word to its place in the reflowed page.
                local ym = (w.y0 + w.y1) / 2
                local boxes = doc:getPageBoxesFromPositions(page,
                    { x = x0 + 0.5, y = ym, page = page }, { x = x1 - 0.5, y = ym, page = page })
                for __, b in ipairs(boxes or {}) do
                    rects[#rects + 1] = { x = b.x, y = b.y, w = b.w, h = b.h }
                end
            else
                rects[#rects + 1] = { x = x0, y = w.y0, w = x1 - x0, h = w.y1 - w.y0 }
            end
        end
    end
    return rects
end

-- Screen boxes for all visible pages.
function ProfanityMask:getPagingBoxes()
    local view = self.view
    local doc = self.ui.document
    local cacheable = not (doc.configurable and doc.configurable.text_wrap == 1)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local boxes = {}
    for __, page in ipairs(view:getCurrentPageList()) do
        local rects = cacheable and self.page_cache[page]
        if not rects then
            local ok, res = pcall(self.collectPageRects, self, page)
            if not ok then
                logger.warn("ProfanityMask: failed to collect page rects:", res)
                res = {}
            end
            rects = res
            if cacheable then self.page_cache[page] = rects end
        end
        for __, r in ipairs(rects) do
            local b = view:pageToScreenTransform(page, r)
            if b then
                local x0, y0 = math.max(math.floor(b.x), 0), math.max(math.floor(b.y), 0)
                local x1, y1 = math.min(math.ceil(b.x + b.w), sw), math.min(math.ceil(b.y + b.h), sh)
                if x1 > x0 and y1 > y0 then
                    boxes[#boxes + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
                end
            end
        end
    end
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
    if not self:isActive() or self.matcher:isEmpty() then return end
    local boxes
    if self.ui.rolling then
        boxes = self:getBoxes()
    elseif self.ui.paging then
        boxes = self:getPagingBoxes()
    else
        return
    end
    local style = self.settings.style
    for __, b in ipairs(boxes) do
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

--- Full-screen editor for profanity.txt.
function ProfanityMask:showEditor()
    local editor
    editor = InputDialog:new{
        title = _("Edit word list"),
        input = WordList.ensure(self.list_path),
        input_face = Font:getFace("smallinfont"),
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        cursor_at_end = false,
        add_nav_bar = true,
        scroll_by_pan = true,
        reset_callback = function()
            return WordList.read(self.list_path) or "", _("Changes discarded")
        end,
        save_callback = function(content)
            local ok, err = WordList.write(self.list_path, content or "")
            if not ok then
                return false, T(_("Could not save word list:\n%1"), err)
            end
            self:loadWordList()
            self:refresh()
            return true, _("Word list saved")
        end,
    }
    UIManager:show(editor)
    editor:onShowKeyboard()
end

function ProfanityMask:showNewProfileDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("New profile"),
        description = T(_("Starts with the same categories as \"%1\"."), self:getProfile()),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Create"),
                is_enter_default = true,
                callback = function()
                    local ok, res = Profiles.create(self.settings, dialog:getInputText(), self:getProfile())
                    UIManager:close(dialog)
                    if ok then
                        self.settings.active_profile = res
                        self:reload()
                        UIManager:show(InfoMessage:new{ text = T(_("Profile \"%1\" is now active."), res), timeout = 2 })
                    elseif res == "exists" then
                        UIManager:show(InfoMessage:new{ text = _("A profile with that name already exists.") })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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

    local function categoryItems()
        local items = {}
        local profile = self:getProfile()
        for __, cat in ipairs(self.categories) do
            items[#items + 1] = {
                text = cat,
                checked_func = function() return Profiles.isCategoryEnabled(self.settings, profile, cat) end,
                callback = function()
                    Profiles.setCategoryEnabled(self.settings, profile, cat,
                        not Profiles.isCategoryEnabled(self.settings, profile, cat))
                    self:reload()
                end,
            }
        end
        if #items == 0 then
            items[1] = { text = _("(word list is empty)"), enabled = false }
        end
        return items
    end

    local function profileItems()
        local items = {}
        for __, name in ipairs(Profiles.names(self.settings)) do
            items[#items + 1] = {
                text = name,
                radio = true,
                checked_func = function() return self.settings.active_profile == name end,
                callback = function()
                    self.settings.active_profile = name
                    self:reload()
                end,
            }
        end
        items[#items].separator = true
        items[#items + 1] = {
            text = _("New profile…"),
            keep_menu_open = true,
            callback = function() self:showNewProfileDialog() end,
        }
        local book_items = {{
            text = _("Use active profile"),
            radio = true,
            checked_func = function() return self:getBookProfile() == nil end,
            callback = function() self:setBookProfile(nil) end,
            separator = true,
        }}
        for __, name in ipairs(Profiles.names(self.settings)) do
            book_items[#book_items + 1] = {
                text = name,
                radio = true,
                checked_func = function() return self:getBookProfile() == name end,
                callback = function() self:setBookProfile(name) end,
            }
        end
        items[#items + 1] = {
            text_func = function()
                return T(_("This book: %1"), self:getBookProfile() or _("active profile"))
            end,
            sub_item_table = book_items,
        }
        local delete_items = {}
        for __, name in ipairs(Profiles.names(self.settings)) do
            if name ~= Profiles.DEFAULT then
                delete_items[#delete_items + 1] = {
                    text = name,
                    callback = function(touchmenu_instance)
                        Profiles.delete(self.settings, name)
                        self:reload()
                        if touchmenu_instance then touchmenu_instance:backToUpperMenu() end
                    end,
                }
            end
        end
        items[#items + 1] = {
            text = _("Delete profile"),
            enabled = #delete_items > 0,
            sub_item_table = delete_items,
        }
        return items
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
                text_func = function() return T(_("Profile: %1"), self:getProfile()) end,
                sub_item_table_func = profileItems,
            },
            {
                text_func = function() return T(_("Categories (%1)"), self:getProfile()) end,
                sub_item_table_func = categoryItems,
            },
            {
                text = _("Also match plurals"),
                checked_func = function() return self.settings.plurals end,
                callback = function()
                    self.settings.plurals = not self.settings.plurals
                    self:reload()
                end,
                separator = true,
            },
            {
                text = _("Edit word list…"),
                callback = function() self:showEditor() end,
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
