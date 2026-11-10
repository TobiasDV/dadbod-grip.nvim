-- connections_spec.lua -- characterization tests for M.switch()'s single-pass
-- read/mutate/write behavior and persistence scope.
-- M.switch() used to read the local connections file up to 4 times and write
-- it up to twice per call; it now reads each registry at most once for the
-- mutation and writes only the owning registry. These
-- tests pin the observable behavior of that rewrite against real files in an
-- isolated temp directory, since nothing in the suite previously exercised it.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

-- Rebound to a freshly loaded module by every with_real_file() below, because
-- connections.lua keeps per-URL health in a module-local table with no reset
-- hook: without the reload, a switch() in one test leaves its URL marked "ok"
-- for every later case.
local connections = require("dadbod-grip.connections")
local picker_opts

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

-- ── real-file harness ────────────────────────────────────────────────────
-- M.switch() is heavily side-effecting: it opens the grid/schema/query pad
-- via vim.schedule(). These tests only care about the synchronous file-write
-- behavior, so UI-facing modules are stubbed to no-ops. Pending vim.schedule
-- callbacks are flushed with vim.wait() *before* teardown (while the stubs
-- and the fake project/home dirs are still live), so nothing fires later
-- against an already-deleted temp directory or a restored real module.
--
-- Isolation notes:
-- - paths.project_root is patched (not paths.grip_dir): connections.lua
--   captures `local grip_dir = paths.grip_dir` at require time, so patching
--   the grip_dir *field* on the module later would not affect that alias.
--   The captured function still calls `M.project_root()` dynamically though,
--   so patching project_root reaches it either way.
-- - vim.fn.expand("~") is patched to a fake home so the global connections
--   file used by tests never touches the real ~/.grip/connections.json.
-- - the module under test is reloaded per call so its module-local state
--   (notably the _health table set_health writes to) starts empty; the
--   file-level `connections` alias is rebound to that instance.
local function with_real_file(fn)
  local project_dir = vim.fn.tempname() .. "_grip_conn_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(fake_home, "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_g_db = vim.g.db
  local orig_g_dbs = vim.g.dbs
  local orig_opts = grip.get_opts()
  local orig_open = grip.open
  local orig_open_welcome = grip.open_welcome
  local orig_schema = package.loaded["dadbod-grip.schema"]
  local orig_query_pad = package.loaded["dadbod-grip.query_pad"]
  local orig_completion = package.loaded["dadbod-grip.completion"]
  local orig_duckdb = package.loaded["dadbod-grip.adapters.duckdb"]
  local orig_connections = package.loaded["dadbod-grip.connections"]
  local orig_picker = package.loaded["dadbod-grip.grip_picker"]
  local orig_docker = package.loaded["dadbod-grip.sources.docker_localdb"]

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  vim.notify = function() end
  grip.setup({})
  package.loaded["dadbod-grip.sources.docker_localdb"] = {
    fetch = function() return { connections = {} } end,
  }
  vim.g.db, vim.g.dbs = nil, nil
  picker_opts = nil
  package.loaded["dadbod-grip.grip_picker"] = { open = function(opts) picker_opts = opts end }
  grip.open = function() end
  grip.open_welcome = function() end
  package.loaded["dadbod-grip.schema"] = {
    is_open = function() return true end,
    refresh = function() end,
    toggle = function() end,
    get_winid = function() return nil end,
    -- switch() prefetches the schema under the preloader, before it opens
    -- any window; the double has to answer that call too.
    prefetch = function() return {} end,
  }
  package.loaded["dadbod-grip.query_pad"] = { open = function() end }
  package.loaded["dadbod-grip.completion"] = { invalidate = function() end, warm_schema = function() end }
  package.loaded["dadbod-grip.adapters.duckdb"] = { load_attachments = function() end }
  package.loaded["dadbod-grip.connections"] = nil
  connections = require("dadbod-grip.connections")

  local local_grip = project_dir .. "/.grip"
  local global_grip = fake_home .. "/.grip"
  local ok, err = pcall(fn, local_grip, global_grip)
  vim.wait(50) -- flush any vim.schedule() callbacks queued by switch()

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  vim.g.db = orig_g_db
  vim.g.dbs = orig_g_dbs
  grip.setup(orig_opts)
  grip.open = orig_open
  grip.open_welcome = orig_open_welcome
  package.loaded["dadbod-grip.schema"] = orig_schema
  package.loaded["dadbod-grip.query_pad"] = orig_query_pad
  package.loaded["dadbod-grip.completion"] = orig_completion
  package.loaded["dadbod-grip.adapters.duckdb"] = orig_duckdb
  package.loaded["dadbod-grip.connections"] = orig_connections
  package.loaded["dadbod-grip.grip_picker"] = orig_picker
  package.loaded["dadbod-grip.sources.docker_localdb"] = orig_docker
  connections = orig_connections

  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

