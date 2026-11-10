-- sqlserver_write.lua: verified grid transactions for SQL Server.
-- transaction.compile hands SQL Server plans here; the adapter runs the
-- script and turns its output back into the events transaction.decode reads.
--
-- One batch, one transaction. Every UPDATE and DELETE first locks and counts
-- the row as the grid loaded it, and every operation prints the row before
-- and after as JSON, which is where Undo gets its values and keys from.
-- Pure: no database calls.
local sql = require("dadbod-grip.sql")

local M = {}
local q = sql.quote_column

local EVENT = "__GRIP_EVENT__"
M.COMMIT = "__GRIP_COMMIT__"
M.ROLLBACK = "__GRIP_ROLLBACK__"

-- As in the adapter's PAGE_BATCH: larger binaries reach the grid as
-- "<binary N bytes>".
local MAX_BINARY_BYTES = 8000

-- Shown as text by the grid and by the events (FOR JSON refuses them).
local CLR_TYPES = { geography = true, geometry = true, hierarchyid = true }
-- Types = refuses or cannot take a string for: compared as their text.
local COMPARED_AS_TEXT = {
  text = true, ntext = true, xml = true, sql_variant = true,
  geography = true, geometry = true, hierarchyid = true,
}
local ANSI_TYPES = { char = true, varchar = true }

local function base_type(type_name)
  return ((type_name or ""):match("^[%a_]+") or ""):lower()
end

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function placeholder_bytes(value)
  return type(value) == "string" and value:match("^<binary (%d+) bytes>$") or nil
end

--- { column = type name }: the table's own metadata first, since a grid over
--- a projection only knows the types of the columns it shows.
local function column_types(plan)
  local types = {}
  for col, type_name in pairs(plan.column_types or {}) do types[col] = type_name end
  for _, info in ipairs(plan.schema or {}) do
    if info.data_type and info.data_type ~= "" then types[info.column_name] = info.data_type end
  end
  return types
end
M.column_types = column_types

--- A value as it is written by SET and VALUES.
local function literal(col, value, type_name)
  if is_null(value) then return "NULL" end
  if sql.is_sqlserver_binary(type_name) then
    assert(not placeholder_bytes(value),
      "the binary value of " .. col .. " is over " .. MAX_BINARY_BYTES
      .. " bytes and was never loaded, so it cannot be written back")
  end
  return sql.quote_value(tostring(value), "sqlserver", type_name)
end

--- `col = value` as the column's type needs it. A key keeps a plain varchar
--- literal where it can: N'...' against a varchar key can turn the lookup
--- (and the lock it takes) into a scan.
local function term(col, value, type_name, is_key)
  local name, base = q(col), base_type(type_name)
  if is_null(value) then return name .. " IS NULL" end
  local text = tostring(value)
  if sql.is_sqlserver_binary(type_name) then
    local bytes = placeholder_bytes(text)
    if bytes then return "DATALENGTH(" .. name .. ") = " .. bytes end
    if base == "image" then
      return "CAST(" .. name .. " AS varbinary(max)) = " .. literal(col, text, "varbinary")
    end
    return name .. " = " .. literal(col, text, type_name)
  end
  if COMPARED_AS_TEXT[base] then
    return "CAST(" .. name .. " AS nvarchar(max)) = " .. sql.quote_value(text, "sqlserver")
  end
  if is_key and ANSI_TYPES[base] and not text:find("[\128-\255\r]") then
    return name .. " = '" .. sql.escape_literal(text) .. "'"
  end
  return name .. " = " .. sql.quote_value(text, "sqlserver")
end

