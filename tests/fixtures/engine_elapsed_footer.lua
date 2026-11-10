return function(scenario)
  if scenario == "zen" or scenario == "hidden" then
    require("dadbod-grip").setup({ show_hints = false, show_result_time = scenario ~= "hidden" })
  end
  local view, data = require("dadbod-grip.view"), require("dadbod-grip.data")
  local st = data.new({ columns = { "id", "wide" }, rows = { { "1", string.rep("data ", 25) } },
    primary_keys = { "id" }, table_name = "engine_fixture" })
  local buf = view.open(st, "sqlite:synthetic-only", nil, { elapsed_ms = 44,
    engine_timing = { status = "available", elapsed_ms = 12.345, source = "duckdb_profile" },
    write_engine_timing = { status = "available", elapsed_ms = 8.1, source = "duckdb_profile" },
    reuse_win = vim.api.nvim_get_current_win(), max_col_width = 100 })
  local win = vim.api.nvim_get_current_win()
  local function check(w)
    vim.cmd("redraw")
    local info, text = vim.fn.getwininfo(w)[1], ""
    for row = info.winrow, info.winrow + info.height - 1 do
      for col = info.wincol + info.textoff, info.wincol + info.width - 1 do
        text = text .. vim.fn.screenstring(row, col)
      end
      text = text .. "\n"
    end
    if scenario == "hidden" then
      assert(not text:find("ngine:", 1, true) and not text:find("44ms client", 1, true), text)
      assert(view._sessions[buf]._query_engine_times[st.rows].elapsed_ms == 12.345)
      assert(view._sessions[buf]._write_engine_times[st.rows].elapsed_ms == 8.1)
      return
    end
    assert(text:find("Engine: 12.3ms", 1, true), "engine label missing from visible native footer: " .. text)
    assert(text:find("Write engine: 8.1ms", 1, true), "write engine label missing: " .. text)
    assert(text:find("44ms client", 1, true), "client label lost: " .. text)
    if info.width >= 60 then assert(text:find("DuckDB profiler latency", 1, true), text) end
  end
  if scenario == "shared" then
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(other, 24)
    check(win); check(other)
  elseif scenario == "scroll" then
    vim.api.nvim_win_set_cursor(win, { view._sessions[buf]._render.data_start, 65 })
    vim.fn.winrestview({ leftcol = 45 })
    check(win)
    assert(vim.fn.winsaveview().leftcol == 45, "footer reset data viewport")
  else check(win) end
  return true
end
