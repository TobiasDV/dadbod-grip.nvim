-- Real disposable DuckDB writes through public preview/apply mappings.
dofile("tests/minimal_init.lua")
if vim.fn.executable("duckdb") ~= 1 then
  assert(vim.env.GRIP_REQUIRE_DUCKDB ~= "1", "DuckDB required but unavailable")
  print("engine_timing_write_spec: SKIPPED (duckdb not found)"); return
end
local grip, view, db = require("dadbod-grip"), require("dadbod-grip.view"), require("dadbod-grip.db")
local adapters = require("dadbod-grip.adapters")
local opts = grip.get_opts()
local confirm, notify = vim.fn.confirm, vim.notify
vim.fn.confirm = function() return 1 end
local errors = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = tostring(msg) end
end
local path = vim.fn.tempname() .. "_engine_write.duckdb"
local url = "duckdb:" .. path
local pass, fail = 0, 0
local function cleanup()
  local buffers = {}; for b in pairs(view._sessions) do buffers[#buffers + 1] = b end
  for _, b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
end
local function test(name, fn)
  cleanup()
  errors = {}
  grip.setup({ engine_timing = true, show_result_time = true, show_running_time = true, show_hints = true, timeout = 2000 })
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function open(sql)
  grip.open(sql, url, { from_pad = true })
  local buf = vim.api.nvim_get_current_buf()
  return buf, assert(view._sessions[buf], "public open did not create a grid")
end
local function apply()
  local map = vim.fn.maparg(require("dadbod-grip.keymaps").get("grid_apply"), "n", false, true)
  assert(type(map.callback) == "function"); map.callback()
end
assert(db.execute("CREATE TABLE writes(id INTEGER PRIMARY KEY, value VARCHAR); INSERT INTO writes VALUES(1,'one')", url))
assert(require("dadbod-grip.engine_timing").options({ engine_timing = true }))

test("successful single mutation retains distinct write and SELECT profiler latency", function()
  local _, preview = open("INSERT INTO writes VALUES(2,'two')")
  assert(preview.pending_mutation)
  apply()
  local buf = vim.api.nvim_get_current_buf()
  local session = assert(view._sessions[buf])
  assert(session._write_engine_times[session.state.rows].status == "available")
  assert(session._query_engine_times[session.state.rows].status == "available")
  assert(text(buf):find("Write engine:", 1, true), text(buf))
  assert(text(buf):find("Engine:", 1, true) and text(buf):find("Query:", 1, true))
  -- Let the scheduled metadata CLI release DuckDB's file lock before testing
  -- a successful refresh. A failed refresh intentionally retains old timing.
  assert(vim.wait(5000, function() return session._column_info ~= nil end, 5), "column metadata did not settle")
  local previous_rows = session.state.rows
  session.on_refresh(buf)
  assert(session.state.rows ~= previous_rows, "refresh did not replace the displayed result: " .. table.concat(errors, "; "))
  assert(not text(buf):find("Write engine:", 1, true), "unrelated refresh inherited write engine duration")
end)

test("result display/Zen flags hide engine labels while collection stays enabled", function()
  grip.setup({ show_result_time = false, show_hints = false, show_running_time = false })
  open("INSERT INTO writes VALUES(3,'three')")
  apply()
  local buf = vim.api.nvim_get_current_buf()
  local session = assert(view._sessions[buf])
  assert(session._write_engine_times[session.state.rows].status == "available")
  assert(session._query_engine_times[session.state.rows].status == "available")
  assert(not text(buf):find("ngine:", 1, true) and not text(buf):find("Query:", 1, true), text(buf))
  assert(grip.get_opts().engine_timing == true)
end)

test("real profiled write Ctrl-C keeps pending SQL and reports unknown outcome", function()
  local sql = "INSERT INTO writes SELECT i + 100, 'bulk' FROM range(100000000000) t(i)"
  local buf, session = open(sql)
  assert(session.pending_mutation, "INSERT SELECT preview did not retain SQL")
  local before, before_state = text(buf), session.state
  local real_run, real_system, real_delete = adapters.run_cmd, vim.system, vim.fn.delete
  local message, calls, child, exited, profile_dir = nil, 0, nil, false, nil
  vim.notify = function(msg) message = msg end
  vim.system = function(args, sysopts, callback)
    local writing = sysopts.stdin and sysopts.stdin:find(sql, 1, true)
    local object = real_system(args, sysopts, function(result)
      if writing then exited = true end
      if callback then callback(result) end
    end)
    if writing then child = object; vim.defer_fn(function() vim.api.nvim_input("\003") end, 30) end
    return object
  end
  adapters.run_cmd = function(args, timeout, runopts)
    if runopts and runopts.stdin:find(sql, 1, true) then
      calls = calls + 1
      local raw = assert(runopts.stdin:match("SET profiling_output = (.-);\n"))
      profile_dir = vim.fn.fnamemodify(raw:sub(2, -2):gsub("''", "'"), ":h")
      assert(runopts.terminate_on_interrupt)
    end
    return real_run(args, timeout, runopts)
  end
  vim.fn.delete = function(target, flags)
    if target == profile_dir then assert(exited, "write profile removed before exit callback") end
    return real_delete(target, flags)
  end
  local ok, err = xpcall(apply, debug.traceback)
  adapters.run_cmd, vim.system, vim.fn.delete = real_run, real_system, real_delete
  vim.notify = function() end
  if child and not exited then pcall(child.kill, child, 9); pcall(child.wait, child, 1000) end
  assert(ok, err)
  assert(calls == 1 and child and exited and vim.uv.kill(child.pid, 0) == nil, "write retried or child unreaped")
  assert(profile_dir and vim.fn.isdirectory(profile_dir) == 0, "write profile remains")
  assert(view._sessions[buf] == session and session.pending_mutation and session.state == before_state and text(buf) == before,
    "unconfirmed write replaced pending result")
  assert(message and message:find("database outcome is unknown", 1, true) and message:find("Refresh before retrying", 1, true),
    "profiled write cancellation was presented as confirmed failure: " .. tostring(message))
  assert(not message:find("Failed:", 1, true), message)
end)

cleanup()
grip.setup(opts)
vim.fn.confirm, vim.notify = confirm, notify
vim.fn.delete(path)
print(string.format("engine_timing_write_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