--- switch() reports which branch it took from inside a scheduled callback --
--- it notifies after the workspace is on screen, not before it is built -- so
--- the queue has to be flushed before the message can be read.
local function flush_schedules()
  vim.wait(100)
end

local function read_connections_json(dir)
  return vim.fn.json_decode(table.concat(vim.fn.readfile(dir .. "/connections.json"), "\n"))
end

local function write_connections_json(dir, entries)
  paths.ensure_dir(dir)
  vim.fn.writefile({ vim.fn.json_encode(entries) }, dir .. "/connections.json")
end

local function picker_entry(url)
  connections.pick()
  assert(picker_opts, "picker opened")
  for _, c in ipairs(picker_opts.items) do
    if c.url == url then return c end
  end
  error("connection missing from picker")
end

-- ── switching to an existing connection (by name, and without one) ────────

test("switch: switching to an existing connection by name upserts + touches, single write", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")

    connections.switch("postgresql://u:p@h/db", "mydb", "postgresql", {})

    local data = read_connections_json(local_grip)
    eq(#data, 1, "still one entry, renamed not duplicated")
    eq(data[1].name, "mydb", "renamed")
    eq(data[1].url, "postgresql://u:p@h/db", "url unchanged")
    eq(data[1].type, "postgresql", "type unchanged")
    assert(data[1].last_used > 100, "last_used touched")
  end)
end)

test("switch: switching to an existing connection without a name still touches last_used", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "saved-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")

    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})

    local data = read_connections_json(local_grip)
    eq(#data, 1, "still one entry")
    eq(data[1].name, "saved-name", "name preserved (no rename requested)")
    assert(data[1].last_used > 100, "last_used touched even without a name")
  end)
end)

-- ── write is skipped when nothing changed, happens when it did ────────────

test("switch: write is skipped when nothing changed (unnamed, not-yet-saved URL)", function()
  with_real_file(function(local_grip)
    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0,
      "no connections.json created -- nothing to persist for a nameless, unsaved connection")
  end)
end)

test("switch: write happens when a name is given for a brand-new URL", function()
  with_real_file(function(local_grip)
    -- Note: the persisted `type` field comes from is_file_url(), not the
    -- conn_type parameter -- that's pre-existing M.add() behavior, unchanged
    -- by this refactor. postgresql:// isn't a file url, so type stays nil.
    connections.switch("postgresql://u:p@h/db", "brand-new", "postgresql", {})
    local data = read_connections_json(local_grip)
    eq(#data, 1, "inserted")
    eq(data[1].name, "brand-new", "name")
    eq(data[1].type, nil, "type field derives from is_file_url, not conn_type")
  end)
end)

-- ── module-local health state does not leak between tests ─────────────────
-- Placed after the switch() cases above on purpose: they all switch to this
-- same URL, so without the per-test module reload in with_real_file the first
-- assertion below reads their leftover "ok" instead of a clean slate.

test("switch: health state starts clean in every test, then switch records it", function()
  with_real_file(function()
    eq(connections.get_health("postgresql://u:p@h/db"), "unknown",
      "no health carried in from an earlier test's switch()")
    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})
    eq(connections.get_health("postgresql://u:p@h/db"), "ok", "switch marks the connection healthy")
  end)
end)

-- ── type precedence across registries ──────────────────────────────────────
-- Signal: the only externally-observable trace of resolved_type is the
-- notify message ("opening" for type == "file" vs "connected to" otherwise).
-- customscheme:// is not detected as a file url by the is_file_url()
-- heuristic, so seeding the global file with type = "file" for it makes the
-- notify text a faithful proxy for "was the global file's type honored".

