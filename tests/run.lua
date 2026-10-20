-- Desktop unit tests for the pure-Lua parts of the Profanity Mask plugin.
-- Run from the repo root:  luajit tests/run.lua

package.path = "./profanitymask.koplugin/?.lua;" .. package.path

local Matcher = require("matcher")
local WordList = require("wordlist")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write("FAIL  ", name, "\n      ", tostring(err), "\n")
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "", tostring(expected), tostring(actual)), 2)
    end
end

-- Returns the masked substring(s) of `token`, joined by "|", or nil.
local function masked(m, token)
    local spans = m:matchToken(token)
    if not spans then return nil end
    local chars = Matcher.splitChars(token)
    local parts = {}
    for _, s in ipairs(spans) do
        parts[#parts + 1] = table.concat(chars, "", s[1], s[2])
    end
    return table.concat(parts, "|")
end

local function make(list, plurals)
    return Matcher.new{ entries = Matcher.parseEntries(list), plurals = plurals }
end

local m = make("damn\nhell\n# comment\n\n[Strong]\nson of a\n")
local mp = make("damn\nparty\nbox\n", true)

-- FR-1 exact match
test("exact", function() eq(masked(m, "damn"), "damn") end)
test("no partial word", function() eq(masked(m, "damnation"), nil); eq(masked(m, "hello"), nil); eq(masked(m, "shell"), nil) end)

-- FR-2 case insensitive
test("case", function()
    eq(masked(m, "DAMN"), "DAMN"); eq(masked(m, "Damn"), "Damn"); eq(masked(m, "DaMn"), "DaMn")
end)

-- FR-3 punctuation
test("punctuation", function()
    eq(masked(m, "damn,"), "damn"); eq(masked(m, "damn."), "damn"); eq(masked(m, "(damn)"), "damn")
    eq(masked(m, "“Damn!”"), "Damn"); eq(masked(m, "—hell…"), "hell"); eq(masked(m, "'damn'"), "damn")
end)

-- FR-4 possessive
test("possessive", function()
    eq(masked(m, "damn's"), "damn"); eq(masked(m, "Hell’s"), "Hell"); eq(masked(m, "hell's,"), "hell")
end)

-- FR-5 plurals (configurable)
test("plurals off", function() eq(masked(m, "damns"), nil) end)
test("plurals on", function()
    eq(masked(mp, "damns"), "damns"); eq(masked(mp, "parties"), "parties"); eq(masked(mp, "boxes"), "boxes")
    eq(masked(mp, "damns'"), "damns"); eq(masked(mp, "damn's"), "damn")
end)

test("compound tokens", function()
    eq(masked(m, "damn-it"), "damn"); eq(masked(m, "hell/damn"), "hell|damn"); eq(masked(m, "well-made"), nil)
end)

test("phrases", function()
    local _, n1 = m:matchToken("Son"); local _, n2 = m:matchToken("of"); local _, n3 = m:matchToken("a,")
    eq(m:matchPhraseEnding({ "you", n1, n2, n3 }), 3)
    eq(m:matchPhraseEnding({ n1, n2 }), nil)
end)

test("page pre-check", function()
    eq(m:textMayMatch("Nothing to see here."), false)
    eq(m:textMayMatch("Well, DAMN."), true)
    eq(mp:textMayMatch("Two parties."), true)
    eq(make("# only comments\n"):isEmpty(), true)
end)

test("regex lines reserved", function()
    local e = Matcher.parseEntries("re:d.mn\n")
    eq(e[1].kind, "regex")
end)

-- Word list file round trip
local tmp = os.tmpname()
os.remove(tmp)
test("wordlist create/add/remove", function()
    local content = WordList.ensure(tmp)
    eq(WordList.contains(content, "Damn"), true)
    eq(WordList.add(tmp, "  Frak  "), true)
    eq(WordList.add(tmp, "frak"), false, "duplicate")
    eq(WordList.contains(WordList.read(tmp), "FRAK"), true)
    eq(WordList.remove(tmp, "frak"), true)
    eq(WordList.remove(tmp, "frak"), false)
    local after = WordList.read(tmp)
    eq(WordList.contains(after, "frak"), false)
    eq(after:find("# Profanity Mask word list", 1, true) ~= nil, true, "comments kept")
    eq(WordList.contains(after, "crap"), true)
end)
os.remove(tmp)

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
