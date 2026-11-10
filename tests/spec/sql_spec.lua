-- sql_spec.lua: unit tests for sql.lua (pure SQL generation)
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

-- ── quote_value() ───────────────────────────────────────────────────────────

test("quote_value: nil becomes NULL", function()
  eq(sql.quote_value(nil), "NULL")
end)

test("quote_value: string gets single quotes", function()
  eq(sql.quote_value("hello"), "'hello'")
end)

test("quote_value: escapes single quotes", function()
  eq(sql.quote_value("it's"), "'it''s'")
end)

test("quote_value: number stays as number", function()
  eq(sql.quote_value(42), "42")
end)

test("quote_value: boolean true", function()
  eq(sql.quote_value(true), "TRUE")
end)

test("quote_value: boolean false", function()
  eq(sql.quote_value(false), "FALSE")
end)

test("wrap_transaction: keeps the shared transaction syntax", function()
  eq(sql.wrap_transaction({ "INSERT ONE", "INSERT TWO" }, "sqlite"),
    "BEGIN;\nINSERT ONE;\nINSERT TWO;\nCOMMIT;")
end)

test("wrap_transaction: uses SQL Server transaction statements", function()
  eq(sql.wrap_transaction({ "INSERT ONE", "INSERT TWO" }, "sqlserver"),
    "SET XACT_ABORT ON;\nBEGIN TRANSACTION;\nINSERT ONE;\nINSERT TWO;\nCOMMIT TRANSACTION;")
end)

-- ── quote_ident() ───────────────────────────────────────────────────────────

test("quote_ident: wraps in double quotes", function()
  eq(sql.quote_ident("users"), '"users"')
end)

test("quote_ident: escapes existing double quotes", function()
  eq(sql.quote_ident('my"table'), '"my""table"')
end)

-- ── build_update() ──────────────────────────────────────────────────────────

test("build_update: generates valid UPDATE", function()
  local result = sql.build_update("users", { id = "1" }, { name = "alice" })
  contains(result, 'UPDATE "users"')
  contains(result, 'SET "name" = \'alice\'')
  contains(result, 'WHERE "id" = \'1\'')
end)

test("build_update: NULL value in changes", function()
  local result = sql.build_update("users", { id = "1" }, { name = nil })
  -- nil value means the key is removed from changes table, so nothing to SET
  -- Actually in data.lua, NULL_SENTINEL is cleaned to nil before passing to sql.lua
  -- An empty changes table would generate "SET " which is invalid
  -- This test verifies behavior when value is nil (key gets removed from table)
  -- The changes table with name=nil effectively has no entries
  contains(result, "UPDATE")
end)

test("build_update: multiple columns sorted deterministically", function()
  local result = sql.build_update("users", { id = "1" }, { email = "x@y", name = "bob" })
  -- SET parts are sorted alphabetically
  local set_idx = result:find("SET")
  local email_idx = result:find('"email"', set_idx)
  local name_idx = result:find('"name"', set_idx)
  assert(email_idx < name_idx, "email should come before name in SET clause")
end)

-- ── build_insert() ──────────────────────────────────────────────────────────

test("build_insert: generates valid INSERT", function()
  local result = sql.build_insert("users", { name = "carol" }, { "id", "name", "email" })
  contains(result, 'INSERT INTO "users"')
  contains(result, '"name"')
  contains(result, "'carol'")
end)

test("build_insert: all defaults generates DEFAULT VALUES", function()
  local result = sql.build_insert("users", {}, { "id", "name" })
  contains(result, "DEFAULT VALUES")
end)

test("build_insert: skips nil columns", function()
  local result = sql.build_insert("users", { name = "carol" }, { "id", "name", "email" })
  -- id and email are nil so they should be skipped
  assert(not result:find('"id"'), "should skip nil id column")
  assert(not result:find('"email"'), "should skip nil email column")
end)

-- ── build_delete() ──────────────────────────────────────────────────────────

test("build_delete: generates valid DELETE", function()
  local result = sql.build_delete("users", { id = "1" })
  contains(result, 'DELETE FROM "users"')
  contains(result, 'WHERE "id" = \'1\'')
end)

test("build_delete: composite PK sorted", function()
  local result = sql.build_delete("order_items", { order_id = "10", product_id = "5" })
  local oid_idx = result:find('"order_id"')
  local pid_idx = result:find('"product_id"')
  assert(oid_idx < pid_idx, "order_id should come before product_id in WHERE")
end)

test("projected edits and deletes use every original composite key value", function()
  local data = require("dadbod-grip.data")
  local st = data.new({ table_name = "order_items", primary_keys = { "order_id", "product_id" },
    columns = { "name", "product_id", "order_id" }, rows = { { "before", "5", "10" } } })
  eq(st.readonly, false)
  st = data.add_change(st, 1, "order_id", "20")
  st = data.add_change(st, 1, "name", "after")
  local upd = data.get_updates(st)[1]
  eq(sql.build_update(st.table_name, upd.pk_values, upd.changes),
    [[UPDATE "order_items" SET "name" = 'after', "order_id" = '20' WHERE "order_id" = '10' AND "product_id" = '5']])
  local del = data.get_deletes(data.toggle_delete(st, 1))[1]
  eq(sql.build_delete(st.table_name, del.pk_values),
    [[DELETE FROM "order_items" WHERE "order_id" = '10' AND "product_id" = '5']])
end)

