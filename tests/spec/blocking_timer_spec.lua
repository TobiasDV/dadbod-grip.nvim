-- Real event-loop regressions for the loading float and its timer.
dofile("tests/minimal_init.lua")
local ui = require("dadbod-grip.ui")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function busy(ms) vim.wait(ms, function() return false end, 5) end
local function float()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then return win, vim.api.nvim_win_get_buf(win) end
  end
  error("loading float missing")
end
-- Track actual handles created by these operations. uv.walk() includes Neovim's
-- internal non-Lua handles and crashes the luv bundled with Neovim 0.10.
local new_timer, handles = vim.uv.new_timer, {}
vim.uv.new_timer = function(...)
  local handle = new_timer(...)
  handles[#handles + 1] = handle
  return handle
end
local function timers()
  local count = 0
  for _, handle in ipairs(handles) do
    if not handle:is_closing() and handle:is_active() then count = count + 1 end
  end
  return count
end
local function line(buf) return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] end

test("long Unicode labels keep elapsed inside the editor width", function()
  local ok, err = pcall(ui.blocking, string.rep("長い表", 20), function()
    busy(650)
    local win, buf = float()
    local text = line(buf)
    assert(text:find("%d+%.%d+s$"), "elapsed suffix missing: " .. text)
    assert(vim.fn.strdisplaywidth(text) <= vim.api.nvim_win_get_width(win),
      "elapsed suffix lies outside the visible text width")
    assert(not vim.wo[win].wrap, "loading label should stay on one line")
  end)
  assert(ok, err)
end)

test("a longer nested step remains readable in the same float", function()
  ui.blocking("outer", function()
    local outer = float()
    ui.blocking(string.rep("nested-label-", 10), function()
      busy(650)
      local win, buf = float()
      assert(win == outer, "nested step must borrow the same float")
      assert(vim.fn.strdisplaywidth(line(buf)) <= vim.api.nvim_win_get_width(win),
        "nested label and elapsed must fit the float")
    end)
  end)
end)

test("closing the float stops hidden writes and its active timer", function()
  local before = timers()
  ui.blocking("external-close", function()
    local win, buf = float()
    vim.api.nvim_win_close(win, true)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    busy(240)
    assert(vim.api.nvim_buf_get_changedtick(buf) == tick, "closed float kept rewriting its hidden buffer")
    assert(timers() == before, "closed float kept its timer active")
  end)
end)

test("queued callbacks stay inert after cleanup and during a later operation", function()
  -- Capture the real scheduled callback so its already-queued work can be
  -- replayed deterministically after the real libuv timer has been closed.
  local wrap, old_callback = vim.schedule_wrap
  vim.schedule_wrap = function(callback)
    old_callback = callback
    return wrap(callback)
  end
  local ok, err = pcall(ui.blocking, "old-operation", function() busy(120) end)
  vim.schedule_wrap = wrap
  assert(ok, err)
  assert(old_callback, "spinner callback was not scheduled")
  local redraw, redraws = vim.cmd, 0
  vim.cmd = function(command)
    if command == "redraw" then redraws = redraws + 1 end
    return redraw(command)
  end
  ok, err = pcall(function()
    old_callback()
    assert(redraws == 0, "old callback redrew after cleanup")
    ui.blocking("current-operation", function()
      local _, buf = float()
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local before = redraws
      old_callback()
      assert(vim.api.nvim_buf_get_changedtick(buf) == tick, "old callback changed current float")
      assert(redraws == before, "old callback redrew during a later operation")
    end)
  end)
  vim.cmd = redraw
  assert(ok, err)
end)

test("a caught nested error restores the outer label and clock", function()
  ui.blocking("outer-restored", function()
    busy(600)
    local _, buf = float()
    local before = tonumber(line(buf):match("(%d+%.%d+)s$"))
    local ok = pcall(ui.blocking, "inner-fails", function() busy(160); error("nested failure") end)
    assert(not ok, "nested error must propagate")
    busy(120)
    local text = line(buf)
    assert(text:find("outer-restored", 1, true), "outer label was not restored")
    assert(tonumber(text:match("(%d+%.%d+)s$")) >= before, "outer clock restarted after error")
  end)
end)

for _, outcome in ipairs({ "success", "error", "cancelled wait" }) do
  test("timer is released after " .. outcome, function()
    local before = timers()
    local wins, bufs = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
    local interrupted
    local ok, result = pcall(ui.blocking, "lifecycle", function()
      if outcome == "cancelled wait" then
        vim.defer_fn(function() vim.api.nvim_input("\003") end, 120)
        local completed, reason = vim.wait(1000, function() return false end, 5)
        interrupted = not completed and reason == -2
        return "cancelled"
      end
      busy(180)
      if outcome == "error" then error("intentional timer error") end
      return "done"
    end)
    assert(ok == (outcome ~= "error"), "operation outcome changed")
    if outcome == "cancelled wait" then
      assert(interrupted and result == "cancelled", "wait was not interrupted by Ctrl-C")
    end
    busy(120)
    assert(timers() == before, "timer remained active after " .. outcome)
    assert(#vim.api.nvim_list_wins() == wins, "float leaked after " .. outcome)
    assert(#vim.api.nvim_list_bufs() == bufs, "buffer leaked after " .. outcome)
  end)
end

test("each new operation starts below the elapsed threshold", function()
  ui.blocking("first-operation", function() busy(650) end)
  ui.blocking("second-operation", function()
    busy(120)
    local _, buf = float()
    assert(not line(buf):find("%d+%.%d+s$"), "second operation reused the first clock")
  end)
end)

vim.uv.new_timer = new_timer

print(string.format("blocking_timer_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
