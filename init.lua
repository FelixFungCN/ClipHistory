local config = require("ClipHistory.config")
local db = require("ClipHistory.db")
local capture = require("ClipHistory.capture")
local panel = require("ClipHistory.panel")

local M = {}
local hotkey

function M.start()
  hs.accessibilityState(true)
  local ok, err = db.open(config.dbPath)
  if not ok then error("db open failed: " .. tostring(err)) end
  capture.start()
  panel.start()

  hotkey = hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, function()
    panel.toggle()
  end)
end

function M.stop()
  capture.stop()
  panel.stop()
  if hotkey then
    hotkey:delete()
    hotkey = nil
  end
  db.close()
end

function M.count()
  return db.count()
end

function M.search(q)
  local keywords = {}
  for kw in tostring(q or ""):lower():gmatch("%S+") do keywords[#keywords + 1] = kw end
  return db.search(keywords)
end

return M
