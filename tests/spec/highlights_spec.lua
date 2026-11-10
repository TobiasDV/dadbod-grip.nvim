-- highlights_spec.lua: setup overrides survive the two paths that rebuild
-- Grip's groups: a colorscheme change and a connection accent change.
local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local pass, fail = 0, 0
local original_opts = grip.get_opts()
local original_scheme = vim.g.colors_name
local original_background = vim.o.background

local function eq(got, want, message)
  assert(vim.deep_equal(got, want), (message or "") .. ": expected "
    .. vim.inspect(want) .. ", got " .. vim.inspect(got))
end

local function hl(name, link)
  return vim.api.nvim_get_hl(0, { name = name, link = link or false })
end

local function test(name, fn)
  grip.setup({ highlights = {} })
  view.set_connection_accent(nil)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

test("no option preserves the existing group definitions", function()
  grip.setup({})
  eq(hl("GripColHighlight"), { bg = 0x313244, ctermbg = 237 })
  eq(hl("GripHeaderActive"), { bold = true, cterm = { bold = true }, bg = 0x313244, ctermbg = 237 })
  eq(hl("GripBorder"), { bold = true, cterm = { bold = true }, fg = 0xcba6f7, ctermfg = 147 })
  eq(grip.get_opts().highlights, {}, "default config exposes an empty map")
end)

test("each override replaces the group instead of merging defaults", function()
  grip.setup({ highlights = {
    GripColHighlight = { fg = "#102030", bg = "#ddeeff", ctermfg = 16, ctermbg = 255 },
    GripHeaderActive = { link = "Visual" },
    GripNull = {},
    GripBorder = { fg = "#456789" },
  } })
  eq(hl("GripColHighlight"), { fg = 0x102030, bg = 0xddeeff, ctermfg = 16, ctermbg = 255 })
  eq(hl("GripHeaderActive", true), { link = "Visual" }, "links are not mixed with hardcoded colors")
  eq(hl("GripNull"), {}, "empty definition clears a group")
  eq(hl("GripBorder"), { fg = 0x456789 }, "omitted bold and cterm defaults are removed")
  eq(hl("GripInserted").fg, 0xa6e3a1, "unspecified groups retain defaults")
end)

test("user definitions win over connection accents and survive reconnecting", function()
  grip.setup({ highlights = {
    GripBorder = { fg = "#112233" },
    GripConnAccentBold = { link = "Title" },
  } })
  for _, color in ipairs({ "red", "green", "#abcdef", "invalid" }) do
    view.set_connection_accent(color)
    eq(hl("GripBorder"), { fg = 0x112233 }, "border survives " .. color)
    eq(hl("GripConnAccentBold", true), { link = "Title" }, "linked title survives " .. color)
  end
  view.set_connection_accent(nil)
  eq(hl("GripBorder").fg, 0x112233, "uncolored reconnect keeps the override")
  eq(hl("GripConnAccent").fg, 0xcba6f7, "an unspecified accent group still resets")
end)

test("overrides and the active connection survive ColorScheme", function()
  grip.setup({ highlights = {
    GripColHighlight = { link = "Visual" },
    GripHeaderActive = { link = "Visual" },
    GripBorder = { fg = "#112233" },
  } })
  view.set_connection_accent("red")
  vim.cmd("colorscheme blue")
  eq(hl("GripColHighlight", true), { link = "Visual" })
  eq(hl("GripHeaderActive", true), { link = "Visual" })
  eq(hl("GripBorder").fg, 0x112233)
  eq(hl("GripConnAccent").fg, 0xf38ba8, "unoverridden accent survives too")
end)

local function luminance(rgb)
  local result = 0
  for i, weight in ipairs({ 0.2126, 0.7152, 0.0722 }) do
    local channel = math.floor(rgb / 256 ^ (3 - i)) % 256 / 255
    result = result + weight * (channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4)
  end
  return result
end

for _, scheme in ipairs({ "morning", "habamax" }) do
  test("selected columns follow readable " .. scheme .. " theme colors", function()
    grip.setup({ highlights = {
      GripColHighlight = { link = "Visual" },
      GripHeaderActive = { link = "Visual" },
    } })
    vim.cmd("colorscheme " .. scheme)
    local normal, selected = hl("Normal"), hl("GripColHighlight")
    eq(selected, hl("Visual"), "the active column uses the theme's selection colors")
    eq(hl("GripHeaderActive"), selected, "sticky header and grid selection agree")
    local fg, bg = luminance(selected.fg or normal.fg), luminance(selected.bg or normal.bg)
    local contrast = (math.max(fg, bg) + 0.05) / (math.min(fg, bg) + 0.05)
    assert(contrast >= 4.5, "selected text contrast must be readable, got " .. contrast)
    view.set_connection_accent("red")
    eq(hl("GripColHighlight"), selected, "connection switch preserves readable selection")
  end)
end

