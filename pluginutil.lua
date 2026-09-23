--[[
Book card - shared plugin bootstrap helper.

The plugin's own files live in <koreader>/plugins/bookcard.koplugin/, which is
NOT on package.path, so require() cannot find sibling files. This module
centralises the two things every file needs:

  PluginUtil.dir            the plugin's own directory (with trailing "/")
  PluginUtil.load(name,...) loadfile() a file from the plugin directory and
                            call the resulting chunk with `...`
]]--

local M = {}

local src = debug.getinfo(1, "S").source
M.dir = src:match("^@(.*/)") or "./"

function M.load(name, ...)
    local path = M.dir .. name
    local chunk, err = loadfile(path)
    if not chunk then
        error(("Book card: failed to load %s: %s"):format(name, tostring(err)))
    end
    return chunk(...)
end

return M
