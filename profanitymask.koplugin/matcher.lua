--[[--
Pure-Lua word/phrase matcher for the Profanity Mask plugin.

Has no KOReader dependencies so it can be unit-tested on a desktop LuaJIT.

A token is whatever the renderer considers one word (it may carry leading or
trailing punctuation, e.g. "(damn)," or "damn's"). matchToken() returns the
character span(s) inside that token that should be masked, so punctuation and
possessive suffixes stay visible while the base word is hidden.

@module matcher
--]]

local Matcher = {}
Matcher.__index = Matcher

-- Characters treated as punctuation when trimming tokens (in addition to
-- ASCII punctuation). Apostrophes are handled specially for possessives.
local UNICODE_PUNCT = {
    ["“"] = true, ["”"] = true, ["‘"] = true, ["’"] = true,
    ["«"] = true, ["»"] = true, ["—"] = true, ["–"] = true,
    ["…"] = true, ["„"] = true, ["‚"] = true, ["‹"] = true, ["›"] = true,
}

--- Category of entries that appear before any [Name] header.
Matcher.DEFAULT_CATEGORY = "General"

local APOSTROPHES = { ["'"] = true, ["’"] = true }
-- Separators that may join words inside one rendered token ("damn-it").
local INNER_SEPARATORS = { ["-"] = true, ["—"] = true, ["–"] = true, ["/"] = true }

--- Split a UTF-8 string into an array of characters.
function Matcher.splitChars(str)
    local chars = {}
    for c in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = c
    end
    return chars
end

local function isPunct(c)
    if #c == 1 then
        return c:match("%p") ~= nil
    end
    return UNICODE_PUNCT[c] == true
end

local function isSpace(c)
    return c:match("^%s$") ~= nil or c == "\194\160" -- nbsp
end

