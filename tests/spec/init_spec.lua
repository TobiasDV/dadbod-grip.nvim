-- init_spec.lua: unit tests for resolve_query routing, is_queryable_file and
-- the welcome screen (open_welcome)
local grip = require("dadbod-grip")

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

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

-- ── is_queryable_file: path prefix ───────────────────────────────────────────

test("is_queryable_file: absolute path with .parquet", function()
  eq(grip._is_queryable_file("/data/sales.parquet"), true)
end)

test("is_queryable_file: tilde path with .csv", function()
  eq(grip._is_queryable_file("~/data/report.csv"), true)
end)

test("is_queryable_file: dot-slash with .json", function()
  eq(grip._is_queryable_file("./data.json"), true)
end)

test("is_queryable_file: dot-dot-slash with .tsv", function()
  eq(grip._is_queryable_file("../up/data.tsv"), true)
end)

test("is_queryable_file: bare name is not a file path", function()
  eq(grip._is_queryable_file("tablename"), false)
end)

-- ── is_queryable_file: extension ─────────────────────────────────────────────

test("is_queryable_file: .parquet", function()
  eq(grip._is_queryable_file("/x.parquet"), true)
end)

test("is_queryable_file: .csv", function()
  eq(grip._is_queryable_file("/x.csv"), true)
end)

test("is_queryable_file: .json", function()
  eq(grip._is_queryable_file("/x.json"), true)
end)

test("is_queryable_file: .xlsx", function()
  eq(grip._is_queryable_file("/x.xlsx"), true)
end)

test("is_queryable_file: .ndjson", function()
  eq(grip._is_queryable_file("/x.ndjson"), true)
end)

test("is_queryable_file: .jsonl", function()
  eq(grip._is_queryable_file("/x.jsonl"), true)
end)

test("is_queryable_file: shared ORC, Arrow, and IPC extensions", function()
  eq(grip._is_queryable_file("/x.orc"), true)
  eq(grip._is_queryable_file("/x.arrow"), true)
  eq(grip._is_queryable_file("/x.ipc"), true)
end)

test("is_queryable_file: .txt not supported", function()
  eq(grip._is_queryable_file("/x.txt"), false)
end)

-- ── is_queryable_file: case insensitivity ────────────────────────────────────

test("is_queryable_file: uppercase .CSV", function()
  eq(grip._is_queryable_file("/path/file.CSV"), true)
end)

-- ── resolve_query: routing ───────────────────────────────────────────────────

test("resolve_query: table name returns table spec", function()
  local spec, tbl = grip._resolve_query("users", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "users", "table_name")
end)

test("resolve_query: SELECT extracts table name from FROM clause", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "table_name should be extracted from SELECT")
end)

test("resolve_query: WITH returns raw spec", function()
  local spec = grip._resolve_query("WITH cte AS (SELECT 1) SELECT * FROM cte", 50)
  assert(spec, "spec should not be nil")
end)

test("resolve_query: TABLE extracts table name", function()
  local spec, tbl = grip._resolve_query("TABLE orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "TABLE should extract table name")
end)

test("resolve_query: nil with expand stub returns table spec", function()
  local orig = vim.fn.expand
  vim.fn.expand = function() return "users" end
  local spec, tbl = grip._resolve_query(nil, 50)
  vim.fn.expand = orig
  assert(spec, "spec should not be nil")
  eq(tbl, "users", "table_name from cword")
end)

test("resolve_query: empty string with empty expand returns nil + error", function()
  local orig = vim.fn.expand
  vim.fn.expand = function() return "" end
  local spec, err = grip._resolve_query("", 50)
  vim.fn.expand = orig
  eq(spec, nil, "spec should be nil")
  assert(err, "should return error message")
end)

test("resolve_query: lowercase 'select' returns raw spec", function()
  local spec = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
end)

-- ── resolve_query: table extraction from SELECT/TABLE ────────────────────────

test("resolve_query: SELECT with double-quoted PascalCase table", function()
  local spec, tbl = grip._resolve_query('SELECT * FROM "Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "Participant", "should unquote double-quoted table name")
end)

test("resolve_query: SELECT with backtick-quoted table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM `my_table`", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "my_table", "should unquote backtick-quoted table name")
end)

test("resolve_query: SELECT with schema-qualified table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM public.users", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "public.users", "should extract schema-qualified table name")
end)

