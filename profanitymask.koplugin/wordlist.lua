--[[--
Human-editable word list file (profanity.txt) for the Profanity Mask plugin.

The file is plain UTF-8 text, one entry per line. Comments (#) and category
headers ([Name]) are preserved when words are added or removed from the menu.

No KOReader dependencies, so it can be unit-tested on a desktop LuaJIT.

@module wordlist
--]]

local WordList = {}

WordList.DEFAULT_CONTENT = [[
# Profanity Mask word list
#
# One word or phrase per line. Matching ignores case and surrounding
# punctuation; possessives (word's) are always masked, plurals optionally.
# Lines starting with # are comments.
#
# Optional category headers group the entries that follow them, e.g.
#   [Strong]
# Categories can be switched on and off per profile from the menu
# (Profanity filter > Categories). Entries above the first header are in
# the "General" category.

damn
hell
crap
]]

function WordList.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    -- Strip UTF-8 BOM left by some desktop editors.
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end
    return content
end

local function writeAtomic(path, content)
    if content ~= "" and content:sub(-1) ~= "\n" then
        content = content .. "\n"
    end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    f:write(content)
    f:close()
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, rename_err
    end
    return true
end

--- Replace the whole file (used by the in-app editor).
function WordList.write(path, content)
    return writeAtomic(path, content)
end

--- Read the list, creating it with default content if missing.
function WordList.ensure(path)
    local content = WordList.read(path)
    if content then return content end
    writeAtomic(path, WordList.DEFAULT_CONTENT)
    return WordList.read(path) or WordList.DEFAULT_CONTENT
end

local function normalize(line, lower)
    local s = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return lower(s)
end

local function isEntryLine(line)
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s:sub(1, 1) ~= "#" and not s:match("^%[.+%]$")
end

--- List entries (as written in the file) in file order.
function WordList.entries(content)
    local list = {}
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        if isEntryLine(line) then
            list[#list + 1] = line:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    return list
end

--- Return true if `word` is already in the list.
function WordList.contains(content, word, lower)
    lower = lower or string.lower
    local target = normalize(word, lower)
    for _, entry in ipairs(WordList.entries(content)) do
        if normalize(entry, lower) == target then return true end
    end
    return false
end

local function isHeaderLine(line)
    return line:gsub("^%s+", ""):gsub("%s+$", ""):match("^%[.+%]$") ~= nil
end

local function splitLines(content)
    local lines = {}
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = line
    end
    -- The split yields a trailing empty element for the final newline.
    if lines[#lines] == "" then lines[#lines] = nil end
    return lines
end

--[[--
Add a word or phrase to the General section (before the first [Category]
header, or at the end if there are no headers).
@treturn bool added (false if empty or already present)
@treturn string|nil error message
--]]
function WordList.add(path, word, lower)
    lower = lower or string.lower
    word = word:gsub("[\r\n]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if word == "" then return false end
    local content = WordList.ensure(path)
    if WordList.contains(content, word, lower) then return false end
    local lines = splitLines(content)
    local at = #lines + 1
    for i, line in ipairs(lines) do
        if isHeaderLine(line) then
            at = i
            -- keep the blank line(s) separating the section from the header
            while at > 1 and lines[at - 1]:match("^%s*$") do at = at - 1 end
            break
        end
    end
    table.insert(lines, at, word)
    local ok, err = writeAtomic(path, table.concat(lines, "\n") .. "\n")
    return ok, err
end

--[[--
Remove every line matching `word` (case-insensitive), keeping all other lines.
@treturn bool removed
@treturn string|nil error message
--]]
function WordList.remove(path, word, lower)
    lower = lower or string.lower
    local content = WordList.read(path)
    if not content then return false end
    local target = normalize(word, lower)
    local out, removed = {}, false
    for _, line in ipairs(splitLines(content)) do
        if isEntryLine(line) and normalize(line, lower) == target then
            removed = true
        else
            out[#out + 1] = line
        end
    end
    if not removed then return false end
    local ok, err = writeAtomic(path, table.concat(out, "\n") .. "\n")
    return ok, err
end

return WordList