--- AND of `col = value` over `values`; `only` limits it to those columns.
local function predicate(values, types, key_set, only)
  local terms = {}
  for col, value in pairs(values) do
    if not only or only[col] then
      terms[#terms + 1] = term(col, value, types[col], key_set[col])
    end
  end
  assert(#terms > 0, "missing predicate")
  table.sort(terms)
  return table.concat(terms, " AND ")
end

local function identity(pks, values)
  assert(#pks > 0, "missing primary key")
  local result = {}
  for _, pk in ipairs(pks) do
    assert(not is_null(values[pk]), "NULL or missing primary key: " .. pk)
    result[pk] = values[pk]
  end
  return result
end

--- A column as the grid shows it. `full` keeps a large binary as hex, for a
--- row that Undo has to put back whole.
local function cell_expr(col, type_name, full)
  local name = q(col)
  if sql.is_sqlserver_binary(type_name) then
    local hex = "CONVERT(varchar(max), CONVERT(varbinary(max), " .. name .. "), 1)"
    if full then return hex end
    return "CASE WHEN DATALENGTH(" .. name .. ") > " .. MAX_BINARY_BYTES
      .. " THEN CONCAT(N'<binary ', DATALENGTH(" .. name .. "), N' bytes>') ELSE " .. hex .. " END"
  end
  if CLR_TYPES[base_type(type_name)] then return "CAST(" .. name .. " AS nvarchar(max))" end
  return name
end

--- The script for `plan`, or an error. See transaction.compile.
function M.compile(plan)
  assert(#(plan.pks or {}) > 0, "missing primary key")
  local types = column_types(plan)
  local target = sql.quote_ident(plan.table_name)
  local key_set, writable = {}, {}
  for _, pk in ipairs(plan.pks) do key_set[pk] = true end
  for _, col in ipairs(plan.writable) do writable[col] = true end

  local parts = {
    "SET XACT_ABORT ON",
    "DECLARE @grip_n int",
    "BEGIN TRY",
    "BEGIN TRANSACTION",
  }
  -- BEGIN TRY takes no terminator; everything else gets one, which THROW
  -- needs from the statement before it.
  local function add(statement) parts[#parts + 1] = statement end

  local function guard(count_sql, message)
    add("SELECT @grip_n = " .. count_sql)
    add("IF @grip_n <> 1 THROW 51000, N'Grip: " .. sql.escape_literal(message) .. "', 1")
  end
  local function wrote_one(what)
    add("IF @@ROWCOUNT <> 1 THROW 51000, N'Grip: " .. what .. " did not change exactly one row', 1")
  end

  -- Positional aliases: a column name with a dot would nest the JSON object.
  local function emit(i, phase, from_where, full)
    local cells = {}
    for ci, col in ipairs(plan.columns) do
      cells[ci] = cell_expr(col, types[col], full) .. " AS [c" .. ci .. "]"
    end
    add("SELECT N'" .. EVENT .. i .. ":" .. phase .. ":' + (SELECT " .. table.concat(cells, ", ")
      .. " FROM " .. from_where .. " FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)")
  end

  local function restored(op)
    return op.required_after and predicate(op.required_after, types, key_set, writable) or nil
  end

  for i, op in ipairs(plan.ops) do
    local label = "row of operation " .. i
    if op.kind == "insert" then
      local keys = "#grip_k" .. i
      local pk_list, inserted, join = {}, {}, {}
      for _, pk in ipairs(plan.pks) do
        pk_list[#pk_list + 1] = q(pk)
        inserted[#inserted + 1] = "inserted." .. q(pk)
        join[#join + 1] = "k." .. q(pk) .. " = t." .. q(pk)
      end
      pk_list = table.concat(pk_list, ", ")
      -- The UNION drops an IDENTITY property the copy would otherwise inherit.
      add("SELECT TOP 0 " .. pk_list .. " INTO " .. keys .. " FROM (SELECT " .. pk_list .. " FROM " .. target
        .. " UNION ALL SELECT " .. pk_list .. " FROM " .. target .. ") AS s")

      local cols, vals = {}, {}
      for _, col in ipairs(plan.writable) do
        if op.values[col] ~= nil then
          cols[#cols + 1] = q(col)
          vals[#vals + 1] = literal(col, op.values[col], types[col])
        end
      end
      local output = " OUTPUT " .. table.concat(inserted, ", ") .. " INTO " .. keys
      local statement = "INSERT INTO " .. target
        .. (#cols > 0 and (" (" .. table.concat(cols, ", ") .. ")" .. output
          .. " VALUES (" .. table.concat(vals, ", ") .. ")") or (output .. " DEFAULT VALUES"))
      -- Putting a deleted row back needs its original IDENTITY value, which
      -- the server refuses unless IDENTITY_INSERT is on, and refuses to turn
      -- on for a table without an IDENTITY column.
      local toggle = op.restore and string.format(
        "IF OBJECTPROPERTY(OBJECT_ID(N'%s'), 'TableHasIdentity') = 1 SET IDENTITY_INSERT %s",
        sql.escape_literal(target), target)
      if toggle then add(toggle .. " ON") end
      add(statement)
      if toggle then add(toggle .. " OFF") end

      guard("COUNT(*) FROM " .. keys, "the insert of operation " .. i .. " did not report exactly one key")
      local found = target .. " AS t WHERE EXISTS (SELECT 1 FROM " .. keys .. " AS k WHERE "
        .. table.concat(join, " AND ") .. ")"
      local check = restored(op)
      if check then
        guard("COUNT(*) FROM " .. found .. " AND " .. check, "the " .. label .. " was not restored as it was")
      end
      emit(i, "after", found)
    else
      identity(plan.pks, op.keys)
      local where = predicate(vim.tbl_extend("force", op.expected or {}, op.keys), types, key_set)
      guard("COUNT(*) FROM " .. target .. " WITH (UPDLOCK, HOLDLOCK) WHERE " .. where,
        "the " .. label .. " changed or no longer exists; refresh and retry")
      -- A deleted row comes back whole, so its event carries every byte.
      emit(i, "before", target .. " WHERE " .. where, op.kind == "delete")
      if op.kind == "delete" then
        add("DELETE FROM " .. target .. " WHERE " .. where)
        wrote_one("the delete of operation " .. i)
      else
        local sets = {}
        for col, value in pairs(op.values) do
          sets[#sets + 1] = q(col) .. " = " .. literal(col, value, types[col])
        end
        assert(#sets > 0, "update without values")
        table.sort(sets)
        add("UPDATE " .. target .. " SET " .. table.concat(sets, ", ") .. " WHERE " .. where)
        wrote_one("the update of operation " .. i)
        local after = predicate(identity(plan.pks, op.post_keys or op.keys), types, key_set)
        local check = restored(op)
        guard("COUNT(*) FROM " .. target .. " WHERE " .. after .. (check and (" AND " .. check) or ""),
          check and ("the " .. label .. " was not restored as it was")
            or ("the " .. label .. " cannot be found by its key after the update"))
        emit(i, "after", target .. " WHERE " .. after)
      end
    end
  end

  add("COMMIT TRANSACTION")
  add("SELECT N'" .. M.COMMIT .. "'")
  local body = table.concat(parts, ";\n", 4) .. ";"
  return table.concat({
    parts[1] .. ";", parts[2] .. ";", parts[3], body,
    "END TRY",
    "BEGIN CATCH",
    "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;",
    "SELECT N'" .. M.ROLLBACK .. "';",
    "THROW;",
    "END CATCH",
  }, "\n")
end

--- The events a script printed, as transaction.decode reads them:
--- { [op] = { before = { values }, after = { values } } }, values in
--- plan.columns order. nil, err when the output does not show a commit.
--- decode_row and format_cell are the adapter's JSON row decoder and cell
--- formatter, so an event reads exactly as a grid page does.
function M.events(plan, stdout, decode_row, format_cell)
  local types = column_types(plan)
  local events, committed = {}, false
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line == M.COMMIT then
      committed = true
    elseif line:sub(1, #EVENT) == EVENT then
      local op, phase, json = line:sub(#EVENT + 1):match("^(%d+):(%a+):(.*)$")
      op = tonumber(op)
      if not op or (phase ~= "before" and phase ~= "after") then return nil, "invalid transaction identity result" end
      local keys, values = decode_row(json)
      if not keys or #keys ~= #plan.columns then return nil, "invalid transaction identity result" end
      for ci, col in ipairs(plan.columns) do
        if keys[ci] ~= "c" .. ci then return nil, "invalid transaction identity result" end
        values[ci] = format_cell(values[ci], types[col] or "")
        if values[ci] == nil then return nil, "invalid transaction identity result" end
      end
      events[op] = events[op] or {}
      if events[op][phase] then return nil, "invalid transaction identity result" end
      events[op][phase] = { values = values }
    end
  end
  if not committed then return nil, "the transaction did not report a commit" end
  -- A delete leaves no row to print; its before event is the receipt.
  for i, op in ipairs(plan.ops) do
    if op.kind == "delete" and events[i] and events[i].before and not events[i].after then
      events[i].after = { values = {} }
    end
  end
  return events
end

return M
