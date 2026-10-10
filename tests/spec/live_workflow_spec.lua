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

  test("SQL Server DDL renames and adds columns through sp_rename and ADD", function()
    local ddl = require("dadbod-grip.ddl")
    db.execute("DROP TABLE IF EXISTS grip_live_ddl_renamed", URL)
    db.execute("DROP TABLE IF EXISTS grip_live_ddl", URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE grip_live_ddl (id INT PRIMARY KEY, name NVARCHAR(40))", URL))
      assert(db.execute(ddl._build_rename_column_sql("grip_live_ddl", "name", "full_name", "sqlserver"), URL))
      assert(db.execute(ddl._build_add_column_sql("grip_live_ddl", "bio", "NVARCHAR(100)", "none", "sqlserver"), URL))
      assert(db.execute(ddl._build_rename_table_sql("grip_live_ddl", "grip_live_ddl_renamed", "sqlserver"), URL))
      local names = {}
      for _, col in ipairs(assert(db.get_column_info("grip_live_ddl_renamed", URL))) do
        names[#names + 1] = col.column_name
      end
      eq(table.concat(names, ","), "id,full_name,bio", "columns after DDL")
    end)
    db.execute("DROP TABLE IF EXISTS grip_live_ddl_renamed", URL)
    db.execute("DROP TABLE IF EXISTS grip_live_ddl", URL)
    if not ok then error(err) end
  end)

  test("SQL Server values over 8000 characters stay whole and editable", function()
    local probe = "grip_live_long"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, body NVARCHAR(MAX))", URL))
      assert(db.execute("INSERT INTO " .. probe
        .. " VALUES (1, REPLICATE(CAST(N'a' AS NVARCHAR(MAX)), 30000) + NCHAR(10) + N'end')", URL))
      local spec = query.new_table(probe, 50)
      local page = assert(db.query(query.build_sql(spec), URL))
      eq(page.readonly, nil, "editable")
      eq(#page.rows[1][2], 30004, "whole value")
      local edited = page.rows[1][2] .. "!"
      assert(db.execute(sql.wrap_transaction({
        sql.build_update(probe, { id = "1" }, { body = edited }, "sqlserver"),
      }, "sqlserver"), URL))
      eq(assert(db.query(query.build_sql(spec), URL)).rows[1][2], edited, "round-trip")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server finds an inserted row past text and ntext columns", function()
    local probe = "grip_live_legacy"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe
        .. " (id INT IDENTITY(1,1) PRIMARY KEY, name NVARCHAR(40), txt TEXT, ntxt NTEXT)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " (name, txt, ntxt) VALUES (N'one', 'a', N'b')", URL))
      local page = assert(db.query(query.build_sql(query.new_table(probe, 50)), URL))
      eq(page.incomparable_columns.txt, true, "text reported")
      local values = { name = "one", txt = "a", ntxt = "b" }
      local find_sql = sql.build_insert_lookup(probe, { "id" }, values, page.incomparable_columns, "sqlserver")
      local found = assert(db.query(find_sql, URL))
      eq(found.rows[1][1], "1", "row found")
      local _, unskipped_err = db.query(sql.build_insert_lookup(probe, { "id" }, values, nil, "sqlserver"), URL)
      assert(unskipped_err, "comparing text with = must fail, or this test proves nothing")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server pages of large binaries load quickly, with placeholders", function()
    local probe = "grip_live_blobs"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, blob VARBINARY(MAX))", URL))
      assert(db.execute("INSERT INTO " .. probe .. " SELECT n, CAST(REPLICATE(CAST('A' AS VARCHAR(MAX)), 2000000)"
        .. " AS VARBINARY(MAX)) FROM (VALUES (1), (2), (3), (4), (5)) AS v(n)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (6, 0x41)", URL))
      local started = vim.uv.hrtime()
      local page = assert(db.query(query.build_sql(query.new_table(probe, 50)), URL))
      local seconds = (vim.uv.hrtime() - started) / 1e9
      eq(page.rows[1][2], "<binary 2000000 bytes>", "large binary")
      eq(page.rows[6][2], "0x41", "small binary as hex")
      eq(page.readonly, nil, "grid stays editable")
      assert(seconds < 5, string.format("page took %.1f s", seconds))
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server geography columns load as editable text", function()
    local probe = "grip_live_places"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, loc GEOGRAPHY)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, geography::Point(52.37, 4.89, 4326))", URL))
      local spec = query.new_table(probe, 50)
      local page = assert(db.query(query.build_sql(spec), URL))
      eq(page.rows[1][2], "POINT (4.89 52.37)", "WKT")
      eq(page.readonly, nil, "editable")
      assert(db.execute(sql.wrap_transaction({
        sql.build_update(probe, { id = "1" }, { loc = "POINT (5 53)" }, "sqlserver"),
      }, "sqlserver"), URL))
      eq(assert(db.query(query.build_sql(spec), URL)).rows[1][2], "POINT (5 53)", "WKT written back")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  -- A grid over `probe` as the editor builds it, and the apply/undo the a and u
  -- keys run, so these tests go through the same statements.
  local function grid(probe)
    local page = assert(db.query(query.build_sql(query.new_table(probe, 50)), URL))
    page.primary_keys = db.get_primary_keys(probe, URL)
    page.table_name = probe
    return data.new(page)
  end
  local function run(stmts)
    if #stmts == 0 then return end
    local _, run_err = db.execute(sql.wrap_transaction(stmts, "sqlserver"), URL)
    assert(not run_err, run_err)
  end
  local function apply_grid(st)
    local undo, irreversible = sql.build_undo(st, "sqlserver")
    run(sql.build_apply(st, "sqlserver"))
    return undo, irreversible
  end
  local function dump(q)
    local out = {}
    for _, row in ipairs(assert(db.query(q, URL)).rows) do out[#out + 1] = table.concat(row, "|") end
    return table.concat(out, "\n")
  end

  test("SQL Server keeps empty strings apart from NULL through edit, delete and undo", function()
    local probe = "grip_live_empties"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe
        .. " (id INT PRIMARY KEY, req NVARCHAR(10) NOT NULL, opt NVARCHAR(10) NULL)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, N'', NULL), (2, N'x', N'')", URL))
      local function snap()
        return dump("SELECT id, ISNULL(req, '<null>'), ISNULL(opt, '<null>') FROM " .. probe .. " ORDER BY id")
      end
      local before = snap()
      local st = grid(probe)
      eq(data.effective_value(st, 1, "req"), "", "'' reads as ''")
      eq(data.effective_value(st, 1, "opt"), nil, "NULL reads as NULL")

      local undo = apply_grid(data.toggle_delete(st, 1))
      eq(dump("SELECT COUNT(*) FROM " .. probe), "1", "deleted")
      run(undo)
      eq(snap(), before, "undo of the delete")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server undo restores '' after an edit, and clearing NOT NULL text writes ''", function()
    local probe = "grip_live_empties2"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe
        .. " (id INT PRIMARY KEY, req NVARCHAR(10) NOT NULL, opt NVARCHAR(10) NULL)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, N'', NULL), (2, N'x', N'')", URL))
      local function snap()
        return dump("SELECT id, ISNULL(req, '<null>'), ISNULL(opt, '<null>') FROM " .. probe .. " ORDER BY id")
      end
      local before = snap()
      run((apply_grid(data.add_change(grid(probe), 2, "opt", "y"))))
      eq(snap(), before, "undo of an edit to a '' cell")

      local st = grid(probe)
      apply_grid(data.add_change(st, 2, "req", data.cleared_value(st, 2, "req")))
      eq(dump("SELECT COUNT(*) FROM " .. probe .. " WHERE id = 2 AND req = ''"), "1", "req is ''")

      st = data.clone_row(grid(probe), 1)
      st = data.add_change(st, st._next_insert_idx - 1, "id", "3")
      apply_grid(st)
      eq(dump("SELECT ISNULL(req, '<null>') FROM " .. probe .. " WHERE id = 3"), "", "clone kept ''")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server clones and undoes deletes past computed, rowversion and period columns", function()
    local probe, temporal = "grip_live_generated", "grip_live_temporal"
    local function drop()
      db.execute("DROP TABLE IF EXISTS " .. probe, URL)
      db.execute("IF OBJECT_ID('" .. temporal .. "') IS NOT NULL ALTER TABLE " .. temporal
        .. " SET (SYSTEM_VERSIONING = OFF)", URL)
      db.execute("DROP TABLE IF EXISTS " .. temporal, URL)
      db.execute("DROP TABLE IF EXISTS " .. temporal .. "_history", URL)
    end
    drop()
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe
        .. " (id INT IDENTITY(1,1) PRIMARY KEY, qty INT NOT NULL, total AS qty * 2, rv ROWVERSION)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " (qty) VALUES (5)", URL))
      local st = grid(probe)
      eq(st.generated_columns.total, true, "computed reported")
      eq(st.generated_columns.rv, true, "rowversion reported")
      apply_grid(data.clone_row(st, 1))
      eq(dump("SELECT COUNT(*) FROM " .. probe .. " WHERE qty = 5"), "2", "clone inserted")
      local undo = apply_grid(data.toggle_delete(grid(probe), 1))
      run(undo)
      eq(dump("SELECT id, qty, total FROM " .. probe .. " ORDER BY id"), "1|5|10\n2|5|10", "undo of the delete")

      assert(db.execute("CREATE TABLE " .. temporal .. " (id INT PRIMARY KEY, name NVARCHAR(20) NOT NULL,"
        .. " vf DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL, vt DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,"
        .. " PERIOD FOR SYSTEM_TIME (vf, vt)) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo."
        .. temporal .. "_history))", URL))
      assert(db.execute("INSERT INTO " .. temporal .. " (id, name) VALUES (1, N'first')", URL))
      st = data.clone_row(grid(temporal), 1)
      apply_grid(data.add_change(st, st._next_insert_idx - 1, "id", "2"))
      run((apply_grid(data.toggle_delete(grid(temporal), 1))))
      eq(dump("SELECT id, name FROM " .. temporal .. " ORDER BY id"), "1|first\n2|first", "temporal clone and undo")
    end)
    drop()
    if not ok then error(err) end
  end)

  test("SQL Server writes binary values as hex and restores them on undo", function()
    local probe = "grip_live_binary"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, b VARBINARY(16), img IMAGE, big VARBINARY(MAX))", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, 0xDEADBEEF, 0x0102, NULL),"
        .. " (2, NULL, NULL, CAST(REPLICATE(CAST('A' AS VARCHAR(MAX)), 9000) AS VARBINARY(MAX)))", URL))
      local function snap()
        return dump("SELECT id, CONVERT(varchar(50), b, 1), CONVERT(varchar(50), CAST(img AS varbinary(max)), 1) FROM "
          .. probe .. " ORDER BY id")
      end
      local before = snap()
      local st = data.add_change(grid(probe), 1, "b", "0xCAFE")
      run((apply_grid(data.add_change(st, 1, "img", "0xABCD"))))
      eq(snap(), before, "edit and undo")
      st = grid(probe)
      apply_grid(data.add_change(data.add_change(st, 1, "b", "0xCAFE"), 1, "img", "0xABCD"))
      eq(dump("SELECT CONVERT(varchar(50), b, 1) FROM " .. probe .. " WHERE id = 1"), "0xCAFE", "edit applied")
      run((apply_grid(data.toggle_delete(grid(probe), 1))))
      eq(dump("SELECT CONVERT(varchar(50), b, 1), CONVERT(varchar(50), CAST(img AS varbinary(max)), 1) FROM "
        .. probe .. " WHERE id = 1"), "0xCAFE|0xABCD", "undo of the delete")

      local _, irreversible = sql.build_undo(data.toggle_delete(grid(probe), 2), "sqlserver")
      eq(irreversible[1], 2, "a row with a binary over 8000 bytes is reported, not half-restored")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server query pad runs the SQL people type", function()
    local grip = require("dadbod-grip")
    -- { sql, rows, first cell of the last column of row 1, editable }
    local cases = {
      { "SELECT * FROM users ORDER BY name", 15, nil, true },
      { "SELECT name FROM users ORDER BY name DESC", 15, nil, true },
      { "SELECT u.name, COUNT(*) FROM orders o JOIN users u ON u.id = o.user_id GROUP BY u.name", nil, nil, false },
      { "WITH x AS (SELECT * FROM users) SELECT name FROM x WHERE name = N'Alice'", 1, "Alice", false },
      { "SELECT 1 AS a; SELECT 2 AS b", 1, "2", false },
      { "PRINT 'hi'; SELECT 3 AS a", 1, "3", false },
      { "DECLARE @n int = 2; SELECT TOP (@n) name FROM users ORDER BY id", 2, "Alice", false },
      { "EXEC sp_executesql N'SELECT 4 AS a'", 1, "4", false },
      { "SELECT 5 AS a\nGO\nSELECT 6 AS b", 1, "6", false },
      { "SELECT * FROM users -- every user", 15, nil, true },
      { "/* who */ SELECT name FROM users WHERE name = N'Bob'", 1, "Bob", true },
      { "SELECT name FROM users ORDER BY LEN(name), name", 15, nil, false },
    }
    for _, c in ipairs(cases) do
      local spec, table_name = grip._resolve_query(c[1], 50, "sqlserver")
      assert(spec, c[1] .. ": no spec (" .. tostring(table_name) .. ")")
      local fetched, used_spec, used_table = grip._fetch_grid(URL, spec, table_name)
      assert(fetched.result, c[1] .. ": " .. tostring(fetched.err))
      local r = fetched.result
      if c[2] then eq(#r.rows, c[2], c[1] .. " rows") else assert(#r.rows > 0, c[1] .. " rows") end
      if c[3] then eq(r.rows[1][#r.columns], c[3], c[1] .. " value") end
      eq(used_table ~= nil and not r.readonly, c[4], c[1] .. " editable")
      if used_spec.passthrough then eq(query.build_count_sql(used_spec), nil, "no count") end
    end
    local many = "WITH n AS (SELECT TOP 1500 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS i"
      .. " FROM sys.all_objects a CROSS JOIN sys.all_objects b) SELECT i FROM n"
    local capped = grip._fetch_grid(URL, (grip._resolve_query(many, 50, "sqlserver")))
    eq(#assert(capped.result, capped.err).rows, 1000, "a batch run as written stops at 1000 rows")
    local fallback = grip._fetch_grid(URL, (grip._resolve_query(
      "SELECT o.user_id, COUNT(*) FROM orders o CROSS JOIN orders p GROUP BY o.user_id, p.id", 50, "sqlserver")))
    eq(#assert(fallback.result, fallback.err).rows, 1000, "so does a SELECT the wrapper could not hold")
    local bad = grip._fetch_grid(URL, (grip._resolve_query("SELECT nope FROM users", 50, "sqlserver")))
    assert(not bad.result and tostring(bad.err):find("Invalid column name 'nope'", 1, true),
      "the server's own error: " .. tostring(bad.err))
  end)

  test("SQL Server profiles (gR, gS) tables with bit, image, text, xml and geography", function()
    local profile = require("dadbod-grip.profile")
    local probe = "grip_live_profile"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, flag BIT, img IMAGE, txt TEXT,"
        .. " doc XML, loc GEOGRAPHY, g UNIQUEIDENTIFIER, name NVARCHAR(20))", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, 1, 0x01, 'a', '<a/>', geography::Point(1, 2, 4326), NEWID(), N'x'),"
        .. " (2, 0, NULL, NULL, NULL, NULL, NULL, NULL)", URL))
      local data_report, report_err = profile.gather(probe, URL)
      assert(data_report, "gR: " .. tostring(report_err))
      eq(#data_report.profiles, 8, "every column profiled")
      for _, p in ipairs(data_report.profiles) do
        if p.name == "img" then eq(p.nulls, 1, "img nulls") end
        if p.name == "flag" then eq(p.max, "1", "bit max") end
      end
      for _, ci in ipairs(db.get_column_info(probe, URL)) do
        local cs, cs_err = profile.gather_column(probe, ci.column_name, ci.data_type, URL)
        assert(cs, "gS " .. ci.column_name .. ": " .. tostring(cs_err))
      end
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server quick filter finds the row for every kind of cell", function()
    local probe = "grip_live_filter"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, u NVARCHAR(20), ml NVARCHAR(MAX),"
        .. " b VARBINARY(8), img IMAGE, txt TEXT, nt NTEXT, doc XML, v SQL_VARIANT, loc GEOGRAPHY)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, N'李 😀', N'a' + CHAR(13) + CHAR(10) + N'b',"
        .. " 0xDEAD, 0x0102, 'old', N'ñ', N'<a b=\"1\"/>', CAST(42 AS INT), geography::Point(52, 4, 4326)),"
        .. " (2, N'other', N'x', 0x01, 0x03, 'new', N'n', N'<b/>', CAST(7 AS INT), NULL)", URL))
      local spec = query.new_table(probe, 50)
      local page = assert(db.query(query.build_sql(spec), URL))
      for i, col in ipairs(page.columns) do
        if col ~= "id" then
          local filtered = query.quick_filter(spec, col, page.rows[1][i],
            { kind = "sqlserver", type = page.column_types[col] })
          local hit, hit_err = db.query(query.build_sql(filtered), URL)
          assert(hit, col .. ": " .. tostring(hit_err))
          eq(#hit.rows, 1, col .. " rows")
          eq(hit.rows[1][1], "1", col .. " row")
        end
      end
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server can undo an insert whose values are all text or ntext", function()
    local probe = "grip_live_textonly"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT IDENTITY(1,1) PRIMARY KEY, txt TEXT, ntxt NTEXT)", URL))
      assert(db.execute("INSERT INTO " .. probe .. " (txt, ntxt) VALUES ('old', N'old')", URL))
      local st = grid(probe)
      local values = { txt = "new", ntxt = "nieuw ✓" }
      assert(db.execute(sql.build_insert(probe, values, st.columns, "sqlserver"), URL))
      local find_sql = sql.build_insert_lookup(probe, st.pks, values, st.incomparable_columns, "sqlserver",
        sql.state_opts(st))
      assert(find_sql, "a lookup, not none")
      eq(assert(db.query(find_sql, URL)).rows[1][1], "2", "the inserted row")
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server SQL export loads back into an identical table", function()
    local probe, copy = "grip_live_export", "grip_live_export_copy"
    local function drop()
      db.execute("DROP TABLE IF EXISTS " .. probe, URL)
      db.execute("DROP TABLE IF EXISTS " .. copy, URL)
    end
    drop()
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, u NVARCHAR(20), e VARCHAR(5) NOT NULL,"
        .. " n INT, b VARBINARY(8), ml NVARCHAR(MAX))", URL))
      assert(db.execute("INSERT INTO " .. probe .. " VALUES (1, N'李 😀', '', NULL, 0xDEAD, N'a' + CHAR(13) + CHAR(10) + N'b'),"
        .. " (2, NULL, 'x', 5, NULL, N'')", URL))
      assert(db.execute("SELECT * INTO " .. copy .. " FROM " .. probe .. " WHERE 1 = 0", URL))
      local result = assert(db.query(query.build_sql(query.new_table(probe, 50), { paginate = false }), URL))
      local path = vim.fn.tempname() .. ".sql"
      assert(view._write_export_file(view._export_rows_from_result(result), result.columns, "sql", copy, path,
        { kind = "sqlserver", types = result.column_types }))
      assert(db.execute(table.concat(vim.fn.readfile(path), "\n"), URL))
      vim.fn.delete(path)
      local function snap(t)
        return dump("SELECT id, ISNULL(u, '<null>'), e, ISNULL(CAST(n AS varchar), '<null>'),"
          .. " ISNULL(CONVERT(varchar(20), b, 1), '<null>'), ml FROM " .. t .. " ORDER BY id")
      end
      eq(snap(copy), snap(probe), "same rows")
    end)
    drop()
    if not ok then error(err) end
  end)

  test("SQL Server undo of a clone deletes the clone, never the original (GUID keys)", function()
    local probe = "grip_live_guid"
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe
        .. " (id UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY, label NVARCHAR(20) NOT NULL)", URL))
      for _ = 1, 10 do
        db.execute("DELETE FROM " .. probe, URL)
        assert(db.execute("INSERT INTO " .. probe .. " (label) VALUES (N'first')", URL))
        local original = dump("SELECT id FROM " .. probe)
        local st = data.clone_row(data.clone_row(grid(probe), 1), 1)
        local plan = assert(sql.build_inserted_keys(st, "sqlserver"))
        local before = assert(db.query(plan.sql, URL)).rows
        run(sql.build_apply(st, "sqlserver"))
        local after = assert(db.query(plan.sql, URL)).rows
        local keys = sql.match_inserted_keys(plan, before, after, st.pks)
        assert(keys[1] and keys[2], "both clones found")
        run({ sql.build_delete(probe, keys[1], "sqlserver"), sql.build_delete(probe, keys[2], "sqlserver") })
        eq(dump("SELECT id FROM " .. probe), original, "only the original is left")
      end
    end)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)

  test("SQL Server reports the server's error for a view it cannot describe", function()
    local probe, broken = "grip_live_base", "grip_live_broken"
    db.execute("DROP VIEW IF EXISTS " .. broken, URL)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    local ok, err = pcall(function()
      assert(db.execute("CREATE TABLE " .. probe .. " (id INT PRIMARY KEY, gone INT)", URL))
      assert(db.execute("EXEC ('CREATE VIEW " .. broken .. " AS SELECT id, gone FROM " .. probe .. "')", URL))
      assert(db.execute("ALTER TABLE " .. probe .. " DROP COLUMN gone", URL))
      local page, qerr = db.query(query.build_sql(query.new_table(broken, 50)), URL)
      eq(page, nil, "no page")
      assert(tostring(qerr):find("Invalid column name 'gone'", 1, true), "server error: " .. tostring(qerr))
    end)
    db.execute("DROP VIEW IF EXISTS " .. broken, URL)
    db.execute("DROP TABLE IF EXISTS " .. probe, URL)
    if not ok then error(err) end
  end)
end

print(string.format("\nlive_workflow_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
