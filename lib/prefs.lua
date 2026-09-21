--[[
Book Card - thin, nil-guarded wrappers around KOReader's G_reader_settings.

  Prefs.read(key, default)       raw value, `default` if unset
  Prefs.readBool(key, default)   boolean (only a stored `true` counts as true)
  Prefs.save(key, value)         write a value
]]--

local M = {}

local function store()
    return G_reader_settings
end

function M.read(key, default)
    local s = store()
    if s and s.readSetting then
        local v = s:readSetting(key)
        if v == nil then return default end
        return v
    end
    return default
end

function M.readBool(key, default)
    local v = M.read(key, nil)
    if v == nil then return default end
    return v == true
end

function M.save(key, value)
    local s = store()
    if s and s.saveSetting then
        s:saveSetting(key, value)
    end
end

return M
