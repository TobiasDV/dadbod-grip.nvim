dofile("tests/minimal_init.lua")
local view, data = require("dadbod-grip.view"), require("dadbod-grip.data")
local grip, db = require("dadbod-grip"), require("dadbod-grip.db")
local hints = require("dadbod-grip.result_hints")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function cleanup()
  local buffers = {}; for b in pairs(view._sessions) do buffers[#buffers + 1] = b end
  for _, b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function state()
  return data.new({ columns = { "id", "name" }, rows = { { "1", "first" } }, primary_keys = { "id" }, table_name = "users" })
end
local info = { status = "available", elapsed_ms = 12.345, source = "duckdb_profile", adapter = "duckdb", scope = "statement" }

test("engine label identifies DuckDB profiler latency and preserves tiny positive values", function()
  assert(hints.engine_time(info, math.huge):find("Engine: 12.3ms DuckDB profiler latency", 1, true))
  local tiny = vim.tbl_extend("force", info, { elapsed_ms = 0.00000001 })
  assert(not hints.engine_time(tiny, math.huge):find(" 0ms", 1, true))
  assert(hints.engine_time({ status = "unsupported" }, math.huge):find("Engine: unsupported", 1, true))
  assert(hints.engine_time({ status = "unavailable" }, math.huge):find("Engine: unavailable", 1, true))
end)

test("engine footer belongs to immutable result rows and returns on nav back", function()
  cleanup()
  local st = state()
  local buf = view.open(st, "sqlite:tests/seed_sqlite.db", nil, { elapsed_ms = 44, engine_timing = info })
  assert(text(buf):find("Query: 44ms client", 1, true))
  assert(text(buf):find("Engine: 12.3ms DuckDB profiler latency", 1, true), text(buf))
  view.apply_edit(buf, data.add_change(st, 1, "name", "changed"))
  assert(text(buf):find("Engine:", 1, true), "staging lost original engine time")
  view.render(buf, state())
  assert(not text(buf):find("Engine:", 1, true), "unrelated rows inherited engine time")
  view.render(buf, st)
  assert(text(buf):find("Engine:", 1, true), "nav back lost original engine time")
end)

test("public SELECT and refresh opt in; count and metadata stay unprofiled", function()
  cleanup()
  grip.setup({ engine_timing = true })
  local original, selected, counts = db.query, 0, 0
  db.query = function(sql, url, opts)
    local result, err = original(sql, url, opts)
    if sql:find("COUNT", 1, true) then
      counts = counts + 1; assert(not (opts and opts.engine_timing), "COUNT was profiled")
    elseif opts and opts.engine_timing then
      selected = selected + 1
      if result then result.engine_timing = vim.deepcopy(info) end
    end
    return result, err
  end
  local ok, err = xpcall(function()
    grip.open("users", "sqlite:tests/seed_sqlite.db", { from_pad = true })
    local buf, session = next(view._sessions)
    assert(buf and text(buf):find("Engine:", 1, true), "public open did not retain engine timing")
    assert(selected == 1 and counts == 1, "unexpected main SELECT/COUNT collection")
    assert(vim.wait(1000, function() return session._column_info ~= nil end, 5))
    assert(selected == 1, "column metadata was profiled")
    local st = session.state
    view.switch_view(buf, "columns")
    assert(not text(buf):find("Engine:", 1, true), "metadata inherited engine timing")
    view.switch_view(buf, "records")
    assert(text(buf):find("Engine:", 1, true))
    session.on_refresh(buf)
    assert(selected == 2 and session.state.rows ~= st.rows)
    assert(session._query_engine_times[session.state.rows].elapsed_ms == info.elapsed_ms)
    local before = text(buf)
    db.query = function() return nil, "synthetic failed refresh" end
    local notify = vim.notify; vim.notify = function() end
    local refreshed, refresh_err = pcall(session.on_refresh, buf)
    vim.notify = notify
    assert(refreshed, refresh_err); assert(text(buf) == before, "failed refresh replaced engine timing")
  end, debug.traceback)
  db.query = original
  grip.setup({ engine_timing = false })
  if not ok then error(err, 0) end
end)

for _, scenario in ipairs({ "wide", "narrow", "shared", "scroll", "zen", "hidden" }) do
  test("native stdio linegrid engine footer: " .. scenario, function()
    local child = vim.fn.jobstart({ vim.g.grip_test_progpath, "--clean", "--embed", "--headless", "-n", "-i", "NONE",
      "-u", "tests/minimal_init.lua" }, { rpc = true })
    local ok, err = pcall(function()
      vim.fn.rpcrequest(child, "nvim_ui_attach", scenario == "narrow" and 24 or 100, 30, { rgb = true })
      assert(vim.fn.rpcrequest(child, "nvim_exec_lua", "return dofile('tests/fixtures/engine_elapsed_footer.lua')(...)", { scenario }))
    end)
    vim.fn.jobstop(child)
    assert(ok, err)
  end)
end

cleanup()
print(string.format("engine_timing_ui_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
