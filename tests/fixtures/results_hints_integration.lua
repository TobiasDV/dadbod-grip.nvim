return function(scenario)
  local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
  grip._keymaps = scenario:match("^custom") and {
    help = "<F2>", grid_edit = "界", grid_apply = false, tab_4 = "<F4>", tab_5 = false,
  } or scenario == "disabled-help" and { help = false } or nil
  local state = require("dadbod-grip.data").new({ columns = { "id", "description", "tail" },
    rows = { { "1", string.rep("wide data ", 8), "last cell" }, { "2", "second", "end" } },
    primary_keys = scenario == "readonly" and {} or { "id" }, table_name = "synthetic_hints" })
  local buf = view.open(state, "sqlite:synthetic-only", nil, {
    reuse_win = vim.api.nvim_get_current_win(), max_col_width = 80 })
  local session = view._sessions[buf]
  if scenario:match("^mutation") then session.pending_mutation = { type = "UPDATE" }; view.render(buf, state) end
  if scenario == "metadata" or scenario == "custom-metadata" then session.current_view = "columns"; view.render(buf, state) end
  local win = vim.api.nvim_get_current_win()
  local function footer(w)
    vim.cmd("redraw")
    local result = {}
    vim.api.nvim_win_call(w, function()
      local info = vim.fn.getwininfo(w)[1]
      local last = vim.api.nvim_buf_line_count(buf)
      for line = last - 1, last do
        local pos = vim.fn.screenpos(w, line, 1)
        -- screenpos(column1) is offscreen after a horizontal data scroll.
        local row = pos.row > 0 and pos.row or (info.winrow + line - vim.fn.line("w0")
          + (vim.wo[w].winbar ~= "" and 1 or 0))
        local text = ""
        for col = info.wincol + info.textoff, info.wincol + info.width - 1 do
          text = text .. vim.fn.screenstring(row, col)
        end
        result[#result + 1] = text:gsub("%s+$", "")
      end
    end)
    return table.concat(result, "\n"), result
  end
  local function check(w, wanted)
    local text, lines = footer(w)
    assert(text:find(wanted or "?:help", 1, true), "footer lost help at window width: " .. vim.inspect(lines))
    assert(not vim.wo[w].wrap, "table data was wrapped")
    local render = session._render
    assert(render.data_start + #render.ordered - 1 < vim.api.nvim_buf_line_count(buf) - 2,
      "footer changed the data range")
    return text
  end
  if scenario == "tiny" then
    local text = footer(win)
    assert(text:find("?:help", 1, true), "tiny footer lost help")
  elseif scenario == "custom" or scenario == "custom-metadata" then
    local text = check(win, "<F2>:help")
    if scenario == "custom" then assert(text:find("界:edit", 1, true), "Unicode custom key absent") end
    if scenario == "custom-metadata" then
      assert(text:find("<F4>:ER", 1, true), "remapped view key absent")
      assert(not text:find("4-9:views", 1, true) and not text:find("5:Stat", 1, true), "disabled/default view key advertised")
    end
    assert(not text:find("a:apply", 1, true) and not text:find("?:help", 1, true), "disabled/default key advertised")
  elseif scenario == "disabled-help" then
    local text = check(win, ":help dadbod-grip")
    assert(not text:find("?:help", 1, true), "disabled help key advertised")
  elseif scenario == "scroll" then
    vim.api.nvim_win_set_cursor(win, { 4, 60 })
    vim.fn.winrestview({ leftcol = 35 })
    check(win)
    assert(vim.fn.winsaveview().leftcol == 35, "footer reset horizontal data scroll")
  elseif scenario == "shared" then
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(other, 35)
    vim.wo[other].wrap = false
    vim.api.nvim_win_set_cursor(other, { 4, 60 })
    vim.fn.winrestview({ leftcol = 45 })
    check(win); check(other)
    assert(footer(win) ~= footer(other), "same buffer did not adapt to independent window widths")
  elseif scenario == "gutter" then
    vim.wo.number, vim.wo.signcolumn = true, "yes:2"
    check(win)
  elseif scenario == "resize" then
    local old_tick = vim.api.nvim_buf_get_changedtick(buf)
    _G.results_hints_resize_check = function()
      check(win)
      assert(vim.api.nvim_buf_get_changedtick(buf) == old_tick, "resize rewrote data buffer")
      return true
    end
    check(win)
  elseif scenario == "zoom" then
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.wo[other].wrap = false
    local before = footer(other)
    require("dadbod-grip.zoom").toggle()
    check(other)
    require("dadbod-grip.zoom").toggle()
    assert(footer(other) == before, "zoom restore did not restore footer layout")
  else
    local text = check(win)
    if scenario == "readonly" then assert(not text:find("i:edit", 1, true), "read-only footer advertises edit") end
    if scenario == "mutation" then
      assert(text:find("a:execute UPDATE", 1, true) and text:find("U:cancel", 1, true), "mutation controls absent")
    end
    if scenario == "mutation-narrow" then assert(text:find("U:cancel", 1, true), "narrow mutation lost cancellation") end
    if scenario == "metadata" then assert(text:find("▶6:Col", 1, true), "metadata view marker absent") end
  end
  assert(not session.state.changes or not next(session.state.changes), "footer staged a change")
  return true
end
