-- Resize existing split windows: closing them would wipe Grip result buffers.
local M = {}
local saved = {}

local function restore_options(state)
  for win, item in pairs(state.windows) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winfixwidth = item.fixwidth
      vim.wo[win].winfixheight = item.fixheight
    end
  end
end

local function restore(tab, state)
  saved[tab] = nil
  if not vim.api.nvim_tabpage_is_valid(tab) then restore_options(state); return end
  local anchor = vim.api.nvim_win_is_valid(state.win) and state.win or nil
  if not anchor then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_config(win).relative == "" then anchor = win; break end
    end
  end
  if not anchor then restore_options(state); return end
  vim.api.nvim_win_call(anchor, function()
    local views = {}
    for win, item in pairs(state.windows) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == item.buf then
        local current = vim.api.nvim_win_call(win, vim.fn.winsaveview)
        -- Keep navigation made while zoomed; undo only resize-induced scrolling.
        local zoomed = item.zoom_view or item.view
        local moved = current.lnum ~= zoomed.lnum or current.col ~= zoomed.col
          or current.coladd ~= zoomed.coladd
        local scrolled = state.visited[win] and not vim.deep_equal(current, zoomed)
        views[win] = (moved or scrolled) and current or item.view
      end
    end
    local exact = vim.deep_equal(vim.fn.winlayout(), state.layout)
      and vim.o.columns == state.columns and vim.o.lines == state.lines
    local ok, err = pcall(function()
      if exact then
        vim.cmd(state.sizes)
      else
        for win, item in pairs(state.windows) do
          if vim.api.nvim_win_is_valid(win) then
            if item.fixwidth then vim.api.nvim_win_set_width(win, item.width) end
            if item.fixheight then vim.api.nvim_win_set_height(win, item.height) end
          end
        end
        restore_options(state)
        vim.cmd("wincmd =")
      end
    end)
    restore_options(state)
    for win, view in pairs(views) do
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
    end
    if not ok then vim.notify("Could not restore window sizes: " .. tostring(err), vim.log.levels.WARN) end
  end)
end

-- Reveal an explicitly opened pane without ending zoom on its existing owner.
function M.restore_for(win)
  local tab = vim.api.nvim_get_current_tabpage()
  local state = saved[tab]
  if state and state.win ~= win then restore(tab, state) end
end

function M.toggle()
  local tab, win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  if saved[tab] then return restore(tab, saved[tab]) end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    vim.notify("Zoom applies to split windows; close the floating pane first.", vim.log.levels.INFO)
    return
  end
  local state = { win = win, layout = vim.fn.winlayout(), sizes = vim.fn.winrestcmd(), windows = {},
    visited = { [win] = true },
    columns = vim.o.columns, lines = vim.o.lines }
  local count = 0
  for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(wid).relative == "" then
      count = count + 1
      state.windows[wid] = { buf = vim.api.nvim_win_get_buf(wid),
        fixwidth = vim.wo[wid].winfixwidth, fixheight = vim.wo[wid].winfixheight,
        width = vim.api.nvim_win_get_width(wid), height = vim.api.nvim_win_get_height(wid),
        view = vim.api.nvim_win_call(wid, vim.fn.winsaveview) }
    end
  end
  if count < 2 then return end
  saved[tab] = state
  for wid in pairs(state.windows) do
    vim.wo[wid].winfixwidth, vim.wo[wid].winfixheight = false, false
  end
  local ok, err = pcall(function()
    vim.cmd("wincmd _")
    vim.cmd("wincmd |")
  end)
  if not ok then
    restore(tab, state)
    vim.notify("Could not zoom window: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  for wid, item in pairs(state.windows) do
    item.zoom_view = vim.api.nvim_win_call(wid, vim.fn.winsaveview)
  end
end

vim.api.nvim_create_autocmd({ "WinEnter", "WinClosed", "TabClosed" }, {
  group = vim.api.nvim_create_augroup("DadbodGripZoom", { clear = true }),
  callback = function(event)
    if event.event == "WinEnter" then
      local state = saved[vim.api.nvim_get_current_tabpage()]
      if state then state.visited[vim.api.nvim_get_current_win()] = true end
      return
    end
    vim.schedule(function()
      for tab, state in pairs(saved) do
        if not vim.api.nvim_tabpage_is_valid(tab) or not vim.api.nvim_win_is_valid(state.win) then
          restore(tab, state)
        end
      end
    end)
  end,
})

return M