test("switch: global file is consulted when no local match and no configured path", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("opening", 1, true),
      "type resolved from global file, file-open branch should have run: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when connections_path is configured", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    grip.setup({ connections_path = local_grip .. "/connections.json" })

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "global type must be ignored when connections_path is configured: " .. vim.inspect(notified))
  end)
end)

test("switch: an explicit conn_type wins over the globally stored type", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, "postgresql", {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "explicit conn_type param must win over global lookup: " .. vim.inspect(notified))
  end)
end)

test("switch: the locally stored type wins over the global type", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(local_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "local", url = "customscheme://host/db", type = "postgresql", last_used = 1 },
    }) }, local_grip .. "/connections.json")
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "locally-known type must win over global lookup: " .. vim.inspect(notified))
  end)
end)

-- A global-only profile must stay global: a metadata-free local shadow used
-- to win entry_for() immediately after the first selection and prevent the
-- second selection (or any later query) from resolving its env_file.
test("switch: selecting a global-only templated profile twice keeps its settings and scope", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    local env_file = global_grip .. "/fixture.env"
    local url = "${GRIP_TEST_GLOBAL_PROFILE_URL}"
    local expanded = "postgresql://fixture:fixture@invalid.example/global"
    vim.fn.writefile({ "GRIP_TEST_GLOBAL_PROFILE_URL=" .. expanded }, env_file)
    local entry = {
      id = "conn_global_fixture", name = "global fixture", url = url, type = "postgresql",
      env_file = env_file, mode = "ro", color = "orange", last_used = 100,
      attachments = { { alias = "fixture", dsn = "sqlite:/fixture/attachment.db" } },
    }
    write_connections_json(global_grip, { entry })

    local first = picker_entry(url)
    picker_opts.on_select(first)
    local second = picker_entry(url)
    picker_opts.on_select(second)

    eq(connections.get_health(url), "ok", "both selections resolved the profile")
    eq(connections.expand_url(url), expanded, "later queries still resolve via env_file")
    eq(vim.g.db, url, "active URL stays templated")
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "no project copy created")
    eq(connections.current_mode(url), "ro", "read-only mode survives selection")
    local stored = read_connections_json(global_grip)[1]
    assert(stored.last_used > 100, "global MRU persisted")
    stored.last_used = entry.last_used
    assert(vim.deep_equal(stored, entry), "every persisted profile field survives")
    eq(connections.entry_for(url).source, "global", "lookups still use the global profile")
  end)
end)

test("switch: unnamed global selection with an explicit type updates only global MRU", function()
  with_real_file(function(local_grip, global_grip)
    local url = "postgresql://fixture:fixture@invalid.example/global"
    write_connections_json(local_grip, { { name = "local", url = "sqlite:/fixture/local.db", last_used = 7 } })
    write_connections_json(global_grip, {
      { name = "global", url = url, type = "postgresql", last_used = 1 },
      { name = "other", url = "sqlite:/fixture/other.db", last_used = 100 },
    })
    local before = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")

    assert(connections.switch(url, nil, "postgresql"), "switch committed")

    local stored = read_connections_json(global_grip)
    assert(stored[1].last_used > 100, "MRU written despite explicit type and no name")
    eq(stored[2].last_used, 100, "unselected global profile unchanged")
    eq(table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n"), before,
      "unrelated local file remains byte-identical")
    picker_entry(url)
    local first_global
    for _, c in ipairs(picker_opts.items) do
      if c.source == "global" then first_global = c; break end
    end
    eq(first_global.url, url, "reopened picker orders the used global profile first")
  end)
end)

test("switch: intentional local override keeps its metadata and touches only local MRU", function()
  with_real_file(function(local_grip, global_grip)
    local url = "postgresql://fixture:fixture@invalid.example/shared"
    write_connections_json(local_grip, {
      { id = "conn_local", name = "local", url = url, mode = "ro", color = "orange", last_used = 1 },
    })
    write_connections_json(global_grip, {
      { id = "conn_global", name = "global", url = url, mode = "rw", color = "red", last_used = 2 },
    })
    local before = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")

    local selected = picker_entry(url)
    picker_opts.on_select(selected)

    local stored = read_connections_json(local_grip)[1]
    eq(stored.id, "conn_local", "local identity wins even with the global picker badge")
    eq(stored.color, "orange", "local settings win")
    eq(connections.current_mode(url), "ro", "local mode wins")
    assert(stored.last_used > 1, "local MRU updated")
    eq(table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n"), before,
      "shadowed global profile remains byte-identical")
  end)
end)

