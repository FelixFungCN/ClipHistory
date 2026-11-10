local M = {
  hotkey = { mods = { "cmd" }, key = "b" },
  dbPath = (os.getenv("HOME") or "") .. "/.hammerspoon/clipboard.db",
  panelWidth = 720,
  panelHeight = 520,
  maxItemBytes = 1024 * 1024,
  searchLimit = 200,
  pasteFocusTimeout = 1.0,
}

return M
