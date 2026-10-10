-- theme_spec.lua -- grip's highlight groups come from the active colorscheme.
--
-- Each test starts from `highlight clear` (what a colorscheme does), defines
-- the groups a scheme would, and asserts what grip derives from them.
local theme = require("dadbod-grip.theme")

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

local function hl(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

local function fresh(scheme)
  vim.cmd("highlight clear")
  for name, def in pairs(scheme or {}) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

test("a colour-name group wins over the standard groups", function()
  fresh({ Red = { fg = 0x123456 }, DiagnosticError = { fg = 0x654321 } })
  theme.apply()
  eq(hl("GripNegative").fg, 0x123456, "GripNegative is the scheme's Red")
  eq(hl("GripDeleted").fg, 0x123456, "GripDeleted too")
  eq(hl("GripBoolFalse").fg, 0x123456, "and GripBoolFalse")
end)

test("gruvbox.nvim's Gruvbox* groups are found", function()
  fresh({ GruvboxGreen = { fg = 0x00aa00 } })
  theme.apply()
  eq(hl("GripInserted").fg, 0x00aa00, "green from GruvboxGreen")
end)

test("the standard groups are the fallback", function()
  fresh({ DiagnosticWarn = { fg = 0xaaaa00 }, Comment = { fg = 0x777777, italic = true } })
  theme.apply()
  eq(hl("GripModified").fg, 0xaaaa00, "yellow from DiagnosticWarn")
  eq(hl("GripNull").fg, 0x777777, "grey from Comment")
  eq(hl("GripNull").italic, true, "and NULL stays italic")
end)

test("staged rows take the diff backgrounds", function()
  fresh({ DiffAdd = { bg = 0x002200 }, DiffChange = { bg = 0x000022 }, DiffDelete = { bg = 0x220000 } })
  theme.apply()
  eq(hl("GripInserted").bg, 0x002200, "inserted on DiffAdd")
  eq(hl("GripModified").bg, 0x000022, "modified on DiffChange")
  eq(hl("GripNullStaged").bg, 0x000022, "staged NULL on DiffChange")
  eq(hl("GripDeleted").bg, 0x220000, "deleted on DiffDelete")
  eq(hl("GripDeleted").strikethrough, true, "deleted stays struck through")
end)

test("a group the user defined is left alone", function()
  fresh({ Comment = { fg = 0x777777 } })
  vim.api.nvim_set_hl(0, "GripNull", { fg = 0xabcdef })
  theme.apply()
  eq(hl("GripNull").fg, 0xabcdef, "the user's GripNull wins")
  eq(hl("GripReadonly").fg, 0x777777, "the others are still derived")
end)

test("the cterm index follows the source group, or is approximated", function()
  fresh({ Red = { fg = 0xff0000, ctermfg = 196 }, Green = { fg = 0x00ff00 } })
  theme.apply()
  eq(hl("GripNegative").ctermfg, 196, "ctermfg copied from Red")
  eq(hl("GripBoolTrue").ctermfg, 46, "Green had none: #00ff00 approximated to 46")
end)

test("the default accent is the Title colour and the border the float border", function()
  fresh({ Title = { fg = 0xaa5500, bold = true }, FloatBorder = { fg = 0x555555 } })
  theme.apply_accent(nil)
  eq(hl("GripConnAccent").fg, 0xaa5500, "accent from Title")
  eq(hl("GripConnAccentBold").bold, true, "bold variant is bold")
  eq(hl("GripBorder").fg, 0x555555, "border from FloatBorder")
end)

test("a connection colour name is the scheme's colour", function()
  fresh({ Blue = { fg = 0x0000aa } })
  theme.apply_accent("blue")
  eq(hl("GripBorder").fg, 0x0000aa, "blue is the scheme's Blue")
  theme.apply_accent("#00ff00")
  eq(hl("GripBorder").fg, 0x00ff00, "a hex is taken as given")
  eq(theme.accent("chartreuse-ish"), nil, "an unknown name resolves to nothing")
end)

test("every role resolves under the stock colorscheme", function()
  pcall(vim.cmd, "colorscheme default")
  for role in pairs(theme.ROLES) do
    assert(theme.fg(role), role .. " has a foreground")
  end
end)

test("no file but theme.lua carries a hex colour", function()
  local offenders = {}
  for _, path in ipairs(vim.fn.glob("lua/dadbod-grip/**/*.lua", true, true)) do
    if not path:match("theme%.lua$") then
      for lnum, line in ipairs(vim.fn.readfile(path)) do
        if line:match("#%x%x%x%x%x%x") then
          table.insert(offenders, path .. ":" .. lnum)
        end
      end
    end
  end
  eq(#offenders, 0, "hex colours outside theme.lua: " .. table.concat(offenders, ", "))
end)

-- Put the groups back the way the other specs expect them.
pcall(vim.cmd, "colorscheme default")
theme.apply()
theme.apply_accent(nil)

print(string.format("\ntheme_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