test("switch: configured path owns persistence even when the URL also exists globally", function()
  with_real_file(function(local_grip, global_grip)
    local url = "postgresql://fixture:fixture@invalid.example/shared"
    local custom_dir = local_grip .. "/custom"
    write_connections_json(global_grip, { { name = "global", url = url, mode = "ro", last_used = 2 } })
    grip.setup({ connections_path = custom_dir .. "/connections.json" })
    local before = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")

    connections.switch(url, "custom", "postgresql")
    local custom = read_connections_json(custom_dir)[1]
    custom.mode, custom.color = "rw", "green"
    custom.env_file = custom_dir .. "/fixture.env"
    custom.attachments = { { alias = "custom", dsn = "sqlite:/fixture/custom.db" } }
    write_connections_json(custom_dir, { custom })
    connections.switch(url, "custom", "postgresql")

    local stored = read_connections_json(custom_dir)
    eq(#stored, 1, "one custom profile after repeated selection")
    eq(stored[1].name, "custom", "new profile saved to configured file")
    eq(stored[1].id, custom.id, "custom identity preserved")
    eq(stored[1].color, "green", "custom color preserved")
    eq(stored[1].env_file, custom.env_file, "custom env_file preserved")
    assert(vim.deep_equal(stored[1].attachments, custom.attachments), "custom attachments preserved")
    assert(stored[1].last_used > 2, "custom MRU persisted")
    eq(connections.current_mode(url), "rw", "global mode ignored")
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "default project file untouched")
    eq(table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n"), before,
      "global file untouched")
  end)
end)

test("switch: a failed global template does not touch either registry", function()
  with_real_file(function(local_grip, global_grip)
    local url = "${GRIP_TEST_MISSING_GLOBAL_URL}"
    write_connections_json(global_grip, {
      { name = "global", url = url, env_file = global_grip .. "/missing.env", last_used = 1 },
    })
    local before = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")

    eq(connections.switch(url, "global", "postgresql"), false, "unresolved template aborts")

    eq(table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n"), before,
      "failed selection does not write global MRU")
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "failed selection does not create a shadow")
  end)
end)

test("switch: global DuckDB attachments restore from their original profile", function()
  with_real_file(function(local_grip, global_grip)
    local url = "duckdb:/fixture/global.duckdb"
    local attachments = { { alias = "fixture", dsn = "sqlite:/fixture/attachment.db" } }
    write_connections_json(global_grip, {
      { name = "global duck", url = url, type = "duckdb", attachments = attachments, last_used = 1 },
    })
    local captured_url, captured_atts
    package.loaded["dadbod-grip.adapters.duckdb"] = {
      load_attachments = function(u, atts) captured_url, captured_atts = u, atts end,
    }

    connections.switch(url, "global duck", "duckdb")

    eq(captured_url, url, "attachments loaded for the selected connection")
    assert(vim.deep_equal(captured_atts, attachments), "global attachments restored")
    assert(vim.deep_equal(read_connections_json(global_grip)[1].attachments, attachments),
      "attachments still persisted in global scope")
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "attachments do not create a local shadow")
  end)
end)