test("setup copies the map and get_opts cannot mutate live overrides", function()
  local highlights = { GripBorder = { fg = "#112233" } }
  grip.setup({ highlights = highlights })
  highlights.GripBorder.fg = "#aabbcc"
  local returned = grip.get_opts()
  eq(returned.highlights.GripBorder.fg, "#112233", "input map was copied")
  returned.highlights.GripBorder.fg = "#ddeeff"
  view.set_connection_accent("red")
  eq(hl("GripBorder").fg, 0x112233, "neither mutable table changed the stored override")
end)

test("a later setup replaces the map and empty setup restores defaults", function()
  grip.setup({ highlights = { GripBorder = { fg = "#112233" }, GripNull = {} } })
  view.set_connection_accent("red")
  grip.setup({ highlights = { GripHeader = { link = "Title" } } })
  eq(hl("GripBorder").fg, 0xf38ba8, "removed override returns to the current accent")
  eq(hl("GripNull").fg, 0x6c7086, "removed clear returns to default")
  grip.setup({})
  eq(hl("GripHeader"), { bold = true, cterm = { bold = true } }, "empty setup restores the default header")
  eq(grip.get_opts().highlights, {}, "empty map is the default")
end)

test("opening and scrolling a real grid preserves selection overrides", function()
  local original_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local buf
  local ok, err = pcall(function()
    grip.setup({ sticky_header = true, highlights = {
      GripColHighlight = { link = "Visual" }, GripHeaderActive = { link = "Visual" },
    } })
    local rows = {}
    for i = 1, 80 do rows[i] = { tostring(i), "Analyst " .. i } end
    local st = require("dadbod-grip.data").new({
      columns = { "id", "name" }, rows = rows, primary_keys = { "id" },
      table_name = "highlight_fixture", url = "sqlite::memory:",
    })
    local win = vim.api.nvim_get_current_win()
    buf = view.open(st, st.url, "SELECT * FROM highlight_fixture", { reuse_win = win })
    local bp = view._sessions[buf]._render.hdr_byte_positions.name
    vim.api.nvim_win_set_cursor(win, { 25, bp.start })
    vim.fn.winrestview({ topline = 20, lnum = 25 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    vim.api.nvim_exec_autocmds("WinScrolled", { buffer = buf })
    local marks = vim.api.nvim_buf_get_extmarks(buf,
      vim.api.nvim_create_namespace("grip_col_hl"), 0, -1, { details = true })
    eq(#marks, 81, "all data cells and the column heading are highlighted")
    for _, mark in ipairs(marks) do eq(mark[4].hl_group, "GripColHighlight") end
    assert(vim.wo[win].winbar:find("%%#GripHeaderActive#name"), "sticky heading uses active selection")
    eq(hl("GripColHighlight", true), { link = "Visual" }, "grid open did not reset the override")
    eq(hl("GripHeaderActive", true), { link = "Visual" })
  end)
  if buf then
    view._sessions[buf] = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  vim.api.nvim_set_current_tabpage(original_tab)
  if not ok then error(err) end
end)

for _, case in ipairs({
  { "non-table map", false },
  { "list instead of group map", { { bg = "#112233" } } },
  { "unknown group", { GripColTypo = { bg = "#112233" } } },
  { "non-Grip group", { Normal = { bg = "#112233" } } },
  { "non-table definition", { GripBorder = "Visual" } },
  { "invalid color", { GripBorder = { fg = "#zzzzzz" } } },
  { "invalid attribute", { GripBorder = { bodl = true } } },
  { "default flag", { GripBorder = { default = true, fg = "#112233" } } },
  { "force flag", { GripBorder = { force = false, fg = "#112233" } } },
}) do
  test("invalid " .. case[1] .. " fails setup without altering live config", function()
    grip.setup({ limit = 51, highlights = { GripBorder = { fg = "#112233" } } })
    local before_opts, before_hl = grip.get_opts(), hl("GripBorder")
    local ok, err = pcall(grip.setup, { limit = 13, highlights = case[2] })
    eq(ok, false, "invalid config must be rejected")
    assert(tostring(err):find("highlights", 1, true), "error identifies the setup option: " .. tostring(err))
    eq(grip.get_opts(), before_opts, "options stay unchanged")
    eq(hl("GripBorder"), before_hl, "visible groups stay unchanged")
    view.set_connection_accent("green")
    eq(hl("GripBorder"), before_hl, "stored overrides stay unchanged")
  end)
end

test("one invalid definition cannot partially apply valid siblings", function()
  grip.setup({ highlights = { GripBorder = { fg = "#112233" } } })
  local ok = pcall(grip.setup, { highlights = {
    GripColHighlight = { bg = "#ddeeff" }, GripBorder = { fg = "#zzzzzz" },
  } })
  eq(ok, false)
  eq(hl("GripColHighlight").bg, 0x313244)
  eq(hl("GripBorder").fg, 0x112233)
end)

grip.setup(original_opts)
view.set_connection_accent(nil)
vim.o.background = original_background
vim.cmd("colorscheme " .. (original_scheme or "default"))
print(string.format("\nhighlights_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