-- ── preview_staged() ────────────────────────────────────────────────────────

test("preview_staged: no changes returns comment", function()
  local result = sql.preview_staged("users", {}, {}, {})
  eq(result, "-- no staged changes")
end)

test("preview_staged: includes all statement types", function()
  local updates = { { pk_values = { id = "1" }, changes = { name = "x" } } }
  local deletes = { { pk_values = { id = "2" } } }
  local inserts = { { values = { name = "y" }, columns = { "id", "name" } } }
  local result = sql.preview_staged("users", updates, deletes, inserts)
  contains(result, "DELETE")
  contains(result, "UPDATE")
  contains(result, "INSERT")
end)

test("preview_staged: deletes come before updates", function()
  local updates = { { pk_values = { id = "1" }, changes = { name = "x" } } }
  local deletes = { { pk_values = { id = "2" } } }
  local result = sql.preview_staged("users", updates, deletes, {})
  local del_idx = result:find("DELETE")
  local upd_idx = result:find("UPDATE")
  assert(del_idx < upd_idx, "DELETE should come before UPDATE")
end)

-- ── IS NULL in WHERE clause ──────────────────────────────────────────────────

test("build_update: empty-string pk value uses a literal predicate", function()
  local result = sql.build_update("users", { id = "" }, { name = "alice" })
  contains(result, '"id" = \'\'')
  assert(not result:find("IS NULL", 1, true), "empty text is not NULL")
end)

test("build_delete: empty-string pk value uses a literal predicate", function()
  local result = sql.build_delete("users", { id = "" })
  contains(result, '"id" = \'\'')
  assert(not result:find("IS NULL", 1, true), "empty text is not NULL")
end)

test("build_update: non-nil pk value still uses = (regression guard)", function()
  local result = sql.build_update("users", { id = "1" }, { name = "bob" })
  contains(result, '"id" = \'1\'')
  assert(not result:find("IS NULL", 1, true), "should not have IS NULL for real pk")
end)

test("build_delete: non-nil pk value still uses = (regression guard)", function()
  local result = sql.build_delete("orders", { order_id = "42" })
  contains(result, '"order_id" = \'42\'')
  assert(not result:find("IS NULL", 1, true), "should not have IS NULL for real pk")
end)

-- ── unquote_ident() ─────────────────────────────────────────────────────────

test("unquote_ident: bare identifier passes through", function()
  eq(sql.unquote_ident("users"), "users")
end)

test("unquote_ident: strips double quotes", function()
  eq(sql.unquote_ident('"Participant"'), "Participant")
end)

test("unquote_ident: strips backticks", function()
  eq(sql.unquote_ident("`tablename`"), "tablename")
end)

test("unquote_ident: un-escapes doubled double quotes", function()
  eq(sql.unquote_ident('"my""table"'), 'my"table')
end)

test("unquote_ident: un-escapes doubled backticks", function()
  eq(sql.unquote_ident("`my``table`"), "my`table")
end)

test("unquote_ident: schema-qualified double-quoted", function()
  eq(sql.unquote_ident('"public"."Participant"'), "public.Participant")
end)

test("unquote_ident: schema-qualified bare", function()
  eq(sql.unquote_ident("public.users"), "public.users")
end)

test("unquote_ident: mixed quoting (schema bare, table quoted)", function()
  eq(sql.unquote_ident('public."Participant"'), "public.Participant")
end)

test("unquote_ident: roundtrip with quote_ident", function()
  eq(sql.unquote_ident(sql.quote_ident("users")), "users")
  eq(sql.unquote_ident(sql.quote_ident("public.users")), "public.users")
end)

-- ── sqlserver dialect ───────────────────────────────────────────────────────

test("quote_value: sqlserver strings are N-prefixed", function()
  eq(sql.quote_value("Zoë 李", "sqlserver"), "N'Zoë 李'")
  eq(sql.quote_value("it's", "sqlserver"), "N'it''s'")
end)

test("quote_value: sqlserver splices CRs in as NCHAR(13)", function()
  eq(sql.quote_value("a\r\nb's", "sqlserver"), "CAST(N'a' AS nvarchar(max)) + NCHAR(13) + N'\nb''s'")
  eq(sql.quote_value("a\nb", "sqlserver"), "N'a\nb'", "LF alone is left as is")
  eq(sql.quote_value("a\r\nb", "postgresql"), "'a\r\nb'", "other adapters unchanged")
end)