test("global GripAttach and GripDetach changes survive reconnect without a local copy", function()
  if vim.fn.executable("duckdb") ~= 1 then
    assert(vim.env.GRIP_REQUIRE_DUCKDB ~= "1", "DuckDB required for attachment command regression")
    print("SKIP: global attachment commands (duckdb CLI not installed)")
    return
  end
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    local env_file = global_grip .. "/attachments.env"
    local main_path = global_grip .. "/main.duckdb"
    local old_path = global_grip .. "/old.duckdb"
    local fresh_path = global_grip .. "/fresh.duckdb"
    for _, path in ipairs({ main_path, old_path, fresh_path }) do
      local result = vim.system({ "duckdb", path, "-c", "CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES (42);" },
        { text = true }):wait()
      eq(result.code, 0, "isolated DuckDB fixture seeded: " .. (result.stderr or ""))
    end
    local url, live_url = "${GRIP_TEST_GLOBAL_DUCK_URL}", "duckdb:" .. main_path
    local old_dsn, fresh_dsn = "${GRIP_TEST_GLOBAL_OLD_DSN}", "${GRIP_TEST_GLOBAL_FRESH_DSN}"
    vim.fn.writefile({
      "GRIP_TEST_GLOBAL_DUCK_URL=" .. live_url,
      "GRIP_TEST_GLOBAL_OLD_DSN=" .. old_path,
      "GRIP_TEST_GLOBAL_FRESH_DSN=" .. fresh_path,
    }, env_file)
    local profile = {
      id = "conn_global_attachments", name = "global duck", url = url, type = "duckdb",
      env_file = env_file, mode = "rw", color = "orange", last_used = 100,
      attachments = { { alias = "old", dsn = old_dsn } },
    }
    write_connections_json(global_grip, { profile })
    package.loaded["dadbod-grip.adapters.duckdb"] = nil
    local duckdb = require("dadbod-grip.adapters.duckdb")
    assert(connections.switch(url, profile.name, "duckdb"), "initial global selection succeeds")
    eq(duckdb.get_attachments(live_url)[1].alias, "old", "initial attachment restored")

    vim.cmd("GripAttach " .. fresh_dsn .. " fresh")
    eq(#duckdb.get_attachments(live_url), 2, "actual attach command updates live registry")
    local stored = read_connections_json(global_grip)[1]
    eq(#stored.attachments, 2, "actual attach command persists to global registry")
    eq(stored.attachments[2].dsn, fresh_dsn, "global persistence keeps DSN template")

    vim.cmd("GripDetach old")
    eq(#duckdb.get_attachments(live_url), 1, "actual detach command updates live registry")
    stored = read_connections_json(global_grip)[1]
    eq(#stored.attachments, 1, "actual detach command persists removal")
    eq(stored.attachments[1].alias, "fresh", "only the new attachment stays persisted")
    assert(connections.switch(url, profile.name, "duckdb"), "reconnect succeeds")
    eq(#duckdb.get_attachments(live_url), 1, "reconnect keeps the current attachment set")
    eq(duckdb.get_attachments(live_url)[1].alias, "fresh", "removed attachment is not resurrected")
    local result, err = duckdb.query("SELECT value FROM fresh.fixture", live_url)
    assert(result, err)
    eq(result.rows[1][1], "42", "reconnected attachment can query its isolated fixture")

    vim.cmd("GripDetach fresh")
    eq(read_connections_json(global_grip)[1].attachments, nil, "detaching the last attachment persists an empty set")
    assert(connections.switch(url, profile.name, "duckdb"), "reconnect without attachments succeeds")
    eq(#duckdb.get_attachments(live_url), 0, "reconnect does not resurrect the final detached attachment")
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "commands never create a project shadow")
    eq(vim.g.db, url, "active connection remains templated")
    stored = read_connections_json(global_grip)[1]
    stored.attachments, stored.last_used = nil, nil
    local expected = vim.deepcopy(profile)
    expected.attachments, expected.last_used = nil, nil
    assert(vim.deep_equal(stored, expected), "attachment changes preserve all other profile fields")
  end)
end)

test("save_attachments: a local override owns changes without rewriting its global counterpart", function()
  with_real_file(function(local_grip, global_grip)
    local url = "duckdb:/fixture/shared.duckdb"
    local local_profile = {
      id = "conn_local_attachment", name = "local", url = url, type = "duckdb",
      env_file = "/fixture/local.env", mode = "ro", color = "orange", last_used = 17,
    }
    write_connections_json(local_grip, { local_profile })
    write_connections_json(global_grip, {
      { id = "conn_global_attachment", name = "global", url = url, color = "red",
        attachments = { { alias = "global", dsn = "/fixture/global.duckdb" } } },
    })
    local before = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")
    local attachments = { { alias = "local", dsn = "/fixture/local.duckdb" } }

    connections.save_attachments(url, attachments)

    local_profile.attachments = attachments
    assert(vim.deep_equal(read_connections_json(local_grip)[1], local_profile), "local settings and attachments retained")
    eq(table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n"), before,
      "global counterpart remains byte-identical")
  end)
end)

test("save_attachments: a configured path owns changes and never falls back to global", function()
  with_real_file(function(local_grip, global_grip)
    local url = "duckdb:/fixture/shared.duckdb"
    local custom_dir = local_grip .. "/custom"
    local custom = {
      id = "conn_custom_attachment", name = "custom", url = url, type = "duckdb",
      env_file = "/fixture/custom.env", mode = "ro", color = "green", last_used = 31,
    }
    write_connections_json(custom_dir, { custom })
    write_connections_json(global_grip, { { name = "global", url = url, color = "red" } })
    grip.setup({ connections_path = custom_dir .. "/connections.json" })
    local before = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")
    local attachments = { { alias = "custom", dsn = "/fixture/custom.duckdb" } }

    connections.save_attachments(url, attachments)

    custom.attachments = attachments
    assert(vim.deep_equal(read_connections_json(custom_dir)[1], custom), "configured profile preserves every field")
    write_connections_json(custom_dir, {})
    connections.save_attachments(url, attachments)
    eq(#read_connections_json(custom_dir), 0, "missing configured profile is not copied from global")
    eq(table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n"), before, "global remains byte-identical")
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "default local registry untouched")
  end)
end)

test("save_attachments: an unsaved connection does not create a profile", function()
  with_real_file(function(local_grip, global_grip)
    connections.save_attachments("duckdb:/fixture/unsaved.duckdb", { { alias = "side", dsn = "/fixture/side.duckdb" } })
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0, "unsaved connection stays unsaved locally")
    eq(vim.fn.filereadable(global_grip .. "/connections.json"), 0, "unsaved connection stays unsaved globally")
  end)
end)

-- ── attachments-restore reads the pre-mutation snapshot ────────────────────

test("switch: attachments-restore reads the pre-mutation snapshot (rename doesn't disturb .attachments)", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old", url = "duckdb:/tmp/some.duckdb", type = "duckdb",
        attachments = { "foo.duckdb", "bar.duckdb" }, last_used = 100 },
    }) }, local_grip .. "/connections.json")

    local captured_url, captured_atts
    package.loaded["dadbod-grip.adapters.duckdb"] = {
      load_attachments = function(u, atts) captured_url, captured_atts = u, atts end,
    }

    connections.switch("duckdb:/tmp/some.duckdb", "renamed", "duckdb", {})

    eq(captured_url, "duckdb:/tmp/some.duckdb", "load_attachments called with the right url")
    assert(captured_atts ~= nil, "attachments were restored")
    eq(#captured_atts, 2, "both attachments survived the rename")
    eq(captured_atts[1], "foo.duckdb", "attachment 1")
    eq(captured_atts[2], "bar.duckdb", "attachment 2")

    local data = read_connections_json(local_grip)
    eq(data[1].name, "renamed", "renamed on disk")
    eq(#data[1].attachments, 2, "attachments preserved on disk too")
  end)
end)

