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

--- What sqlcmd was given to run: the -i script file's contents, or stdin.
--- Read inside the mock, since the adapter removes the file afterwards.
local function script_of(args, opts)
  for i, a in ipairs(args) do
    if a == "-i" then return table.concat(vim.fn.readfile(args[i + 1], "b"), "\n") end
  end
  return opts and opts.stdin
end

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
    captured._stdin = script_of(args, opts)
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

test("sqlserver: statements reach sqlcmd as a script file, never through stdin", function()
  with_executable(function()
    local args, script, path, piped
    local orig = vim.system
    vim.system = function(a, opts, cb)
      args = a
      for i, v in ipairs(a) do
        if v == "-i" then path = a[i + 1] end
      end
      script = path and table.concat(vim.fn.readfile(path, "b"), "\n")
      piped = opts and opts.stdin
      cb({ stdout = "(1 row affected)\n", stderr = "", code = 0 })
    end
    -- Microsoft's ODBC sqlcmd breaks a line read from a pipe every ~4096 bytes.
    local long = string.rep("x", 5000)
    local ok, err = pcall(sqlserver.execute, "UPDATE t SET v = N'" .. long .. "'", URL)
    vim.system = orig
    assert(ok, err)
    assert(path, "-i missing: " .. table.concat(args, " "))
    eq(piped, nil, "nothing on stdin")
    contains(script, long, "the statement, its line unbroken")
    eq(vim.fn.filereadable(path), 0, "script file removed afterwards")
  end)
end)

test("sqlserver: sqlcmd script ends with a newline (go-sqlcmd skips an unterminated line on stdin)", function()
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
    -- Microsoft's ODBC sqlcmd refuses -y together with -W.
    assert(not vim.tbl_contains(args, "-W"), "-W with -y: " .. table.concat(args, " "))
  end)
end)

test("sqlserver: sqlcmd runs with -x (no $(var) substitution inside values)", function()
  with_executable(function()
    local args = capture_system_args("id\n--\n1\n", function() sqlserver.execute("SELECT 1", URL) end)
    assert(vim.tbl_contains(args, "-x"), "-x missing: " .. table.concat(args, " "))
  end)
end)

-- ── editable grids ──────────────────────────────────────────────────────────

test("sqlserver: grids are editable (no adapter-wide readonly)", function()
  eq(sqlserver.readonly, nil)
  eq(require("dadbod-grip.db").is_readonly(URL), false)
end)

test("sqlserver text output: always read-only (fields are trimmed, NULL is ambiguous)", function()
  with_executable(function()
    with_system_mock(lines({ "id\tname", "--\t----", "1\tAlice   ", "2\tNULL" }), "", 0, function()
      local r = sqlserver.query("SELECT id, name FROM dbo.users", URL)
      eq(r.rows[1][2], "Alice", "trimmed")
      eq(r.rows[2][2], "", "NULL is an empty cell")
      eq(r.readonly, true)
      eq(r.readonly_reason, "plain text output")
    end)
  end)
end)

-- ── JSON pages ──────────────────────────────────────────────────────────────

