local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local grip = require("dadbod-grip")
local connections = require("dadbod-grip.connections")
local picker = require("dadbod-grip.grip_picker")
local ui = require("dadbod-grip.ui")
local eq = H.eq

local function write(path, rows)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(rows) }, path)
end
local function raw(path) return table.concat(vim.fn.readfile(path), "\n") end
local function read(path) return vim.json.decode(raw(path)) end
local function capture()
  local original, opts = picker.open
  picker.open = function(value) opts = value end
  local ok, err = pcall(connections.pick)
  picker.open = original
  assert(ok, err)
  return assert(opts, "picker did not open")
end
local function selected(opts, id)
  for _, row in ipairs(opts.items) do if row.id == id then return row end end
  error("missing selected fixture row " .. id)
end
local function stores(c)
  return c.root .. "/project/.grip/connections.json", c.root .. "/home/.grip/connections.json"
end

H.test("C01 global same-name deletion preserves local peer byte-for-byte", function(c)
  local loc, glob = stores(c)
  write(loc, { { id = "local", name = "same", url = "sqlite:" .. c.root .. "/local.db", color = "green" } })
  write(glob, {
    { id = "global", name = "same", url = "sqlite:" .. c.root .. "/global.db", mode = "ro", color = "red" },
    { id = "other", name = "other", url = "sqlite:" .. c.root .. "/other.db" },
  })
  local before = raw(loc)
  local opts = capture()
  opts.on_delete(selected(opts, "global"), function() end)
  eq(raw(loc), before, "local registry must not change")
  eq(#read(glob), 1)
  eq(read(glob)[1].id, "other")
end)

H.test("C02 same-URL shadow deletes owning local profile not display-global profile", function(c)
  local loc, glob = stores(c)
  local url = "sqlite:" .. c.root .. "/shared.db"
  write(loc, { { id = "local", name = "local shadow", url = url, color = "green" } })
  write(glob, { { id = "global", name = "global original", url = url, color = "red" } })
  local before = raw(glob)
  local opts = capture()
  opts.on_delete(selected(opts, "local"), function() end)
  eq(read(loc), {})
  eq(raw(glob), before, "global profile has an independent identity")
end)

H.test("C03 custom registry deletion never leaks to project or home registry", function(c)
  local loc, glob = stores(c)
  local custom = c.root .. "/custom.json"
  local url = "sqlite:" .. c.root .. "/one.db"
  local profile = { id = "one", name = "same", url = url }
  write(loc, { profile }); write(glob, { profile }); write(custom, { profile })
  local before_local, before_global = raw(loc), raw(glob)
  grip.setup({ discovery = false, connections_path = custom })
  local opts = capture()
  opts.on_delete(selected(opts, "one"), function() end)
  eq(read(custom), {})
  eq(raw(loc), before_local)
  eq(raw(glob), before_global)
end)

H.test("C04 stale selected identity cannot delete a replacement with same name", function(c)
  local loc, glob = stores(c)
  write(loc, { { id = "old", name = "same", url = "sqlite:" .. c.root .. "/old.db" } })
  write(glob, {})
  local opts = capture()
  local row = selected(opts, "old")
  write(loc, { { id = "replacement", name = "same", url = "sqlite:" .. c.root .. "/new.db" } })
  local before = raw(loc)
  opts.on_delete(row, function() end)
  eq(raw(loc), before, "stale selector must not match by name alone")
end)

H.test("C05 cancel preserves both registries exactly", function(c)
  local loc, glob = stores(c)
  write(loc, { { id = "local", name = "same", url = "sqlite:" .. c.root .. "/local.db" } })
  write(glob, { { id = "global", name = "same", url = "sqlite:" .. c.root .. "/global.db" } })
  local before_local, before_global = raw(loc), raw(glob)
  ui.confirm = function() return false end
  local opts = capture()
  opts.on_delete(selected(opts, "global"), function() error("cancel must not refresh as deletion") end)
  eq(raw(loc), before_local)
  eq(raw(glob), before_global)
end)

H.test("C06 same-name rows within one registry delete only selected URL and ID", function(c)
  local loc, glob = stores(c)
  write(loc, {
    { id = "one", name = "same", url = "sqlite:" .. c.root .. "/one.db" },
    { id = "two", name = "same", url = "sqlite:" .. c.root .. "/two.db" },
  })
  write(glob, {})
  local opts = capture()
  opts.on_delete(selected(opts, "two"), function() end)
  eq(#read(loc), 1)
  eq(read(loc)[1].id, "one")
end)

H.test("C07 unselected valid profile retains extension fields and nested values", function(c)
  local loc, glob = stores(c)
  local survivor = {
    id = "keep", name = "keep", url = "sqlite:" .. c.root .. "/keep.db",
    type = "sqlite", label = "User annotation", custom = { nested = { "one", "two" }, enabled = false },
    mode = "ro", color = "green", last_used = 73,
    attachments = { { alias = "extra", dsn = "${FIXTURE_DSN}" } },
  }
  write(loc, { { id = "delete", name = "delete", url = "sqlite:" .. c.root .. "/delete.db" }, survivor })
  write(glob, {})
  local opts = capture()
  opts.on_delete(selected(opts, "delete"), function() end)
  eq(read(loc), { survivor }, "deleting a peer must not reconstruct unselected profiles from a whitelist")
end)

H.test("C08 rounded numeric ID cannot authorize deletion of a stale replacement", function(c)
  local loc, glob = stores(c)
  local function numeric_profile(id)
    vim.fn.writefile({ '[{"id":' .. id .. ',"name":"same","url":"sqlite:' .. c.root .. '/same.db"}]' }, loc)
  end
  write(glob, {})
  numeric_profile("9007199254740992")
  local opts = capture()
  local row
  for _, item in ipairs(opts.items) do if item.name == "same" then row = item end end
  assert(row, "reader exposes the numeric-ID saved profile")
  numeric_profile("9007199254740993")
  local before = raw(loc)
  opts.on_delete(row, function() end)
  eq(raw(loc), before, "approximate numeric equality is not proof of persisted identity")
end)

H.finish("safety_adversarial_connections_spec")
