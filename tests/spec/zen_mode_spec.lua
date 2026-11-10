-- Real rendering and runtime commands; visibility must not become editor state.
dofile('tests/minimal_init.lua')
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print('FAIL: ' .. name .. ': ' .. tostring(err)) end
end
local grip = require('dadbod-grip')
test('hints default on, validate booleans and preserve explicit false', function()
  assert(grip.get_opts().show_hints == true, 'default show_hints missing')
  grip.setup({show_hints = false})
  grip.setup({limit = 5})
  assert(grip.get_opts().show_hints == false, 'unrelated setup reset false')
  local copy = grip.get_opts(); copy.show_hints = true
  assert(grip.get_opts().show_hints == false, 'get_opts exposes live state')
  local ok, err = pcall(grip.setup, {show_hints = 'false'})
  assert(not ok and tostring(err):find('show_hints', 1, true), 'invalid hints accepted')
end)
for _, case in ipairs({
  {'grid', 160}, {'grid', 80}, {'grid', 40}, {'gutter', 40}, {'shared', 100},
  {'ambiwidth', 40}, {'readonly', 40}, {'metadata', 80}, {'mutation', 40},
  {'unknown', 40}, {'surfaces', 80}, {'custom', 80}, {'pad-editing', 80}, {'failures', 80}, {'write-owned', 40},
}) do
  test('native Zen ' .. case[1] .. ' ' .. case[2], function()
    local child = vim.fn.jobstart({vim.g.grip_test_progpath, '--clean', '--embed', '--headless',
      '-n', '-i', 'NONE', '-u', 'tests/minimal_init.lua'}, {rpc = true})
    local active = true
    vim.defer_fn(function() if active then vim.fn.jobstop(child) end end, 15000)
    local ok, err = pcall(function()
      vim.fn.rpcrequest(child, 'nvim_ui_attach', case[2], 40, {rgb = true})
      assert(vim.fn.rpcrequest(child, 'nvim_exec_lua',
        "return dofile('tests/fixtures/zen_mode.lua')(...)", {case[1]}))
    end)
    active = false
    vim.fn.jobstop(child)
    assert(ok, err)
  end)
end
grip.setup({show_hints = true})
print(string.format('zen_mode_spec: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
