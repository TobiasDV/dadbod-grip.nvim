-- ddl_spec.lua: unit tests for DDL module scoping, SQL generation, quoting
local ddl = require("dadbod-grip.ddl")
local sql = require("dadbod-grip.sql")

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

local function not_contains(s, pattern, msg)
  assert(not s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' NOT to contain '" .. pattern .. "'")
end

-- ── module scoping ───────────────────────────────────────────────────────────

test("ddl: build_create_sql is not a global", function()
  eq(rawget(_G, "build_create_sql"), nil, "_G.build_create_sql")
end)

test("ddl: build_create_sql is not a public export", function()
  eq(ddl.build_create_sql, nil, "ddl.build_create_sql")
end)

-- ── build_create_sql: SQL generation ─────────────────────────────────────────

-- _build_create_sql takes (table_name, columns, url, on_done) but we only
-- care about the SQL it generates. We mock confirm_ddl and db.execute via
-- capturing the SQL string that would be passed to confirm_ddl.
-- Since _build_create_sql calls confirm_ddl (which opens a float), we cannot
-- call it directly without a UI. Instead, we test the SQL generation logic
-- by reproducing it here using the same sql.lua functions the module uses.

local function make_create_sql(table_name, columns)
  local col_defs = {}
  local pk_cols = {}
  for _, col in ipairs(columns) do
    local def = sql.quote_ident(col.name) .. " " .. col.type
    table.insert(col_defs, def)
    if col.pk then
      table.insert(pk_cols, sql.quote_ident(col.name))
    end
  end
  if #pk_cols > 0 then
    table.insert(col_defs, "PRIMARY KEY (" .. table.concat(pk_cols, ", ") .. ")")
  end
  return string.format(
    "CREATE TABLE %s (\n  %s\n)",
    sql.quote_ident(table_name),
    table.concat(col_defs, ",\n  ")
  )
end

test("create SQL: single column with PK", function()
  local result = make_create_sql("users", {{ name = "id", type = "integer", pk = true }})
  contains(result, 'CREATE TABLE "users"', "table name")
  contains(result, '"id" integer', "column def")
  contains(result, 'PRIMARY KEY ("id")', "PK clause")
end)

test("create SQL: multiple columns, first PK", function()
  local result = make_create_sql("users", {
    { name = "id", type = "integer", pk = true },
    { name = "name", type = "text", pk = false },
  })
  contains(result, '"id" integer', "first col")
  contains(result, '"name" text', "second col")
  contains(result, 'PRIMARY KEY ("id")', "PK")
end)

test("create SQL: composite PK", function()
  local result = make_create_sql("join_table", {
    { name = "a_id", type = "integer", pk = true },
    { name = "b_id", type = "integer", pk = true },
  })
  contains(result, 'PRIMARY KEY ("a_id", "b_id")', "composite PK")
end)

test("create SQL: no PK columns", function()
  local result = make_create_sql("logs", {
    { name = "msg", type = "text", pk = false },
  })
  not_contains(result, "PRIMARY KEY", "no PK clause")
end)

test("create SQL: table name is double-quoted", function()
  local result = make_create_sql("my table", {{ name = "id", type = "int", pk = false }})
  contains(result, '"my table"', "quoted table name")
end)

test("create SQL: column name with spaces is quoted", function()
  local result = make_create_sql("t", {{ name = "my col", type = "text", pk = false }})
  contains(result, '"my col"', "quoted column name")
end)

test("create SQL: column type preserved verbatim", function()
  local result = make_create_sql("t", {{ name = "x", type = "varchar(255)", pk = false }})
  contains(result, "varchar(255)", "type verbatim")
end)

test("create SQL: empty columns produces valid SQL", function()
  local result = make_create_sql("empty", {})
  contains(result, 'CREATE TABLE "empty"', "table name")
end)

-- ── DDL SQL patterns: rename ─────────────────────────────────────────────────

test("rename SQL: correct ALTER TABLE format", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s RENAME COLUMN %s TO %s',
    sql.quote_ident("users"),
    sql.quote_ident("old_col"),
    sql.quote_ident("new_col")
  )
  contains(ddl_sql, 'ALTER TABLE "users"', "table")
  contains(ddl_sql, 'RENAME COLUMN "old_col" TO "new_col"', "rename")
end)

test("rename SQL: names are quoted for injection safety", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s RENAME COLUMN %s TO %s',
    sql.quote_ident('my"table'),
    sql.quote_ident("col; DROP"),
    sql.quote_ident("safe_name")
  )
  -- quote_ident doubles internal quotes
  contains(ddl_sql, '"my""table"', "escaped table name")
  contains(ddl_sql, '"col; DROP"', "column name is quoted not executed")
end)

-- ── DDL SQL patterns: drop column ────────────────────────────────────────────

