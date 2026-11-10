return function(flags)
  local grip, ui = require('dadbod-grip'), require('dadbod-grip.ui')
  local view, data = require('dadbod-grip.view'), require('dadbod-grip.data')
  local running, result = flags[1] ~= false, flags[2] ~= false
  local registry = vim.fn.tempname()
  vim.fn.writefile({'[]'}, registry)
  grip.setup({show_running_time = flags[1], show_result_time = flags[2], connections_path = registry})
  local function screen(win)
    vim.cmd('redraw')
    local info, lines = vim.fn.getwininfo(win)[1], {}
    for row = info.winrow, info.winrow + info.height - 1 do
      local line = ''
      for col = info.wincol + info.textoff, info.wincol + info.width - 1 do
        line = line .. vim.fn.screenstring(row, col)
      end
      lines[#lines + 1] = line
    end
    return table.concat(lines, '\n')
  end
  local function spinner()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then return win, vim.api.nvim_win_get_buf(win) end
    end
    error('busy float missing')
  end
  local before = #vim.api.nvim_list_wins()
  local busy_buf
  ui.blocking('visibility wait', function()
    local win, buf = spinner()
    busy_buf = buf
    local initial = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    assert(not initial:find('%d'), 'timer appeared before delay')
    vim.wait(700, function() return false end, 5)
    local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    assert(line:find('visibility wait', 1, true) and line:sub(1, 6) ~= initial:sub(1, 6),
      'spinner feedback did not animate')
    assert((line:find('%d+%.%d+s') ~= nil) == running, 'running visibility mismatch: ' .. line)
    assert(screen(win):find('visibility wait', 1, true), 'busy feedback not painted')
  end)
  assert(#vim.api.nvim_list_wins() == before and not vim.api.nvim_buf_is_valid(busy_buf), 'busy float leaked')
  local st = data.new({columns = {'id', 'name'}, rows = {{'1', string.rep('wide ', 20)}},
    primary_keys = {'id'}, table_name = 'timer_visibility'})
  local buf = view.open(st, 'sqlite:synthetic-only', nil,
    {elapsed_ms = 4321, reuse_win = vim.api.nvim_get_current_win(), max_col_width = 100})
  local session = view._sessions[buf]
  session.elapsed_ms, session.last_action = 53, 'updated'
  view.render(buf, st)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert((text:find('Query: 4.3s client', 1, true) ~= nil) == result, 'retained query visibility mismatch')
  assert((text:find('53ms', 1, true) ~= nil) == result, 'action timing visibility mismatch')
  assert(text:find('updated', 1, true) and text:find('1 rows', 1, true), 'result status was suppressed')
  assert(session._query_times[st.rows] == 4321 and session.elapsed_ms == 53, 'visibility changed measurement')
  local first = vim.api.nvim_get_current_win()
  assert(screen(first):find('?:help', 1, true), 'timer setting hid key hints')
  vim.cmd('vsplit')
  local second = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(second, 24)
  for _, win in ipairs({first, second}) do
    local visible = screen(win)
    assert((visible:find('4.3s client', 1, true) ~= nil) == result, 'window-local footer visibility mismatch: ' .. visible)
    if not result then assert(not visible:find('53ms', 1, true), 'hidden action timer leaked in shared window') end
  end
  vim.api.nvim_win_close(second, true)
  for _, failure in ipairs({'error', 'cancel'}) do
    local completed, reason
    local ok, err = pcall(ui.blocking, 'visibility ' .. failure, function()
      local _, b = spinner()
      busy_buf = b
      if failure == 'error' then error('visibility cleanup failure') end
      vim.defer_fn(function() vim.api.nvim_input('\003') end, 30)
      completed, reason = vim.wait(1000, function() return false end, 5)
    end)
    if failure == 'error' then assert(not ok and tostring(err):find('visibility cleanup failure', 1, true), 'error swallowed')
    else assert(ok and not completed and reason == -2, 'actual Ctrl-C did not cancel') end
    assert(#vim.api.nvim_list_wins() == before and not vim.api.nvim_buf_is_valid(busy_buf), 'failure float leaked')
  end
  _G.timer_visibility_resize_check = function()
    local visible = screen(first)
    assert((visible:find('4.3s client', 1, true) ~= nil) == result, 'resized footer visibility mismatch: ' .. visible)
    if not result then assert(not visible:find('53ms', 1, true), 'hidden action timer leaked after resize') end
    return true
  end
  vim.fn.delete(registry)
  return true
end