test("resolve_query: SELECT with schema-qualified quoted table", function()
  local spec, tbl = grip._resolve_query('SELECT * FROM "public"."Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "public.Participant", "should unquote schema-qualified quoted table")
end)

test("resolve_query: SELECT with WHERE clause still extracts table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders WHERE id = 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "should extract table when WHERE clause follows")
end)

test("resolve_query: direct projected columns keep editable table metadata", function()
  local spec, tbl = grip._resolve_query("SELECT id, total FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders")
end)

test("resolve_query: qualified direct projected columns keep editable table metadata", function()
  local spec, tbl = grip._resolve_query("SELECT o.id, o.total FROM orders o", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders")
end)

test("resolve_query: MySQL backtick projected columns keep editable table metadata", function()
  local spec, tbl = grip._resolve_query("SELECT `id`, `total` FROM `orders`", 50, "mysql")
  assert(spec, "spec should not be nil")
  eq(tbl, "orders")
end)

test("resolve_query: MySQL ANSI_QUOTES columns stay editable", function()
  local spec, tbl = grip._resolve_query('SELECT "id", "total" FROM orders', 50, "mysql")
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "the adapter enables ANSI_QUOTES before each query")
end)

test("resolve_query: Unicode direct columns stay editable", function()
  for _, projection in ipairs({ "姓名", '"姓名"', "o.姓名", "name姓名2" }) do
    local _, tbl = grip._resolve_query(
      "SELECT id, " .. projection .. " FROM orders o", 50, "sqlite")
    eq(tbl, "orders", projection)
  end
end)

test("resolve_query: bare value keywords stay read-only", function()
  local cases = {
    sqlite = { "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "NULL" },
    postgresql = {
      "LOCALTIME", "LOCALTIMESTAMP", "CURRENT_CATALOG", "CURRENT_ROLE",
      "CURRENT_SCHEMA", "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER",
      "TRUE", "FALSE",
    },
    mysql = {
      "CURRENT_USER", "CURRENT_ROLE", "LOCALTIME", "LOCALTIMESTAMP",
      "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "TRUE", "FALSE",
    },
    sqlserver = { "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER" },
  }
  for kind, keywords in pairs(cases) do
    for _, keyword in ipairs(keywords) do
      local _, tbl = grip._resolve_query(
        "SELECT id, " .. keyword:lower() .. " FROM orders", 50, kind)
      eq(tbl, nil, kind .. ": " .. keyword)
    end
  end
end)

test("resolve_query: quoted or qualified keyword columns stay editable",
function()
  for _, projection in ipairs({
    '"CURRENT_TIMESTAMP"', "`CURRENT_DATE`", "[CURRENT_TIME]",
    "o.CURRENT_TIMESTAMP", "o.CURRENT_DATE", "o.CURRENT_TIME",
    "user", "true", "false",
  }) do
    local _, tbl = grip._resolve_query(
      "SELECT id, " .. projection .. " FROM orders o", 50, "sqlite")
    eq(tbl, "orders", projection)
  end
end)

test("resolve_query: MySQL executable comments stay read-only", function()
  for _, comment in ipairs({
    "/*! AS status */", "/*!80000 AS status */", "/*M! AS status */",
    "/*M!100100 AS status */",
  }) do
    local _, tbl = grip._resolve_query(
      "SELECT id, total " .. comment .. " FROM orders", 50, "mysql")
    eq(tbl, nil, comment)
  end
end)

test("resolve_query: MySQL double minus arithmetic stays read-only",
function()
  local _, tbl = grip._resolve_query(
    "SELECT id, total--1 AS status\nFROM orders", 50, "mysql")
  eq(tbl, nil, "-- without following whitespace is not a MySQL comment")
end)

test("resolve_query: ordinary projection comments remain supported",
function()
  for _, projection in ipairs({
    "id, total /* ordinary comment */",
    "id, total -- ordinary comment\n",
  }) do
    local _, tbl = grip._resolve_query(
      "SELECT " .. projection .. " FROM orders", 50, "mysql")
    eq(tbl, "orders", projection)
  end
end)

test("resolve_query: PostgreSQL nested comments cannot hide an alias", function()
  local _, tbl = grip._resolve_query(
    "SELECT id, total /* outer /* inner */ FROM orders */ AS status FROM orders;",
    50, "postgresql")
  eq(tbl, nil, "the actual projection aliases total as status")
end)

test("resolve_query: PostgreSQL nested comments keep direct columns editable", function()
  local _, tbl = grip._resolve_query(
    "SELECT id, total /* outer /* inner /* deeper */ */ FROM decoy */ FROM orders",
    50, "postgresql")
  eq(tbl, "orders", "the full nested comment must be skipped")
end)

test("resolve_query: malformed or dialect-ambiguous nested comments stay read-only", function()
  for _, kind in ipairs({ "postgresql", "mysql", "sqlite", "duckdb" }) do
    local _, tbl = grip._resolve_query(
      "SELECT id, total /* outer /* inner */ FROM orders", 50, kind)
    eq(tbl, nil, kind)
  end
end)

test("resolve_query: source extraction ignores FROM inside comments and identifiers", function()
  for _, statement in ipairs({
    "SELECT id /* FROM decoy */ FROM orders",
    "SELECT id -- FROM decoy\nFROM orders",
    "SELECT id -- FROM decoy\rFROM orders",
    'SELECT "FROM decoy" FROM orders',
    "SELECT id FROM /* FROM decoy */ orders",
    "SELECT o.id FROM orders /* FROM decoy */ AS o",
  }) do
    local _, tbl = grip._resolve_query(statement, 50, "postgresql")
    eq(tbl, "orders", statement)
  end
end)

test("resolve_query: comment text cannot hide additional sources", function()
  for _, statement in ipairs({
    "SELECT * FROM orders /* WHERE hidden */ JOIN other ON orders.id = other.id",
    "SELECT * FROM orders /* LIMIT hidden */, other",
    "SELECT * FROM orders AS o(id, status)",
  }) do
    local _, tbl = grip._resolve_query(statement, 50, "postgresql")
    eq(tbl, nil, statement)
  end
end)

test("resolve_query: line comments respect dialect line endings", function()
  for _, kind in ipairs({ "postgresql", "duckdb", "mysql", "sqlite" }) do
    local _, tbl = grip._resolve_query("SELECT id -- comment\r\nFROM orders", 50, kind)
    eq(tbl, "orders", kind .. " CRLF")
    _, tbl = grip._resolve_query("SELECT id -- comment\rFROM orders", 50, kind)
    local expected = (kind == "postgresql" or kind == "duckdb") and "orders" or nil
    eq(tbl, expected, kind .. " bare CR")
    _, tbl = grip._resolve_query(
      "SELECT * FROM orders -- comment\rUNION ALL SELECT * FROM other", 50, kind)
    eq(tbl, nil, kind .. " hidden set operation")
  end
end)

test("resolve_query: DuckDB struct projections stay read-only", function()
  for _, statement in ipairs({
    "SELECT id, details.* FROM orders",
    "SELECT id, details.status FROM orders",
    "SELECT id, orders.details.status FROM orders",
    "SELECT id, o.details.status FROM orders AS o",
    'SELECT id, "details"."status" FROM orders',
    "SELECT id, orders.status FROM orders AS o",
    "SELECT id, orders.* FROM orders AS o",
  }) do
    local _, tbl = grip._resolve_query(statement, 50, "duckdb")
    eq(tbl, nil, statement)
  end
end)

test("resolve_query: actual table and alias qualifiers stay editable", function()
  for _, statement in ipairs({
    "SELECT orders.* FROM orders",
    "SELECT orders.id, orders.status FROM orders",
    "SELECT o.* FROM orders AS o",
    "SELECT o.id, o.status FROM orders o",
    'SELECT "o".* FROM "orders" AS "o"',
    "SELECT O.status FROM orders AS o",
    "SELECT DISTINCT o.id, o.status FROM orders AS o",
    "SELECT ALL orders.* FROM orders",
  }) do
    local _, tbl = grip._resolve_query(statement, 50, "duckdb")
    eq(tbl, "orders", statement)
  end
end)

test("resolve_query: schema qualifiers must match the complete actual source", function()
  for _, projection in ipairs({ "orders.*", "public.orders.*", "public.orders.status" }) do
    local _, tbl = grip._resolve_query(
      "SELECT " .. projection .. " FROM public.orders", 50, "postgresql")
    eq(tbl, "public.orders", projection)
  end
  for _, projection in ipairs({ "other.orders.*", "orders.details.status", "public.status" }) do
    local _, tbl = grip._resolve_query(
      "SELECT " .. projection .. " FROM public.orders", 50, "postgresql")
    eq(tbl, nil, projection)
  end
end)

test("resolve_query: PostgreSQL qualifier matching preserves quoted case", function()
  local _, tbl = grip._resolve_query('SELECT "O".* FROM orders AS "O"', 50, "postgresql")
  eq(tbl, "orders")
  _, tbl = grip._resolve_query('SELECT o.* FROM orders AS "O"', 50, "postgresql")
  eq(tbl, nil, "an unquoted lowercase qualifier does not name the quoted alias")
  _, tbl = grip._resolve_query("SELECT Orders.* FROM Orders", 50, "postgresql")
  eq(tbl, "orders", "unquoted PostgreSQL table names fold to lowercase")
end)

test("resolve_query: unsupported source and projection shapes stay read-only", function()
  for _, statement in ipairs({
    'SELECT * FROM "public.orders"',
    "SELECT * FROM ONLY orders",
    "SELECT id, total. FROM orders",
    "SELECT id, total FROM orders UNION ALL SELECT id, status FROM other",
    "SELECT * FROM orders WHERE id > 0 UNION ALL SELECT * FROM other",
    "SELECT * FROM orders -- comment\rUNION ALL SELECT * FROM other",
    "SELECT * FROM orders; SELECT * FROM other",
  }) do
    local _, tbl = grip._resolve_query(statement, 50, "postgresql")
    eq(tbl, nil, statement)
  end
end)

test("resolve_query: ordinary tail expressions preserve single-source metadata", function()
  for _, statement in ipairs({
    "SELECT * FROM orders WHERE status = 'FROM other UNION SELECT'",
    "SELECT * FROM orders WHERE id IN (SELECT id FROM other) ORDER BY id LIMIT 10;",
    "SELECT * FROM orders WHERE status = 'it''s a value'",
  }) do
    local _, tbl = grip._resolve_query(statement, 50, "postgresql")
    eq(tbl, "orders", statement)
  end
end)

test("resolve_query: LEFT and RIGHT tail functions are not joins", function()
  for _, kind in ipairs({ "postgresql", "duckdb", "mysql" }) do
    local statement = "SELECT id, status FROM orders WHERE LEFT(status, 1) = 'b' ORDER BY RIGHT(status, 1)"
    local _, tbl = grip._resolve_query(statement, 50, kind)
    eq(tbl, "orders", kind)
    _, tbl = grip._resolve_query(statement .. " UNION ALL SELECT id, status FROM other", 50, kind)
    eq(tbl, nil, kind .. " real set operation")
  end
end)

test("resolve_query: qualified keyword fields in the tail preserve editing", function()
  for _, keyword in ipairs({ "union", "intersect", "except" }) do
    for _, tail in ipairs({
      "WHERE o." .. keyword .. " = 'base'",
      "WHERE details." .. keyword .. " = 3",
      "WHERE o./* comment */" .. keyword .. " = 'base'",
      "ORDER BY o." .. keyword,
    }) do
      local _, tbl = grip._resolve_query("SELECT id, status FROM orders o " .. tail, 50, "duckdb")
      eq(tbl, "orders", tail)
    end
  end
end)

test("resolve_query: qualified fields and decimal points cannot hide set operations", function()
  for _, operation in ipairs({ "UNION", "INTERSECT", "EXCEPT" }) do
    for _, tail in ipairs({
      "WHERE orders.union = 'base' ",
      "WHERE id = 1. ",
      "WHERE id = 1./* comment */",
      "WHERE id = 0_1. ",
      "WHERE id = 0_1.",
      "WHERE id = 0_1./* comment */",
      "WHERE id = .0_1e2 ",
      "WHERE id = 0_1.e0 ",
      "WHERE id = 1e0",
    }) do
      local statement = "SELECT id, status FROM orders " .. tail
        .. operation .. " SELECT id, status FROM other"
      local _, tbl = grip._resolve_query(statement, 50, "duckdb")
      eq(tbl, nil, statement)
    end
  end
end)

test("resolve_query: numeric literals in filters preserve editing", function()
  for _, literal in ipairs({ "0_1.", "1.0_0", "1e0_0", ".1e1", "1.e+0", "1e-0", "0x_1", "0b_1", "0o_1" }) do
    local _, tbl = grip._resolve_query("SELECT id FROM orders WHERE id = " .. literal, 50, "postgresql")
    eq(tbl, "orders", literal)
    _, tbl = grip._resolve_query("SELECT id, " .. literal .. " FROM orders", 50, "postgresql")
    eq(tbl, nil, "numeric projection " .. literal)
  end
  local _, tbl = grip._resolve_query(
    "SELECT id, status FROM orders AS _1 WHERE _1.union = 'base'", 50, "duckdb")
  eq(tbl, "orders", "underscore-prefixed aliases are still identifiers")
end)

test("resolve_query: ambiguous numeric suffixes stay read-only", function()
  for _, literal in ipairs({ "0x", "0b_", "0o8", "1e_1", "1e+", "1e-", "1f", "0x1g" }) do
    local _, tbl = grip._resolve_query("SELECT id FROM orders WHERE id = " .. literal, 50, "postgresql")
    eq(tbl, nil, literal)
  end
end)

test("resolve_query: plain backslash filters preserve direct-column editing", function()
  for _, kind in ipairs({ "postgresql", "duckdb", "mysql", "sqlite" }) do
    local _, tbl = grip._resolve_query([[SELECT id FROM orders WHERE status = 'C:\data\orders']], 50, kind)
    eq(tbl, "orders", kind)
    _, tbl = grip._resolve_query([[SELECT id FROM orders WHERE status = 'C:\data\\']], 50, kind)
    eq(tbl, "orders", kind .. " even trailing backslashes")
    _, tbl = grip._resolve_query([[SELECT id FROM orders WHERE status = 'C:\data\']], 50, kind)
    local expected
    if kind ~= "postgresql" and kind ~= "mysql" then expected = "orders" end
    eq(tbl, expected, kind .. " trailing backslash quote boundary")
  end
end)

test("resolve_query: explicit escape strings cannot hide set operations", function()
  for _, kind in ipairs({ "postgresql", "duckdb" }) do
    for _, literal in ipairs({
      [[E'it\'s FROM other UNION SELECT']],
      "E''\n'first'\n'\\' -- '",
      "E'' -- continuation\n'\\' -- '",
    }) do
      local statement = "SELECT id FROM orders WHERE status = " .. literal
      local _, tbl = grip._resolve_query(statement, 50, kind)
      eq(tbl, "orders", kind .. " " .. literal)
      _, tbl = grip._resolve_query(statement .. " UNION ALL SELECT id FROM other", 50, kind)
      eq(tbl, nil, kind .. " real set operation after " .. literal)
    end
  end
end)

test("resolve_query: dollar-quoted filters use exact delimiter boundaries", function()
  for _, kind in ipairs({ "postgresql", "duckdb" }) do
    for _, literal in ipairs({ "$$it's FROM other UNION SELECT$$", "$tag$' /* FROM $$ UNION */$tag$" }) do
      local statement = "SELECT id FROM orders WHERE status = " .. literal
      local _, tbl = grip._resolve_query(statement, 50, kind)
      eq(tbl, "orders", kind .. " " .. literal)
      _, tbl = grip._resolve_query(statement .. " UNION ALL SELECT id FROM other", 50, kind)
      eq(tbl, nil, kind .. " real set operation")
      _, tbl = grip._resolve_query("SELECT id, " .. literal .. " FROM orders", 50, kind)
      eq(tbl, nil, kind .. " literal projection")
    end
    for _, literal in ipairs({ "$$unterminated", "$tag$wrong case$TAG$", "$1$invalid tag$1$" }) do
      local _, tbl = grip._resolve_query("SELECT id FROM orders WHERE status = " .. literal, 50, kind)
      eq(tbl, nil, kind .. " " .. literal)
    end
  end
end)

test("resolve_query: dollar delimiters do not copy the remaining SQL", function()
  local literals = {}
  for idx = 1, 1000 do literals[idx] = "$tag$value" .. idx .. "$tag$" end
  local statement = "SELECT id FROM orders WHERE status IN (" .. table.concat(literals, ",") .. ")"
  local original_sub, suffix_copies = string.sub, 0
  -- luacheck: push ignore 122
  string.sub = function(value, first, last)
    if value == statement and last == nil then suffix_copies = suffix_copies + 1 end
    return original_sub(value, first, last)
  end
  local ok, spec, tbl = pcall(grip._resolve_query, statement, 50, "postgresql")
  string.sub = original_sub
  -- luacheck: pop
  assert(ok, spec)
  eq(spec.base_sql, statement, "query text remains unchanged")
  eq(tbl, "orders", "large literal list retains its source")
  eq(suffix_copies, 0, "dollar delimiter matching must not copy SQL suffixes")
end)

test("resolve_query: PostgreSQL JSON operators are allowed only in tail expressions", function()
  local _, tbl = grip._resolve_query([[SELECT id FROM orders WHERE details #>> '{status}' = 'base']], 50, "postgresql")
  eq(tbl, "orders")
  _, tbl = grip._resolve_query([[SELECT id, details #>> '{status}' FROM orders]], 50, "postgresql")
  eq(tbl, nil, "JSON extraction is not a direct column")
end)

test("resolve_query: DuckDB nested lists do not act as quoted identifiers", function()
  local statement = [=[SELECT id FROM orders WHERE [[status]] = [['base']]]=]
  local _, tbl = grip._resolve_query(statement, 50, "duckdb")
  eq(tbl, "orders")
  _, tbl = grip._resolve_query(statement .. " UNION ALL SELECT id FROM other", 50, "duckdb")
  eq(tbl, nil, "real set operation after list filter")
  _, tbl = grip._resolve_query("SELECT id, [status] FROM orders", 50, "duckdb")
  eq(tbl, nil, "list construction is not a direct column")
end)

test("resolve_query: aliased projected column does not expose editable table", function()
  local spec, tbl = grip._resolve_query("SELECT id, total AS status FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "aliased result columns cannot be safely mapped back to the base table")
end)

test("resolve_query: computed projected column does not expose editable table", function()
  local spec, tbl = grip._resolve_query("SELECT id, total * 2 AS status FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "computed result columns cannot be safely mapped back to the base table")
end)

test("resolve_query: SELECT with JOIN returns nil table (ambiguous)", function()
  local spec, tbl = grip._resolve_query("SELECT a.*, b.* FROM users a JOIN orders b ON a.id = b.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for JOINs")
end)

test("resolve_query: SELECT with LEFT JOIN returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for LEFT JOINs")
end)

test("resolve_query: SELECT with comma-join returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM users, orders WHERE users.id = orders.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for comma-joins")
end)

test("resolve_query: SELECT from subquery returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM (SELECT 1) t", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for subqueries")
end)

test("resolve_query: select 1 (no FROM) returns nil table", function()
  local spec, tbl = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil when no FROM clause")
end)

test("resolve_query: TABLE with quoted name extracts unquoted", function()
  local spec, tbl = grip._resolve_query('TABLE "Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "Participant", "TABLE should unquote table name")
end)

test("resolve_query: multiline SELECT extracts table", function()
  local spec, tbl = grip._resolve_query("SELECT *\nFROM orders\nWHERE id > 0", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "should extract table from multiline SELECT")
end)

-- ── resolve_query: file-as-table ─────────────────────────────────────────────

test("resolve_query: readable file path returns raw spec", function()
  local orig_readable = vim.fn.filereadable
  local orig_fnamemodify = vim.fn.fnamemodify
  vim.fn.filereadable = function() return 1 end
  vim.fn.fnamemodify = function(p) return p end
  local spec, tbl, fpath = grip._resolve_query("/data/sales.parquet", 50)
  vim.fn.filereadable = orig_readable
  vim.fn.fnamemodify = orig_fnamemodify
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil")
  eq(fpath, "/data/sales.parquet", "file_path")
end)

test("resolve_query: file path with single quote is escaped", function()
  local orig_readable = vim.fn.filereadable
  local orig_fnamemodify = vim.fn.fnamemodify
  vim.fn.filereadable = function() return 1 end
  vim.fn.fnamemodify = function(p) return p end
  local spec = grip._resolve_query("/data/it's.csv", 50)
  vim.fn.filereadable = orig_readable
  vim.fn.fnamemodify = orig_fnamemodify
  assert(spec, "spec should not be nil")
  -- The SQL in the spec should have escaped single quote
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "it''s", "single quote should be escaped")
end)

-- ── is_queryable_file: URL detection ────────────────────────────────────────

test("is_queryable_file: https URL with .csv", function()
  eq(grip._is_queryable_file("https://example.com/data.csv"), true)
end)

test("is_queryable_file: http URL with .parquet", function()
  eq(grip._is_queryable_file("http://example.com/data.parquet"), true)
end)

test("is_queryable_file: S3 URL with .parquet", function()
  eq(grip._is_queryable_file("s3://analytics/data.parquet"), true)
end)

test("is_queryable_file: https URL with .json", function()
  eq(grip._is_queryable_file("https://example.com/data.json"), true)
end)

test("is_queryable_file: https URL with .ndjson", function()
  eq(grip._is_queryable_file("https://example.com/data.ndjson"), true)
end)

test("is_queryable_file: https URL with .xlsx", function()
  eq(grip._is_queryable_file("https://example.com/data.xlsx"), true)
end)

test("is_queryable_file: https URL with unsupported extension", function()
  eq(grip._is_queryable_file("https://example.com/page.html"), false)
end)

test("is_queryable_file: URL with query string stripped for extension check", function()
  eq(grip._is_queryable_file("https://example.com/data.csv?token=abc"), true)
end)

test("is_queryable_file: URL with fragment stripped for extension check", function()
  eq(grip._is_queryable_file("https://example.com/data.parquet#row=5"), true)
end)

test("is_queryable_file: URL case insensitive", function()
  eq(grip._is_queryable_file("https://example.com/DATA.CSV"), true)
end)

test("is_queryable_file: bare https not a file", function()
  eq(grip._is_queryable_file("https://example.com/"), false)
end)

-- ── resolve_query: URL-as-table ─────────────────────────────────────────────

test("resolve_query: https URL returns raw spec with URL as file_path", function()
  local spec, tbl, fpath = grip._resolve_query("https://example.com/data.csv", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil for URL queries")
  eq(fpath, "https://example.com/data.csv", "file_path should be the URL")
end)

test("resolve_query: S3 URL returns raw spec with URL as file_path", function()
  local spec, tbl, fpath = grip._resolve_query("s3://analytics/data.parquet", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil for S3 queries")
  eq(fpath, "s3://analytics/data.parquet", "file_path should be the S3 URL")
  contains(require("dadbod-grip.query").build_sql(spec), "s3://analytics/data.parquet",
    "SQL should contain the S3 URL")
end)

test("resolve_query: URL SQL contains the URL in FROM clause", function()
  local spec = grip._resolve_query("https://example.com/data.parquet", 50)
  assert(spec, "spec should not be nil")
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "https://example.com/data.parquet", "SQL should contain the URL")
end)

test("resolve_query: URL with single quote is escaped", function()
  local spec = grip._resolve_query("https://example.com/it's.csv", 50)
  assert(spec, "spec should not be nil")
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "it''s", "single quote should be escaped")
end)

test("resolve_query: URL does not call filereadable", function()
  local called = false
  local orig = vim.fn.filereadable
  vim.fn.filereadable = function() called = true; return 0 end
  local spec = grip._resolve_query("https://example.com/data.csv", 50)
  vim.fn.filereadable = orig
  assert(spec, "spec should not be nil")
  eq(called, false, "filereadable should not be called for URLs")
end)

-- Rendered highlight ranges protect the retained logo and actionable hints.
local WELCOME_NS = vim.api.nvim_create_namespace("grip_welcome")
local function open_welcome_and_wait()
  grip.open_welcome()
  local buf = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(buf, WELCOME_NS, 0, -1, { details = true })
  assert(#marks > 0, "welcome has no highlight ranges")
  return buf, marks
end

local WELCOME_GROUPS = {
  Comment = function(text, line) return text == line end,
  Special = function(text, line) return text == line end,
  Title = function(text, line)
    return text:match("^dadbod%-grip")
      or (text == line and (text:match("^  [A-Z][A-Z ]+") or text == "  Welcome keys"))
  end,
  Statement = function(text) return text:match("^:Grip%S*$") end,
  Identifier = function(text) return text:match("^%S+$") end,
}

test("open_welcome: highlight ranges fit their rendered semantic groups", function()
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local seen, per_line = {}, {}
  for _, mark in ipairs(marks) do
    local row, col, det = mark[2], mark[3], mark[4]
    local line = assert(lines[row + 1], "mark outside welcome text")
    assert(det.end_col and det.end_col > col and det.end_col <= #line, "invalid highlight range")
    local pred = assert(WELCOME_GROUPS[det.hl_group], "unexpected highlight group")
    assert(pred(line:sub(col + 1, det.end_col), line), "highlight covers the wrong semantic range: " .. det.hl_group)
    seen[det.hl_group], per_line[row] = true, true
  end
  for group in pairs(WELCOME_GROUPS) do assert(seen[group], "missing highlight group " .. group) end
  for i, line in ipairs(lines) do if line ~= "" then assert(per_line[i - 1], "unhighlighted welcome row") end end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("open_welcome: action commands and keys have their own highlight ranges", function()
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, token in ipairs({ ":GripStart", ":GripConnect", "3", "2" }) do
    local found = false
    for _, mark in ipairs(marks) do
      local det = mark[4]
      if det.hl_group == "Statement" or det.hl_group == "Identifier" then
        local text = lines[mark[2] + 1]:sub(mark[3] + 1, det.end_col)
        if text == token then found = true end
      end
    end
    assert(found, "action hint is not highlighted independently: " .. token)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("open_welcome: brand title excludes the unchanged box glyphs", function()
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false
  for _, mark in ipairs(marks) do
    local line = lines[mark[2] + 1]
    local start = line:find("dadbod-grip", 1, true)
    if start and mark[4].hl_group == "Title" then
      eq(mark[3], start - 1, "brand starts at plugin name")
      eq(mark[4].end_col, #line, "brand includes runtime version")
      found = true
    end
  end
  assert(found, "brand title mark missing")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

print(string.format("\ninit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
