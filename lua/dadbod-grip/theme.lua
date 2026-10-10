-- theme.lua: every colour grip draws with comes from the active colorscheme.
--
-- Grip used to ship its own hex values, so it looked the same under every
-- colorscheme and matched none of them. Each group is now derived from
-- groups the colorscheme already defines, by role: red for deleted, green
-- for inserted, yellow for changed, grey for dimmed, blue for links, the
-- Title colour as the connection accent. Under gruvbox that is gruvbox's
-- red, green and yellow; under anything else, that scheme's own.
--
-- A role tries colour-name groups first (gruvbox-material defines Red,
-- Green, ...; gruvbox.nvim GruvboxRed, ...), then standard groups every
-- scheme has, so there is always an answer.
--
-- Groups are defined with `default = true`, so one the user defined in
-- their own config wins. The accent trio is the exception: see
-- view.set_connection_accent.
local M = {}

M.ROLES = {
  red     = { "Red",    "GruvboxRed",    "DiagnosticError", "ErrorMsg" },
  green   = { "Green",  "GruvboxGreen",  "DiagnosticOk",    "String" },
  yellow  = { "Yellow", "GruvboxYellow", "DiagnosticWarn",  "WarningMsg" },
  orange  = { "Orange", "GruvboxOrange", "Special",         "DiagnosticWarn" },
  blue    = { "Blue",   "GruvboxBlue",   "DiagnosticInfo",  "Function" },
  violet  = { "Purple", "GruvboxPurple", "Boolean",         "Constant" },
  grey    = { "Grey",   "GruvboxGray",   "Comment",         "NonText" },
  title   = { "Title",  "Orange", "GruvboxOrange", "Special" },
  border  = { "FloatBorder", "WinSeparator", "Comment" },
  column  = { "CursorColumn", "CursorLine", "Visual" },
  added   = { "DiffAdd" },
  changed = { "DiffChange" },
  deleted = { "DiffDelete" },
  text    = { "Normal" },
}

-- The six names a connection's "color" may use.
M.ACCENT_NAMES = { green = true, orange = true, red = true, blue = true, violet = true, yellow = true }

--- Nearest xterm-256 index for a hex colour, for groups whose source has no
--- ctermfg. The 240 colours above the ANSI 16 are a 6x6x6 cube (levels
--- 0/95/135/175/215/255) plus a 24-step grey ramp (8 + 10i); the nearer of
--- the two candidates wins, so a near-grey lands on the ramp and not on a
--- saturated cube entry.
function M.cterm_for(hex)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  local function dist(cr, cg, cb)
    return (r - cr) ^ 2 + (g - cg) ^ 2 + (b - cb) ^ 2
  end
  -- Cube levels are unevenly spaced at the bottom.
  local function level(v)
    if v < 48  then return 0 end
    if v < 115 then return 1 end
    return math.floor((v - 35) / 40)
  end
  local function level_value(i) return i == 0 and 0 or 55 + i * 40 end
  local ri, gi, bi = level(r), level(g), level(b)
  local cube_d = dist(level_value(ri), level_value(gi), level_value(bi))

  local gi_ramp = math.floor(((r + g + b) / 3 - 8) / 10 + 0.5)
  gi_ramp = math.max(0, math.min(23, gi_ramp))
  local grey = 8 + 10 * gi_ramp

  if dist(grey, grey, grey) < cube_d then return 232 + gi_ramp end
  return 16 + 36 * ri + 6 * gi + bi
end

