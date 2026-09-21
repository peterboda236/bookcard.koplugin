--[[
Book Card - persistent cache of the last-read book's card data.

Why a cache: when the device is locked from the file manager there is no
open document, so KOReader's live reading state (progress, pace, page
counts, the statistics plugin's in-memory numbers) does not exist. The card
is therefore snapshotted whenever a book is open (on close, and whenever the
device sleeps with a book open) and read back from here when it isn't.

Two things are stored:
  <settings>/bookcard_cache.lua    the card table (plain Lua values)
  <data>/cache/bookcard/cover.png  the downscaled cover of that book

  Cache.load()               card table or nil
  Cache.save(card)           write the card table
  Cache.clear()              delete card + cover
  Cache.coverPath()          path of the cached cover (may not exist)
  Cache.hasCover()           true if the cached cover file exists
  Cache.saveCover(bb)        downscale + write a cover BlitBuffer as PNG;
                             takes ownership of `bb`; returns true/false
]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local M = {}

local CARD_FILE = DataStorage:getSettingsDir() .. "/bookcard_cache.lua"
local COVER_DIR = DataStorage:getDataDir() .. "/cache/bookcard"
local COVER_FILE = COVER_DIR .. "/cover.png"

-- Tall enough for any e-ink screen; keeps the PNG small and quick to load.
local COVER_MAX_HEIGHT = 900

function M.coverPath()
    return COVER_FILE
end

function M.hasCover()
    return lfs.attributes(COVER_FILE, "mode") == "file"
end

function M.load()
    local ok, card = pcall(function()
        if lfs.attributes(CARD_FILE, "mode") ~= "file" then return nil end
        return LuaSettings:open(CARD_FILE):readSetting("card")
    end)
    if ok and type(card) == "table" then return card end
    return nil
end

function M.save(card)
    local ok, err = pcall(function()
        local s = LuaSettings:open(CARD_FILE)
        s:saveSetting("card", card)
        s:flush()
    end)
    if not ok then logger.warn("BookCard: cache save failed:", err) end
    return ok
end

function M.clear()
    pcall(os.remove, CARD_FILE)
    pcall(os.remove, COVER_FILE)
end

local function ensureDir()
    if lfs.attributes(COVER_DIR, "mode") == "directory" then return true end
    local util = require("util")
    local ok = pcall(util.makePath, COVER_DIR .. "/")
    return ok and lfs.attributes(COVER_DIR, "mode") == "directory"
end

function M.saveCover(bb)
    if not bb then return false end
    local ok = pcall(function()
        if not ensureDir() then error("cannot create " .. COVER_DIR) end
        local h = bb:getHeight()
        if h > COVER_MAX_HEIGHT then
            local RenderImage = require("ui/renderimage")
            local w = math.floor(bb:getWidth() * COVER_MAX_HEIGHT / h + 0.5)
            bb = RenderImage:scaleBlitBuffer(bb, w, COVER_MAX_HEIGHT, true)
        end
        os.remove(COVER_FILE)
        bb:writePNG(COVER_FILE)
        bb:free()
    end)
    if not ok then
        logger.warn("BookCard: cover cache failed")
        return false
    end
    return M.hasCover()
end

return M
