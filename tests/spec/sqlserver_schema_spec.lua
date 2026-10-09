-- sqlserver_schema_spec.lua: parse-level tests for the sqlserver schema queries
-- (get_schema_batch / get_column_info).
--
-- The schema tests mirror the pg/mysql/sqlite get_schema_batch tests in
-- adapter_spec.lua: feed sqlcmd's tab-separated output through the real parser
-- and assert on the structure, without a server.
--
-- This file used to also carry a generic "adapters.run_cmd_async contract"
-- section (added alongside the SQL Server watchdog work); it moved to
-- tests/spec/run_cmd_async_spec.lua in full, so run_cmd_async has one home
-- instead of two.
local sqlserver = require("dadbod-grip.adapters.sqlserver")

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

local function contains(s, needle, msg)
  assert(s:find(needle, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. needle .. "'")
end

-- ── mock helpers ─────────────────────────────────────────────────────────────

local function with_system_mock(stdout, stderr, code, fn)
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    local r = { stdout = stdout, stderr = stderr or "", code = code or 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
end

local function capture_system_args(stdout, fn)
  local captured
  local orig = vim.system
  vim.system = function(args, opts, cb)
    captured = args
    captured._stdin = opts and opts.stdin
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured
end

local function with_executable(fn)
  local orig = vim.fn.executable
  vim.fn.executable = function() return 1 end
  local ok, err = pcall(fn)
  vim.fn.executable = orig
  if not ok then error(err) end
end

local URL = "sqlserver://sa:pw@localhost:1433/grip_test"

local function lines(t)
  return table.concat(t, "\n") .. "\n"
end

-- ── get_schema_batch ─────────────────────────────────────────────────────────

local BATCH_OUT = lines({
  "table_name\tcolumn_name\tdata_type\tis_nullable",
  "----------\t-----------\t---------\t-----------",
  "users\tid\tint\tNO",
  "users\tname\tnvarchar(100)\tNO",
  "users\temail\tnvarchar(255)\tYES",
  "orders\tid\tint\tNO",
  "orders\ttotal\tdecimal(10,2)\tNO",
  "",
  "(5 rows affected)",
})

test("sqlserver get_schema_batch: groups columns by table", function()
  local result
  with_executable(function()
    with_system_mock(BATCH_OUT, "", 0, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  assert(result, "result must not be nil")
  assert(result["users"], "must have users key")
  assert(result["orders"], "must have orders key")
  eq(#result["users"], 3, "users has 3 columns")
  eq(#result["orders"], 2, "orders has 2 columns")
  eq(result["users"][2].column_name, "name", "users second column")
  eq(result["users"][2].data_type, "nvarchar(100)", "length suffix survives")
  eq(result["users"][2].is_nullable, "NO", "name is NOT NULL")
  eq(result["users"][3].is_nullable, "YES", "email is nullable")
  eq(result["orders"][2].data_type, "decimal(10,2)", "precision,scale suffix survives")
end)

test("sqlserver get_schema_batch: (N rows affected) is not a column row", function()
  local result
  with_executable(function()
    with_system_mock(BATCH_OUT, "", 0, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  for tname, cols in pairs(result) do
    contains(tname, "", "table name")
    assert(not tname:find("rows affected", 1, true), "row-count line leaked in as a table: " .. tname)
    for _, c in ipairs(cols) do
      assert(not c.column_name:find("rows affected", 1, true),
        "row-count line leaked in as a column of " .. tname)
    end
  end
  eq(#result["orders"], 2, "orders still has exactly 2 columns")
end)

test("sqlserver get_schema_batch: failure returns nil", function()
  local result = "unset"
  with_executable(function()
    with_system_mock("", "Login failed for user 'sa'.", 1, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  eq(result, nil, "must return nil when sqlcmd fails")
end)

-- A server error is not a result grid: with -b sqlcmd exits non-zero and prints
-- "Msg 208, ..." on stdout, and the parser must never be handed that as data.
test("sqlserver get_schema_batch: Msg error text is not parsed as a grid", function()
  local msg = lines({
    "Msg 208, Level 16, State 1, Server abc, Line 2",
    "Invalid object name 'INFORMATION_SCHEMA.COLUMNS'.",
  })
  local result = "unset"
  with_executable(function()
    with_system_mock(msg, "", 1, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  eq(result, nil, "error text must not become a schema table")
end)

test("sqlserver query: Msg error text on stdout becomes err, not columns", function()
  local msg = lines({
    "Msg 208, Level 16, State 1, Server abc, Line 2",
    "Invalid object name 'dbo.no_such_table'.",
  })
  local result, err = "unset", nil
  with_executable(function()
    with_system_mock(msg, "", 1, function()
      result, err = sqlserver.query("SELECT * FROM dbo.no_such_table", URL)
    end)
  end)
  eq(result, nil, "no result on error")
  assert(err, "err must be set")
  contains(err, "Msg 208", "err carries the server message")
  contains(err, "Invalid object name", "err carries the detail line")
end)

test("sqlserver execute: server error is an error, not a successful 0 rows", function()
  local msg = lines({
    "Msg 3726, Level 16, State 1, Server abc, Line 1",
    "Could not drop object 'dbo.users' because it is referenced by a FOREIGN KEY constraint.",
  })
  local result, err = "unset", nil
  with_executable(function()
    with_system_mock(msg, "", 1, function()
      result, err = sqlserver.execute('DROP TABLE "dbo"."users"', URL)
    end)
  end)
  eq(result, nil, "no result on error")
  assert(err, "err must be set")
  contains(err, "Msg 3726", "err carries the server message")
end)

-- A batch that fails at run time has already printed the successful statements'
-- row counts, and those must not end up in front of the error the user reads.
test("sqlserver execute: row counts before the error are stripped from err", function()
  local out = lines({
    "(3 rows affected)",
    "Msg 3726, Level 16, State 1, Server abc, Line 1",
    "Could not drop object 'dbo.users' because it is referenced by a FOREIGN KEY constraint.",
  })
  local err
  with_executable(function()
    with_system_mock(out, "", 1, function()
      local _, e = sqlserver.execute("UPDATE dbo.products SET price = price; DROP TABLE dbo.users;", URL)
      err = e
    end)
  end)
  assert(err, "err must be set")
  eq(err:sub(1, 3), "Msg", "err starts at the server message")
  assert(not err:find("rows affected", 1, true), "row-count noise must be gone: " .. err)
  contains(err, "FOREIGN KEY constraint", "the detail line is kept")
end)

test("sqlserver execute: failure text without a Msg line is passed through whole", function()
  local err
  with_executable(function()
    with_system_mock("Sqlcmd: Error: Internal error at ConnectDb.\n", "", 1, function()
      local _, e = sqlserver.execute("SELECT 1", URL)
      err = e
    end)
  end)
  contains(err, "Internal error at ConnectDb", "non-Msg output survives")
end)

test("sqlserver: sqlcmd runs with -b (without it the server exits 0 on errors)", function()
  with_executable(function()
    for _, case in ipairs({
      { "query", function() sqlserver.query("SELECT 1", URL) end },
      { "execute", function() sqlserver.execute("UPDATE dbo.users SET age = 1", URL) end },
    }) do
      local args = capture_system_args("id\n--\n1\n", case[2])
      local found = false
      for _, a in ipairs(args) do
        if a == "-b" then found = true end
      end
      assert(found, case[1] .. " must pass -b: " .. table.concat(args, " "))
    end
  end)
end)

test("sqlserver: sqlcmd stdin ends with a newline (go-sqlcmd skips an unterminated line)", function()
  with_executable(function()
    for _, case in ipairs({
      { "query", function() sqlserver.query("SELECT 1", URL) end },
      { "execute", function() sqlserver.execute("UPDATE dbo.users SET age = 1", URL) end },
    }) do
      local args = capture_system_args("id\n--\n1\n", case[2])
      eq(args._stdin:sub(-1), "\n", case[1] .. " stdin is newline-terminated")
    end
  end)
end)

test("sqlserver: sqlcmd runs with -y 8000 (the default cuts (max) values to 256)", function()
  with_executable(function()
    local args = capture_system_args("id\n--\n1\n", function() sqlserver.query("SELECT 1", URL) end)
    local width
    for i, a in ipairs(args) do
      if a == "-y" then width = args[i + 1] end
    end
    eq(width, "8000", "-y width: " .. table.concat(args, " "))
  end)
end)

-- ── editable grids ──────────────────────────────────────────────────────────

test("sqlserver: grids are editable (no adapter-wide readonly)", function()
  eq(sqlserver.readonly, nil)
  eq(require("dadbod-grip.db").is_readonly(URL), false)
end)

test("sqlserver query: clean output stays editable", function()
  with_executable(function()
    with_system_mock(lines({ "id\tname", "--\t----", "1\tAlice", "2\tNULL" }), "", 0, function()
      local r = sqlserver.query("SELECT id, name FROM dbo.users", URL)
      eq(#r.rows, 2)
      eq(r.rows[2][2], "", "NULL is an empty cell")
      eq(r.readonly, nil)
    end)
  end)
end)

test("sqlserver text output: a newline inside a value makes the grid read-only", function()
  with_executable(function()
    with_system_mock(lines({ "id\tnote\tqty", "--\t----\t---", "1\tline one", "line two\t5" }), "", 0, function()
      eq(sqlserver.query("SELECT * FROM dbo.notes", URL).readonly, true)
    end)
  end)
end)

test("sqlserver text output: a tab inside a value makes the grid read-only", function()
  with_executable(function()
    with_system_mock(lines({ "id\tnote", "--\t----", "1\ta\tb" }), "", 0, function()
      eq(sqlserver.query("SELECT * FROM dbo.notes", URL).readonly, true)
    end)
  end)
end)

test("sqlserver text output: a value at the -y width makes the grid read-only", function()
  with_executable(function()
    local cut = string.rep("x", 8000)
    with_system_mock(lines({ "id\tnote", "--\t----", "1\t" .. cut }), "", 0, function()
      eq(sqlserver.query("SELECT * FROM dbo.notes", URL).readonly, true)
    end)
    -- 4000 two-byte characters is 8000 bytes but well under the width.
    local wide = string.rep("é", 4000)
    with_system_mock(lines({ "id\tnote", "--\t----", "1\t" .. wide }), "", 0, function()
      eq(sqlserver.query("SELECT * FROM dbo.notes", URL).readonly, nil)
    end)
  end)
end)

-- ── JSON pages ──────────────────────────────────────────────────────────────

local JSON_PAGE_OUT = lines({
  "name\tsystem_type_name",
  "----\t----------------",
  "id\tint",
  "note\tnvarchar(max)",
  "blob\tvarbinary(max)",
  "ratio\tfloat",
  "",
  "_grip_json",
  "----------",
  [[{"id":1,"note":"line one\nline two\ttabbed","blob":"3q2+7w==","ratio":1.500000000000000e+000}]],
  [[{"id":9223372036854775807,"note":null,"blob":null,"ratio":null}]],
})

test("sqlserver json_page_sql: grid queries are rewritten, everything else is not", function()
  local table_sql = sqlserver._json_page_sql(
    'SELECT * FROM "dbo"."my ""t""" WHERE ("id" > 1) ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY')
  contains(table_sql, [[SELECT (SELECT "dbo"."my ""t""".* FOR JSON PATH]], "table rows")
  contains(table_sql, [[FROM "dbo"."my ""t""" WHERE ("id" > 1) ORDER BY]], "original tail kept")
  contains(table_sql, [[dm_exec_describe_first_result_set(N'SELECT * FROM "dbo"]], "described first")

  local raw_sql = sqlserver._json_page_sql("SELECT * FROM (SELECT 'a' AS x) AS _grip ORDER BY (SELECT NULL)")
  contains(raw_sql, "SELECT (SELECT _grip.* FOR JSON PATH", "raw wrapper rows")
  contains(raw_sql, "N'SELECT * FROM (SELECT ''a'' AS x) AS _grip", "describe literal escaped")

  eq(sqlserver._json_page_sql("SELECT id FROM dbo.users"), nil, "explicit column list")
  eq(sqlserver._json_page_sql("SELECT * FROM dbo.users"), nil, "unquoted name")
  eq(sqlserver._json_page_sql("SELECT * FROM (SELECT 1 AS x) AS t"), nil, "foreign wrapper")
  eq(sqlserver._json_page_sql("EXEC sp_who"), nil, "not a SELECT")
end)

test("sqlserver decode_json_row: values keep their exact text", function()
  local keys, values = sqlserver._decode_json_row(
    [[{"a":"x\"y\\z\/","b":-12.3400,"c":true,"d":false,"e":null,"f":"é"}]])
  eq(table.concat(keys, ","), "a,b,c,d,e,f")
  eq(values[1], [[x"y\z/]], "escapes")
  eq(values[2], "-12.3400", "number text")
  eq(values[3], "1", "true")
  eq(values[4], "0", "false")
  eq(values[5], "", "null")
  eq(values[6], "é", "unicode escape")

  eq(sqlserver._decode_json_row([[{"a":{"b":1}}]]), nil, "nested object")
  eq(sqlserver._decode_json_row([[{"a":"cut off]]), nil, "truncated row")
  eq(sqlserver._decode_json_row([[{"a":1}x]]), nil, "trailing text")
end)

test("sqlserver query: a JSON page keeps tabs, newlines, exact numbers and hex binaries", function()
  with_executable(function()
    with_system_mock(JSON_PAGE_OUT, "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "notes" LIMIT 100', URL))
      eq(table.concat(r.columns, ","), "id,note,blob,ratio")
      eq(#r.rows, 2)
      eq(r.rows[1][2], "line one\nline two\ttabbed", "value intact")
      eq(r.rows[1][3], "0xDEADBEEF", "base64 shown as hex")
      eq(r.rows[1][4], "1.5", "float shortened")
      eq(r.rows[2][1], "9223372036854775807", "bigint exact")
      eq(r.rows[2][2], "", "NULL is an empty cell")
      eq(r.readonly, nil, "editable")
    end)
  end)
end)

test("sqlserver query: an empty JSON page still has its columns", function()
  with_executable(function()
    local out = lines({ "name\tsystem_type_name", "----\t----------------", "id\tint", "", "_grip_json", "----------" })
    with_system_mock(out, "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "notes" LIMIT 100', URL))
      eq(table.concat(r.columns, ","), "id")
      eq(#r.rows, 0)
    end)
  end)
end)

test("sqlserver query: a page JSON cannot carry falls back to the text output", function()
  with_executable(function()
    local calls = {}
    local orig = vim.system
    vim.system = function(_args, opts, cb)
      calls[#calls + 1] = opts.stdin
      local r = #calls == 1
        and { stdout = "Msg 13604, Level 16, State 1\nFOR JSON cannot serialize CLR objects.\n", stderr = "", code = 1 }
        or { stdout = lines({ "id\tshape", "--\t-----", "1\tPOINT (4 52)" }), stderr = "", code = 0 }
      cb(r)
    end
    local ok, r, err = pcall(sqlserver.query, 'SELECT * FROM "places" LIMIT 100', URL)
    vim.system = orig
    assert(ok, r)
    assert(r, err)
    eq(#calls, 2, "text query after the JSON one")
    contains(calls[1], "FOR JSON", "first call")
    assert(not calls[2]:find("FOR JSON", 1, true), "second call is plain")
    eq(r.rows[1][2], "POINT (4 52)")
  end)
end)

test("sqlserver query: an ordinary error is not retried as text", function()
  with_executable(function()
    local calls = 0
    local orig = vim.system
    vim.system = function(_args, _opts, cb)
      calls = calls + 1
      local r = { stdout = "Msg 208, Level 16, State 1\nInvalid object name 'nope'.\n", stderr = "", code = 1 }
      cb(r)
    end
    local ok, r, err = pcall(sqlserver.query, 'SELECT * FROM "nope" LIMIT 100', URL)
    vim.system = orig
    assert(ok, r)
    eq(r, nil)
    contains(err, "Invalid object name")
    eq(calls, 1)
  end)
end)

test("sqlserver execute: a read-only connection never reaches sqlcmd", function()
  local adapters = require("dadbod-grip.adapters")
  with_executable(function()
    local spawned = false
    local orig = vim.system
    vim.system = function() spawned = true end
    local previous = adapters.set_call_readonly(true)
    local ok, result, err = pcall(sqlserver.execute, "DELETE FROM dbo.users", URL)
    adapters.set_call_readonly(previous)
    vim.system = orig
    assert(ok, result)
    eq(result, nil)
    contains(err, "read-only")
    eq(spawned, false, "sqlcmd spawned")
  end)
end)

test("sqlserver: declares a readonly_caveat", function()
  contains(sqlserver.readonly_caveat(URL), "no read-only session")
end)

-- ── get_column_info ─────────────────────────────────────────────────────────

local COLUMN_INFO_OUT = lines({
  "COLUMN_NAME\tdata_type\tIS_NULLABLE\tcolumn_default\t",
  "-----------\t---------\t-----------\t--------------\t-",
  "id\tint\tNO\t\t",
  "name\tnvarchar(100)\tNO\t\t",
  "body\tnvarchar(max)\tYES\t\t",
  "created_at\tdatetime2\tNO\t(sysutcdatetime())\t",
  "",
})

test("sqlserver get_column_info: parses name, type, nullability and default", function()
  local cols, err
  with_executable(function()
    with_system_mock(COLUMN_INFO_OUT, "", 0, function()
      cols, err = sqlserver.get_column_info("dbo.long_values", URL)
    end)
  end)
  assert(not err, "should not error: " .. tostring(err))
  eq(#cols, 4, "four columns")
  eq(cols[1].column_name, "id", "first column name")
  eq(cols[1].data_type, "int", "int has no suffix")
  eq(cols[2].data_type, "nvarchar(100)", "length suffix")
  eq(cols[3].data_type, "nvarchar(max)", "MAX types keep (max)")
  eq(cols[3].is_nullable, "YES", "nullable")
  eq(cols[4].column_default, "(sysutcdatetime())", "default expression")
end)

test("sqlserver get_column_info: schema-qualified name is split into schema + table", function()
  local args
  with_executable(function()
    args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("sales.invoices", URL)
    end)
  end)
  local sent = args._stdin
  contains(sent, "TABLE_SCHEMA = 'sales'", "schema from the qualified name")
  contains(sent, "TABLE_NAME = 'invoices'", "bare table name")
end)

test("sqlserver get_column_info: unqualified name defaults to dbo", function()
  local args
  with_executable(function()
    args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("users", URL)
    end)
  end)
  contains(args._stdin, "TABLE_SCHEMA = 'dbo'", "dbo is the default schema")
end)

-- MAX types report CHARACTER_MAXIMUM_LENGTH = -1, which the plain `> 0` guard
-- silently dropped; both statements must ask for the (max) arm.
test("sqlserver: batch and column_info both handle CHARACTER_MAXIMUM_LENGTH = -1", function()
  with_executable(function()
    local batch_args = capture_system_args(BATCH_OUT, function()
      sqlserver.get_schema_batch(URL)
    end)
    local info_args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("users", URL)
    end)
    for _, case in ipairs({ { "get_schema_batch", batch_args }, { "get_column_info", info_args } }) do
      local sent = case[2]._stdin
      contains(sent, "CHARACTER_MAXIMUM_LENGTH = -1", case[1] .. " must special-case MAX types")
      contains(sent, "'(max)'", case[1] .. " must render them as (max)")
    end
  end)
end)

-- The two statements must stay in sync: a table read from the batch and the same
-- table read per-table have to report the same data_type string.
test("sqlserver: batch and column_info share one data_type expression", function()
  local function type_expr(sent)
    return sent:match("(DATA_TYPE %+.-END AS data_type)")
  end
  with_executable(function()
    local batch_args = capture_system_args(BATCH_OUT, function()
      sqlserver.get_schema_batch(URL)
    end)
    local info_args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("users", URL)
    end)
    local a = type_expr(batch_args._stdin)
    local b = type_expr(info_args._stdin)
    assert(a, "batch statement must contain the data_type expression")
    assert(b, "column_info statement must contain the data_type expression")
    eq(a, b, "the two data_type expressions must be identical")
  end)
end)

-- ── get_referencing_foreign_keys ────────────────────────────────────────────
-- Columns are child_schema, child_table, fk_column, ref_column, constraint_name.

test("sqlserver get_referencing_foreign_keys: parses one inbound FK", function()
  local out = lines({
    "child_schema\tchild_table\tfk_column\tref_column\tconstraint_name",
    "------------\t-----------\t---------\t----------\t---------------",
    "dbo\torders\tuser_id\tid\tfk_orders_users",
    "",
  })
  local refs, err
  with_executable(function()
    with_system_mock(out, "", 0, function()
      refs, err = sqlserver.get_referencing_foreign_keys("users", URL)
    end)
  end)
  assert(not err, "should not error: " .. tostring(err))
  eq(#refs, 1, "one referencing table")
  eq(refs[1].table, "orders", "dbo children are named without the schema")
  eq(refs[1].column, "user_id", "fk column")
  eq(refs[1].ref_column, "id", "referenced column")
  eq(refs[1].composite, nil, "a single-column FK is not composite")
end)

-- Two rows sharing a constraint name are one two-column FK, not two FKs: the
-- CASCADE/warning logic counts entries, so ungrouped rows would double-count.
test("sqlserver get_referencing_foreign_keys: composite FK groups into one entry", function()
  local out = lines({
    "child_schema\tchild_table\tfk_column\tref_column\tconstraint_name",
    "------------\t-----------\t---------\t----------\t---------------",
    "dbo\tchild\ta\ta\tfk_child_parent",
    "dbo\tchild\tb\tb\tfk_child_parent",
    "dbo\tother\tp\ta\tfk_other_parent",
    "",
  })
  local refs
  with_executable(function()
    with_system_mock(out, "", 0, function()
      refs = sqlserver.get_referencing_foreign_keys("parent", URL)
    end)
  end)
  eq(#refs, 2, "two referencing tables, not three rows")
  eq(refs[1].table, "child", "grouped entry keeps the child table")
  eq(refs[1].column, "a,b", "both fk columns, in ordinal order")
  eq(refs[1].ref_column, "a,b", "both referenced columns")
  eq(refs[1].composite, true, "flagged composite")
  eq(refs[2].composite, nil, "the single-column FK stays plain")
end)

test("sqlserver get_referencing_foreign_keys: non-dbo children keep their schema", function()
  local out = lines({
    "child_schema\tchild_table\tfk_column\tref_column\tconstraint_name",
    "------------\t-----------\t---------\t----------\t---------------",
    "sales\tinvoices\tuser_id\tid\tfk_invoices_users",
    "dbo\torders\tuser_id\tid\tfk_orders_users",
    "",
  })
  local refs
  with_executable(function()
    with_system_mock(out, "", 0, function()
      refs = sqlserver.get_referencing_foreign_keys("users", URL)
    end)
  end)
  eq(#refs, 2, "two referencing tables")
  eq(refs[1].table, "sales.invoices", "other schemas are qualified, like list_tables")
  eq(refs[2].table, "orders", "dbo stays implicit")
end)

test("sqlserver get_referencing_foreign_keys: target schema comes from the name", function()
  with_executable(function()
    local qualified = capture_system_args("", function()
      sqlserver.get_referencing_foreign_keys("sales.invoices", URL)
    end)
    contains(qualified._stdin, "ps.name = 'sales'", "qualified name selects its schema")
    contains(qualified._stdin, "pt.name = 'invoices'", "bare table name")

    local bare = capture_system_args("", function()
      sqlserver.get_referencing_foreign_keys("users", URL)
    end)
    contains(bare._stdin, "ps.name = 'dbo'", "unqualified name defaults to dbo")
    contains(bare._stdin, "pt.name = 'users'", "table name")
  end)
end)

test("sqlserver get_referencing_foreign_keys: query failure returns {} and err", function()
  local refs, err = "unset", nil
  with_executable(function()
    with_system_mock("Msg 262, Level 14, State 1, Server abc, Line 1\nVIEW DEFINITION permission denied.\n",
      "", 1, function()
        refs, err = sqlserver.get_referencing_foreign_keys("users", URL)
      end)
  end)
  eq(type(refs), "table", "always a table, never nil")
  eq(#refs, 0, "no entries on failure")
  assert(err, "err must be set")
  contains(err, "Msg 262", "err carries the server message")
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nsqlserver_schema_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