local function hl_of(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then return hl end
end

local function to_hex(n) return string.format("#%06x", n) end

--- The first group of `role` that has `attr` ("fg" or "bg"), as
--- { hex = "#rrggbb", cterm = n }, or nil when none does.
function M.color(role, attr)
  attr = attr or "fg"
  for _, name in ipairs(M.ROLES[role] or {}) do
    local hl = hl_of(name)
    if hl and hl[attr] then
      local hex = to_hex(hl[attr])
      local cterm = hl[attr == "fg" and "ctermfg" or "ctermbg"]
      return { hex = hex, cterm = cterm or M.cterm_for(hex) }
    end
  end
  return nil
end

--- A role's foreground; Normal's when the role has none, grey as a last resort.
function M.fg(role)
  return M.color(role, "fg") or M.color("text", "fg") or { hex = "#808080", cterm = 244 }
end

--- A connection "color": one of ACCENT_NAMES in the colorscheme's own colour,
--- or "#rrggbb". Anything else is nil, so a typo costs the colour, not the
--- connection.
function M.accent(color)
  if type(color) ~= "string" then return nil end
  local role = color:lower()
  if M.ACCENT_NAMES[role] then return M.fg(role) end
  local hex = color:match("^#%x%x%x%x%x%x$")
  if hex then return { hex = hex, cterm = M.cterm_for(hex) } end
  return nil
end

local function spec(fg, bg, extra)
  local s = { default = true }
  for k, v in pairs(extra or {}) do s[k] = v end
  if fg then s.fg, s.ctermfg = fg.hex, fg.cterm end
  if bg then s.bg, s.ctermbg = bg.hex, bg.cterm end
  return s
end

--- Define every grip group from the current colorscheme. Safe to call
--- repeatedly: a group that already exists is left alone.
function M.apply()
  local hl = vim.api.nvim_set_hl
  local red, green, yellow = M.fg("red"), M.fg("green"), M.fg("yellow")
  local orange, blue, grey = M.fg("orange"), M.fg("blue"), M.fg("grey")
  local column  = M.color("column", "bg")
  local added   = M.color("added", "bg")
  local changed = M.color("changed", "bg")
  local deleted = M.color("deleted", "bg")

  hl(0, "GripHeader",       spec(nil, nil, { bold = true }))
  hl(0, "GripHeaderActive", spec(nil, column, { bold = true }))
  hl(0, "GripColHighlight", spec(nil, column))
  hl(0, "GripNull",         spec(grey, nil, { italic = true }))
  hl(0, "GripReadonly",     spec(grey, nil, { italic = true }))
  hl(0, "GripDatePast",     spec(grey, nil, { italic = true }))
  hl(0, "GripColType",      spec(grey))
  -- Staged changes: the diff backgrounds, with the role colour on top.
  hl(0, "GripModified",     spec(yellow, changed, { bold = true }))
  hl(0, "GripInserted",     spec(green, added, { bold = true }))
  hl(0, "GripDeleted",      spec(red, deleted, { strikethrough = true }))
  hl(0, "GripNullStaged",   spec(orange, changed, { bold = true }))
  hl(0, "GripStatusOk",     spec(green, nil, { bold = true }))
  hl(0, "GripStatusChg",    spec(yellow, nil, { bold = true }))
  hl(0, "GripNegative",     spec(red, nil, { bold = true }))
  hl(0, "GripBoolTrue",     spec(green, nil, { bold = true }))
  hl(0, "GripBoolFalse",    spec(red, nil, { bold = true }))
  hl(0, "GripUrl",          spec(blue, nil, { underline = true }))
  hl(0, "GripWatch",        spec(blue, nil, { bold = true }))
  hl(0, "GripDiffChanged",  spec(yellow, nil, { bold = true }))
  hl(0, "GripDiffAdded",    spec(green, nil, { bold = true }))
  hl(0, "GripDiffDeleted",  spec(red, nil, { bold = true }))
  hl(0, "GripDiffSep",      spec(grey, nil, { bold = true }))
  hl(0, "GripProfileHeader", spec(M.fg("title"), nil, { bold = true }))
end

--- Define the accent trio for a connection colour; nil restores the
--- colorscheme's own look: the Title colour for the accent, the float
--- border colour for borders and grid rules. Always overwrites, so leaving
--- a coloured connection takes its tint with it.
function M.apply_accent(color)
  local hl = vim.api.nvim_set_hl
  local a = M.accent(color)
  local accent = a or M.fg("title")
  local border = a or M.color("border", "fg") or M.fg("grey")
  hl(0, "GripConnAccent",     { fg = accent.hex, ctermfg = accent.cterm })
  hl(0, "GripConnAccentBold", { bold = true, fg = accent.hex, ctermfg = accent.cterm })
  hl(0, "GripBorder",         { bold = true, fg = border.hex, ctermfg = border.cterm })
end

return M