--- Answer successive sqlcmd calls from `replies` ({stdout, code} each) and
--- return the stdin of every call.
local function with_replies(replies, fn)
  local calls = {}
  local orig = vim.system
  vim.system = function(args, opts, cb)
    calls[#calls + 1] = script_of(args, opts)
    local reply = replies[#calls] or replies[#replies]
    cb({ stdout = reply[1], stderr = "", code = reply[2] })
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return calls
end

--- The single line a DESCRIBE_SQL batch prints: { {"id", "int"}, ... } as JSON.
local function describe_line(cols)
  local parts = {}
  for _, c in ipairs(cols) do
    parts[#parts + 1] = vim.json.encode({ name = c[1], system_type_name = c[2] })
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local JSON_PAGE_OUT = lines({
  describe_line({ { "id", "int" }, { "note", "nvarchar(max)" }, { "blob", "varbinary(max)" }, { "ratio", "float" } }),
  [[{"id":1,"note":"line one\nline two\ttabbed","blob":"0xDEADBEEF","ratio":1.500000000000000e+000}]],
  [[{"id":9223372036854775807,"note":null,"blob":null,"ratio":null}]],
})

test("sqlserver json_page_sql: grid queries are rewritten, everything else is not", function()
  local table_sql = sqlserver._json_page_sql(
    'SELECT * FROM "dbo"."my ""t""" WHERE ("id" > 1) ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY')
  contains(table_sql, [[FROM "dbo"."my ""t""" WHERE ("id" > 1) ORDER BY]], "original tail kept")
  contains(table_sql, [[DECLARE @q nvarchar(max) = N'SELECT * FROM "dbo"."my ""t""" WHERE]], "the statement described")
  contains(table_sql, "ORDER BY column_ordinal FOR JSON PATH, INCLUDE_NULL_VALUES);",
    "describe is a single JSON line")
  contains(table_sql, [[N'"dbo"."my ""t""".' + QUOTENAME(name)]], "columns qualified by the source")
  contains(table_sql, "CONVERT(varchar(max), CONVERT(varbinary(max), ", "binaries as hex, by the server")
  contains(table_sql, "<binary ", "large binaries as a placeholder")
  contains(table_sql, "AS nvarchar(max))", "CLR types as text")
  contains(table_sql, "EXEC (", "row objects built from the description")
  assert(not table_sql:find("_grip_json", 1, true), "no header alias needed")

  local raw_sql = sqlserver._json_page_sql("SELECT * FROM (SELECT 'a' AS x) AS _grip ORDER BY (SELECT NULL)")
  contains(raw_sql, "N'_grip.' + QUOTENAME(name)", "raw wrapper columns")
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

test("sqlserver query: JSON pages run with -y 0 and no header flags", function()
  with_executable(function()
    local args = capture_system_args(JSON_PAGE_OUT, function()
      sqlserver.query('SELECT * FROM "notes" LIMIT 100', URL)
    end)
    local width
    for i, a in ipairs(args) do
      if a == "-y" then width = args[i + 1] end
    end
    eq(width, "0", "-y width: " .. table.concat(args, " "))
    assert(not vim.tbl_contains(args, "-h"), "-h is refused next to -y 0")
    assert(not vim.tbl_contains(args, "-W"), "-W is refused next to -y")
  end)
end)

test("sqlserver query: a value over 8000 characters arrives whole and editable", function()
  with_executable(function()
    local long = string.rep("x", 20000)
    local out = lines({ describe_line({ { "id", "int" }, { "body", "varchar(max)" } }),
      '{"id":1,"body":"' .. long .. '"}' })
    with_system_mock(out, "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "documents" LIMIT 100', URL))
      eq(#r.rows[1][2], 20000, "whole value")
      eq(r.readonly, nil, "editable")
    end)
  end)
end)

test("sqlserver query: text, ntext and image columns are reported as incomparable", function()
  with_executable(function()
    local out = lines({
      describe_line({ { "id", "int" }, { "txt", "text" }, { "ntxt", "ntext" }, { "name", "nvarchar(10)" },
        { "doc", "xml" }, { "loc", "geography" }, { "shape", "geometry" } }),
      [[{"id":1,"txt":"a","ntxt":"b","name":"c","doc":"<a/>","loc":"POINT (1 2)","shape":"POINT (0 0)"}]],
    })
    with_system_mock(out, "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "legacy" LIMIT 100', URL))
      eq(r.incomparable_columns.txt, true)
      eq(r.incomparable_columns.ntxt, true)
      eq(r.incomparable_columns.name, nil)
      eq(r.incomparable_columns.doc, true, "xml cannot be compared with =")
      eq(r.incomparable_columns.loc, true, "geography cannot be compared with =")
      eq(r.incomparable_columns.shape, true, "geometry cannot be compared with =")
    end)
  end)
end)

test("sqlserver query: a server warning between JSON rows is not a row", function()
  with_executable(function()
    local out = JSON_PAGE_OUT .. "Warning: Null value is eliminated by an aggregate or other SET operation.\n"
    with_system_mock(out, "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "notes" LIMIT 100', URL))
      eq(#r.rows, 2)
      eq(r.readonly, nil)
    end)
  end)
end)

test("sqlserver query: an empty JSON page still has its columns", function()
  with_executable(function()
    with_system_mock(lines({ describe_line({ { "id", "int" } }) }), "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "notes" LIMIT 100', URL))
      eq(table.concat(r.columns, ","), "id")
      eq(#r.rows, 0)
    end)
  end)
end)

test("sqlserver query: a describe without column names falls back to the text output", function()
  with_executable(function()
    local r
    local calls = with_replies({
      { lines({ '[{"name":null,"system_type_name":null}]' }), 0 },
      { lines({ "id", "--", "7" }), 0 },
    }, function()
      r = assert(sqlserver.query("SELECT * FROM (SELECT id FROM #t) AS _grip LIMIT 100", URL))
    end)
    eq(#calls, 2, "JSON, then text")
    assert(not calls[2]:find("FOR JSON", 1, true), "second call is plain")
    eq(r.rows[1][1], "7")
  end)
end)

local CLR_ERROR = "Msg 13604, Level 16, State 1\nFOR JSON cannot serialize CLR objects.\n"

test("sqlserver query: reports types, generated and required text columns, and empty strings", function()
  with_executable(function()
    local describe = vim.json.encode({
      { name = "id", system_type_name = "int", is_nullable = false, is_updateable = false, is_identity_column = true },
      { name = "code", system_type_name = "varchar(10)", is_nullable = false, is_updateable = true, is_identity_column = false },
      { name = "note", system_type_name = "nvarchar(50)", is_nullable = true, is_updateable = true, is_identity_column = false },
      { name = "total", system_type_name = "decimal(21,2)", is_nullable = true, is_updateable = false, is_identity_column = false },
      { name = "rv", system_type_name = "timestamp", is_nullable = false, is_updateable = false, is_identity_column = false },
    })
    local out = lines({ describe,
      [[{"id":1,"code":"","note":null,"total":2.00,"rv":"0x00000000000007D1"}]],
      [[{"id":2,"code":"x","note":"","total":null,"rv":"0x00000000000007D2"}]] })
    with_system_mock(out, "", 0, function()
      local r = assert(sqlserver.query('SELECT * FROM "versioned" LIMIT 100', URL))
      eq(r.column_types.code, "varchar(10)")
      eq(r.generated_columns.total, true, "computed")
      eq(r.generated_columns.rv, true, "rowversion")
      eq(r.generated_columns.id, nil, "identity is written back on undo")
      eq(r.required_text_columns.code, true, "NOT NULL text")
      eq(r.required_text_columns.note, nil, "nullable")
      eq(r.empty_cells[1][2], true, "'' in row 1")
      eq((r.empty_cells[1] or {})[3], nil, "NULL is not ''")
      eq(r.empty_cells[2][3], true, "'' in row 2")
      eq(r.rows[1][2], "", "rows still hold ''")
    end)
  end)
end)

test("sqlserver query: the page batch describes nullability and writability", function()
  local batch = sqlserver._json_page_sql('SELECT * FROM "t" ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY')
  contains(batch, "is_nullable")
  contains(batch, "is_updateable")
  contains(batch, "is_identity_column")
end)

test("sqlserver query: binaries and CLR columns arrive formatted, in one call", function()
  with_executable(function()
    local r
    local calls = with_replies({
      { lines({ describe_line({ { "id", "int" }, { "loc", "geography" }, { "blob", "varbinary(max)" } }),
        [[{"id":1,"loc":"POINT (4.9 52.4)","blob":"0xDEADBEEF"}]],
        [[{"id":2,"loc":null,"blob":"<binary 2097152 bytes>"}]] }), 0 },
    }, function()
      r = assert(sqlserver.query('SELECT * FROM "dbo"."places" LIMIT 100', URL))
    end)
    eq(#calls, 1, "one sqlcmd call")
    eq(r.rows[1][2], "POINT (4.9 52.4)")
    eq(r.rows[1][3], "0xDEADBEEF", "hex as the server sent it")
    eq(r.rows[2][3], "<binary 2097152 bytes>", "placeholder as the server sent it")
    eq(r.readonly, nil)
  end)
end)

test("sqlserver query: a page JSON cannot carry falls back to the text output", function()
  with_executable(function()
    local r
    local calls = with_replies({
      { CLR_ERROR, 1 },
      { lines({ "id\tshape", "--\t-----", "1\tPOINT (4 52)" }), 0 },
    }, function()
      r = assert(sqlserver.query('SELECT * FROM "places" LIMIT 100', URL))
    end)
    eq(#calls, 2, "JSON, then text")
    assert(not calls[2]:find("FOR JSON", 1, true), "last call is plain")
    eq(r.rows[1][2], "POINT (4 52)")
    eq(r.readonly, true, "text fallback is read-only")
  end)
end)

test("sqlserver text output: raw bytes make the grid read-only instead of breaking it", function()
  with_executable(function()
    with_system_mock(lines({ "id\tloc", "--\t---", "1\t\230\16\0\0\1" }), "", 0, function()
      local r = sqlserver.query("SELECT * FROM dbo.places", URL)
      eq(r.readonly, true)
      eq(r.readonly_reason, "plain text output")
      assert(not r.rows[1][2]:find("%z"), "NUL bytes stripped")
    end)
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

-- ── query pad: what can be wrapped and paged, what runs as written ─────────

test("plan_query: classifies query pad SQL", function()
  local cases = {
    { "customers", nil },
    { "UPDATE customers SET vip = 1", nil },
    { "SELECT * FROM customers WHERE vip = 1", "select" },
    { "SELECT 1;", "select" },
    { "/* lead */ SELECT * FROM customers", "select" },
    { "SELECT * FROM customers -- trailing", "select" },
    { "SELECT 'a;b' AS x", "select" },
    { "SELECT * FROM t WHERE x = 'ORDER BY y'", "select" },
    { "SELECT TOP 5 * FROM many ORDER BY id", "select" },
    { "SELECT * FROM t ORDER BY LEN(name)", "passthrough" },
    { "SELECT * FROM t ORDER BY 1", "passthrough" },
    { "SELECT 1 AS a; SELECT 2 AS b", "passthrough" },
    { "WITH x AS (SELECT 1 AS a) SELECT * FROM x", "passthrough" },
    { "EXEC sp_help 'customers'", "passthrough" },
    { "exec sp_who", "passthrough" },
    { "DECLARE @n int = 3; SELECT @n", "passthrough" },
    { "PRINT 'hi'; SELECT 1 AS a", "passthrough" },
    { "SELECT 1 AS a\nGO\nSELECT 2 AS b", "passthrough" },
    { "SELECT * INTO #t FROM customers", "passthrough" },
    { "SELECT * FROM t FOR JSON PATH", "passthrough" },
    { "SELEKT 1", nil },
    { "order lines", nil },
    { "my table", nil },
    { "SET NOCOUNT OFF; SELECT 1", "passthrough" },
    { "IF 1 = 1 SELECT 1", "passthrough" },
    { "TRUNCATE TABLE t", "passthrough" },
  }
  for _, c in ipairs(cases) do
    local plan = sqlserver.plan_query(c[1])
    eq(plan and plan.kind, c[2], c[1])
  end
end)

test("plan_query: a plain trailing ORDER BY becomes the grid's sort", function()
  local plan = sqlserver.plan_query("SELECT c.name, c.id FROM customers c ORDER BY c.name DESC, [id]")
  eq(plan.kind, "select")
  eq(plan.sql, "SELECT c.name, c.id FROM customers c")
  eq(#plan.sorts, 2)
  eq(plan.sorts[1].column, "name")
  eq(plan.sorts[1].dir, "DESC")
  eq(plan.sorts[2].column, "id")
  eq(plan.sorts[2].dir, "ASC")
  local top = sqlserver.plan_query("SELECT TOP 5 * FROM many ORDER BY id")
  eq(#top.sorts, 0, "ORDER BY with TOP is legal inside the wrapper")
  eq(top.sql, "SELECT TOP 5 * FROM many ORDER BY id")
end)

test("plan_query: read-only batches are capped at 1000 rows, others are not", function()
  local cap = "SET ROWCOUNT 1000; "
  eq(sqlserver.plan_query("SELECT * FROM t ORDER BY LEN(x)").prefix, cap)
  eq(sqlserver.plan_query("WITH x AS (SELECT 1 AS a) SELECT * FROM x").prefix, cap)
  eq(sqlserver.plan_query("DECLARE @n int = 1; SELECT @n").prefix, cap)
  eq(sqlserver.plan_query("EXEC sp_help 't'").prefix, nil, "ROWCOUNT would reach into the procedure")
  eq(sqlserver.plan_query("PRINT 'x'; DELETE FROM t").prefix, nil, "ROWCOUNT would limit the DELETE")
  eq(sqlserver.plan_query("SELECT * INTO #t FROM t; SELECT * FROM #t").prefix, nil, "would fill #t partly")
  eq(sqlserver.row_cap_prefix("SELECT u.name, COUNT(*) FROM u GROUP BY u.name"), cap)
end)

test("plan_query: a batch that writes is flagged", function()
  eq(sqlserver.plan_query("PRINT 'x'; DELETE FROM t").writes, true)
  eq(sqlserver.plan_query("DECLARE @t TABLE (a int); INSERT INTO @t VALUES (1); SELECT * FROM @t").writes, true)
  eq(sqlserver.plan_query("EXEC sp_help 'customers'").writes, false)
  eq(sqlserver.plan_query("SELECT 'DROP TABLE x' AS s; SELECT 1").writes, false, "inside a literal")
end)

test("sqlserver text output: the last result set wins, PRINT lines are not rows", function()
  local out = lines({ "hi", "a", "-", "1", "", "b\tc", "-\t-", "2\tx", "3\ty" })
  local r = sqlserver._parse_sqlcmd_table(out)
  eq(table.concat(r.columns, ","), "b,c")
  eq(#r.rows, 2)
  eq(r.rows[2][2], "y")
  local msg = sqlserver._parse_sqlcmd_table(lines({ "only a message" }))
  eq(#msg.columns, 0, "no result set")
  eq(msg.messages[1], "only a message")
end)

test("sqlcmd script: the session setup shares the first line, so error lines match", function()
  local script = sqlserver._sqlcmd_script("SELECT 1\nSELEKT 2")
  eq(select(2, script:gsub("\n", "")), 2, "two lines in, two lines out")
  assert(script:find("^SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON; SELECT 1\n"), script)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nsqlserver_schema_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
