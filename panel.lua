local config = require("ClipHistory.config")
local db = require("ClipHistory.db")
local capture = require("ClipHistory.capture")

local M = {}
local log = hs.logger.new("ClipHistory.panel", "warning")

local wv, uc
local visible = false
local focusedOnce = false
local currentQuery = ""
local targetBundle

local UI_PATH = (os.getenv("HOME") or "") .. "/.hammerspoon/ClipHistory/ui/panel.html"

local function panelFrameOn(screen)
  local f = screen:fullFrame()
  local w, h = config.panelWidth, config.panelHeight
  return {
    x = math.floor(f.x + (f.w - w) / 2),
    y = math.floor(f.y + (f.h - h) * 0.32),
    w = w,
    h = h,
  }
end

local function targetScreen()
  local win = hs.window.focusedWindow()
  if win then
    local s = win:screen()
    if s then return s end
  end
  local app = hs.application.frontmostApplication()
  if app then
    local w = app:mainWindow()
    if w then
      local s = w:screen()
      if s then return s end
    end
  end
  return hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end

local function clipBody(s)
  local pos = utf8.offset(s, 301)
  if not pos then return s end
  return s:sub(1, pos - 1)
end

local DISPLAY_LIMIT = 20000

local function expandBody(s)
  local pos = utf8.offset(s, DISPLAY_LIMIT + 1)
  if not pos then return s, false end
  return s:sub(1, pos - 1), true
end

local function keywords(q)
  local out = {}
  for kw in tostring(q or ""):lower():gmatch("%S+") do out[#out + 1] = kw end
  return out
end

local function sendItems()
  if not wv then return end
  local rows = db.search(keywords(currentQuery))
  local payload = { items = {}, total = db.count(), query = currentQuery }
  for _, r in ipairs(rows) do
    payload.items[#payload.items + 1] = {
      id = tonumber(r.id),
      body = clipBody(r.body),
      src = r.src_name or "未知",
      ts = tonumber(r.created_at),
    }
  end
  local ok, err = pcall(function()
    wv:evaluateJavaScript("window.render(" .. hs.json.encode(payload) .. ")")
  end)
  if not ok then log.e("render failed: " .. tostring(err)) end
end

local dragTap, dragOrigin, dragFrame

local function stopDrag(save)
  if dragTap then
    dragTap:stop()
    dragTap = nil
  end
  if save and wv then
    local f = wv:frame()
    hs.settings.set("ClipHistory.panelFrame", { x = f.x, y = f.y, w = f.w, h = f.h })
  end
  dragOrigin = nil
  dragFrame = nil
end

local function startDrag()
  if not visible or not wv then return end
  stopDrag(false)
  local p = hs.mouse.absolutePosition()
  local f = wv:frame()
  dragOrigin = { x = p.x, y = p.y }
  dragFrame = { x = f.x, y = f.y, w = f.w, h = f.h }
  dragTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp,
  }, function(e)
    if e:getType() == hs.eventtap.event.types.leftMouseUp then
      stopDrag(true)
      return false
    end
    local q = e:location()
    wv:frame({
      x = dragFrame.x + (q.x - dragOrigin.x),
      y = dragFrame.y + (q.y - dragOrigin.y),
      w = dragFrame.w,
      h = dragFrame.h,
    })
    return true
  end)
  dragTap:start()
end

local function hide(restoreFocus)
  if not visible then return end
  stopDrag(false)
  visible = false
  focusedOnce = false
  if wv then wv:hide() end
  if restoreFocus and targetBundle then
    local app = hs.application.get(targetBundle)
    if app then app:activate() end
  end
end

local function copyItem(id)
  local item = db.get(id)
  if not item then return end
  hs.pasteboard.setContents(item.body)
  capture.markSelfWrite()
  hide(true)
end

