-- sqlserver_write_spec.lua: the SQL Server grid transaction, without a server.
-- The script it compiles, the events it reads back, and the adapter's
-- grid_write around a mocked sqlcmd. live_workflow_spec.lua runs the same
-- path against a real server.
local data = require("dadbod-grip.data")
local transaction = require("dadbod-grip.transaction")
local writer = require("dadbod-grip.sqlserver_write")
local sqlserver = require("dadbod-grip.adapters.sqlserver")

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
local function eq(a, b, msg)
  assert(vim.deep_equal(a, b), (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end
local function contains(s, needle, msg)
  assert(s:find(needle, 1, true), (msg or "") .. ": expected to find '" .. needle .. "' in:\n" .. s)
end
local function lacks(s, needle, msg)
  assert(not s:find(needle, 1, true), (msg or "") .. ": did not expect '" .. needle .. "' in:\n" .. s)
end

local INFO = {
  { column_name = "id", data_type = "int" },
  { column_name = "code", data_type = "varchar(10)" },
  { column_name = "note", data_type = "nvarchar(50)" },
  { column_name = "b", data_type = "varbinary(max)" },
  { column_name = "body", data_type = "text" },
  { column_name = "total", data_type = "decimal(21,2)", generated = true },
  { column_name = "rv", data_type = "timestamp", generated = true },
}
local COLUMNS = { "id", "code", "note", "b", "body", "total", "rv" }

local function grid(rows)
  return data.new({
    rows = rows or {
      { "1", "a", vim.NIL, "0xDEAD", "old", "2.00", "0x00000000000007D1" },
      { "2", "", "x", "<binary 9000 bytes>", vim.NIL, vim.NIL, "0x00000000000007D2" },
    },
    columns = COLUMNS, primary_keys = { "id" }, table_name = "dbo.things",
    storage_adapter = "sqlserver", generated_columns = { total = true, rv = true },
    column_types = { id = "int", code = "varchar(10)", note = "nvarchar(50)", b = "varbinary(max)",
      body = "text", total = "decimal(21,2)", rv = "timestamp" },
  })
end
local function compile(state)
  local plan = assert(transaction.plan(state, INFO))
  return assert(transaction.compile(plan, "sqlserver")), plan
end

test("compile: one transaction inside TRY, with commit and rollback markers", function()
  local script = compile(data.add_change(grid(), 1, "note", "n"))
  contains(script, "SET XACT_ABORT ON;")
  contains(script, "BEGIN TRY\nBEGIN TRANSACTION;")
  contains(script, "COMMIT TRANSACTION;\nSELECT N'__GRIP_COMMIT__';\nEND TRY")
  contains(script, "BEGIN CATCH\nIF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;\nSELECT N'__GRIP_ROLLBACK__';\nTHROW;\nEND CATCH")
end)

test("compile: an update locks and checks the row as loaded, by each column's type", function()
  local script = compile(data.add_change(grid(), 1, "note", "it's"))
  contains(script, 'FROM "dbo"."things" WITH (UPDLOCK, HOLDLOCK) WHERE ')
  contains(script, [["id" = N'1']], "key")
  contains(script, [["code" = N'a']])
  contains(script, [["note" IS NULL]], "NULL")
  contains(script, [["b" = 0xDEAD]], "binary literal")
  contains(script, [[CAST("body" AS nvarchar(max)) = N'old']], "text compared as text")
  contains(script, [["rv" = 0x00000000000007D1]], "rowversion guards against a concurrent edit")
  contains(script, [[UPDATE "dbo"."things" SET "note" = N'it''s' WHERE ]])
  contains(script, "IF @@ROWCOUNT <> 1 THROW 51000")
  contains(script, "__GRIP_EVENT__1:before:")
  contains(script, "__GRIP_EVENT__1:after:")
end)

test("compile: a varchar key keeps a plain literal, a non-ASCII one stays N'...'", function()
  local rows = { { "k", "x" } }
  local function script_for(key)
    rows[1][1] = key
    local st = data.new({ rows = rows, columns = { "code", "v" }, primary_keys = { "code" }, table_name = "t",
      storage_adapter = "sqlserver" })
    local plan = assert(transaction.plan(data.add_change(st, 1, "v", "y"),
      { { column_name = "code", data_type = "varchar(10)" }, { column_name = "v", data_type = "nvarchar(10)" } }))
    return assert(transaction.compile(plan, "sqlserver"))
  end
  contains(script_for("o'k"), [["code" = 'o''k']])
  contains(script_for("李"), [["code" = N'李']])
end)

test("compile: a binary placeholder is compared by length and never written", function()
  local script = compile(data.add_change(grid(), 2, "note", "y"))
  contains(script, [[DATALENGTH("b") = 9000]])
  lacks(script, "N'<binary 9000 bytes>'")
  local plan = assert(transaction.plan(data.add_change(grid(), 1, "b", "<binary 9000 bytes>"), INFO))
  local refused, err = transaction.compile(plan, "sqlserver")
  eq(refused, nil, "refused")
  contains(err, "never loaded")
end)

test("compile: a delete's receipt carries every byte, an update's keeps the placeholder", function()
  local deleted = compile(data.toggle_delete(grid(), 2))
  contains(deleted, [[CONVERT(varchar(max), CONVERT(varbinary(max), "b"), 1) AS [c4],]])
  lacks(deleted, "<binary ', DATALENGTH", "no placeholder in a delete's receipt")
  contains(deleted, [[DELETE FROM "dbo"."things" WHERE ]])
  local updated = compile(data.add_change(grid(), 2, "note", "y"))
  contains(updated, [[CASE WHEN DATALENGTH("b") > 8000 THEN CONCAT(N'<binary ', DATALENGTH("b"), N' bytes>')]])
end)

test("compile: an insert captures its key with OUTPUT and skips generated columns", function()
  local script = compile(data.clone_row(grid(), 1))
  contains(script, [[SELECT TOP 0 "id" INTO #grip_k1 FROM (SELECT "id" FROM "dbo"."things" UNION ALL SELECT "id" FROM "dbo"."things") AS s]])
  contains(script, [[INSERT INTO "dbo"."things" ("code", "note", "b", "body") OUTPUT inserted."id" INTO #grip_k1 VALUES (N'a', NULL, 0xDEAD, N'old')]])
  lacks(script, "IDENTITY_INSERT", "a new row takes the server's key")
  contains(script, [[WHERE EXISTS (SELECT 1 FROM #grip_k1 AS k WHERE k."id" = t."id")]])
  local blank = compile(data.insert_row(grid(), 2))
  contains(blank, [[INSERT INTO "dbo"."things" OUTPUT inserted."id" INTO #grip_k1 DEFAULT VALUES]])
end)

-- The events a server would print for `plan`, from before/after rows.
local function event(i, phase, row)
  local cells = {}
  for ci, value in ipairs(row) do
    cells[ci] = '"c' .. ci .. '":' .. (value == vim.NIL and "null" or vim.json.encode(value))
  end
  return "__GRIP_EVENT__" .. i .. ":" .. phase .. ":{" .. table.concat(cells, ",") .. "}"
end

test("events: rows read as a grid page does, in plan column order", function()
  local _, plan = compile(data.add_change(grid(), 1, "note", "n"))
  local before = { "1", "a", vim.NIL, "0xDEAD", "old", "2.00", "0x00000000000007D1" }
  local after = { "1", "a", "n", "0xDEAD", "old", "2.00", "0x00000000000007D5" }
  local out = table.concat({ event(1, "before", before), event(1, "after", after), "__GRIP_COMMIT__" }, "\n")
  local events = assert(writer.events(plan, out, sqlserver._decode_json_row, sqlserver._json_cell))
  eq(events[1].before.values, before)
  eq(events[1].after.values, after)
  local none, err = writer.events(plan, event(1, "before", before), sqlserver._decode_json_row, sqlserver._json_cell)
  eq(none, nil, "no commit marker, no events")
  contains(err, "commit")
end)

-- sqlcmd stand-in: records the script, answers with `stdout` and `code`.
local function with_sqlcmd(stdout, code, fn)
  local orig_system, orig_exe, script = vim.system, vim.fn.executable, nil
  vim.fn.executable = function() return 1 end
  vim.system = function(args, _opts, cb)
    for i, a in ipairs(args) do
      if a == "-i" then script = table.concat(vim.fn.readfile(args[i + 1], "b"), "\n") end
    end
    local r = { stdout = stdout, stderr = "", code = code or 0 }
    if cb then cb(r) end
    return { wait = function() return r end, kill = function() end }
  end
  local ok, err = pcall(fn, function() return script end)
  vim.system, vim.fn.executable = orig_system, orig_exe
  if not ok then error(err, 0) end
end
local URL = "sqlserver://sa:pw@localhost:1433/grip_test"

test("grid_write: a committed batch returns the plan that undoes it", function()
  local state = data.toggle_delete(data.add_change(grid(), 1, "note", "n"), 2)
  local plan = assert(transaction.plan(state, INFO))
  -- Deletes come first in a plan: op 1 is the delete of row 2.
  local deleted = { "2", "", "x", "0x" .. string.rep("AB", 9000), vim.NIL, vim.NIL, "0x00000000000007D2" }
  local before = { "1", "a", vim.NIL, "0xDEAD", "old", "2.00", "0x00000000000007D1" }
  local after = { "1", "a", "n", "0xDEAD", "old", "2.00", "0x00000000000007D5" }
  local out = table.concat({ event(1, "before", deleted), event(2, "before", before), event(2, "after", after),
    "__GRIP_COMMIT__" }, "\n")
  with_sqlcmd(out, 0, function(script)
    local lifecycle = {}
    local result, err = sqlserver.grid_write(plan, URL, { write_lifecycle = lifecycle })
    assert(result, err)
    eq(result.affected, 2)
    contains(script(), "BEGIN TRANSACTION")
    eq(result.sql:find("BEGIN TRANSACTION", 1, true) ~= nil, true, "the script is kept for history")
    local undo = result.undo
    eq(undo.ops[1].kind, "update", "reversed in reverse order")
    eq(undo.ops[1].values, { note = vim.NIL }, "the edit goes back to NULL")
    eq(undo.ops[1].expected.rv, "0x00000000000007D5", "checked against the row as written")
    eq(undo.ops[2].kind, "insert")
    eq(undo.ops[2].restore, true)
    eq(#undo.ops[2].values.b, 2 + 18000, "the deleted row's binary, whole")

    local undo_script = assert(transaction.compile(undo, "sqlserver"))
    contains(undo_script, [[SET IDENTITY_INSERT "dbo"."things" ON]])
    contains(undo_script, [[INSERT INTO "dbo"."things" ("id", "code", "note", "b", "body")]])
    contains(undo_script, "was not restored as it was")
    lacks(undo_script:match("was not restored.-\n") or "", '"rv"', "generated columns are not compared after a restore")
  end)
end)

test("grid_write: a server refusal is an error with the rollback proved", function()
  local plan = assert(transaction.plan(data.add_change(grid(), 1, "note", "n"), INFO))
  local out = "__GRIP_ROLLBACK__\nMsg 51000, Level 16, State 1, Server x, Line 6\n"
    .. "Grip: the row of operation 1 changed or no longer exists; refresh and retry\n"
  with_sqlcmd(out, 1, function()
    local lifecycle = {}
    local result, err = sqlserver.grid_write(plan, URL, { write_lifecycle = lifecycle })
    eq(result, nil)
    contains(err, "changed or no longer exists")
    lacks(err, "__GRIP_ROLLBACK__", "the error starts at the server's message")
    eq(lifecycle.rollback_confirmed, true)
  end)
end)

test("grid_write: output without a commit or a server message proves nothing", function()
  local plan = assert(transaction.plan(data.add_change(grid(), 1, "note", "n"), INFO))
  with_sqlcmd("", 1, function()
    local lifecycle = {}
    local result = sqlserver.grid_write(plan, URL, { write_lifecycle = lifecycle })
    eq(result, nil)
    eq(lifecycle.rollback_confirmed, false, "left for write.execute to report as unknown")
  end)
  with_sqlcmd("garbage\n", 0, function()
    local result, err = sqlserver.grid_write(plan, URL, { write_lifecycle = {} })
    eq(result, nil)
    contains(err, "identity result", "exit 0 without a commit marker is not a success")
  end)
end)

test("grid_write: a read-only connection never reaches sqlcmd", function()
  local adapters = require("dadbod-grip.adapters")
  local plan = assert(transaction.plan(data.add_change(grid(), 1, "note", "n"), INFO))
  with_sqlcmd("__GRIP_COMMIT__\n", 0, function(script)
    local previous = adapters.set_call_readonly(true)
    local ok, result, err = pcall(sqlserver.grid_write, plan, URL, {})
    adapters.set_call_readonly(previous)
    assert(ok, result)
    eq(result, nil)
    contains(err, "read-only")
    eq(script(), nil, "nothing was run")
  end)
end)

print(string.format("\nsqlserver_write_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
