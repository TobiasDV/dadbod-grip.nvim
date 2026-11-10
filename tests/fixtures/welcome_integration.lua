return function(scenario)
  local grip = require("dadbod-grip")
  local qpad = require("dadbod-grip.query_pad")
  local schema = require("dadbod-grip.schema")
  local view = require("dadbod-grip.view")
  vim.g.db = nil
  vim.env.DATABASE_URL = nil
  local opts = { discovery = false, ai = false, completion = false }
  if scenario == "remap" or scenario == "help-remap" or scenario == "pad-hints-remap"
      or scenario == "diagram-remap" or scenario == "compact-all-remap" then
    opts.keymaps = { welcome_activate = "<F4>", welcome_next = "<F5>",
      welcome_prev = "<F6>", tab_1 = "<F10>", tab_2 = "<F7>", tab_3 = "<F11>", zoom = "<F8>", qpad_execute = "<F9>" }
  elseif scenario == "disabled" or scenario == "help-disabled" or scenario == "pad-hints-disabled"
      or scenario == "diagram-disabled" then
    opts.keymaps = { welcome_activate = false, welcome_next = false,
      welcome_prev = false, zoom = false, tab_1 = false, schema_browser = false,
      tab_2 = false, tab_3 = false, table_picker_go = false, qpad_execute = false }
  elseif scenario == "compact-schema-remap" then opts.keymaps = { tab_1 = "<F10>" }
  elseif scenario == "compact-help-disabled" then opts.keymaps = { help = false }
  elseif scenario == "next-only" then opts.keymaps = { welcome_prev = false }
  elseif scenario == "prev-only" then opts.keymaps = { welcome_next = false }
  end
  grip.setup(opts)
  vim.o.scrolloff = 5
  vim.wo.number = true
  vim.wo.relativenumber = true
  vim.wo.wrap = true
  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  end
  local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), "\n") end
  local function select_row(label)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line:find(label, 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }); return end
    end
    error("action row absent: " .. label)
  end
  local function check_welcome()
    assert(vim.bo.filetype == "grip-welcome")
    local all = text()
    assert(all:find("╔═╦═╦═╗", 1, true) and all:find("║d║b║g║", 1, true), "DBG logo lost")
    local v = vim.fn.winsaveview()
    assert(v.topline == 1 and v.leftcol == 0, "welcome starts scrolled: " .. vim.inspect(v))
    assert(not vim.wo.wrap and not vim.wo.number and not vim.wo.relativenumber, "welcome inherited distracting options")
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(0), "welcome overflow: " .. line)
    end
    local heading = assert(all:find("  Welcome keys\n", 1, true), "welcome key scope is not a standalone heading")
    local diagram = assert(all:find("  +", 1, true), "welcome diagram absent")
    assert(heading < diagram, "welcome key heading is orphaned below its shortcuts")
    assert(not all:find("Welcome keys", heading + 14, true), "duplicate trailing welcome key label")
    assert(vim.api.nvim_buf_line_count(0) <= vim.api.nvim_win_get_height(0), "welcome actions need scrolling")
    return all
  end
  grip.open_welcome()
  vim.wait(20)
  local welcome = vim.api.nvim_get_current_buf()
  local all = check_welcome()
  assert(vim.api.nvim_get_current_line():find("Open demo", 1, true), "initial Enter does not select demo")
  if scenario:match("^compact%-") then
    if scenario == "compact-help-disabled" then
      assert(all:find("Full manual: :help dadbod-grip", 1, true), "disabled help lacks truthful manual fallback")
      assert(not all:find("shows their local keys", 1, true), "static manual advertised as configured local help")
      assert(vim.fn.maparg("?", "n") == "", "disabled help still mapped")
    else
      assert(all:find("<F10> Schema", 1, true), "compact diagram lost remapped schema key")
      assert(all:find("Zoom/restore", 1, true), "compact diagram lost restore hint")
      press(scenario == "compact-all-remap" and "<F5>" or "<Tab>")
      assert(vim.api.nvim_get_current_line():find("Connect a database", 1, true),
        "compact diagram changed action row identity")
    end
    return true
  elseif scenario == "next-only" or scenario == "prev-only" then
    local hint = scenario == "next-only" and "<Tab> next" or "<S-Tab> previous"
    local disabled = scenario == "next-only" and "<S-Tab>" or "<Tab>"
    assert(all:find(hint, 1, true), "single active action control is not explained")
    assert(not all:find(disabled, 1, true) and vim.fn.maparg(disabled, "n") == "", "disabled action control advertised")
    press(scenario == "next-only" and "<Tab>" or "<S-Tab>")
    assert(vim.api.nvim_get_current_line():find(scenario == "next-only" and "Connect a database" or "Open SQL pad", 1, true))
    return true
  elseif scenario == "diagram" or scenario == "diagram-remap" then
    local labels = scenario == "diagram" and { "1 Schema", "2 SQL", "3 Table/results" }
      or { "<F10> Schema", "<F7> SQL", "<F11> Table/results" }
    for _, label in ipairs(labels) do assert(all:find(label, 1, true), "diagram key missing: " .. label) end
    for _, key in ipairs(scenario == "diagram" and { "1", "2", "3" } or { "<F10>", "<F7>", "<F11>" }) do
      assert(vim.fn.maparg(key, "n", false, true).buffer == 1, "diagram key is not active here: " .. key)
    end
    assert(all:find("Welcome keys", 1, true), "diagram presents digits as universal mappings")
    assert(all:find("Zoom/restore", 1, true), "daily restore action absent")
    return true
  elseif scenario == "diagram-disabled" then
    assert(all:find("Table/results", 1, true), "workspace diagram lost")
    for _, label in ipairs({ "1 Schema", "2 SQL", "3 Table/results" }) do
      assert(not all:find(label, 1, true), "disabled diagram key advertised: " .. label)
    end
    for _, key in ipairs({ "1", "2", "3" }) do assert(vim.fn.maparg(key, "n") == "") end
    return true
  elseif scenario == "split" then
    vim.cmd("split")
    vim.cmd("redraw")
    vim.wait(40)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      vim.api.nvim_win_call(win, function()
        check_welcome()
        assert(vim.api.nvim_get_current_line():find("Open demo", 1, true), "split changed selected action")
      end)
    end
    return true
  elseif scenario == "tabs" then
    local first_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("split")
    grip.open_welcome()
    vim.cmd("redraw")
    vim.wait(40)
    check_welcome()
    assert(vim.api.nvim_get_current_line():find("Open demo", 1, true), "second tab did not select demo")
    for _, tab in ipairs({ first_tab, second_tab }) do
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("redraw")
      vim.wait(40)
      assert(vim.api.nvim_get_current_line():find("Open demo", 1, true), "another tab changed selected action")
      check_welcome()
    end
    assert(not vim.g.db and not next(view._sessions), "tab lifecycle performed DB work")
    return true
  elseif scenario == "entry" then
    press("<Tab>"); assert(vim.api.nvim_get_current_line():find("Connect a database", 1, true))
    press("<S-Tab>"); assert(vim.api.nvim_get_current_line():find("Open demo", 1, true))
    vim.api.nvim_win_set_cursor(0, { 1, 0 }); press("<CR>")
    assert(vim.api.nvim_get_current_buf() == welcome and not vim.g.db, "nonaction Enter connected")
    assert(not schema.is_open() and not qpad.get_pad_bufnr(), "welcome performed implicit DB work")
    press(";"); assert(text():find("Chonk holds the center.", 1, true), "existing Easter egg lost")
    press("q"); assert(vim.api.nvim_get_current_buf() == welcome)
    return true
  elseif scenario == "remap" then
    for _, key in ipairs({ "<F4>", "<F5>", "<F7>", "<F8>", "<F9>" }) do
      assert(all:find(key, 1, true), "configured hint missing: " .. key)
    end
    assert(vim.fn.maparg("<CR>", "n") == "" and vim.fn.maparg("gz", "n") == "", "legacy key still bound after remap")
    press("<F5>"); assert(vim.api.nvim_get_current_line():find("Connect a database", 1, true))
    return true
  elseif scenario == "disabled" then
    assert(not all:find("gz", 1, true) and not all:find("<C-CR>", 1, true), "disabled key advertised")
    assert(all:find(":GripStart", 1, true) and all:find(":GripQuery", 1, true), "minimal command fallback missing")
    assert(vim.fn.maparg("<CR>", "n") == "" and vim.fn.maparg("2", "n") == "", "disabled action registered")
    assert(all:find(":Grip SELECT sku FROM rolls LIMIT 20", 1, true), "disabled run key lacks executable demo fallback")
    return true
  elseif scenario:match("^pad%-hints") then
    qpad.open("sqlite:tests/seed_sqlite.db")
    local b = qpad.get_pad_bufnr()
    vim.cmd("redraw!")
    local info, hints = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1], ""
    for row = info.winrow, info.winrow + info.height - 1 do
      for col = info.wincol, info.wincol + info.width - 1 do hints = hints .. vim.fn.screenstring(row, col) end
      hints = hints .. "\n"
    end
    assert(not hints:find("C-CR", 1, true), "SQL-pad hint advertises old/disabled execution key")
    if scenario == "pad-hints-remap" then assert(hints:find("<F9>", 1, true), "configured run hint absent") end
    assert(not qpad._has_real_content(vim.api.nvim_buf_get_lines(b, 0, -1, false)), "owned hints block initial SQL")
    qpad.open("sqlite:tests/seed_sqlite.db", { initial_sql = "SELECT 1" })
    assert(text(b) == "SELECT 1", "initial SQL did not replace owned hints")
    return true
  elseif scenario:match("^help") then
    qpad.open("sqlite:tests/seed_sqlite.db")
    local pad = qpad.get_pad_bufnr()
    vim.api.nvim_buf_set_lines(pad, 0, -1, false, { "-- unfinished query" })
    press("?")
    local help = text()
    assert(help:match("q%s+[^\n]*welcome"), "SQL help describes q as opening SQL instead of returning home")
    assert(not help:find("Edit cell under cursor", 1, true), "SQL help shows grid editing bindings as local actions")
    if scenario == "help-remap" then
      assert(help:find("<F9>", 1, true) and not help:find("<C-CR>", 1, true), "SQL help ignores remapped run key")
    elseif scenario == "help-disabled" then
      assert(not help:find("<C-CR>", 1, true), "SQL help advertises disabled run key")
    end
    if scenario == "help-about" then
      press("G")
      assert(help:find("About dadbod-grip", 1, true), "About section absent")
      assert(help:find("╭─┤ id │ hello", 1, true), "selected Table Hug absent")
      local top = vim.fn.line("w0")
      local visible = table.concat(vim.api.nvim_buf_get_lines(0, top - 1, top - 1 + vim.api.nvim_win_get_height(0), false), "\n")
      assert(visible:find("Chonk holds the center", 1, true), "About character/phrase need hidden scrolling")
      assert(not next(view._sessions), "About executed SQL")
      local ns = vim.api.nvim_create_namespace("grip_help_hl")
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
        assert(mark[4].hl_group ~= "DiagnosticWarn", "About drawing is incorrectly shown as a warning")
      end
    end
    local width = vim.api.nvim_win_get_width(0)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) <= width, "help line clipped: " .. line)
    end
    press("q")
    assert(vim.api.nvim_get_current_buf() == pad and text() == "-- unfinished query", "help lost SQL draft/focus")
    return true
  end

  -- Real bundled SQLite demo, with a private disposable path and no scanner downloads.
  local dir = vim.fn.tempname()
  local demo = require("dadbod-grip.demo")
  demo.spec = function()
    return { kind = "sqlite", path = dir .. "/softrear.db", url = "sqlite:" .. dir .. "/softrear.db",
      seed = vim.fn.getcwd() .. "/demo/softrear_sqlite.sql", supplier_path = dir .. "/supplier.db" }
  end
  press("<CR>")
  assert(vim.wait(5000, function()
    local b = qpad.get_pad_bufnr()
    return b and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_get_current_buf() == b
      and text(b):find("SELECT sku", 1, true)
  end, 10), "Open demo row did not load real walkthrough; current=" .. vim.api.nvim_buf_get_name(0)
    .. "; pad=" .. tostring(qpad.get_pad_bufnr()) .. "; messages=" .. vim.api.nvim_exec2("messages", {output=true}).output)
  assert(vim.api.nvim_get_current_buf() == qpad.get_pad_bufnr(), "demo did not focus SQL")
  assert(vim.api.nvim_get_current_line():find("SELECT sku", 1, true), "demo cursor is not ready to run first SQL block")
  assert(not next(view._sessions), "opening demo executed a query automatically")

  -- A real table first, then its auto-synced SQL, just like the native journey.
  grip.open_welcome()
  press("1")
  assert(vim.api.nvim_get_current_win() == schema.get_winid(), "welcome1 did not focus schema")
  local state = schema.get_state(vim.g.db)
  for i, node in ipairs(state.nodes) do
    if node.kind == "table" and node.name == "rolls" then vim.api.nvim_win_set_cursor(0, { i + 2, 0 }); break end
  end
  press("<CR>")
  assert(vim.wait(3000, function()
    local b = qpad.get_pad_bufnr()
    local last = b and vim.api.nvim_buf_get_lines(b, -2, -1, false)[1]
    local s = view._sessions[vim.api.nvim_get_current_buf()]
    return s and s.state.table_name == "rolls" and last == 'SELECT * FROM "rolls"'
  end, 10), "table did not finish its normal SQL-pad sync")
  assert(text():find("ULTRA_BUDGET_XTRM", 1, true), "wrong demo table opened")
  press("2")
  assert(vim.api.nvim_get_current_buf() == qpad.get_pad_bufnr())
  assert(vim.api.nvim_get_current_line() == 'SELECT * FROM "rolls"', "table's ready SQL was not selected")
  local grid = vim.fn.bufnr("grip://rolls")
  press("3")
  assert(vim.api.nvim_get_current_buf() == grid, "SQL-pad3 did not return to the table")
  press("2")
  assert(vim.api.nvim_get_current_buf() == qpad.get_pad_bufnr(), "grid2 did not return to SQL")
  press("<C-CR>")
  assert(vim.wait(5000, function()
    for _, session in pairs(view._sessions) do
      if session.query_sql and session.query_sql:find('SELECT * FROM "rolls"', 1, true)
          and #session.state.rows == 35 then return true end
    end
    return false
  end, 10), "table's ready SQL did not execute through its real mapping")

  -- Re-entering welcome must not lose the draft or query session.
  local pad = qpad.get_pad_bufnr()
  vim.api.nvim_buf_set_lines(pad, -1, -1, false, { "-- my unfinished draft" })
  local draft = text(pad)
  grip.open_welcome(); vim.wait(20); check_welcome()
  select_row("Open SQL pad"); press("<CR>")
  assert(vim.api.nvim_get_current_buf() == pad and text(pad) == draft, "SQL action replaced a draft")
  grip.open_welcome(); vim.wait(20); check_welcome()
  vim.fn.delete(dir, "rf")
  return true
end
