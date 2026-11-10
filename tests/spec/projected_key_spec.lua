-- Projected query editing through the real SQLite adapter, reload callbacks,
-- and grid controls. All database/storage paths belong to this disposable fixture.
local grip = require("dadbod-grip")
local db = require("dadbod-grip.db")
local data = require("dadbod-grip.data")
local view = require("dadbod-grip.view")
local qmod = require("dadbod-grip.query")
local paths = require("dadbod-grip.paths")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local fixture = vim.fn.tempname() .. "_projected_key"
vim.fn.mkdir(fixture, "p")
local url = "sqlite:" .. fixture .. "/test.db"
local real_root, real_expand, real_notify = paths.project_root, vim.fn.expand, vim.notify
local old_opts = grip.get_opts()
paths.project_root = function() return fixture end
vim.fn.expand = function(arg, ...)
  if arg == "~" then return fixture end
  return real_expand(arg, ...)
end
vim.notify = function() end
grip.setup({})

local _, seed_err = db.query([[
  CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);
  INSERT INTO people VALUES (1, 'alice'), (2, 'bob');
  CREATE TABLE empty_people (id INTEGER PRIMARY KEY, name TEXT);
  CREATE TABLE items (order_id INTEGER, product_id INTEGER, name TEXT,
    PRIMARY KEY (order_id, product_id));
  INSERT INTO items VALUES (10, 5, 'first'), (10, 6, 'sibling'), (11, 5, 'other');
]], url)
assert(not seed_err, seed_err)

local function cleanup()
  for bufnr in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

local function open(statement)
  cleanup()
  grip.open(statement, url, { from_pad = true })
  local bufnr, session = next(view._sessions)
  assert(session, "no grid opened for " .. statement)
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local render = session._render
  local name = render.byte_positions[1] and render.byte_positions[1].name
  if name then vim.api.nvim_win_set_cursor(win, { render.data_start, name.start }) end
  return bufnr, session
end

local function press(bufnr, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if map.lhs == lhs then
      assert(type(map.callback) == "function", "expected Lua callback for " .. lhs)
      map.callback()
      return
    end
  end
  error("missing grid mapping " .. lhs)
end

for _, case in ipairs({
  { "single PK omitted", "SELECT name FROM people" },
  { "first composite PK omitted", "SELECT product_id, name FROM items" },
  { "last composite PK omitted", "SELECT order_id, name FROM items" },
}) do
  test(case[1] .. ": read-only after open, refresh and requery", function()
    local bufnr, session = open(case[2])
    eq(session.state.readonly, true, "opening query")
    session.on_refresh(bufnr)
    eq(view._sessions[bufnr].state.readonly, true, "manual refresh")
    session.on_requery(bufnr, qmod.toggle_sort(session.query_spec, "name"))
    eq(view._sessions[bufnr].state.readonly, true, "sort requery")
  end)

  test(case[1] .. ": grid controls cannot stage edits or deletes", function()
    local bufnr, session = open(case[2])
    local edits, deletes = 0, 0
    session.on_edit = function() edits = edits + 1 end
    session.on_delete = function() deletes = deletes + 1 end
    press(bufnr, "i")
    press(bufnr, "d")
    press(bufnr, "x")
    eq(edits, 0, "edit callback")
    eq(deletes, 0, "delete callback")
    eq(data.has_changes(session.state), false, "no staged changes")
    eq(view._is_editable(session), false, "full-buffer editor guard")
  end)
end

test("empty raw projection cannot use schema fallback as proof of selected keys", function()
  for _, statement in ipairs({
    "SELECT name FROM people WHERE 0",
    "SELECT id, name FROM people WHERE 0",
    "SELECT order_id, name FROM items WHERE 0",
    "SELECT product_id, name FROM items WHERE 0",
  }) do
    local bufnr, session = open(statement)
    eq(#session.state.rows, 0)
    eq(session.state.readonly, true, statement)
    session.on_refresh(bufnr)
    eq(session.state.readonly, true, "refresh: " .. statement)
    session.on_requery(bufnr, qmod.toggle_sort(session.query_spec, "name"))
    eq(session.state.readonly, true, "requery: " .. statement)
  end
end)

test("empty full-table view retains schema columns and insertion", function()
  local bufnr, session = open("empty_people")
  eq(session.state.readonly, false)
  eq(table.concat(session.state.columns, ","), "id,name")
  session.on_refresh(bufnr)
  eq(session.state.readonly, false, "empty full-table refresh")
  session.on_requery(bufnr, qmod.toggle_sort(session.query_spec, "name"))
  eq(session.state.readonly, false, "empty full-table requery")
  press(bufnr, "o")
  local row_idx = next(session.state.inserted)
  assert(row_idx, "insert key stages a new row")
  view.apply_edit(bufnr, data.add_change(session.state, row_idx, "name", "first"))
  session.on_apply(bufnr)
  eq(session.state.rows[1][2], "first", "insert reaches the isolated database")
end)

test("complete composite key remains editable after refresh and requery", function()
  local bufnr, session = open("SELECT name, product_id, order_id FROM items")
  eq(session.state.readonly, false)
  session.on_refresh(bufnr)
  eq(session.state.readonly, false, "manual refresh")
  session.on_requery(bufnr, qmod.toggle_sort(session.query_spec, "name"))
  eq(session.state.readonly, false, "sort requery")
  local edits, deletes = 0, 0
  session.on_edit = function() edits = edits + 1 end
  session.on_delete = function() deletes = deletes + 1 end
  press(bufnr, "i")
  press(bufnr, "d")
  eq(edits, 1, "edit callback remains reachable")
  eq(deletes, 1, "delete callback remains reachable")
end)

test("aliases, computed keys and duplicate aliased labels retain projection protections", function()
  for _, statement in ipairs({
    "SELECT id AS id, name FROM people",
    "SELECT id + 1 AS id, name FROM people",
    "SELECT id, id AS id, name FROM people",
  }) do
    local bufnr, session = open(statement)
    eq(session.state.readonly, true, statement)
    session.on_refresh(bufnr)
    eq(session.state.readonly, true, "refresh: " .. statement)
  end
end)

test("applying a complete projected key changes and deletes only its matching row", function()
  local bufnr, session = open("SELECT name, product_id, order_id FROM items ORDER BY order_id, product_id")
  view.apply_edit(bufnr, data.add_change(session.state, 1, "name", "edited"))
  session.on_apply(bufnr)
  local result, err = db.query("SELECT name FROM items ORDER BY order_id, product_id", url)
  assert(result, err)
  eq(table.concat(vim.tbl_map(function(row) return row[1] end, result.rows), ","),
    "edited,sibling,other", "UPDATE changes only the complete-key match")

  view.apply_edit(bufnr, data.toggle_delete(session.state, 1))
  session.on_apply(bufnr)
  result, err = db.query("SELECT name FROM items ORDER BY order_id, product_id", url)
  assert(result, err)
  eq(table.concat(vim.tbl_map(function(row) return row[1] end, result.rows), ","),
    "sibling,other", "DELETE preserves rows sharing either key component")
end)

cleanup()
paths.project_root, vim.fn.expand, vim.notify = real_root, real_expand, real_notify
grip.setup(old_opts)
vim.fn.delete(fixture, "rf")

print(string.format("projected_key_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
