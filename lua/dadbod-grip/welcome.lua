-- Compact, actionable welcome content. The caller owns navigation and commands.
local M = {}

function M.render(buf)
  local show_hints = require("dadbod-grip").get_opts().show_hints
  local km = require("dadbod-grip.keymaps")
  local function key(action, fallback) return km.get(action) or fallback end
  local lines, marks, rows = {}, {}, {}
  local function add(text, hl, col, end_col)
    lines[#lines + 1] = text
    if hl then marks[#marks + 1] = { #lines - 1, hl, col or 0, end_col or #text } end
  end
  add("  ╔═╦═╦═╗", "Special")
  local brand = "  ║d║b║g║  dadbod-grip v" .. require("dadbod-grip.version")
  add(brand, "Special")
  marks[#marks + 1] = { #lines - 1, "Title", brand:find("dadbod-grip", 1, true) - 1, #brand }
  add("  ╚═╩═╩═╝", "Special")
  local activate = km.get("welcome_activate")
  local move, previous = km.get("welcome_next"), km.get("welcome_prev")
  local controls = activate and activate .. " choose" or "Type a command"
  if move and previous then controls = controls .. " | " .. move .. "/" .. previous .. " move"
  elseif move then controls = controls .. " | " .. move .. " next"
  elseif previous then controls = controls .. " | " .. previous .. " previous" end
  add(show_hints and ("  START  " .. controls) or "  START", "Title")
  for _, action in ipairs({
    { "demo", "Open demo", ":GripStart" },
    { "connect", "Connect a database", ":GripConnect" },
    { "tables", "Browse tables", km.get("tab_3") or key("table_picker_go", ":GripTables") },
    { "query", "Open SQL pad", key("tab_2", ":GripQuery") },
  }) do
    local prefix = string.format("  %-21s ", action[2])
    add(prefix .. (show_hints and action[3] or ""), action[3]:sub(1, 1) == ":" and "Statement" or "Identifier", #prefix)
    rows[#lines] = action[1]
  end
  if show_hints then
    -- Stable row identities keep selections intact when this buffer is shared by
    -- differently sized windows or tabs. The workspace also fits a short split.
    local function label(binding, name) return binding and (binding .. " " .. name) or name end
    local schema = label(km.get("tab_1") or km.get("schema_browser"), "Schema")
    local query = label(km.get("tab_2"), "SQL")
    local results = label(km.get("tab_3") or km.get("table_picker_go"), "Table/results")
    local left = math.max(10, vim.fn.strdisplaywidth(schema))
    local right = math.max(vim.fn.strdisplaywidth(query), vim.fn.strdisplaywidth(results))
    local function cell(text, width) return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text)) end
    local border = "  +" .. string.rep("-", left) .. "+" .. string.rep("-", right) .. "+"
    add("  Welcome keys", "Title")
    local hints = {
      km.get("qpad_execute") and ("SQL: " .. km.get("qpad_execute") .. " run") or "",
      km.get("zoom") and (km.get("zoom") .. " Zoom/restore") or "",
      km.get("help") and (km.get("help") .. " Help") or "",
      km.get("welcome_close") and (km.get("welcome_close") .. " Close") or "",
      "",
    }
    for i, line in ipairs({ border,
      "  |" .. cell(schema, left) .. "|" .. cell(query, right) .. "|",
      "  |" .. string.rep(" ", left) .. "+" .. string.rep("-", right) .. "+",
      "  |" .. string.rep(" ", left) .. "|" .. cell(results, right) .. "|", border,
    }) do
      if hints[i] ~= "" then line = line .. "  " .. hints[i] end
      add(line, "Comment")
    end
    if km.get("qpad_execute") then
      add(km.get("help") and ("  Other panes: " .. km.get("help") .. " shows their local keys.")
        or "  Full manual: :help dadbod-grip", "Comment")
    else
      add("  Demo: :Grip SELECT sku FROM rolls LIMIT 20", "Comment")
    end
  end
  -- Reopening in another tab must not rewrite an already visible buffer.
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  local ns = vim.api.nvim_create_namespace("grip_welcome")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[3], { end_col = mark[4], hl_group = mark[2] })
  end
  return rows
end

return M
