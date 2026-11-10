local url = vim.env.GRIP_TEST_PG_URL
if not url or url == "" then
  assert(vim.env.GRIP_REQUIRE_POSTGRES ~= "1", "demo_postgres_spec requires GRIP_TEST_PG_URL")
  print("SKIP: demo_postgres_spec (GRIP_TEST_PG_URL not set)")
  print("\ndemo_postgres_spec: 0 passed, 0 failed (skipped)")
  return
end

local pg = require("dadbod-grip.adapters.postgresql")
local created = false
local ok, err = pcall(function()
  local path = "demo/softrear_postgres.sql"
  assert(vim.fn.filereadable(path) == 1, "bundled PostgreSQL lab seed missing")
  assert(pg.execute(table.concat(vim.fn.readfile(path), "\n"), url))
  created = true
  local counts = assert(pg.query([[SELECT
    (SELECT COUNT(*) FROM grip_demo.incidents),
    (SELECT COUNT(*) FROM grip_demo.incidents_2026_01),
    (SELECT COUNT(*) FROM grip_demo.open_incidents),
    grip_demo.severity_label(8)]], url))
  assert(vim.deep_equal(counts.rows[1], { "4", "2", "2", "high" }), vim.inspect(counts.rows))
  local objects = {}
  for _, item in ipairs(assert(pg.list_tables(url))) do objects[item.name] = item end
  local parent, year, leaf = objects["grip_demo.incidents"], objects["grip_demo.incidents_2026"],
    objects["grip_demo.incidents_2026_01"]
  assert(parent and parent.relation_kind == "p", "parent partition metadata missing")
  assert(year and year.is_partition and year.parent_id == parent.relation_id, "first partition level missing")
  assert(leaf and leaf.is_partition and leaf.parent_id == year.relation_id, "nested partition link missing")
  assert(objects["grip_demo.open_incidents"].type == "view", "lab view not listed")
  local found
  for _, routine in ipairs(assert(pg.list_routines(url))) do
    if routine.schema == "grip_demo" and routine.name:find("severity_label", 1, true) then found = routine end
  end
  assert(found, "lab function not listed")
  local source = assert(pg.get_routine_source(found.source_id or found.name, url))
  assert(source:find("CASE", 1, true), "function source cannot be browsed")
end)
if created then
  local cleaned, cleanup_err = pg.execute("DROP SCHEMA grip_demo CASCADE", url)
  assert(cleaned, cleanup_err)
end
if not ok then
  print("FAIL: PostgreSQL lab retains real hierarchy and callable/browsable function: " .. tostring(err))
  print("\ndemo_postgres_spec: 0 passed, 1 failed")
  os.exit(1)
end
print("\ndemo_postgres_spec: 1 passed, 0 failed")
