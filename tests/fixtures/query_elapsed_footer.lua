return function(scenario)
  local view, data = require('dadbod-grip.view'), require('dadbod-grip.data')
  local st = data.new({columns={'id','wide'},rows={{'1',string.rep('data ',25)}},primary_keys={'id'},table_name='elapsed_fixture'})
  local buf = view.open(st,'sqlite:synthetic-only',nil,{elapsed_ms=4321,reuse_win=vim.api.nvim_get_current_win(),max_col_width=100})
  assert(view._sessions[buf].elapsed_ms == 4321, 'result timing changed during open')
  local win = vim.api.nvim_get_current_win()
  local function screen(w)
    vim.cmd('redraw')
    local info = vim.fn.getwininfo(w)[1]
    local text = ''
    for row = info.winrow, info.winrow + info.height - 1 do
      for col = info.wincol + info.textoff, info.wincol + info.width - 1 do
        text = text .. vim.fn.screenstring(row,col)
      end
      text = text .. '\n'
    end
    return text
  end
  local function check(w)
    local text = screen(w)
    assert(text:find('4.3s client',1,true),'client query duration missing from visible native footer: '..text)
    assert(not vim.wo[w].wrap,'footer must preserve horizontal data scrolling')
  end
  if scenario == 'shared' then
    vim.cmd('vsplit')
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(other,24)
    check(win); check(other)
  elseif scenario == 'scroll' then
    vim.api.nvim_win_set_cursor(win,{4,65})
    vim.fn.winrestview({leftcol=45})
    check(win)
    assert(vim.fn.winsaveview().leftcol==45,'footer reset data viewport')
  else check(win) end
  return true
end
