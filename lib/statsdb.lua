--[[
Book Card - read-only access to KOReader's statistics.sqlite3.

This plugin never writes to the statistics database; it only SELECTs.

  StatsDb.path()                 database file path
  StatsDb.exists()               true if the file is present
  StatsDb.open()                 connection (caller must close) or nil
  StatsDb.withDb(fallback, fn)   open -> pcall(fn, conn) -> close; returns
                                 fn's result or `fallback` on any failure
  StatsDb.first(conn, sql, n)    first row of `sql` as { col1, col2, ... }
                                 (numbers/strings), or nil
  StatsDb.all(conn, sql, n)      every row as a list of { col1, col2, ... }
]]--

local DataStorage = require("datastorage")
local SQ3         = require("lua-ljsqlite3/init")
local logger      = require("logger")

local M = {}

local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

-- KOReader's statistics plugin writes to this file while we read, so wait
-- for a writer instead of failing at once. Connection-local settings only.
local PRAGMAS = "PRAGMA busy_timeout=3000; PRAGMA temp_store=MEMORY;"

function M.path()
    return db_path
end

function M.exists()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(db_path, "mode") == "file"
end

function M.open()
    if not M.exists() then return nil end
    local ok, conn = pcall(SQ3.open, db_path)
    if not ok or not conn then return nil end
    pcall(function() conn:exec(PRAGMAS) end)
    return conn
end

function M.withDb(fallback, fn)
    local conn = M.open()
    if not conn then return fallback end
    local ok, result = pcall(fn, conn)
    pcall(function() conn:close() end)
    if ok then return result end
    logger.warn("BookCard: statistics query failed:", result)
    return fallback
end

local function convert(v)
    if v == nil then return nil end
    local n = tonumber(v)
    if n ~= nil then return n end
    return tostring(v)
end

-- Runs `sql` and hands every row to `on_row(row)` (a plain table of the
-- converted column values). Errors are logged and swallowed.
local function run(conn, sql, ncols, on_row)
    local ok, err = pcall(function()
        local stmt = conn:prepare(sql)
        local ran, res = pcall(function()
            for row in stmt:rows() do
                local out = {}
                for i = 1, ncols do out[i] = convert(row[i]) end
                if on_row(out) == false then break end
            end
        end)
        pcall(function() stmt:close() end)
        if not ran then error(res, 0) end
    end)
    if not ok then
        logger.warn("BookCard: statement failed:", err, "--", sql)
    end
    return ok
end

function M.first(conn, sql, ncols)
    local found
    run(conn, sql, ncols or 3, function(row) found = row; return false end)
    return found
end

function M.all(conn, sql, ncols)
    local rows = {}
    run(conn, sql, ncols or 2, function(row) rows[#rows + 1] = row end)
    return rows
end

return M
