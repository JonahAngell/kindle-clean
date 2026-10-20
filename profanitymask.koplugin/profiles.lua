--[[--
Named profiles for the Profanity Mask plugin.

A profile is a set of disabled word-list categories, so e.g. a "Kids" profile
can mask everything while a "Mild" profile leaves [Mild] words visible.
Profiles live in the plugin's settings table:

    settings.profiles       = { Default = { disabled = { Mild = true } }, ... }
    settings.active_profile = "Default"

A book may override the active profile (stored in its doc settings).

No KOReader dependencies, so it can be unit-tested on a desktop LuaJIT.

@module profiles
--]]

local Profiles = {}

Profiles.DEFAULT = "Default"

--- Make sure `settings` has a valid profile table and active profile.
function Profiles.normalize(settings)
    if type(settings.profiles) ~= "table" then
        settings.profiles = {}
    end
    if type(settings.profiles[Profiles.DEFAULT]) ~= "table" then
        settings.profiles[Profiles.DEFAULT] = { disabled = {} }
    end
    for _, p in pairs(settings.profiles) do
        if type(p.disabled) ~= "table" then p.disabled = {} end
    end
    if not settings.profiles[settings.active_profile] then
        settings.active_profile = Profiles.DEFAULT
    end
    return settings
end

--- Profile names, Default first, the rest sorted.
function Profiles.names(settings)
    local list = {}
    for name in pairs(settings.profiles) do
        if name ~= Profiles.DEFAULT then list[#list + 1] = name end
    end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    table.insert(list, 1, Profiles.DEFAULT)
    return list
end

--- The profile in effect: the book's override if it still exists, else the active one.
function Profiles.resolve(settings, book_profile)
    if book_profile and settings.profiles[book_profile] then
        return book_profile
    end
    return settings.active_profile
end

--- Set of disabled categories for profile `name`.
function Profiles.disabled(settings, name)
    local p = settings.profiles[name] or settings.profiles[Profiles.DEFAULT]
    return p.disabled
end

function Profiles.isCategoryEnabled(settings, name, category)
    return not Profiles.disabled(settings, name)[category]
end

function Profiles.setCategoryEnabled(settings, name, category, enabled)
    Profiles.disabled(settings, name)[category] = (not enabled) or nil
end

--[[--
Create a profile, copying the categories of `from` (if given).
@treturn bool created
@treturn string|nil reason ("empty" or "exists")
--]]
function Profiles.create(settings, name, from)
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, "empty" end
    if settings.profiles[name] then return false, "exists" end
    local disabled = {}
    if from and settings.profiles[from] then
        for k, v in pairs(settings.profiles[from].disabled) do disabled[k] = v end
    end
    settings.profiles[name] = { disabled = disabled }
    return true, name
end

--- Delete a profile (the Default profile can't be deleted).
function Profiles.delete(settings, name)
    if name == Profiles.DEFAULT or not settings.profiles[name] then return false end
    settings.profiles[name] = nil
    if settings.active_profile == name then
        settings.active_profile = Profiles.DEFAULT
    end
    return true
end

return Profiles