test("drop column SQL: correct format", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s DROP COLUMN %s',
    sql.quote_ident("users"),
    sql.quote_ident("email")
  )
  contains(ddl_sql, 'ALTER TABLE "users" DROP COLUMN "email"', "drop column")
end)

test("drop column SQL: column name is quoted", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s DROP COLUMN %s',
    sql.quote_ident("t"),
    sql.quote_ident("my col")
  )
  contains(ddl_sql, '"my col"', "quoted col name")
end)

-- ── DDL SQL patterns: drop table ─────────────────────────────────────────────

test("drop table SQL: correct format", function()
  local ddl_sql = "DROP TABLE " .. sql.quote_ident("users")
  eq(ddl_sql, 'DROP TABLE "users"', "drop table")
end)

test("drop table SQL: table name is quoted", function()
  local ddl_sql = "DROP TABLE " .. sql.quote_ident("my table")
  contains(ddl_sql, '"my table"', "quoted name")
end)

-- ── drop table SQL: CASCADE scoping (M._build_drop_sql) ──────────────────────

test("drop table CASCADE: postgresql appends CASCADE when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "postgresql", true)
  eq(ddl_sql, 'DROP TABLE "users" CASCADE', "postgresql + referenced")
end)

test("drop table CASCADE: duckdb appends CASCADE when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "duckdb", true)
  eq(ddl_sql, 'DROP TABLE "users" CASCADE', "duckdb + referenced")
end)

test("drop table CASCADE: postgresql omits CASCADE when not referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "postgresql", false)
  eq(ddl_sql, 'DROP TABLE "users"', "postgresql, no referencing FKs")
end)

test("drop table CASCADE: sqlite never appends CASCADE, even when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "sqlite", true)
  eq(ddl_sql, 'DROP TABLE "users"', "sqlite has no CASCADE syntax")
end)

test("drop table CASCADE: mysql never appends CASCADE, even when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "mysql", true)
  eq(ddl_sql, 'DROP TABLE "users"', "mysql ignores CASCADE silently, so we must not send it")
end)

test("drop table CASCADE: sqlserver never appends CASCADE, even when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "sqlserver", true)
  eq(ddl_sql, 'DROP TABLE "users"', "sqlserver has no CASCADE syntax")
end)

test("drop table CASCADE: unknown/nil kind never appends CASCADE", function()
  local ddl_sql = ddl._build_drop_sql("users", nil, true)
  eq(ddl_sql, 'DROP TABLE "users"', "unresolved adapter kind must not get CASCADE")
end)

-- ── drop table: referencing-FK filter (M._filter_referencing) ───────────────
-- drop_table replaced its N+1 per-table FK scan with one call to
-- db.get_referencing_foreign_keys(). Every adapter shipped today answers that
-- with its own schema-exact query. An adapter without one falls back (in
-- db.lua) to a bare-name scan that can't distinguish two same-named tables in
-- different schemas; _filter_referencing is the guard that keeps that
-- combination from widening past the old scan's strictness, so the cases below
-- exercise it with a kind that is deliberately not in SCHEMA_EXACT_REF_KINDS.

