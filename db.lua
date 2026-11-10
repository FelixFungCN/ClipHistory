local sqlite3 = require("hs.sqlite3")
local config = require("ClipHistory.config")

local M = {}
local db

local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function chmod600(path)
  if hs.fs.attributes(path) then
    hs.execute("/bin/chmod 600 " .. shq(path))
  end
end

local function escapeLike(s)
  return (s:gsub("[\\%%_]", function(c) return "\\" .. c end))
end

local function rows(sql)
  local out = {}
  for row in db:nrows(sql) do out[#out + 1] = row end
  return out
end

function M.open(path, retried)
  local d, err = sqlite3.open(path)
  if not d then return nil, err end
  db = d

  db:exec("PRAGMA journal_mode = WAL;")
  db:exec("PRAGMA synchronous = NORMAL;")
  db:exec("PRAGMA secure_delete = ON;")

  local qc = rows("PRAGMA quick_check;")
  if not (qc[1] and qc[1].quick_check == "ok") then
    db:close()
    db = nil
    local ts = os.time()
    os.rename(path, path .. ".broken-" .. ts)
    os.rename(path .. "-wal", path .. ".broken-" .. ts .. "-wal")
    os.rename(path .. "-shm", path .. ".broken-" .. ts .. "-shm")
    if not retried then return M.open(path, true) end
    return nil, "database corrupt"
  end

  local version = 0
  local v = rows("PRAGMA user_version;")
  if v[1] then version = tonumber(v[1].user_version) or 0 end

  if version == 0 then
    db:exec([[
      CREATE TABLE IF NOT EXISTS items (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        body       TEXT    NOT NULL,
        src_bundle TEXT,
        src_name   TEXT,
        created_at INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL
      );
    ]])
    db:exec("PRAGMA user_version = 1;")
  elseif version ~= 1 then
    return nil, "unknown schema version " .. tostring(version)
  end

  chmod600(path)
  chmod600(path .. "-wal")
  chmod600(path .. "-shm")
  return true
end

function M.close()
  if db then db:close(); db = nil end
end

local function lastItem()
  local r = rows("SELECT id, body FROM items ORDER BY id DESC LIMIT 1")
  return r[1]
end

function M.insert(item)
  local now = os.time()
  local last = lastItem()
  if last and last.body == item.body then
    local stmt = db:prepare("UPDATE items SET created_at = ?, src_bundle = ?, src_name = ? WHERE id = ?")
    if not stmt then return nil end
    stmt:bind_values(now, item.src_bundle, item.src_name, last.id)
    stmt:step()
    stmt:finalize()
    return tonumber(last.id)
  end

  local stmt = db:prepare("INSERT INTO items (body, src_bundle, src_name, created_at, size_bytes) VALUES (?, ?, ?, ?, ?)")
  if not stmt then return nil end
  stmt:bind_values(item.body, item.src_bundle, item.src_name, now, #item.body)
  stmt:step()
  stmt:finalize()
  return tonumber(db:last_insert_rowid())
end

function M.get(id)
  local stmt = db:prepare("SELECT id, body, src_bundle, src_name, created_at FROM items WHERE id = ?")
  if not stmt then return nil end
  stmt:bind_values(tonumber(id))
  local out
  for row in stmt:nrows() do out = row end
  stmt:finalize()
  return out
end

function M.search(keywords, limit)
  limit = limit or config.searchLimit
  local where, binds = {}, {}
  for _, kw in ipairs(keywords or {}) do
    if kw ~= "" then
      where[#where + 1] = "body LIKE ? ESCAPE '\\'"
      binds[#binds + 1] = "%" .. escapeLike(kw) .. "%"
    end
  end

  local sql = "SELECT id, body, src_bundle, src_name, created_at FROM items"
  if #where > 0 then sql = sql .. " WHERE " .. table.concat(where, " AND ") end
  sql = sql .. " ORDER BY id DESC LIMIT " .. limit

  local stmt = db:prepare(sql)
  if not stmt then return {} end
  if #binds > 0 then stmt:bind_values(table.unpack(binds)) end
  local out = {}
  for row in stmt:nrows() do out[#out + 1] = row end
  stmt:finalize()
  return out
end

function M.delete(id)
  local stmt = db:prepare("DELETE FROM items WHERE id = ?")
  if not stmt then return false end
  stmt:bind_values(tonumber(id))
  stmt:step()
  stmt:finalize()
  return true
end

function M.count()
  local r = rows("SELECT COUNT(*) AS n FROM items")
  return tonumber(r[1] and r[1].n) or 0
end

return M