--[[--
Parse word-list file contents into entries.

Format (one entry per line):
    word                -- single word
    son of a            -- phrase (any line containing spaces)
    [Strong]            -- category header; applies to following entries
                        -- (entries before any header are in "General")
    # comment           -- ignored, as are blank lines
    re:...              -- reserved for a future regex mode (currently skipped)
--]]
function Matcher.parseEntries(text, lower)
    lower = lower or string.lower
    local entries = {}
    local category = Matcher.DEFAULT_CATEGORY
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "" or line:sub(1, 1) == "#" then -- luacheck: ignore 542
            -- skip
        elseif line:match("^%[.+%]$") then
            category = line:sub(2, -2):gsub("^%s+", ""):gsub("%s+$", "")
        elseif line:sub(1, 3) == "re:" then
            entries[#entries + 1] = { kind = "regex", pattern = line:sub(4), category = category }
        else
            local norm = lower(line):gsub("%s+", " ")
            local words = {}
            for w in norm:gmatch("%S+") do words[#words + 1] = w end
            entries[#entries + 1] = {
                kind = #words > 1 and "phrase" or "word",
                text = norm,
                words = words,
                category = category,
            }
        end
    end
    return entries
end

--- Category names used by `entries`, in file order (General first if used).
function Matcher.categories(entries)
    local list, seen = {}, {}
    for _, e in ipairs(entries) do
        if e.category and not seen[e.category] then
            seen[e.category] = true
            list[#list + 1] = e.category
        end
    end
    return list
end

--[[--
Create a matcher.

@tparam table opts
  entries: array from parseEntries()
  plurals: boolean, also match simple plural forms (words/boxes/parties)
  lower:   UTF-8 aware lowercase function (defaults to string.lower)
  disabled_categories: optional set {name = true} of categories to ignore
--]]
function Matcher.new(opts)
    local self = setmetatable({}, Matcher)
    self.lower = opts.lower or string.lower
    self.plurals = opts.plurals and true or false
    self.words = {}       -- set of normalized single words
    self.phrases = {}     -- array of { words = {...} }
    self.needles = {}     -- substrings for the fast page pre-check
    self.max_phrase_len = 1
    local seen_needle = {}
    local disabled = opts.disabled_categories or {}
    for _, e in ipairs(opts.entries or {}) do
        if disabled[e.category] then -- luacheck: ignore 542
            -- skip
        elseif e.kind == "word" then
            self.words[e.text] = true
        elseif e.kind == "phrase" then
            self.phrases[#self.phrases + 1] = e
            if #e.words > self.max_phrase_len then
                self.max_phrase_len = #e.words
            end
        end
        if e.words and e.words[1] and not disabled[e.category] then
            local needle = e.words[1]
            -- for plurals like "parties" from "party", search the stem
            if self.plurals and needle:sub(-1) == "y" and #needle > 2 then
                needle = needle:sub(1, -2)
            end
            if not seen_needle[needle] then
                seen_needle[needle] = true
                self.needles[#self.needles + 1] = needle
            end
        end
    end
    return self
end

function Matcher:isEmpty()
    return #self.needles == 0
end

--- Fast check: could this page text contain any entry at all?
function Matcher:textMayMatch(text)
    if not text or text == "" or #self.needles == 0 then return false end
    local lowered = self.lower(text)
    for _, needle in ipairs(self.needles) do
        if lowered:find(needle, 1, true) then
            return true
        end
    end
    return false
end

-- Is `word` (already lowercased) in the list, directly or as a plural form?
function Matcher:isListedWord(word)
    if word == "" then return false end
    if self.words[word] then return true end
    if self.plurals then
        local n = #word
        if n > 3 and word:sub(-3) == "ies" and self.words[word:sub(1, -4) .. "y"] then
            return true
        end
        if n > 2 and word:sub(-2) == "es" and self.words[word:sub(1, -3)] then
            return true
        end
        if n > 1 and word:sub(-1) == "s" and self.words[word:sub(1, -2)] then
            return true
        end
    end
    return false
end

-- Match a punctuation-free core given as a char array slice [a, b].
-- Returns the masked span (a', b') or nil.
function Matcher:_matchCore(chars, a, b)
    if a > b then return nil end
    local core = self.lower(table.concat(chars, "", a, b))
    if self:isListedWord(core) then
        return a, b
    end
    -- Possessive: damn's / damn’s  -> mask "damn"
    if b - a >= 2 and APOSTROPHES[chars[b - 1]] and (chars[b] == "s" or chars[b] == "S") then
        local base = self.lower(table.concat(chars, "", a, b - 2))
        if self:isListedWord(base) then
            return a, b - 2
        end
    end
    -- Plural possessive: damns' -> mask "damns"
    if b - a >= 1 and APOSTROPHES[chars[b]] then
        local base = self.lower(table.concat(chars, "", a, b - 1))
        if self:isListedWord(base) then
            return a, b - 1
        end
    end
    return nil
end

--[[--
Match a single rendered token.

@string token raw token text as rendered
@treturn table|nil array of {start_char, end_char} spans (1-based, inclusive,
  in UTF-8 characters of `token`), or nil if nothing matches
@treturn string normalized core of the token (used for phrase matching)
--]]
function Matcher:matchToken(token)
    local chars = Matcher.splitChars(token)
    local a, b = 1, #chars
    while a <= b and (isSpace(chars[a]) or isPunct(chars[a])) do a = a + 1 end
    while b >= a and (isSpace(chars[b]) or (isPunct(chars[b]) and not APOSTROPHES[chars[b]])) do b = b - 1 end
    -- Trailing apostrophe is kept only if it might be a plural possessive;
    -- otherwise it's a closing quote.
    local core_b = b
    if b >= a and APOSTROPHES[chars[b]] and not (b > a and (chars[b - 1] == "s" or chars[b - 1] == "S")) then
        core_b = b - 1
        b = core_b
    end
    local norm = a <= core_b and self.lower(table.concat(chars, "", a, core_b)) or ""

    local s, e = self:_matchCore(chars, a, b)
    if s then
        return { { s, e } }, norm
    end

    -- Compound tokens: damn-it, hell/damn
    local spans
    local seg_start = a
    for i = a, b + 1 do
        if i > b or INNER_SEPARATORS[chars[i]] then
            if i > seg_start and (i <= b or seg_start > a) then
                local ss, se = self:_matchCore(chars, seg_start, i - 1)
                if ss then
                    spans = spans or {}
                    spans[#spans + 1] = { ss, se }
                end
            end
            seg_start = i + 1
        end
    end
    return spans, norm
end

--[[--
Check whether a listed phrase ends at the latest token.

@tparam table window array of normalized token cores, most recent last
@treturn int|nil number of trailing tokens covered by the longest matching
  phrase, or nil
--]]
function Matcher:matchPhraseEnding(window)
    local best
    local n = #window
    for _, p in ipairs(self.phrases) do
        local len = #p.words
        if len <= n and (not best or len > best) then
            local ok = true
            for k = 1, len do
                if window[n - len + k] ~= p.words[k] then
                    ok = false
                    break
                end
            end
            if ok then best = len end
        end
    end
    return best
end

--[[--
Match a whole sequence of tokens (e.g. the words of a PDF page, in reading order).

@tparam table tokens array of raw token strings
@treturn table array of hits. A word hit is
  { first = i, last = i, s = start_char, e = end_char, n = token_chars };
  a phrase hit covers whole tokens: { first = i, last = j }.
--]]
function Matcher:matchSequence(tokens)
    local hits = {}
    local window, idx = {}, {}
    local max_window = self.max_phrase_len
    for i, token in ipairs(tokens) do
        local spans, norm = self:matchToken(token)
        if spans then
            local n = #Matcher.splitChars(token)
            for _, sp in ipairs(spans) do
                hits[#hits + 1] = { first = i, last = i, s = sp[1], e = sp[2], n = n }
            end
        end
        if max_window > 1 and norm ~= "" then
            window[#window + 1] = norm
            idx[#idx + 1] = i
            if #window > max_window then
                table.remove(window, 1)
                table.remove(idx, 1)
            end
            local len = self:matchPhraseEnding(window)
            if len then
                hits[#hits + 1] = { first = idx[#idx - len + 1], last = i }
            end
        end
    end
    return hits
end

return Matcher
