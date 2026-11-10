-- Retained query time belongs to displayed results, not a global last request.
dofile('tests/minimal_init.lua')
local view, data = require('dadbod-grip.view'), require('dadbod-grip.data')
local grip, db, qmod = require('dadbod-grip'), require('dadbod-grip.db'), require('dadbod-grip.query')
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print('FAIL: ' .. name .. ': ' .. tostring(err)) end
end
local function cleanup()
  local buffers = {}
  for b in pairs(view._sessions) do buffers[#buffers + 1] = b end
  for _, b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function state(rows)
  return data.new({ columns = { 'id', 'name' }, rows = rows or {{'1','first'}}, primary_keys = {'id'}, table_name = 'users' })
end
local function timed(ms, rows)
  local st = state(rows)
  return view.open(st, 'sqlite:tests/seed_sqlite.db', 'SELECT * FROM users', {elapsed_ms = ms}), st
end
local function public_grid()
  cleanup()
  grip.open('users', 'sqlite:tests/seed_sqlite.db', {from_pad = true})
  local buf = assert(next(view._sessions))
  return buf, view._sessions[buf]
end
for _, example in ipairs({{0,'0ms'},{17,'17ms'},{1650,'1.6s'},{59999,'60.0s'},{60000,'1m00s'},{72104,'1m12s'}}) do
  test('retained client query label for ' .. example[1] .. 'ms', function()
    cleanup()
    local buf = timed(example[1])
    assert(text(buf):find('Query: ' .. example[2] .. ' client', 1, true), text(buf))
    assert(not text(buf):find(example[1] .. 'ms query', 1, true), 'duplicate terse query badge remains')
  end)
end

test('empty result retains its successful query time', function()
  cleanup()
  local buf = timed(23, {})
  assert(text(buf):find('0 rows', 1, true) and text(buf):find('Query: 23ms client', 1, true), text(buf))
end)

test('staged editing and undo keep the original result duration', function()
  cleanup()
  local buf, st = timed(1234)
  view.apply_edit(buf, data.add_change(st, 1, 'name', 'staged'))
  assert(view._sessions[buf].state.rows == st.rows, 'ordinary edits must share immutable result rows')
  assert(text(buf):find('Query: 1.2s client', 1, true) and text(buf):find('1 staged', 1, true), text(buf))
  view.render(buf, st)
  assert(text(buf):find('Query: 1.2s client', 1, true), 'undo lost duration')
end)

test('untimed replacement and metadata rows do not inherit query time; nav back restores it', function()
  cleanup()
  local buf, original = timed(4321)
  view.render(buf, state({{'2','different result'}}))
  assert(not text(buf):find('4.3s', 1, true), 'different result inherited timing')
  view.render(buf, original)
  assert(text(buf):find('Query: 4.3s client', 1, true), 'restored original rows lost their duration')
end)

test('metadata view suppresses record timing and restores it on records', function()
  local buf, session = public_grid()
  local before = text(buf):match('(Query: [^\n]+)')
  assert(before, 'initial query footer missing')
  view.switch_view(buf, 'columns')
  assert(not text(buf):find('Query:', 1, true), 'metadata inherited records duration')
  view.switch_view(buf, 'records')
  assert(text(buf):find(before, 1, true), 'records duration lost after metadata view')
  assert(session == view._sessions[buf], 'metadata replaced result session')
end)

test('real FK navigation suppresses untimed duration and nav back restores it', function()
  cleanup()
  grip.open('orders', 'sqlite:tests/seed_sqlite.db', {from_pad = true})
  local buf = assert(next(view._sessions))
  local session = view._sessions[buf]
  local before = text(buf):match('(Query: [^\n]+)')
  assert(before, 'initial query footer missing')
  local pos = assert(session._render.byte_positions[1].user_id)
  vim.api.nvim_win_set_cursor(0, {session._render.data_start, pos.start})
  local km = require('dadbod-grip.keymaps')
  local function invoke(action)
    local map = vim.fn.maparg(km.get(action), 'n', false, true)
    assert(type(map.callback) == 'function', 'missing action ' .. action)
    map.callback()
  end
  invoke('grid_fk_follow')
  assert(session.state.table_name == 'users', 'FK did not navigate')
  assert(not text(buf):find('Query:', 1, true), 'FK rows inherited source duration')
  invoke('grid_fk_back')
  assert(session.state.table_name == 'orders', 'FK back did not restore rows')
  assert(text(buf):find(before, 1, true), 'FK back lost source result duration')
end)

test('result buffers isolate their times and a new untimed buffer has none', function()
  cleanup()
  local first = timed(65000)
  local second = view.open(state(), 'sqlite:tests/seed_sqlite.db', nil, {elapsed_ms = 7, force_split = true})
  assert(text(first):find('Query: 1m05s client', 1, true), 'first buffer duration changed')
  assert(text(second):find('Query: 7ms client', 1, true), 'second buffer did not reset')
  local third = view.open(state(), 'sqlite:tests/seed_sqlite.db', nil, {force_split = true})
  assert(not text(third):find('Query:', 1, true), 'untimed buffer inherited global duration')
end)

test('mutation action badge remains separate from retained query duration', function()
  cleanup()
  local buf = timed(1400)
  local session = view._sessions[buf]
  session.elapsed_ms, session.last_action = 53, 'updated'
  view.render(buf, session.state)
  assert(text(buf):find('53ms updated', 1, true), 'action timing lost')
  assert(text(buf):find('Query: 1.4s client', 1, true), 'query time overwritten by action')
end)

test('failed requery preserves prior rows, query identity, count and duration', function()
  local buf, session = public_grid()
  local before = {state = session.state, spec = session.query_spec, sql = session.query_sql,
    total = session.total_rows, ms = session.elapsed_ms, text = text(buf)}
  local query, notify = db.query, vim.notify
  db.query = function(sql)
    if sql:find('COUNT', 1, true) then return {columns={'count'},rows={{'999'}}} end
    return nil, 'intentional failed SELECT'
  end
  vim.notify = function() end
  local ok, err = pcall(session.on_requery, buf, qmod.toggle_sort(session.query_spec, 'name'))
  db.query, vim.notify = query, notify
  assert(ok, err)
  assert(session.state == before.state and session.query_spec == before.spec and session.query_sql == before.sql,
    'failed query changed displayed identity')
  assert(session.total_rows == before.total and session.elapsed_ms == before.ms and text(buf) == before.text,
    'failed query published count/duration or repainted the old result')
end)

test('successful refresh publishes new rows with their own client time and unchanged history semantics', function()
  local buf, session = public_grid()
  local original = session.state
  local history = require('dadbod-grip.history').list(1)[1]
  assert(history and history.elapsed_ms == session.elapsed_ms, 'initial query/history timing diverged')
  local original_label = text(buf):match('(Query: [^\n]+)')
  session.on_refresh(buf)
  assert(session.state.rows ~= original.rows, 'refresh did not replace result snapshot')
  local label = require('dadbod-grip.result_hints').query_time(session.elapsed_ms, math.huge)
  assert(text(buf):find(label, 1, true), 'new rows did not publish their own duration')
  view.render(buf, original)
  assert(text(buf):find(original_label, 1, true), 'original snapshot lost its duration')
end)

test('actual interrupted wait preserves prior result time', function()
  local buf, session = public_grid()
  -- Initial column metadata is scheduled after open. Let its real adapter wait
  -- finish before injecting Ctrl-C, so it cannot consume the target interrupt.
  assert(vim.wait(1000, function() return session._column_info ~= nil end, 5),
    'initial column metadata did not finish')
  local previous = text(buf)
  local query, notify = db.query, vim.notify
  local interrupted
  db.query = function()
    vim.defer_fn(function() vim.api.nvim_input('\003') end, 30)
    local completed, reason = vim.wait(1000, function() return false end, 5)
    interrupted = not completed and reason == -2
    return nil, 'interrupted'
  end
  vim.notify = function() end
  local ok, err = pcall(session.on_refresh, buf)
  db.query, vim.notify = query, notify
  assert(ok, err)
  assert(interrupted, 'wait did not receive actual Ctrl-C')
  assert(text(buf) == previous, 'interruption replaced previous result/time')
end)

test('closed result ignores completion without changing its old session', function()
  local buf, session = public_grid()
  local previous = session.query_spec
  local query = db.query
  local once = false
  db.query = function(...)
    local result, err = query(...)
    if not once then once = true; vim.api.nvim_buf_delete(buf, {force=true}) end
    return result, err
  end
  local ok, err = pcall(session.on_requery, buf, qmod.toggle_sort(previous, 'name'))
  db.query = query
  assert(ok, err)
  assert(not view._sessions[buf] and not vim.api.nvim_buf_is_valid(buf), 'closed result resurrected')
  assert(session.query_spec == previous, 'closed session accepted stale query identity')
end)

test('a newer nested refresh wins over an older completion', function()
  local buf, session = public_grid()
  local query, nested = db.query, false
  db.query = function(sql, ...)
    local result, err = query(sql, ...)
    if result and result.rows[1] and not sql:find('COUNT', 1, true) then
      if not nested then
        nested = true
        session.on_refresh(buf)
        result.rows[1][2] = 'older completion'
      else result.rows[1][2] = 'newer completion' end
    end
    return result, err
  end
  local ok, err = pcall(session.on_refresh, buf)
  db.query = query
  assert(ok, err)
  assert(session.state.rows[1][2] == 'newer completion', 'older completion overwrote latest result')
end)

for _, scenario in ipairs({'wide','narrow','tiny','shared','scroll'}) do
  test('native window-local query duration: ' .. scenario, function()
    local child = vim.fn.jobstart({vim.g.grip_test_progpath,'--clean','--embed','--headless','-n','-i','NONE',
      '-u','tests/minimal_init.lua'}, {rpc=true})
    local ok, err = pcall(function()
      vim.fn.rpcrequest(child,'nvim_ui_attach',scenario == 'tiny' and 12 or scenario == 'narrow' and 24 or 100,30,{rgb=true})
      assert(vim.fn.rpcrequest(child,'nvim_exec_lua',"return dofile('tests/fixtures/query_elapsed_footer.lua')(...)",{scenario}))
    end)
    vim.fn.jobstop(child)
    assert(ok, err)
  end)
end
cleanup()
print(string.format('query_elapsed_spec: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