-- ── output format matches the pre-refactor multi-pass sequence ─────────────
-- The old M.switch() body was, in effect, M.add(name, url) followed by
-- M.touch(url) -- two separate read+write round trips. M.add()/M.touch()
-- still exist with that exact behavior (now built on the same upsert_conn/
-- touch_conn helpers switch() uses in memory), so running them back-to-back
-- characterizes what the old switch() wrote. os.time() is pinned so both
-- sequences produce the exact same last_used and can be compared byte-for-byte.

test("switch: resulting file is byte-identical to the old add()+touch() sequence for the same inputs", function()
  local orig_os_time = os.time
  -- luacheck: push ignore 122
  os.time = function() return 1700000000 end

  local old_content, new_content
  local seed = { { name = "old-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 } }

  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode(seed) }, local_grip .. "/connections.json")
    connections.add("mydb", "postgresql://u:p@h/db")
    connections.touch("postgresql://u:p@h/db")
    old_content = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
  end)

  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode(seed) }, local_grip .. "/connections.json")
    connections.switch("postgresql://u:p@h/db", "mydb", "postgresql", {})
    new_content = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
  end)

  os.time = orig_os_time
  -- luacheck: pop

  eq(old_content, new_content, "byte-identical output for the same logical mutation")
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nconnections_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
