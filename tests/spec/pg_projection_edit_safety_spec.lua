-- pg_projection_edit_safety_spec.lua: PostgreSQL comments must not change
-- which displayed columns the grid treats as editable base-table columns.
-- Uses its own schema; requires GRIP_TEST_PG_URL and the psql CLI.

local URL = vim.env.GRIP_TEST_PG_URL
local REQUIRED = vim.env.GRIP_REQUIRE_POSTGRES == "1"

local function unavailable(reason)
  if REQUIRED then
    error("pg_projection_edit_safety_spec: " .. reason
      .. " while GRIP_REQUIRE_POSTGRES=1")
  end
  print("SKIP: pg_projection_edit_safety_spec (" .. reason .. ")")
  print("\npg_projection_edit_safety_spec: 0 passed, 0 failed (skipped)")
end

if not URL or URL == "" then
  unavailable("GRIP_TEST_PG_URL not set")
  return
end

local pg = require("dadbod-grip.adapters.postgresql")

if vim.fn.executable("psql") == 0 then
  unavailable("psql CLI not found")
  return
end

if not pg.ping(URL) then
  unavailable("database is unreachable")
  return
end

local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, msg)
  assert(actual == expected,
    (msg or "") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual))
end

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function open_query(query)
  cleanup_grids()
  grip.open(query, URL, { from_pad = true })
  local bufnr, session = next(view._sessions)
  assert(bufnr and session, "expected a PostgreSQL grid session")
  return session
end

-- Schema qualification preserves the reviewed query's behavior without
-- altering an existing orders table in the shared integration database.
local schema = "grip_projection_" .. vim.fn.getpid()
  .. "_" .. string.format("%.0f", vim.uv.hrtime())
local table_name = schema .. ".orders"
local created, create_err = pg.execute("CREATE SCHEMA " .. schema, URL)
assert(created, create_err)

local ok, err = pcall(function()
  local fixture, fixture_err = pg.execute(
    "CREATE TABLE " .. table_name
      .. " (id INTEGER PRIMARY KEY, total TEXT, status TEXT);"
      .. " INSERT INTO " .. table_name
      .. " VALUES (1, 'from-total', 'base-status');", URL)
  assert(fixture, fixture_err)

  test("nested comment cannot hide a column alias", function()
    local session = open_query(
      "SELECT id, total /* outer /* inner */ FROM " .. table_name
        .. " */ AS status FROM " .. table_name .. ";")
    eq(session.state.columns[2], "status", "aliased output column")
    eq(session.state.rows[1][2], "from-total", "value read from total")
    eq(session.state.table_name, nil, "aliased result has no mutation table")
    eq(session.state.readonly, true, "aliased result must stay read-only")
    eq(#session.state.pks, 0, "aliased result has no editable primary keys")
    eq(view._is_editable(session), false, "grid edits must be disabled")
  end)

  test("benign nested comments preserve direct-column editing", function()
    local session = open_query(
      "SELECT id, total /* outer /* inner */ still outer */ FROM "
        .. table_name .. ";")
    eq(session.state.rows[1][2], "from-total", "direct stored value")
    eq(session.state.table_name, table_name, "real source table")
    eq(session.state.pks[1], "id", "real primary key")
    eq(session.state.readonly, false, "direct columns remain editable")
    eq(view._is_editable(session), true, "grid edits remain enabled")
  end)

  for _, comment in ipairs({
    "/* FROM absent_projection_source */",
    "/* outer /* inner */ FROM absent_projection_source */",
  }) do
    test("source comes from the actual FROM clause: " .. comment, function()
      local session = open_query(
        "SELECT id, total " .. comment .. " FROM " .. table_name .. ";")
      eq(session.state.rows[1][2], "from-total", "actual source value")
      eq(session.state.table_name, table_name, "comment source is ignored")
      eq(session.state.pks[1], "id", "actual source primary key")
      eq(session.state.readonly, false, "actual source remains editable")
      eq(view._is_editable(session), true, "grid edits remain enabled")
    end)
  end
end)

cleanup_grids()
local dropped, drop_err = pg.execute("DROP SCHEMA " .. schema .. " CASCADE", URL)
assert(dropped, drop_err)
if not ok then error(err) end

print(string.format("pg_projection_edit_safety_spec: %d passed, %d failed",
  pass, fail))
if fail > 0 then os.exit(1) end
