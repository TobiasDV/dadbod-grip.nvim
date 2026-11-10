-- Native windows and real commands: catches inert rows and the wrong query block.
dofile("tests/minimal_init.lua")
local pass, fail = 0, 0
for _, case in ipairs({
  { "entry", 80, 30 }, { "entry", 100, 36 }, { "entry", 160, 40 },
  { "diagram", 80, 30 }, { "diagram-remap", 80, 30 }, { "diagram-disabled", 80, 30 },
  { "compact-schema-remap", 55, 17 }, { "compact-all-remap", 55, 17 },
  { "compact-help-disabled", 55, 17 },
  { "next-only", 80, 30 }, { "prev-only", 80, 30 },
  { "split", 100, 36 }, { "tabs", 100, 36 },
  { "flow", 80, 30 }, { "flow", 100, 36 }, { "flow", 160, 40 },
  { "remap", 80, 30 }, { "disabled", 80, 30 },
  { "help", 80, 30 }, { "help-remap", 80, 30 }, { "help-disabled", 80, 30 },
  { "help-about", 80, 30 },
  { "pad-hints-remap", 80, 30 }, { "pad-hints-disabled", 80, 30 },
}) do
  local child = vim.fn.jobstart({ vim.g.grip_test_progpath, "--clean", "--embed", "--headless",
    "-n", "-i", "NONE", "-u", "tests/minimal_init.lua" }, { rpc = true })
  local active = true
  vim.defer_fn(function() if active then vim.fn.jobstop(child) end end, 15000)
  local ok, err = pcall(function()
    vim.fn.rpcrequest(child, "nvim_ui_attach", case[2], case[3], { rgb = true })
    assert(vim.fn.rpcrequest(child, "nvim_exec_lua",
      "return dofile('tests/fixtures/welcome_integration.lua')(...)", { case[1] }) == true)
    assert(vim.fn.rpcrequest(child, "nvim_eval", "1") == 1, "fixture did not finish")
  end)
  active = false
  vim.fn.jobstop(child)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: welcome " .. case[1] .. " " .. case[2] .. ": " .. tostring(err)) end
end
print(string.format("welcome_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