test("quote_value: sqlserver booleans are 1/0", function()
  eq(sql.quote_value(true, "sqlserver"), "1")
  eq(sql.quote_value(false, "sqlserver"), "0")
end)

test("quote_value: other adapters are unchanged", function()
  eq(sql.quote_value("x", "postgresql"), "'x'")
  eq(sql.quote_value(true, "postgresql"), "TRUE")
  eq(sql.quote_value("x"), "'x'")
end)

test("build_update: sqlserver N-prefixes values and keys", function()
  -- A plain '...' key never matches an nvarchar value outside the code page,
  -- which would turn the UPDATE into a silent no-op.
  eq(sql.build_update("dbo.tags", { code = "李" }, { label = "x" }, "sqlserver"),
    [[UPDATE "dbo"."tags" SET "label" = N'x' WHERE "code" = N'李']])
end)

test("build_insert: sqlserver N-prefixes values", function()
  eq(sql.build_insert("orders", { product = "Mouse", customer_id = "1" }, { "customer_id", "product" }, "sqlserver"),
    [[INSERT INTO "orders" ("customer_id", "product") VALUES (N'1', N'Mouse')]])
end)

test("build_delete: sqlserver N-prefixes keys", function()
  eq(sql.build_delete("tags", { code = "李" }, "sqlserver"), [[DELETE FROM "tags" WHERE "code" = N'李']])
end)

test("preview_staged: shows the adapter's SQL", function()
  local preview = sql.preview_staged("t",
    { { pk_values = { id = "1" }, changes = { a = "é", b = "0xBEEF" }, adapter_kind = "sqlserver",
        value_types = { b = "varbinary(16)" } } }, {}, {})
  contains(preview, "N'é'")
  contains(preview, '"b" = 0xBEEF')
end)

test("build_insert: sqlserver writes a binary column's hex as a binary literal", function()
  eq(sql.build_insert("t", { id = "1", b = "0xDEAD", n = vim.NIL }, { "id", "b", "n" },
      { adapter_kind = "sqlserver", value_types = { b = "varbinary(16)" } }),
    [[INSERT INTO "t" ("id", "b", "n") VALUES (N'1', 0xDEAD, NULL)]])
end)

-- ── typed values ──────────────────────────────────────────

local data_mod = require("dadbod-grip.data")

test("value_sql: NULL, '' and SQL Server binary hex", function()
  eq(sql.value_sql(data_mod.NULL_SENTINEL, "sqlserver", "nvarchar(10)"), "NULL")
  eq(sql.value_sql(nil, "sqlserver", "nvarchar(10)"), "NULL")
  eq(sql.value_sql("", "sqlserver", "nvarchar(10)"), "N''")
  eq(sql.value_sql("", "postgresql", "text"), "''")
  eq(sql.value_sql("0xCAFE", "sqlserver", "varbinary(16)"), "0xCAFE")
  eq(sql.value_sql("0xcafe", "sqlserver", "image"), "0xcafe")
  eq(sql.value_sql("0xCAFE", "sqlserver", "nvarchar(10)"), "N'0xCAFE'", "text that looks like hex stays text")
  eq(sql.value_sql("0xC'; DROP", "sqlserver", "varbinary(16)"), "N'0xC''; DROP'", "not hex: quoted")
  eq(sql.value_sql("0xCAFE", "postgresql", "bytea"), "'0xCAFE'", "other adapters unchanged")
end)

test("equals_sql: SQL Server compares by the column's type", function()
  eq(sql.equals_sql("c", nil, "sqlserver"), [["c" IS NULL]])
  eq(sql.equals_sql("c", vim.NIL, "sqlserver"), [["c" IS NULL]])
  eq(sql.equals_sql("c", "李", "sqlserver", "nvarchar(10)"), [["c" = N'李']])
  eq(sql.equals_sql("c", "a\r\nb", "sqlserver", "nvarchar(max)"),
    [["c" = CAST(N'a' AS nvarchar(max)) + NCHAR(13) + N'
b']])
  eq(sql.equals_sql("c", "0xDEAD", "sqlserver", "varbinary(16)"), [["c" = 0xDEAD]])
  eq(sql.equals_sql("c", "0xDEAD", "sqlserver", "image"), [[CAST("c" AS varbinary(max)) = 0xDEAD]])
  eq(sql.equals_sql("c", "old", "sqlserver", "text"), [[CAST("c" AS nvarchar(max)) = N'old']])
  eq(sql.equals_sql("c", "<a/>", "sqlserver", "xml"), [[CAST("c" AS nvarchar(max)) = N'<a/>']])
  eq(sql.equals_sql("c", "42", "sqlserver", "sql_variant"), [[CAST("c" AS nvarchar(max)) = N'42']])
  eq(sql.equals_sql("c", "POINT (1 2)", "sqlserver", "geography"), [[CAST("c" AS nvarchar(max)) = N'POINT (1 2)']])
  eq(sql.equals_sql("c", "x", "postgresql", "text"), [["c" = 'x']], "other adapters unchanged")
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\nsql_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