test("filter_referencing: bare table name is never filtered, any kind", function()
  -- A trailing nil in the list literal would end ipairs early and silently skip
  -- the unresolved-kind case, so it is asserted separately below the loop.
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  for _, kind in ipairs({ "postgresql", "mysql", "duckdb", "sqlite", "sqlserver" }) do
    local out = ddl._filter_referencing(refs, "users", kind)
    eq(#out, 1, "kind=" .. kind)
  end
  eq(#ddl._filter_referencing(refs, "users", nil), 1, "kind=nil")
end)

test("filter_referencing: schema-qualified name kept for schema-exact adapters", function()
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  for _, kind in ipairs({ "postgresql", "mysql", "duckdb", "sqlite", "sqlserver" }) do
    local out = ddl._filter_referencing(refs, "public.users", kind)
    eq(#out, 1, "kind=" .. kind .. " should keep exact-schema matches")
  end
end)

test("filter_referencing: schema-qualified name dropped for adapters without a dedicated query", function()
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  -- No shipped adapter kind lands here any more, so the input is a hypothetical
  -- one: this guard is what protects the next adapter added without its own
  -- reverse-FK query.
  local out = ddl._filter_referencing(refs, "dbo.users", "adapter_without_reverse_fk_query")
  eq(#out, 0, "a bare-name fallback can't be trusted for a qualified name")
end)

test("filter_referencing: unresolved/unknown kind treated like a non-exact adapter", function()
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  local out = ddl._filter_referencing(refs, "sales.users", nil)
  eq(#out, 0, "unknown kind + qualified name is filtered defensively")
end)

test("filter_referencing: empty input stays empty", function()
  local out = ddl._filter_referencing({}, "schema.users", "sqlserver")
  eq(#out, 0, "nothing to filter")
end)

-- A self-reference (employees.manager_id -> employees.id) is not an inbound
-- dependency: dropping the table drops its own constraint. No adapter's
-- reverse-FK query excludes it, but the old per-table scan did, so the filter
-- has to. Counting it would append CASCADE on postgresql/duckdb for every
-- table with a parent_id/manager_id column.

test("filter_referencing: self-reference is not an inbound dependency, any kind", function()
  local refs = { { table = "employees", column = "manager_id", ref_column = "id" } }
  for _, kind in ipairs({ "postgresql", "mysql", "duckdb", "sqlite", "sqlserver" }) do
    local out = ddl._filter_referencing(refs, "employees", kind)
    eq(#out, 0, "kind=" .. kind .. " must not treat a self-FK as a dependent")
  end
  local out = ddl._filter_referencing(refs, "employees", nil)
  eq(#out, 0, "kind=nil must not treat a self-FK as a dependent")
end)

test("filter_referencing: self-reference dropped, genuine inbound FK kept", function()
  local refs = {
    { table = "employees", column = "team_id", ref_column = "id" },
    { table = "teams", column = "parent_team_id", ref_column = "id" },
  }
  local out = ddl._filter_referencing(refs, "teams", "postgresql")
  eq(#out, 1, "only the self-FK is filtered")
  eq(out[1].table, "employees", "the real dependent survives")
end)

test("filter_referencing: self-reference matched on bare name across schemas", function()
  -- postgresql returns child tables schema-qualified; the drop target may be
  -- bare (public) or qualified, so both directions must recognise the self-FK.
  local qualified = { { table = "sales.orders", column = "parent_id", ref_column = "id" } }
  eq(#ddl._filter_referencing(qualified, "sales.orders", "postgresql"), 0, "both qualified")
  eq(#ddl._filter_referencing(qualified, "orders", "postgresql"), 0, "target bare")
  local plain = { { table = "orders", column = "parent_id", ref_column = "id" } }
  eq(#ddl._filter_referencing(plain, "public.orders", "postgresql"), 0, "row bare")
end)

-- ── drop table: the CASCADE note reaches the confirmation dialog ─────────────
-- _build_drop_sql above only covers the SQL half of the CASCADE story. The
-- other half is the `note` drop_table hands to destructive_confirm on adapters
-- that cannot CASCADE -- nothing asserted that it is rendered, so the argument
-- could be dropped on the floor without a red test. drop_table is driven for
-- real here (the float it opens is a plain buffer, readable headless); the only
-- stub is the reverse-FK lookup, since the suite has no live server for most
-- adapters. adapters.kind/display_name run unstubbed so the note's adapter name
-- is the one users actually see.

local db = require("dadbod-grip.db")

--- Drive M.drop_table and return the text of the confirmation float it opened.
--- The float (and its buffer) are closed before returning, so specs leave no
--- window behind.
--- @return string  the dialog's lines joined with "\n"
local function drop_table_dialog(table_name, url, refs)
  local orig_refs   = db.get_referencing_foreign_keys
  local orig_notify = vim.notify
  db.get_referencing_foreign_keys = function() return refs end
  vim.notify = function() end

  local ok, err = pcall(ddl.drop_table, table_name, url)

  db.get_referencing_foreign_keys = orig_refs
  vim.notify = orig_notify
  if not ok then error(err, 0) end

  local win   = vim.api.nvim_get_current_win()
  local buf   = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Only ever close what destructive_confirm opened. Should drop_table one day
  -- return before opening the float, the current window is the spec runner's
  -- own -- so the float is identified (a floating window whose first line is
  -- the dialog's banner) before anything is torn down.
  assert(vim.api.nvim_win_get_config(win).relative ~= "",
    "drop_table opened a floating window")
  assert(lines[1] and lines[1]:find("WARNING: DROP TABLE", 1, true),
    "the float is the DROP TABLE confirmation, not some other buffer (line 1: "
      .. tostring(lines[1]) .. ")")

  vim.api.nvim_win_close(win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return table.concat(lines, "\n")
end

local ONE_REF = { { table = "orders", column = "user_id", ref_column = "id" } }

test("drop table dialog: non-CASCADE adapters warn, naming themselves", function()
  -- The name in the note comes from adapters.display_name(url); an unknown
  -- scheme falls back to "This adapter".
  for _, case in ipairs({
    { url = "sqlite:/tmp/grip_ddl_spec.db",   name = "SQLite" },
    { url = "mysql://u:p@h:3306/db",          name = "MySQL" },
    { url = "sqlserver://u:p@h:1433/db",      name = "SQL Server" },
    { url = "weirdscheme://host/db",          name = "This adapter" },
  }) do
    local text = drop_table_dialog("users", case.url, ONE_REF)
    contains(text, 'DROP TABLE "users"', case.name .. ": DDL shown")
    not_contains(text, 'DROP TABLE "users" CASCADE', case.name .. ": no CASCADE in the SQL")
    contains(text, case.name .. " doesn't support CASCADE: dependent foreign keys won't be"
      .. " dropped, so this may fail or leave dangling references.",
      case.name .. ": full note reached the dialog")
  end
end)

test("drop table dialog: CASCADE adapters get CASCADE and no note", function()
  for _, url in ipairs({ "postgresql://u:p@h:5432/db", "duckdb:/tmp/grip_ddl_spec.duckdb" }) do
    local text = drop_table_dialog("users", url, ONE_REF)
    contains(text, 'DROP TABLE "users" CASCADE', url .. ": CASCADE in the SQL")
    not_contains(text, "support CASCADE", url .. ": nothing to warn about")
  end
end)

test("drop table dialog: no dependents means no note on any adapter", function()
  local text = drop_table_dialog("users", "sqlite:/tmp/grip_ddl_spec.db", {})
  contains(text, 'DROP TABLE "users"', "DDL shown")
  not_contains(text, "support CASCADE", "no dependent FKs, so no warning")
end)

test("drop table dialog: a self-FK is no dependent, so it raises no note", function()
  -- Same guard as _filter_referencing above, seen from the dialog: a
  -- manager_id-style self reference must not produce a scary warning.
  local self_ref = { { table = "employees", column = "manager_id", ref_column = "id" } }
  local text = drop_table_dialog("employees", "sqlite:/tmp/grip_ddl_spec.db", self_ref)
  not_contains(text, "support CASCADE", "self-FK filtered before the note is built")
end)

-- ── DDL SQL patterns: add column ─────────────────────────────────────────────

test("add column SQL: basic format", function()
  local parts = { "ALTER TABLE " .. sql.quote_ident("users") }
  local col_def = "ADD COLUMN " .. sql.quote_ident("bio") .. " text"
  table.insert(parts, col_def)
  local ddl_sql = table.concat(parts, " ")
  contains(ddl_sql, 'ALTER TABLE "users" ADD COLUMN "bio" text', "add column")
end)

test("add column SQL: with DEFAULT clause", function()
  local parts = { "ALTER TABLE " .. sql.quote_ident("users") }
  local col_def = "ADD COLUMN " .. sql.quote_ident("status") .. " text"
  col_def = col_def .. " DEFAULT " .. sql.quote_value("active")
  table.insert(parts, col_def)
  local ddl_sql = table.concat(parts, " ")
  contains(ddl_sql, "DEFAULT 'active'", "default value")
end)

-- ── per-adapter DDL builders ─────────────────────────────────────────────────

test("rename column builder: ALTER TABLE ... RENAME COLUMN outside SQL Server", function()
  for _, kind in ipairs({ "postgresql", "mysql", "sqlite", "duckdb" }) do
    eq(ddl._build_rename_column_sql("users", "name", "full_name", kind),
      'ALTER TABLE "users" RENAME COLUMN "name" TO "full_name"', kind)
  end
end)

test("rename column builder: sqlserver uses sp_rename with a quoted source", function()
  eq(ddl._build_rename_column_sql("dbo.users", "name", "full_name", "sqlserver"),
    [[EXEC sp_rename N'"dbo"."users"."name"', N'full_name', N'COLUMN']])
end)

test("rename column builder: sqlserver escapes quotes in both names", function()
  eq(ddl._build_rename_column_sql("users", "it's", "o'neil", "sqlserver"),
    [[EXEC sp_rename N'"users"."it''s"', N'o''neil', N'COLUMN']])
end)

test("rename table builder: ALTER TABLE ... RENAME TO outside SQL Server", function()
  eq(ddl._build_rename_table_sql("users", "people", "postgresql"), 'ALTER TABLE "users" RENAME TO "people"')
end)

test("rename table builder: sqlserver uses sp_rename", function()
  eq(ddl._build_rename_table_sql("dbo.users", "people", "sqlserver"),
    [[EXEC sp_rename N'"dbo"."users"', N'people']])
end)

test("add column builder: ADD COLUMN outside SQL Server, ADD on it", function()
  eq(ddl._build_add_column_sql("users", "bio", "text", "", "postgresql"),
    'ALTER TABLE "users" ADD COLUMN "bio" text')
  eq(ddl._build_add_column_sql("users", "bio", "nvarchar(200)", "none", "sqlserver"),
    [[ALTER TABLE "users" ADD "bio" nvarchar(200) DEFAULT 'none']])
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nddl_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
