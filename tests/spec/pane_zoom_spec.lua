-- Real split windows: closing/recreating them would wipe live Grip results.
dofile("tests/minimal_init.lua")

local pass, fail = 0, 0
local main_panes = { grid = true, query = true, sidebar = true, welcome = true,
  stats = true, columns = true, fk = true, indexes = true, constraints = true,
  ["cell-split"] = true, profile = true, diff = true, ["help-split"] = true }
for _, scenario in ipairs({ "grid", "query", "sidebar", "welcome", "external", "repeat", "edit", "resize",
  "stats", "columns", "fk", "indexes", "constraints", "cell-split", "profile", "diff",
  "float-er", "float-cell", "float-json", "float-info", "float-picker", "float-explain",
  "external-split", "closed-target", "closed-other", "rearranged", "focus", "other-scroll", "help-split",
  "help", "tabs", "single", "child-exit", "query-nav-2", "query-nav-q", "query-nav-command",
  "query-reopen", "query-new-window", "query-other-copy" }) do
  local child = vim.fn.jobstart({ vim.g.grip_test_progpath, "--clean", "--embed", "--headless",
    "-i", "NONE", "-n", "-u", "tests/minimal_init.lua" }, { rpc = true })
  local active = true
  vim.defer_fn(function() if active then vim.fn.jobstop(child) end end, 10000)
  local ok, err = pcall(function()
    vim.fn.rpcrequest(child, "nvim_ui_attach", 100, 36, { rgb = true })
    if scenario == "child-exit" then
      local responded, result = pcall(vim.fn.rpcrequest, child, "nvim_exec_lua", "vim.cmd('cquit 7')", {})
      assert(not responded or result ~= true, "a terminated fixture counted as success")
      return
    end
    assert(vim.fn.rpcrequest(child, "nvim_exec_lua",
      "return dofile('tests/fixtures/pane_zoom_integration.lua')(...)", { scenario }) == true)
    if scenario == "resize" then
      vim.fn.rpcrequest(child, "nvim_ui_try_resize", 80, 28)
      assert(vim.fn.rpcrequest(child, "nvim_exec_lua", [[
        vim.cmd("GripZoom")
        assert(vim.o.columns == 80 and vim.o.lines == 28, "restore changed terminal dimensions")
        return _G.grip_zoom_check()
      ]], {}) == true)
    end
    if main_panes[scenario] then
      vim.fn.rpcrequest(child, "nvim_command", "GripZoom")
      vim.fn.rpcrequest(child, "nvim_ui_try_resize", 80, 28)
      assert(vim.fn.rpcrequest(child, "nvim_exec_lua", [[
        vim.cmd("GripZoom")
        assert(vim.o.columns == 80 and vim.o.lines == 28)
        assert(_G.grip_zoom_main_check())
        vim.cmd("GripZoom")
        vim.cmd("belowright split")
        local extra = vim.api.nvim_get_current_win()
        local draft = vim.api.nvim_create_buf(true, false)
        vim.bo[draft].bufhidden = "hide"
        vim.api.nvim_win_set_buf(extra, draft)
        vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "new pane while zoomed" })
        local layout = vim.fn.winlayout()
        vim.cmd("GripZoom")
        assert(vim.deep_equal(layout, vim.fn.winlayout()), "restore changed new topology")
        assert(vim.api.nvim_buf_is_valid(draft) and vim.bo[draft].modified)
        return _G.grip_zoom_main_check()
      ]], {}) == true)
    end
    assert(vim.fn.rpcrequest(child, "nvim_eval", "1") == 1, "child did not finish cleanly")
  end)
  active = false
  vim.fn.jobstop(child)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: pane zoom " .. scenario .. ": " .. tostring(err)) end
end

print(string.format("pane_zoom_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