local function pasteItem(id)
  local item = db.get(id)
  if not item then return end
  hs.pasteboard.setContents(item.body)
  capture.markSelfWrite()

  local target = targetBundle and hs.application.get(targetBundle) or nil
  hide(false)
  if not target then return end

  target:activate()
  local deadline = hs.timer.secondsSinceEpoch() + config.pasteFocusTimeout
  local function attempt()
    if visible then return end
    local front = hs.application.frontmostApplication()
    if front and front:bundleID() == targetBundle then
      hs.eventtap.keyStroke({ "cmd" }, "v", 0, target)
    elseif hs.timer.secondsSinceEpoch() < deadline then
      hs.timer.doAfter(0.03, attempt)
    end
  end
  hs.timer.doAfter(0.02, attempt)
end

local function onMessage(msg)
  local body = type(msg) == "table" and (msg.body or msg) or nil
  if type(body) ~= "table" then return end
  local t = body.type
  if t == "ready" then
    sendItems()
  elseif t == "search" then
    currentQuery = tostring(body.q or "")
    sendItems()
  elseif t == "expand" then
    local item = db.get(body.id)
    if item and wv then
      local text, truncated = expandBody(item.body)
      wv:evaluateJavaScript("window.expand(" .. hs.json.encode({
        id = tonumber(item.id),
        body = text,
        truncated = truncated,
      }) .. ")")
    end
  elseif t == "drag-start" then
    startDrag()
  elseif t == "delete" then
    db.delete(body.id)
    sendItems()
  elseif t == "copy" then
    copyItem(body.id)
  elseif t == "paste" then
    pasteItem(body.id)
  elseif t == "close" then
    hide(true)
  end
end

local function create()
  uc = hs.webview.usercontent.new("cliphistory")
  uc:setCallback(onMessage)

  wv = hs.webview.new({ 0, 0, config.panelWidth, config.panelHeight }, { developerExtrasEnabled = true }, uc)
  wv:windowStyle({ "borderless" })
  wv:level(hs.drawing.windowLevels.floating)
  wv:behaviorAsLabels({ "moveToActiveSpace", "fullScreenAuxiliary" })
  wv:allowTextEntry(true)
  wv:deleteOnClose(false)
  wv:transparent(true)
  wv:windowCallback(function(action, _, state)
    if action == "focusChange" then
      if state then
        focusedOnce = true
      elseif visible and focusedOnce then
        hide(false)
      end
    end
  end)
  wv:url("file://" .. UI_PATH)
end

local wakeWatcher

function M.start()
  if wakeWatcher then return end
  wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake and visible then
      hide(false)
    end
  end)
  wakeWatcher:start()
end

function M.stop()
  stopDrag(false)
  if wakeWatcher then
    wakeWatcher:stop()
    wakeWatcher = nil
  end
  if wv then
    wv:delete()
    wv = nil
  end
  visible = false
  focusedOnce = false
end

local function restoreFrame()
  local screen = targetScreen()
  local sf = screen:fullFrame()
  local saved = hs.settings.get("ClipHistory.panelFrame")
  if type(saved) == "table" and saved.x and saved.y and saved.w and saved.h then
    local cx, cy = saved.x + saved.w / 2, saved.y + saved.h / 2
    if cx >= sf.x and cx < sf.x + sf.w and cy >= sf.y and cy < sf.y + sf.h then
      return saved
    end
  end
  return panelFrameOn(screen)
end

function M.show()
  if not wv then create() end
  local front = hs.application.frontmostApplication()
  targetBundle = front and front:bundleID()

  currentQuery = ""
  focusedOnce = false
  wv:frame(restoreFrame())
  wv:show()
  wv:bringToFront()
  visible = true

  local hsApp = hs.application.get("Hammerspoon")
  if hsApp then hsApp:activate() end

  wv:evaluateJavaScript("window.reset && window.reset()")
  sendItems()

  hs.timer.doAfter(0.06, function()
    if visible then
      wv:evaluateJavaScript("var e=document.querySelector('.panel-head input'); if (e) e.focus();")
    end
  end)
end

function M.hide()
  hide(true)
end

function M.toggle()
  if visible then hide(true) else M.show() end
end

function M.isVisible()
  return visible
end

function M.frame()
  if wv then return wv:frame() end
end

return M
