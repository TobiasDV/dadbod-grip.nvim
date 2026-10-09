-- cell_buffer_spec.lua: tests for the full-buffer cell editor (issue #18)
--
-- gB opens the cell under cursor in a real split buffer: JSON values open
-- as stored with ft=json, prose columns get ft=markdown, :w stages the
-- buffer content back into the grid session via data.add_change.

local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")
local cell_buffer = require("dadbod-grip.cell_buffer")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("^grip://cell/") then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(0)[#vim.api.nvim_tabpage_list_wins(0)], true)
  end
end

-- Open a grid for the given rows and return its bufnr.
local function open_grid(rows, pks)
  local st = data.new({
    columns = { "id", "payload", "notes" },
    rows = rows,
    primary_keys = pks or { "id" },
    table_name = "docs",
    url = "sqlite:test.db",
  })
  return view.open(st, st.url, "SELECT * FROM docs", {})
end

-- Move the grid cursor onto a specific cell (row order index + column name).
local function goto_cell(bufnr, row_order, col)
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local r = view._sessions[bufnr]._render
  local line = (r.data_start or 4) + row_order - 1
  local bp = r.byte_positions[row_order][col]
  vim.api.nvim_win_set_cursor(win, { line, bp.start })
end

local function has_nmap(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == lhs then return true end
  end
  return false
end

-- ── render_value: JSON detection ────────────────────────────────────────────

test("render_value: JSON object opens as stored, ft=json", function()
  local raw = '{"b":1,"a":12345678901234567890,"c":1.10}'
  local lines, ft = cell_buffer.render_value(raw, "payload")
  eq(ft, "json", "filetype")
  eq(table.concat(lines, "\n"), raw, "key order and number text kept")
end)

test("render_value: multi-line JSON keeps its own layout, ft=json", function()
  local raw = '[\n    1,\n    2\n]'
  local lines, ft = cell_buffer.render_value(raw, "payload")
  eq(ft, "json", "filetype")
  eq(table.concat(lines, "\n"), raw, "layout kept")
end)

test("render_value: surrounding whitespace still detected as JSON", function()
  local _, ft = cell_buffer.render_value('  {"a":1}  ', "payload")
  eq(ft, "json", "filetype")
end)

test("render_value: invalid JSON starting with { stays plain", function()
  local lines, ft = cell_buffer.render_value("{oops", "payload")
  eq(ft, nil, "filetype")
  eq(lines[1], "{oops", "content untouched")
end)

test("render_value: bare number is not JSON", function()
  local lines, ft = cell_buffer.render_value("123", "payload")
  eq(ft, nil, "filetype")
  eq(lines[1], "123", "content untouched")
end)

-- ── render_value: column-name filetype heuristic ────────────────────────────

test("render_value: notes column gets ft=markdown", function()
  local _, ft = cell_buffer.render_value("hello", "notes")
  eq(ft, "markdown", "filetype")
end)

test("render_value: heuristic is case-insensitive (Body)", function()
  local _, ft = cell_buffer.render_value("hello", "Body")
  eq(ft, "markdown", "filetype")
end)

test("render_value: plain column gets no filetype", function()
  local _, ft = cell_buffer.render_value("hello", "id")
  eq(ft, nil, "filetype")
end)

-- ── render_value: multiline + NULL ──────────────────────────────────────────

test("render_value: real newlines split into buffer lines and round-trip", function()
  local lines = cell_buffer.render_value("a\nb\n", "id")
  eq(#lines, 3, "line count")
  eq(table.concat(lines, "\n"), "a\nb\n", "round trip")
end)

test("render_value: NULL opens as a single empty line", function()
  local lines, ft = cell_buffer.render_value(nil, "notes")
  eq(#lines, 1, "line count")
  eq(lines[1], "", "empty")
  eq(ft, nil, "filetype")
end)

-- ── keymap registration ──────────────────────────────────────────────────────

test("keymaps: grid_cell_buffer defaults to gB", function()
  eq(require("dadbod-grip.keymaps").defaults.grid_cell_buffer, "gB")
end)

test("grid buffer has gB mapped", function()
  cleanup()
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } })
  eq(has_nmap(bufnr, "gB"), true, "gB mapped on grid")
  cleanup()
end)

-- ── open: split buffer basics ────────────────────────────────────────────────

test("open: JSON cell opens as stored in a split with a stable name", function()
  cleanup()
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } })
  goto_cell(bufnr, 1, "payload")
  local wins_before = #vim.api.nvim_tabpage_list_wins(0)
  local cb = cell_buffer.open(bufnr)
  assert(cb, "cell buffer created")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins_before + 1, "one new window")
  eq(vim.api.nvim_get_current_buf(), cb, "cell buffer focused")
  assert(vim.api.nvim_buf_get_name(cb):match("grip://cell/docs/1/payload"), "buffer name")
  eq(vim.api.nvim_get_option_value("filetype", { buf = cb }), "json", "filetype")
  eq(vim.api.nvim_get_option_value("buftype", { buf = cb }), "acwrite", "buftype")
  eq(vim.api.nvim_get_option_value("bufhidden", { buf = cb }), "wipe", "bufhidden")
  eq(vim.api.nvim_get_option_value("swapfile", { buf = cb }), false, "swapfile")
  eq(has_nmap(cb, "q"), false, "q left alone in editable mode")
  local lines = vim.api.nvim_buf_get_lines(cb, 0, -1, false)
  eq(table.concat(lines, "\n"), '{"a":1}', "stored content")
  cleanup()
