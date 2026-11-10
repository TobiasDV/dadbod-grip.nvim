-- Two window-local footer rows; grid data keeps its own horizontal viewport.
local M = {}

function M.pack(items, width)
  if width < 1 or #items == 0 then return {} end
  local rows, omitted = { {} }, false
  local function text(row) return #row > 0 and (" " .. table.concat(row, "  ")) or "" end
  for _, item in ipairs(items) do
    local row = rows[#rows]
    local candidate = text(row) .. (#row > 0 and "  " or " ") .. item
    if vim.fn.strdisplaywidth(candidate) <= width then
      row[#row + 1] = item
    elseif #rows < 2 and vim.fn.strdisplaywidth(item) + 1 <= width then
      rows[#rows + 1] = { item }
    else
      omitted = true
    end
  end
  if omitted then
    if #rows < 2 then rows[#rows + 1] = {} end
    local row = rows[#rows]
    -- Discovery and the first core action in each row take precedence over ….
    while #row > 1 and vim.fn.strdisplaywidth(text(row) .. "  …") > width do table.remove(row) end
    local marker = text(row) .. (#row > 0 and "  …" or " …")
    if vim.fn.strdisplaywidth(marker) <= width then row[#row + 1] = "…"
    elseif #row == 0 and vim.fn.strdisplaywidth("…") <= width then row[1] = "…" end
  end
  local result = {}
  for _, row in ipairs(rows) do
    local line = text(row)
    if vim.fn.strdisplaywidth(line) > width then line = "…" end
    if line ~= "" then result[#result + 1] = line end
  end
  return result
end

-- Query time is observed by this client around db.query, not server execution.
-- Keep milliseconds useful for fast queries and share the loading timer's
-- seconds/minutes format for longer ones.
function M.query_time(ms, width)
  local ui = require("dadbod-grip.ui")
  local duration = ms < 1000 and (ms .. "ms") or ui.format_elapsed(ms)
  for _, label in ipairs({ " Query: " .. duration .. " client", " Q: " .. duration .. " client",
      " " .. duration .. " client", " Q:" .. duration, " " .. duration }) do
    if vim.fn.strdisplaywidth(label) <= width then return label end
  end
  return ui.truncate_display(" " .. duration, width)
end

-- DuckDB's whole-query LATENCY, in seconds in its JSON profile. This is
-- distinct from the external client clock and from cumulative operator CPU.
function M.engine_time(info, width, kind)
  local ui = require("dadbod-grip.ui")
  kind = kind or "Engine"
  local label, short
  if info.status == "available" then
    local ms = info.elapsed_ms
    local duration = ms < 1 and string.format("%.3gms", ms)
      or ms < 1000 and (string.format("%.1f", ms):gsub("%.0$", "") .. "ms") or ui.format_elapsed(ms)
    short = kind .. ": " .. duration
    label = short .. " DuckDB profiler latency"
  else
    short = kind .. ": " .. info.status
    label = short .. (info.adapter and (" (" .. info.adapter .. ")") or "")
  end
  for _, text in ipairs({ " " .. label, " " .. short, " " .. kind .. ": n/a" }) do
    if vim.fn.strdisplaywidth(text) <= width then return text end
  end
  return ui.truncate_display(" " .. short, width)
end

-- Essential status never omits a field; narrow windows use additional rows.
function M.status(items, width)
  if width < 1 then return {} end
  local rows, used = {{}}, 0
  local function append(text, hl)
    rows[#rows][#rows[#rows] + 1] = {text, hl}
    used = used + vim.fn.strdisplaywidth(text)
  end
  for _, item in ipairs(items) do
    local text, hl = item[1], item[2] or 'Normal'
    local size = vim.fn.strdisplaywidth(text)
    if used > 0 and used + 3 + size > width then rows[#rows + 1], used = {}, 0 end
    if used > 0 then append(' | ', 'GripReadonly') end
    for i = 0, vim.fn.strchars(text) - 1 do
      local char = vim.fn.strcharpart(text, i, 1)
      local cells = vim.fn.strdisplaywidth(char)
      if used + cells > width then rows[#rows + 1], used = {}, 0 end
      append(char, hl)
    end
  end
  return rows
end

function M.status_width(buf)
  local width = vim.o.columns
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then width = math.min(width, info.width - info.textoff) end
  end
  return math.max(1, width)
end

function M.attach(sessions)
  local ns = vim.api.nvim_create_namespace("grip_result_hints")
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf)
      local render = sessions[buf] and sessions[buf]._render
      if not render then return false end
      local info = vim.fn.getwininfo(win)[1]
      if not info then return false end
      local width = info.width - info.textoff
      if render.status_items then
        local needed = #M.status(render.status_items, M.status_width(buf))
        if needed ~= render.status_rows and not render.status_pending then
          render.status_pending = true
          -- Ephemeral virtual lines are not drawn by supported Neovim versions.
          -- Reserve real footer rows for the narrowest window, then only pack
          -- their overlays per window. Data coordinates remain unchanged.
          vim.schedule(function()
            local session = sessions[buf]
            if session and session._render == render and vim.api.nvim_buf_is_valid(buf) then
              require('dadbod-grip.view').render(buf, session.state)
            end
          end)
        end
        local rows = M.status(render.status_items, width)
        for i = 1, render.status_rows do
          local row, used = rows[i] or {}, 0
          for _, part in ipairs(row) do used = used + vim.fn.strdisplaywidth(part[1]) end
          row[#row + 1] = {string.rep(' ', math.max(0, width - used)), 'Normal'}
          vim.api.nvim_buf_set_extmark(buf, ns, render.status_row + i - 1, 0, {
            virt_text = row, virt_text_win_col = 0, virt_text_pos = 'overlay', ephemeral = true,
          })
        end
      end
      if render.query_time_row then
        local text = require("dadbod-grip.ui").pad_display(M.query_time(render.query_elapsed_ms, width), width, false)
        vim.api.nvim_buf_set_extmark(buf, ns, render.query_time_row, 0, {
          virt_text = { { text, "GripStatusOk" } }, virt_text_win_col = 0,
          virt_text_pos = "overlay", ephemeral = true,
        })
      end
      if render.engine_time_row then
        local text = require("dadbod-grip.ui").pad_display(M.engine_time(render.engine_timing, width), width, false)
        vim.api.nvim_buf_set_extmark(buf, ns, render.engine_time_row, 0, {
          virt_text = { { text, "GripStatusOk" } }, virt_text_win_col = 0,
          virt_text_pos = "overlay", ephemeral = true,
        })
      end
      if render.write_engine_time_row then
        local text = require("dadbod-grip.ui").pad_display(M.engine_time(render.write_engine_timing, width, "Write engine"), width, false)
        vim.api.nvim_buf_set_extmark(buf, ns, render.write_engine_time_row, 0, {
          virt_text = { { text, "GripStatusOk" } }, virt_text_win_col = 0,
          virt_text_pos = "overlay", ephemeral = true,
        })
      end
      if not render.hint_row then return false end
      local key = width .. ":" .. vim.o.ambiwidth
      local lines = render.hint_cache[key]
      if not lines then
        lines = M.pack(render.hint_items, width)
        render.hint_cache[key] = lines
      end
      for i, line in ipairs(lines) do
        vim.api.nvim_buf_set_extmark(buf, ns, render.hint_row + i - 1, 0, {
          virt_text = { { line, "Comment" } }, virt_text_win_col = 0,
          virt_text_pos = "overlay", ephemeral = true,
        })
      end
      return false
    end,
  })
end

return M
