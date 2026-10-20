-- Desktop unit tests for the pure-Lua parts of the Profanity Mask plugin.
-- Run from the repo root:  luajit tests/run.lua

package.path = "./profanitymask.koplugin/?.lua;" .. package.path

local Matcher = require("matcher")
local WordList = require("wordlist")
local Profiles = require("profiles")

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

test("sequence (PDF words)", function()
    local hits = m:matchSequence({ "Well,", "damn's", "it,", "you", "son", "of", "a", "gun.", "“Hell!”" })
    eq(#hits, 3)
    eq(hits[1].first, 2); eq(hits[1].s, 1); eq(hits[1].e, 4); eq(hits[1].n, 6)
    eq(hits[2].first, 5); eq(hits[2].last, 7); eq(hits[2].s, nil)
    eq(hits[3].first, 9); eq(hits[3].s, 2); eq(hits[3].e, 5); eq(hits[3].n, 7)
end)

test("categories", function()
    local entries = Matcher.parseEntries("damn\n[Strong]\nfrak\nson of a\n[ Mild ]\nheck\n")
    local cats = Matcher.categories(entries)
    eq(table.concat(cats, ","), "General,Strong,Mild")
    eq(entries[1].category, "General")
    local all = Matcher.new{ entries = entries }
    eq(masked(all, "frak"), "frak"); eq(masked(all, "heck"), "heck")
    local some = Matcher.new{ entries = entries, disabled_categories = { Strong = true } }
    eq(masked(some, "frak"), nil); eq(masked(some, "damn"), "damn"); eq(masked(some, "heck"), "heck")
    eq(some.max_phrase_len, 1, "phrase in disabled category dropped")
    eq(some:textMayMatch("frak it"), false)
    local none = Matcher.new{ entries = entries, disabled_categories = { General = true, Strong = true, Mild = true } }
    eq(none:isEmpty(), true)
end)

test("profiles", function()
    local s = Profiles.normalize({ active_profile = "Gone" })
    eq(s.active_profile, "Default")
    eq(Profiles.isCategoryEnabled(s, "Default", "Strong"), true)
    Profiles.setCategoryEnabled(s, "Default", "Mild", false)
    eq(Profiles.disabled(s, "Default").Mild, true)
    eq(Profiles.create(s, "  Kids "), true)
    eq(Profiles.create(s, "Kids"), false, "duplicate")
    eq(Profiles.create(s, "   "), false, "empty")
    eq(Profiles.create(s, "Adult", "Default"), true)
    eq(Profiles.disabled(s, "Adult").Mild, true, "copied")
    Profiles.setCategoryEnabled(s, "Adult", "Mild", true)
    eq(Profiles.disabled(s, "Default").Mild, true, "copy is independent")
    eq(table.concat(Profiles.names(s), ","), "Default,Adult,Kids")
    s.active_profile = "Kids"
    eq(Profiles.resolve(s, nil), "Kids")
    eq(Profiles.resolve(s, "Adult"), "Adult")
    eq(Profiles.resolve(s, "Missing"), "Kids")
    eq(Profiles.delete(s, "Default"), false)
    eq(Profiles.delete(s, "Kids"), true)
    eq(s.active_profile, "Default")
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

test("wordlist add goes to General section", function()
    local path = os.tmpname()
    WordList.write(path, "# header\nfoo\n\n[Strong]\nbar")
    eq(WordList.add(path, "baz"), true)
    eq(WordList.read(path), "# header\nfoo\nbaz\n\n[Strong]\nbar\n")
    local entries = Matcher.parseEntries(WordList.read(path))
    eq(entries[2].text, "baz"); eq(entries[2].category, "General")
    eq(WordList.remove(path, "bar"), true)
    eq(WordList.read(path), "# header\nfoo\nbaz\n\n[Strong]\n")
    os.remove(path)
end)

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
