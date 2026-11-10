-- Whole shortcuts fit in at most two rows; Unicode keys are never sliced.
dofile("tests/minimal_init.lua")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
test("shortcuts move whole to the next row", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "i:edit", "a:apply", "q:query" }, 20),
    { " ?:help  i:edit", " a:apply  q:query" })
end)
test("overflow is explicit and limited to two rows", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "i:edit", "a:apply", "q:query" }, 12),
    { " ?:help", " i:edit  …" })
end)
test("Unicode display widths preserve whole shortcuts", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "界:編集", "é:état" }, 16),
    { " ?:help  界:編集", " é:état" })
end)
test("oversized custom shortcut is omitted without truncating its bytes", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "<C-S-F12>:refresh", "i:edit" }, 12),
    { " ?:help", " i:edit  …" })
end)
test("tiny width has a bounded overflow indicator", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "i:edit" }, 1), { "…" })
  eq(require("dadbod-grip.result_hints").pack({ "?:help" }, 0), {})
end)
test("double-width overflow marker never exceeds a one-cell window", function()
  local old = vim.o.ambiwidth
  vim.o.ambiwidth = "double"
  local actual = require("dadbod-grip.result_hints").pack({ "?:help" }, 1)
  vim.o.ambiwidth = old
  eq(actual, {})
end)
test("overflow never evicts help that fits exactly", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "a:execute UPDATE", "U:cancel" }, 7),
    { " ?:help", " …" })
end)
test("narrow mutation keeps cancellation ahead of an overflow marker", function()
  eq(require("dadbod-grip.result_hints").pack({ "?:help", "a:execute UPDATE", "U:cancel" }, 9),
    { " ?:help", " U:cancel" })
end)

for _, case in ipairs({
  { "editable", 80, 30 }, { "editable", 100, 36 }, { "editable", 160, 40 },
  { "narrow", 40, 20 }, { "tiny", 12, 12 }, { "readonly", 80, 30 },
  { "mutation", 80, 30 }, { "mutation-narrow", 12, 12 },
  { "metadata", 80, 30 }, { "custom", 80, 30 }, { "custom-metadata", 80, 30 },
  { "disabled-help", 80, 30 }, { "scroll", 80, 30 }, { "shared", 100, 36 },
  { "gutter", 80, 30 }, { "resize", 100, 36 }, { "zoom", 100, 36 },
}) do
  test("native " .. case[1] .. " " .. case[2], function()
    local child = vim.fn.jobstart({ vim.g.grip_test_progpath, "--clean", "--embed", "--headless",
      "-n", "-i", "NONE", "-u", "tests/minimal_init.lua" }, { rpc = true })
    local ok, err = pcall(function()
      vim.fn.rpcrequest(child, "nvim_ui_attach", case[2], case[3], { rgb = true })
      assert(vim.fn.rpcrequest(child, "nvim_exec_lua",
        "return dofile('tests/fixtures/results_hints_integration.lua')(...)", { case[1] }))
      if case[1] == "resize" then
        for _, width in ipairs({ 45, 120 }) do
          vim.fn.rpcrequest(child, "nvim_ui_try_resize", width, case[3])
          assert(vim.fn.rpcrequest(child, "nvim_exec_lua", "return results_hints_resize_check()", {}))
        end
      end
    end)
    vim.fn.jobstop(child)
    assert(ok, err)
  end)
end
print(string.format("results_hints_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
