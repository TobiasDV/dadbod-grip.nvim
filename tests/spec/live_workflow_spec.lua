-- Cross-adapter release scenario: real schema, CRUD, filter/sort/pagination,
-- requery, and export. CI assigns one live URL and makes skipping fatal.

local URL = vim.env.GRIP_TEST_LIVE_URL
local REQUIRED = vim.env.GRIP_REQUIRE_LIVE == "1"

local function unavailable(reason)
  if REQUIRED then error("live_workflow_spec: " .. reason .. " while GRIP_REQUIRE_LIVE=1") end
  print("SKIP: live_workflow_spec (" .. reason .. ")")
  print("\nlive_workflow_spec: 0 passed, 0 failed (skipped)")
end

if not URL or URL == "" then
  unavailable("GRIP_TEST_LIVE_URL not set")
  return
end

local db = require("dadbod-grip.db")
local data = require("dadbod-grip.data")
local importer = require("dadbod-grip.importer")
local query = require("dadbod-grip.query")
local sql = require("dadbod-grip.sql")
local view = require("dadbod-grip.view")

if not db.ping(URL) then
  unavailable("database is unreachable")
  return
end

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

local function eq(actual, expected, message)
  assert(actual == expected,
    (message or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

test("schema exposes seeded tables and primary keys", function()
  local tables, err = db.list_tables(URL)
  assert(tables, err)
  local found = false
  for _, item in ipairs(tables) do
    if item.name == "orders" or item.name == "dbo.orders" then found = true end
  end
  assert(found, "orders table missing: " .. vim.inspect(tables))
  local cols = assert(db.get_column_info("orders", URL))
  eq(cols[1].column_name, "id", "first column")
  eq(db.get_primary_keys("orders", URL)[1], "id", "primary key")
end)

test("CRUD round-trip changes only the probe table", function()
  db.execute("DROP TABLE IF EXISTS grip_live_probe", URL)
  local ok, err = pcall(function()
    assert(db.execute(
      "CREATE TABLE grip_live_probe (id INTEGER PRIMARY KEY, probe_value VARCHAR(40) NOT NULL)", URL))
    assert(db.execute(
      "INSERT INTO grip_live_probe (id, probe_value) VALUES (1, 'first'), (2, 'second')", URL))
    assert(db.execute("UPDATE grip_live_probe SET probe_value = 'updated' WHERE id = 2", URL))
    local result = assert(db.query("SELECT id, probe_value FROM grip_live_probe ORDER BY id", URL))
    eq(#result.rows, 2, "inserted rows")
    eq(result.rows[2][2], "updated", "updated value")
    assert(db.execute("DELETE FROM grip_live_probe WHERE id = 1", URL))
    eq(#assert(db.query("SELECT id FROM grip_live_probe", URL)).rows, 1, "deleted row")
  end)
  db.execute("DROP TABLE IF EXISTS grip_live_probe", URL)
  if not ok then error(err) end
end)

test("imported rows use the staged-insert pipeline and commit atomically", function()
  db.execute("DROP TABLE IF EXISTS grip_import_probe", URL)
  local ok, err = pcall(function()
    assert(db.execute(table.concat({
      "CREATE TABLE grip_import_probe (",
      "id INTEGER PRIMARY KEY,",
      "probe_value VARCHAR(40) NOT NULL,",
      "optional_note VARCHAR(40) NULL)",
    }, " "), URL))

    local columns = { "id", "probe_value", "optional_note" }
    local parsed = assert(importer.parse(table.concat({
      "id,probe_value,optional_note",
      "901,first import,kept",
      "902,second import,",
    }, "\n"), columns))
    local state = data.new({
      rows = {}, columns = columns, primary_keys = { "id" },
      table_name = "grip_import_probe", url = URL,
    })
    state = data.insert_rows_with_values(state, #state.rows, parsed.rows)

    local statements = {}
    for _, insert in ipairs(data.get_inserts(state)) do
      statements[#statements + 1] = sql.build_insert(
        state.table_name, insert.values, insert.columns)
    end
    assert(db.execute(sql.wrap_transaction(statements,
      require("dadbod-grip.adapters").kind(URL)), URL))

    local result = assert(db.query(
      "SELECT id, probe_value, optional_note FROM grip_import_probe ORDER BY id", URL))
    eq(#result.rows, 2, "imported row count")
    eq(result.rows[1][2], "first import", "first imported value")
    eq(result.rows[2][2], "second import", "second imported value")
    local null_count = assert(db.query(
      "SELECT COUNT(*) FROM grip_import_probe WHERE optional_note IS NULL", URL))
    eq(tonumber(null_count.rows[1][1]), 1, "empty import field committed as NULL")
  end)
  db.execute("DROP TABLE IF EXISTS grip_import_probe", URL)
  if not ok then error(err) end
end)

test("a failed staged-insert transaction commits no partial import", function()
  db.execute("DROP TABLE IF EXISTS grip_import_rollback_probe", URL)
  local ok, err = pcall(function()
    assert(db.execute(
      "CREATE TABLE grip_import_rollback_probe (id INTEGER PRIMARY KEY, probe_value VARCHAR(40))", URL))
    local statements = {
      sql.build_insert("grip_import_rollback_probe", { id = "903", probe_value = "first" },
        { "id", "probe_value" }),
      sql.build_insert("grip_import_rollback_probe", { id = "903", probe_value = "duplicate" },
        { "id", "probe_value" }),
    }
    local result, apply_err = db.execute(sql.wrap_transaction(statements,
      require("dadbod-grip.adapters").kind(URL)), URL)
    assert(not result and apply_err, "duplicate primary key unexpectedly succeeded")
    local count = assert(db.query("SELECT COUNT(*) FROM grip_import_rollback_probe", URL))
    eq(tonumber(count.rows[1][1]), 0, "failed import left a partial row")
  end)
  db.execute("DROP TABLE IF EXISTS grip_import_rollback_probe", URL)
  if not ok then error(err) end
end)

test("filter, sort, pagination, and requery preserve their contract", function()
  local spec = query.new_table("orders", 25)
  spec = query.add_filter(spec, '"id" > 25')
  spec = query.toggle_sort(spec, "id")
  spec = query.set_page(spec, 2)

  local page = assert(db.query(query.build_sql(spec), URL))
  eq(#page.rows, 25, "second page size")
  eq(tonumber(page.rows[1][1]), 51, "filter + offset")

  local count = assert(db.query(query.build_count_sql(spec), URL))
  eq(tonumber(count.rows[1][1]), 125, "matching count")

  local requery = query.set_page(query.toggle_sort(spec, "id"), 1)
  local reversed = assert(db.query(query.build_sql(requery), URL))
  eq(tonumber(reversed.rows[1][1]), 150, "requery applies descending sort")
end)

test("all-row export is complete and atomically written", function()
  local spec = query.add_filter(query.new_table("orders", 25), '"id" > 25')
  spec = query.toggle_sort(spec, "id")
  local result = assert(db.query(query.build_sql(spec, { paginate = false }), URL))
  eq(#result.rows, 125, "all matching rows fetched")

  local path = vim.fn.tempname() .. ".csv"
  local ok, err = view._write_export_file(result.rows, result.columns, "csv", "orders", path)
  assert(ok, err)
  eq(#vim.fn.readfile(path), 126, "header plus every matching row")
  eq(#vim.fn.glob(path .. ".grip-tmp-*", false, true), 0, "no partial file remains")
  vim.fn.delete(path)
end)

if URL:match("^sqlserver://") or URL:match("^mssql://") then
  test("SQL Server temporary tables share one submission but not the next", function()
    local name = "##grip_live_temp_scope"
    local result, err = db.query(table.concat({
      "CREATE TABLE " .. name .. " (id INT NOT NULL);",
      "GO",
      "INSERT INTO " .. name .. " VALUES (7);",
      "GO",
      "SELECT id FROM " .. name .. ";",
    }, "\n"), URL)
    assert(result, err)
    eq(tonumber(result.rows[1][1]), 7, "GO batches share one sqlcmd session")

    local next_result, next_err = db.query("SELECT id FROM " .. name, URL)
    assert(not next_result, "temporary table survived a new sqlcmd invocation")
    assert(next_err and next_err ~= "", "missing-object error was not reported")
  end)

  test("SQL Server staged writes keep Unicode keys and undo IDENTITY deletes", function()
    local probe = "grip_live_nprobe"
    local function apply(stmts)
      return db.execute(sql.wrap_transaction(stmts, "sqlserver"), URL)
    end
    local function rows()
      return assert(db.query("SELECT id, code, label FROM " .. probe .. " ORDER BY id", URL)).rows
    end
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe
        .. " (id INT IDENTITY(1,1) PRIMARY KEY, code NVARCHAR(20) UNIQUE, label NVARCHAR(40))", URL))
      local columns = { "id", "code", "label" }
      assert(apply({ sql.build_insert(probe, { code = "李", label = "first" }, columns, "sqlserver") }))
      eq(rows()[1][2], "李", "Unicode value stored, not '?'")

      -- A Unicode key must match, or the UPDATE is a silent no-op.
      assert(apply({ sql.build_update(probe, { code = "李" }, { label = "Zoë" }, "sqlserver") }))
      eq(rows()[1][3], "Zoë", "update matched the Unicode key")

      local before = rows()[1]
      assert(apply({ sql.build_delete(probe, { id = before[1] }, "sqlserver") }))
      eq(#rows(), 0, "row deleted")
      local values = { id = before[1], code = before[2], label = before[3] }
      assert(apply({ sql.build_reinsert(probe, values, columns, "sqlserver") }))
      eq(rows()[1][1], before[1], "undo restored the original IDENTITY key")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server grids keep multi-line values editable", function()
    local probe = "grip_live_multiline"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, note NVARCHAR(MAX), blob VARBINARY(8))", URL))
      assert(db.execute("INSERT INTO " .. probe
        .. " VALUES (1, N'line one' + CHAR(10) + N'line two' + CHAR(9) + N'tab', 0xDEADBEEF), (2, NULL, NULL)", URL))
      local spec = query.new_table(probe, 50)
      local page = assert(db.query(query.build_sql(spec), URL))
      eq(page.readonly, nil, "grid editable")
      eq(#page.rows, 2, "one row per record")
      eq(page.rows[1][2], "line one\nline two\ttab", "value intact")
      eq(page.rows[1][3], "0xDEADBEEF", "binary as hex")

      local edited = "first\nsecond\tthird"
      assert(db.execute(sql.wrap_transaction({
        sql.build_update(probe, { id = page.rows[1][1] }, { note = edited }, "sqlserver"),
      }, "sqlserver"), URL))
      eq(assert(db.query(query.build_sql(spec), URL)).rows[1][2], edited, "edit round-trips")

      -- sqlcmd reads its stdin line by line: a CRLF must keep its CR and
      -- "$(" must not be taken for a scripting variable.
      local long = string.rep("x", 5000) .. "\r\n" .. string.rep("y", 100)
      for _, value in ipairs({ "windows\r\nline", "costs $(amount)", long }) do
        assert(db.execute(sql.wrap_transaction({
          sql.build_update(probe, { id = "2" }, { note = value }, "sqlserver"),
        }, "sqlserver"), URL))
        local stored = assert(db.query(query.build_sql(spec), URL)).rows[2][2]
        eq(stored, value, "round-trip of " .. #value .. " characters")
        local hit = assert(db.query("SELECT COUNT(*) FROM " .. probe .. " WHERE note = "
          .. sql.quote_value(value, "sqlserver"), URL))
        eq(hit.rows[1][1], "1", "the value matches itself as a key")
      end

      local empty = assert(db.query(query.build_sql(query.add_filter(spec, '"id" < 0')), URL))
      eq(table.concat(empty.columns, ","), "id,note,blob", "empty page keeps its columns")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)
end

print(string.format("\nlive_workflow_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