end)

-- ── :w staging ───────────────────────────────────────────────────────────────

test("open + :w without edits stages nothing (No changes)", function()
  cleanup()
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } })
  goto_cell(bufnr, 1, "payload")
  local cb = cell_buffer.open(bufnr)
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  vim.cmd("write")
  vim.notify = orig_notify
  eq(data.has_changes(view._sessions[bufnr].state), false, "nothing staged")
  eq(vim.api.nvim_get_option_value("modified", { buf = cb }), false, "unmodified")
  eq(notes[#notes], "No changes", "notification")
  cleanup()
end)

test("open + edit + :w stages buffer text as-is", function()
  cleanup()
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } })
  goto_cell(bufnr, 1, "payload")
  local cb = cell_buffer.open(bufnr)
  vim.api.nvim_buf_set_lines(cb, 0, -1, false, { "{", '  "a": 2', "}" })
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  vim.cmd("write")
  vim.notify = orig_notify
  local st = view._sessions[bufnr].state
  eq(data.effective_value(st, 1, "payload"), '{\n  "a": 2\n}', "staged value")
  eq(vim.api.nvim_get_option_value("modified", { buf = cb }), false, "unmodified")
  eq(notes[#notes], "Staged docs.payload", "notification")
  cleanup()
end)

test(":w twice with no further edits stages once then reports No changes", function()
  cleanup()
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } })
  goto_cell(bufnr, 1, "payload")
  local cb = cell_buffer.open(bufnr)
  vim.api.nvim_buf_set_lines(cb, 0, -1, false, { "changed" })
  vim.cmd("write")
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  vim.cmd("write")
  vim.notify = orig_notify
  eq(notes[#notes], "No changes", "second write is a no-op")
  cleanup()
end)

test("multiline value round-trips with real newlines", function()
  cleanup()
  local bufnr = open_grid({ { "1", "{}", "line1\nline2" } })
  goto_cell(bufnr, 1, "notes")
  local cb = cell_buffer.open(bufnr)
  local lines = vim.api.nvim_buf_get_lines(cb, 0, -1, false)
  eq(#lines, 2, "opened with 2 lines")
  vim.api.nvim_buf_set_lines(cb, 0, -1, false, { "one", "two", "three" })
  vim.cmd("write")
  local st = view._sessions[bufnr].state
  eq(data.effective_value(st, 1, "notes"), "one\ntwo\nthree", "staged with real newlines")
  cleanup()
end)

-- ── NULL cells ───────────────────────────────────────────────────────────────

test("NULL cell opens empty; :w empty stages nothing", function()
  cleanup()
  local bufnr = open_grid({ { "1", "{}", "" } })  -- "" = NULL (csv quirk)
  goto_cell(bufnr, 1, "notes")
  local cb = cell_buffer.open(bufnr)
  eq(table.concat(vim.api.nvim_buf_get_lines(cb, 0, -1, false), "\n"), "", "empty buffer")
  vim.cmd("write")
  eq(data.has_changes(view._sessions[bufnr].state), false, "nothing staged")
  cleanup()
end)

test("NULL cell + typed text + :w stages the text", function()
  cleanup()
  local bufnr = open_grid({ { "1", "{}", "" } })
  goto_cell(bufnr, 1, "notes")
  local cb = cell_buffer.open(bufnr)
  vim.api.nvim_buf_set_lines(cb, 0, -1, false, { "not null anymore" })
  vim.cmd("write")
  local st = view._sessions[bufnr].state
  eq(data.effective_value(st, 1, "notes"), "not null anymore", "staged value")
  cleanup()
end)

-- ── read-only grids ──────────────────────────────────────────────────────────

test("read-only grid opens cell in view mode with q to close", function()
  cleanup()
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } }, {})  -- no PKs = readonly
  goto_cell(bufnr, 1, "payload")
  local wins_before = #vim.api.nvim_tabpage_list_wins(0)
  local cb = cell_buffer.open(bufnr)
  assert(cb, "cell buffer created even when read-only")
  eq(vim.api.nvim_get_option_value("modifiable", { buf = cb }), false, "not modifiable")
  eq(vim.api.nvim_get_option_value("filetype", { buf = cb }), "json", "filetype still set")
  eq(has_nmap(cb, "q"), true, "q mapped to close")
  vim.api.nvim_feedkeys("q", "x", false)
  eq(#vim.api.nvim_tabpage_list_wins(0), wins_before, "q closed the split")
  cleanup()
end)

-- ── split style option ───────────────────────────────────────────────────────

test("setup({cell_split='vertical'}) opens a vertical split", function()
  cleanup()
  require("dadbod-grip").setup({ cell_split = "vertical" })
  eq(require("dadbod-grip").get_opts().cell_split, "vertical", "option stored")
  local bufnr = open_grid({ { "1", '{"a":1}', "hello" } })
  goto_cell(bufnr, 1, "payload")
  cell_buffer.open(bufnr)
  local pos = vim.api.nvim_win_get_position(0)
  assert(pos[2] > 0, "cell window sits to the right (col " .. pos[2] .. ")")
  require("dadbod-grip").setup({})  -- restore defaults
  eq(require("dadbod-grip").get_opts().cell_split, "horizontal", "default restored")
  cleanup()
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\ncell_buffer_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
