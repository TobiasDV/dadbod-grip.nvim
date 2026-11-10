-- Timer visibility controls presentation, never measurement or operation state.
dofile('tests/minimal_init.lua')
local grip = require('dadbod-grip')
local registry = vim.fn.tempname()
vim.fn.writefile({'[]'}, registry)
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print('FAIL: ' .. name .. ': ' .. tostring(err)) end
end

test('timer settings default on and retain explicit false in a copied get_opts', function()
  grip.setup({show_running_time = true, show_result_time = true, connections_path = registry})
  assert(grip.get_opts().show_running_time == true and grip.get_opts().show_result_time == true,
    'default timer settings missing')
  grip.setup({show_running_time = false, show_result_time = false})
  local opts = grip.get_opts()
  assert(opts.show_running_time == false and opts.show_result_time == false, 'false was discarded')
  opts.show_running_time, opts.show_result_time = true, true
  assert(grip.get_opts().show_running_time == false and grip.get_opts().show_result_time == false,
    'get_opts exposed mutable settings')
  grip.setup({limit = 5})
  assert(grip.get_opts().show_running_time == false and grip.get_opts().show_result_time == false,
    'unrelated setup discarded explicit false')
end)

for _, name in ipairs({'show_running_time', 'show_result_time'}) do
  test(name .. ' rejects non-boolean values', function()
    local ok, err = pcall(grip.setup, {[name] = 'false'})
    assert(not ok and tostring(err):find(name, 1, true), 'invalid timer option accepted')
  end)
end

for _, flags in ipairs({{}, {true, true}, {true, false}, {false, true}, {false, false}}) do
  local name = #flags == 0 and 'defaults' or tostring(flags[1]) .. '/' .. tostring(flags[2])
  test('native running/result visibility ' .. name, function()
    local child = vim.fn.jobstart({vim.g.grip_test_progpath, '--clean', '--embed', '--headless',
      '-n', '-i', 'NONE', '-u', 'tests/minimal_init.lua'}, {rpc = true})
    local ok, err = pcall(function()
      vim.fn.rpcrequest(child, 'nvim_ui_attach', 100, 30, {rgb = true})
      assert(vim.fn.rpcrequest(child, 'nvim_exec_lua',
        "return dofile('tests/fixtures/timer_visibility.lua')(...)", {flags}))
      for _, width in ipairs({12, 40, 100}) do
        vim.fn.rpcrequest(child, 'nvim_ui_try_resize', width, 30)
        assert(vim.fn.rpcrequest(child, 'nvim_exec_lua', 'return timer_visibility_resize_check()', {}))
      end
    end)
    vim.fn.jobstop(child)
    assert(ok, err)
  end)
end

test('hidden query time still records history and survives refresh, failure and interruption', function()
  local view, db = require('dadbod-grip.view'), require('dadbod-grip.db')
  for buf in pairs(view._sessions) do pcall(vim.api.nvim_buf_delete, buf, {force = true}) end
  grip.setup({show_running_time = false, show_result_time = false, open_sidebar = false,
    connections_path = registry})
  grip.open('users', 'sqlite:tests/seed_sqlite.db', {from_pad = true})
  local buf = assert(next(view._sessions))
  local session = view._sessions[buf]
  local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  assert(not text():find('Query:', 1, true), 'hidden initial query time visible')
  local history = require('dadbod-grip.history').list(1)[1]
  assert(history and type(history.elapsed_ms) == 'number' and history.elapsed_ms == session.elapsed_ms,
    'hidden display disabled history measurement')
  local original = session.state
  session.on_refresh(buf)
  assert(session.state.rows ~= original.rows and type(session._query_times[session.state.rows]) == 'number',
    'hidden refresh failed to retain result measurement')
  assert(vim.wait(1000, function() return session._column_info ~= nil end, 5), 'metadata did not finish')
  local previous, ms, rendered = session.state, session.elapsed_ms, text()
  local query, notify = db.query, vim.notify
  local messages, interrupted = {}, false
  vim.notify = function(msg) messages[#messages + 1] = tostring(msg) end
  db.query = function() return nil, 'visibility fixture failure' end
  local ok, err = pcall(session.on_refresh, buf)
  db.query, vim.notify = query, notify
  assert(ok, err)
  assert(table.concat(messages, '\n'):find('visibility fixture failure', 1, true), 'hidden error was suppressed')
  assert(session.state == previous and session.elapsed_ms == ms and text() == rendered,
    'failed hidden query replaced previous result')
  db.query = function()
    vim.defer_fn(function() vim.api.nvim_input('\003') end, 30)
    local completed, reason = vim.wait(1000, function() return false end, 5)
    interrupted = not completed and reason == -2
    return nil, 'interrupted'
  end
  vim.notify = function() end
  ok, err = pcall(session.on_refresh, buf)
  db.query, vim.notify = query, notify
  assert(ok, err)
  assert(interrupted and session.state == previous and session.elapsed_ms == ms and text() == rendered,
    'interrupted hidden query replaced previous result')
  grip.setup({show_running_time = true, show_result_time = true})
  view.render(buf, original)
  assert(text():find('Query:', 1, true), 'hidden original result lost its retained measurement')
  vim.api.nvim_buf_delete(buf, {force = true})
end)

grip.setup({show_running_time = true, show_result_time = true})
vim.fn.delete(registry)
print(string.format('timer_visibility_spec: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
