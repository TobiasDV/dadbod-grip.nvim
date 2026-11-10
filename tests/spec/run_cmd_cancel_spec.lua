-- Cancellation ownership is additive; ordinary adapter calls keep their contract.
dofile("tests/minimal_init.lua")
local adapters = require("dadbod-grip.adapters")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
for _, owned in ipairs({ false, true }) do
  test("real Ctrl-C child ownership, opt-in=" .. tostring(owned), function()
    local original, child, exited = vim.system, nil, false
    vim.system = function(args, opts, callback)
      child = original(args, opts, function(result) exited = true; callback(result) end)
      return child
    end
    local ok, err = xpcall(function()
      vim.defer_fn(function() vim.api.nvim_input("\003") end, 30)
      -- Ignored TERM is inherited by sleep, exercising the SIGKILL escalation.
      local _, message, code = adapters.run_cmd({ "sh", "-c", "trap '' TERM; exec sleep 2" }, 2000,
        { terminate_on_interrupt = owned })
      if owned then
        assert(code == 130 and message:find("outcome unknown", 1, true), message)
        assert(exited and vim.uv.kill(child.pid, 0) == nil, "owned child alive/unreaped at return")
      else
        assert(code == 1 and message == "command timed out", "default outcome changed")
        assert(not exited and vim.uv.kill(child.pid, 0) ~= nil, "default process behavior changed")
      end
    end, debug.traceback)
    if child and not exited then pcall(child.kill, child, 9); pcall(child.wait, child, 1000) end
    vim.system = original
    assert(ok, err)
  end)
end
print(string.format("run_cmd_cancel_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
