local config = require("ClipHistory.config")
local db = require("ClipHistory.db")
local capture = require("ClipHistory.capture")

local M = {}
local log = hs.logger.new("ClipHistory.panel", "warning")

local wv, uc
local visible = false
local focusedOnce = false
local pendingFocus = false
local pageReady = false
local currentQuery = ""
local targetBundle
local hsApp
local lastFrame
local lastGen, lastQuery
local fontScale = tonumber(hs.settings.get("ClipHistory.fontScale")) or 1

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

local function buildPayload()
  local gen = db.generation()
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
  return payload, gen
end

local function sendItems()
  if not (wv and pageReady) then return end
  local payload, gen = buildPayload()
  local ok, err = pcall(function()
    wv:evaluateJavaScript("window.render(" .. hs.json.encode(payload) .. ")")
  end)
  if ok then
    lastGen, lastQuery = gen, currentQuery
  else
    log.e("render failed: " .. tostring(err))
  end
end

local function applyFontScale()
  if wv then
    wv:evaluateJavaScript("window.setFontScale(" .. tostring(fontScale) .. ")")
  end
end

local function focusSearch()
  if wv then
    wv:evaluateJavaScript("window.focusSearch && window.focusSearch()")
  end
end

local dragTap, dragOrigin, dragFrame

local function stopDrag(save)
  if dragTap then
    dragTap:stop()
    dragTap = nil
  end
  if save and wv then
    local f = wv:frame()
    lastFrame = { x = f.x, y = f.y, w = f.w, h = f.h }
    hs.settings.set("ClipHistory.panelFrame", lastFrame)
  end
  dragOrigin = nil
  dragFrame = nil
end

local function startDrag(px, py)
  if not visible or not wv then return end
  stopDrag(false)
  local f = wv:frame()
  if px and py then
    dragOrigin = { x = f.x + px, y = f.y + py }
  else
    local p = hs.mouse.absolutePosition()
    dragOrigin = { x = p.x, y = p.y }
  end
  dragFrame = { x = f.x, y = f.y, w = f.w, h = f.h }
  local dragMoved = false
  dragTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp,
  }, function(e)
    if e:getType() == hs.eventtap.event.types.leftMouseUp then
      stopDrag(dragMoved)
      if dragMoved and wv then
        wv:evaluateJavaScript("window.suppressClick && window.suppressClick()")
      end
      return false
    end
    local q = e:location()
    local dx, dy = q.x - dragOrigin.x, q.y - dragOrigin.y
    if not dragMoved then
      if math.abs(dx) < 4 and math.abs(dy) < 4 then return true end
      dragMoved = true
    end
    wv:frame({
      x = dragFrame.x + dx,
      y = dragFrame.y + dy,
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
  pendingFocus = false
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
    pageReady = true
    sendItems()
    applyFontScale()
    if visible then focusSearch() end
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
  elseif t == "font-scale" then
    fontScale = tonumber(body.value) or 1
    hs.settings.set("ClipHistory.fontScale", fontScale)
  elseif t == "drag-start" then
    startDrag(tonumber(body.x), tonumber(body.y))
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
        if pendingFocus then
          pendingFocus = false
          focusSearch()
        end
      elseif visible and focusedOnce then
        hide(false)
      end
    end
  end)
  pageReady = false
  wv:url("file://" .. UI_PATH)
end

local wakeWatcher

function M.start()
  if wakeWatcher then return end
  hsApp = hs.application.get("Hammerspoon")
  create()
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
  pageReady = false
  visible = false
  focusedOnce = false
  pendingFocus = false
  lastGen, lastQuery = nil, nil
end

local function framesEqual(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
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
  pendingFocus = true

  local f = restoreFrame()
  if not framesEqual(f, lastFrame) then
    wv:frame(f)
    lastFrame = f
  end

  -- 面板出现前先在隐藏状态把内容准备好，显示时直接是成品
  if pageReady then
    if db.generation() ~= lastGen or lastQuery ~= "" then
      local payload, gen = buildPayload()
      wv:evaluateJavaScript("window.prepare(" .. hs.json.encode(payload) .. ")")
      lastGen, lastQuery = gen, currentQuery
    else
      wv:evaluateJavaScript("window.prepareEmpty()")
    end
  end

  wv:show()
  wv:bringToFront()
  visible = true
  if not hsApp then hsApp = hs.application.get("Hammerspoon") end
  if hsApp then hsApp:activate() end
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
