-- DuckDB struct fields must not inherit same-named base-table edit targets.

if vim.fn.executable("duckdb") ~= 1 then
  if vim.env.GRIP_REQUIRE_DUCKDB == "1" then
    error("duckdb_projection_edit_safety_spec: duckdb missing while GRIP_REQUIRE_DUCKDB=1")
  end
  print("SKIP: duckdb_projection_edit_safety_spec (duckdb not found)")
  print("duckdb_projection_edit_safety_spec: 0 passed, 0 failed (skipped)")
  return
end

local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")
local sql = require("dadbod-grip.sql")

local pass, fail = 0, 0
local fixture = vim.fn.tempname() .. "_projection.duckdb"
local url = "duckdb:" .. fixture

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function cleanup()
  cleanup_grids()
  vim.fn.delete(fixture)
  vim.fn.delete(fixture .. ".wal")
end

local setup_output = vim.fn.system({ "duckdb", "-bail", fixture }, [[
CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  details STRUCT(status VARCHAR),
  status VARCHAR,
  orders STRUCT(status VARCHAR),
  o STRUCT(status VARCHAR),
  "union" VARCHAR,
  "intersect" VARCHAR,
  "except" VARCHAR,
  keyword_fields STRUCT("union" VARCHAR, "intersect" VARCHAR, "except" VARCHAR)
);
INSERT INTO orders VALUES (
  1, {'status': 'nested'}, 'base', {'status': 'nested'}, {'status': 'nested'},
  'base', 'base', 'base', {'union': 'nested', 'intersect': 'nested', 'except': 'nested'}
);
]])
if vim.v.shell_error ~= 0 then
  cleanup()
  error("could not create DuckDB projection fixture: " .. setup_output)
end

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
    (msg or "") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function open_query(query_sql)
  cleanup_grids()
  grip.open(query_sql, url, { from_pad = true })
  local bufnr, session = next(view._sessions)
  assert(bufnr and session, "expected a grid session")
  return session
end

local function assert_grid_readonly(session)
  eq(session.state.readonly, true, "result must be read-only")
  eq(session.state.table_name, nil, "result must not expose a mutation table")
  eq(view._is_editable(session), false, "grid edit actions must stay disabled")
end

local function assert_struct_readonly(query_sql)
  local session = open_query(query_sql)
  eq(table.concat(session.state.columns, ","), "id,status", "projected column names")
  eq(session.state.rows[1][2], "nested", "displayed value comes from the struct")
  assert_grid_readonly(session)
end

for _, case in ipairs({
  { "struct expansion", "SELECT id, details.* FROM orders" },
  { "struct field", "SELECT id, details.status FROM orders" },
  { "table-qualified struct field", "SELECT id, orders.details.status FROM orders" },
  { "alias-qualified struct field", "SELECT o.id, o.details.status FROM orders AS o" },
  { "quoted struct field", 'SELECT id, "details"."status" FROM orders' },
  { "struct field using an aliased-away table name", "SELECT id, orders.status FROM orders AS o" },
}) do
  test(case[1] .. " stays read-only", function()
    assert_struct_readonly(case[2])
  end)
end

test("continued escape string cannot hide a UNION", function()
  assert_struct_readonly([[
SELECT id, status FROM orders WHERE status = E''
'\' -- ' UNION ALL SELECT id, details.status FROM orders
]])
end)

local function assert_base_editable(query_sql, table_name, quoted_table)
  local session = open_query(query_sql)
  eq(session.state.table_name, table_name, "base table")
  eq(session.state.readonly, false, "base-table projection must stay editable")
  eq(session.state.pks[1], "id", "primary key")
  eq(view._is_editable(session), true, "grid edit actions must stay enabled")
  local status_idx
  for i, column in ipairs(session.state.columns) do
    if column == "status" then status_idx = i end
  end
  assert(status_idx, "expected a status column")
  eq(session.state.rows[1][status_idx], "base", "displayed value comes from the base column")

  local changed = data.add_change(session.state, 1, "status", "changed")
  local preview = sql.preview_staged(
    session.state.table_name, data.get_updates(changed), {}, {})
  eq(preview,
    "UPDATE " .. quoted_table .. ' SET "status" = \'changed\' WHERE "id" = \'1\';',
    "staged update must target the displayed base-table column")
end

for _, case in ipairs({
  { "table wildcard", "SELECT orders.* FROM orders" },
  { "table alias wildcard", "SELECT o.* FROM orders AS o" },
  { "table-qualified columns", "SELECT orders.id, orders.status FROM orders" },
  { "alias columns with a same-named struct", "SELECT o.id, o.status FROM orders AS o" },
  { "quoted alias columns", 'SELECT "o"."id", "o"."status" FROM orders AS "o"' },
  { "LEFT function filter", "SELECT id, status FROM orders WHERE left(status, 1) = 'b'" },
  { "RIGHT function ordering", "SELECT id, status FROM orders ORDER BY right(status, 1)" },
  {
    "dollar-quoted filter containing SQL keywords",
    "SELECT id, status FROM orders "
      .. "WHERE $$LEFT JOIN UNION FROM orders$$ = 'LEFT JOIN UNION FROM orders'",
  },
  {
    "nested list filter",
    [=[SELECT id, status FROM orders WHERE [[status]] = [['base']]]=],
  },
  {
    "literal backslash path filter",
    [[SELECT id, status FROM orders WHERE 'C:\data\orders' = 'C:\data\orders']],
  },
}) do
  test(case[1] .. " stays editable", function()
    assert_base_editable(case[2], "orders", '"orders"')
  end)
end

test("schema-qualified columns stay editable", function()
  assert_base_editable(
    "SELECT main.orders.id, main.orders.status FROM main.orders",
    "main.orders", '"main"."orders"')
end)

for _, qualifier in ipairs({ "orders", "keyword_fields" }) do
  test(qualifier .. " keyword-named fields preserve direct-column editing", function()
    local value = qualifier == "orders" and "base" or "nested"
    for _, keyword in ipairs({ "union", "intersect", "except" }) do
      local field = qualifier .. "." .. keyword
      for _, tail in ipairs({ "WHERE " .. field .. " = '" .. value .. "'", "ORDER BY " .. field }) do
        assert_base_editable("SELECT id, status FROM orders " .. tail, "orders", '"orders"')
      end
    end
  end)
end

test("set operations after qualified keyword filters stay read-only", function()
  for _, operation in ipairs({ "UNION", "INTERSECT", "EXCEPT" }) do
    for _, qualifier in ipairs({ "orders", "keyword_fields" }) do
      local value = qualifier == "orders" and "base" or "nested"
      local session = open_query("SELECT id, status FROM orders WHERE "
        .. qualifier .. "." .. operation:lower() .. " = '" .. value .. "' "
        .. operation .. " SELECT id, status FROM orders WHERE id = "
        .. (operation == "EXCEPT" and "2" or "1"))
      eq(table.concat(session.state.columns, ","), "id,status", "direct output columns")
      eq(session.state.rows[1][2], "base", "set operation returns the fixture row")
      assert_grid_readonly(session)
    end
  end
end)

test("a trailing decimal point cannot hide a set operation", function()
  for _, operation in ipairs({ "UNION", "INTERSECT", "EXCEPT" }) do
    local session = open_query("SELECT id, status FROM orders WHERE id = 1. "
      .. operation .. " SELECT id, status FROM orders WHERE id = "
      .. (operation == "EXCEPT" and "2" or "1"))
    eq(session.state.rows[1][2], "base", "set operation returns the fixture row")
    assert_grid_readonly(session)
  end
end)

cleanup()

print(string.format("duckdb_projection_edit_safety_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
