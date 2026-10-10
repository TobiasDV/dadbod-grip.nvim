-- sql.lua: pure SQL generation.
-- No DB calls. No state. Pure string builders.

local M = {}

-- Quote a value for use in SQL.
-- nil    → NULL
-- string → 'value' with single-quote escaping (N'value' on sqlserver)
-- number → n
-- bool   → TRUE / FALSE (1 / 0 on sqlserver)
-- On SQL Server a plain '...' literal is varchar in the database code page,
-- so characters outside it are stored as '?'; N'...' keeps them.
-- Escape a value for embedding in a single-quoted SQL string literal.
-- Only the quote doubling: callers add the surrounding quotes themselves,
-- which is what every catalog query in the adapters needs.
-- Returns exactly one value, so it is safe as the last argument to
-- string.format (a bare :gsub() there leaks its match count as an extra arg).
function M.escape_literal(v)
  return (tostring(v):gsub("'", "''"))
end
local escape_literal = M.escape_literal

function M.quote_value(v, adapter_kind)
  if v == nil then
    return "NULL"
  elseif type(v) == "boolean" then
    if adapter_kind == "sqlserver" then return v and "1" or "0" end
    return v and "TRUE" or "FALSE"
  elseif type(v) == "number" then
    return tostring(v)
  elseif adapter_kind == "sqlserver" then
    -- sqlcmd drops the CR of every CRLF it reads from stdin, so CRs are
    -- spliced in as NCHAR(13). The nvarchar(max) cast stops the concatenation
    -- from cutting a long value to 4000 characters.
    local parts = vim.split(tostring(v), "\r", { plain = true })
    for i, part in ipairs(parts) do parts[i] = "N'" .. escape_literal(part) .. "'" end
    if #parts == 1 then return parts[1] end
    parts[1] = "CAST(" .. parts[1] .. " AS nvarchar(max))"
    return table.concat(parts, " + NCHAR(13) + ")
  else
    return "'" .. escape_literal(v) .. "'"
  end
end

--- Wrap statements in the transaction syntax accepted by the target adapter.
--- Binary column types, whose values the grid shows as 0x hex.
local BINARY_TYPES = { binary = true, varbinary = true, image = true, timestamp = true, rowversion = true }

--- One value as SQL for a column of type `type_name` (nil when unknown):
--- data.NULL_SENTINEL is NULL, data.EMPTY is '', and on SQL Server a 0x hex
--- value for a binary column is written as a binary literal, since the
--- server will not turn N'0x..' into bytes.
function M.value_sql(v, adapter_kind, type_name)
  local data = require("dadbod-grip.data")
  if v == data.NULL_SENTINEL then return "NULL" end
  if v == data.EMPTY then return M.quote_value("", adapter_kind) end
  if adapter_kind == "sqlserver" and type(v) == "string" and type_name
      and BINARY_TYPES[(type_name:match("^%a+") or ""):lower()] and v:match("^0[xX]%x*$") then
    return v
  end
  return M.quote_value(v, adapter_kind)
end

--- `col = value`, or `col IS NULL` for a NULL key.
local function key_sql(col, val, adapter_kind, types)
  local data = require("dadbod-grip.data")
  if val == nil or val == "" or val == data.NULL_SENTINEL then
    return M.quote_ident(col) .. " IS NULL"
  end
  return M.quote_ident(col) .. " = " .. M.value_sql(val, adapter_kind, types and types[col])
end

function M.wrap_transaction(statements, adapter_kind)
  local begin_stmt = adapter_kind == "sqlserver"
      and "SET XACT_ABORT ON;\nBEGIN TRANSACTION;" or "BEGIN;"
  local commit_stmt = adapter_kind == "sqlserver" and "COMMIT TRANSACTION;" or "COMMIT;"
  return begin_stmt .. "\n" .. table.concat(statements, ";\n") .. ";\n" .. commit_stmt
end

-- Quote a column or table identifier with double-quotes.
function M.quote_ident(name)
  -- Split on . and quote each part: schema.table → "schema"."table"
  local parts = {}
  for part in tostring(name):gmatch("[^.]+") do
    table.insert(parts, '"' .. part:gsub('"', '""') .. '"')
  end
  return table.concat(parts, ".")
end
local quote_ident = M.quote_ident

-- Strip outer quotes from each part of a possibly schema-qualified identifier.
-- Inverse of quote_ident: "public"."Participant" → public.Participant
-- Handles double-quotes, backticks, and escaped internal quotes.
-- Bare identifiers pass through unchanged.
function M.unquote_ident(name)
  local parts = {}
  for part in tostring(name):gmatch("[^.]+") do
    if part:match('^"') and part:match('"$') then
      part = part:sub(2, -2):gsub('""', '"')
    elseif part:match("^`") and part:match("`$") then
      part = part:sub(2, -2):gsub("``", "`")
    end
    table.insert(parts, part)
  end
  return table.concat(parts, ".")
end

-- Split a possibly schema-qualified table name and unquote both parts.
-- Catalog tables (information_schema, pg_catalog, …) store bare names, so
-- quoted identifiers must be stripped before they can be compared.
-- default_schema is used when the name carries no qualifier; adapters pass
-- their own ("public", "dbo", the connected database, …).
function M.split_table_name(table_name, default_schema)
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = default_schema
    tbl = table_name
  end
  return M.unquote_ident(schema), M.unquote_ident(tbl)
end

--- Split a URL authority ("user:password@host:port") into its three parts.
--- `user` is nil when there is no "@" at all; `password` is nil when the
--- userinfo carries no ":". `host` is always the remainder.
---
--- The split is on the LAST "@", mirroring parse_dadbod_url's own rule below:
--- a password may itself contain "@", and splitting on the first one would
--- leave the rest of the password — everything between that first "@" and the
--- real one before the host — outside whatever the caller does with it. That
--- is not academic: adapters/duckdb.lua's url_to_dsn used to split on the
--- first "@" and put the tail of the password into host=, which then defeated
--- the ATTACH-error mask downstream.
---
--- The single copy of that rule: redact_url, url_password and url_to_dsn all
--- go through here.
--- @param authority string
--- @return string|nil user
--- @return string|nil password
--- @return string host
local function split_authority(authority)
  local at = nil
  for i = #authority, 1, -1 do
    if authority:sub(i, i) == "@" then at = i; break end
  end
  if not at then return nil, nil, authority end
  local userinfo, host = authority:sub(1, at - 1), authority:sub(at + 1)
  local colon = userinfo:find(":", 1, true)
  if not colon then return userinfo, nil, host end
  return userinfo:sub(1, colon - 1), userinfo:sub(colon + 1), host
end
M.split_authority = split_authority

--- The password out of a URL's authority, or nil when there is none.
---
--- For callers that must scrub a password out of text they did not build —
--- a CLI's own stderr, say, which may have rewritten the URL past
--- recognition. redact_url() is the wrong tool there: it rewrites a URL it
--- can still see, whereas masking the *value* survives re-quoting,
--- truncation, percent-decoding and path-prefixing. See
--- adapters/duckdb.lua's redact_attach_error for the case that forced it.
--- @param url string|nil
--- @return string|nil password
function M.url_password(url)
  if type(url) ~= "string" then return nil end
  local authority = url:match("://([^/]*)")
  if not authority then return nil end
  local _, password = split_authority(authority)
  if password == nil or password == "" then return nil end
  return password
end

--- Mask the password in a connection URL for display in logs, errors, notifications.
--- The authority component is captured up to the next "/" (so this never
--- reaches into the path or query — a "/" always ends the search). Inside
--- that component, the split is on the LAST "@", mirroring
--- parse_dadbod_url's own rule below: a password may itself contain "@",
--- and splitting on the first one would leave the rest of the password —
--- everything between that first "@" and the real one before the host — in
--- cleartext right next to the mask. See redact_spec.lua for both cases.
---
--- Callers also feed this whatever the user typed as a URL even after it has
--- failed to parse (e.g. "Invalid MySQL URL: " .. redact_url(url)), so a
--- string with no "://" at all still needs a pass: fall back to masking any
--- "ident:secret@" run found anywhere in it, as long as neither side contains
--- whitespace. A real URL never has unescaped whitespace, so that costs
--- nothing on the input this fallback is actually for; it exists to keep the
--- fallback from treating an entire free-form sentence as one giant
--- credential (see redact_spec.lua). It is still just a heuristic scan, not
--- authority-aware like the "://" branch above: an incidental
--- whitespace-free "word:word@word" inside non-URL text can still get
--- masked. Callers should feed it a URL argument, not a full error message
--- built from other text.
--- @param url string|nil
--- @return string
function M.redact_url(url)
  if not url then return "" end
  if url:find("://", 1, true) then
    return (url:gsub("://([^/]*)", function(authority)
      local user, password, host = split_authority(authority)
      -- No "@", or no ":" in the userinfo: nothing that is a password.
      if not user or not password then return "://" .. authority end
      return "://" .. user .. ":***@" .. host
    end))
  end
  return (url:gsub("([^:/@%s]+):([^@%s]*)@", "%1:***@"))
end

-- Parse a dadbod-style connection URL into its components.
-- "scheme://user:pass@host:port/dbname" → {user, pass, host, port, dbname}
-- The auth part is matched greedily up to the last @ so passwords may contain @.
-- Missing pieces stay nil except host and port, which fall back to 127.0.0.1
-- and default_port (each adapter passes its own). Returns nil if there is no
-- "scheme://" prefix at all. No percent-decoding: values are passed to the
-- client CLIs verbatim, exactly as dadbod hands them over.
function M.parse_dadbod_url(url, default_port)
  local rest = url:match("^%w+://(.+)$")
  if not rest then return nil end

  local user, pass, host, port, dbname

  -- Split auth@hostpath (match last @ to support passwords containing @)
  local auth, hostpath = rest:match("^(.+)@([^@]+)$")
  if not auth then
    hostpath = rest
  else
    user, pass = auth:match("^([^:]*):(.*)$")
    if not user then user = auth end
  end

  -- Split hostpath into host:port/dbname
  local hp, db = hostpath:match("^([^/]+)/(.+)$")
  if not hp then hp = hostpath end
  dbname = db

  host, port = hp:match("^([^:]+):(%d+)$")
  if not host then host = hp end

  return {
    user   = user,
    pass   = pass,
    host   = host or "127.0.0.1",
    port   = port or default_port,
    dbname = dbname,
  }
end

-- M.build_update(table_name, pk_values, changes, adapter_kind) → string
-- pk_values: { col = "val", ... }
-- changes:   { col = new_val, ... }  (data.NULL_SENTINEL means SQL NULL)
-- opts.types:  { col = type name }, for values that need their type (binaries)
function M.build_update(table_name, pk_values, changes, adapter_kind, opts)
  local types = opts and opts.types
  local set_parts = {}
  for col, val in pairs(changes) do
    table.insert(set_parts, quote_ident(col) .. " = " .. M.value_sql(val, adapter_kind, types and types[col]))
  end
  -- Sort for deterministic output
  table.sort(set_parts)

  local where_parts = {}
  for col, val in pairs(pk_values) do
    table.insert(where_parts, key_sql(col, val, adapter_kind, types))
  end
  table.sort(where_parts)

  return string.format(
    "UPDATE %s SET %s WHERE %s",
    quote_ident(table_name),
    table.concat(set_parts, ", "),
    table.concat(where_parts, " AND ")
  )
end

-- M.build_insert(table_name, values, columns, adapter_kind) → string
-- values:  { col = val, ... }  (data.NULL_SENTINEL means SQL NULL)
-- columns: ordered list of column names (defines INSERT column order)
-- opts.types:  { col = type name };  opts.skip: { col = true } never written
function M.build_insert(table_name, values, columns, adapter_kind, opts)
  local types = opts and opts.types
  local skip = opts and opts.skip
  local col_parts = {}
  local val_parts = {}

  for _, col in ipairs(columns) do
    local val = values[col]
    -- Skip columns with nil that aren't explicitly set (let DB use DEFAULT)
    -- NULL_SENTINEL is non-nil and emits SQL NULL explicitly
    if val ~= nil and not (skip and skip[col]) then
      table.insert(col_parts, quote_ident(col))
      table.insert(val_parts, M.value_sql(val, adapter_kind, types and types[col]))
    end
  end

  if #col_parts == 0 then
    -- All defaults: INSERT with no columns
    return string.format("INSERT INTO %s DEFAULT VALUES", quote_ident(table_name))
  end

  return string.format(
    "INSERT INTO %s (%s) VALUES (%s)",
    quote_ident(table_name),
    table.concat(col_parts, ", "),
    table.concat(val_parts, ", ")
  )
end

-- M.build_reinsert(table_name, values, columns, adapter_kind) → string
-- The INSERT that undoes a DELETE, original key included. SQL Server refuses
-- an explicit IDENTITY value unless IDENTITY_INSERT is on, and refuses to turn
-- that on for a table without an IDENTITY column, hence the OBJECTPROPERTY test.
function M.build_reinsert(table_name, values, columns, adapter_kind, opts)
  local insert = M.build_insert(table_name, values, columns, adapter_kind, opts)
  if adapter_kind ~= "sqlserver" then return insert end
  local ident = quote_ident(table_name)
  local toggle = string.format(
    "IF OBJECTPROPERTY(OBJECT_ID(N'%s'), 'TableHasIdentity') = 1 SET IDENTITY_INSERT %s",
    escape_literal(ident), ident)
  return toggle .. " ON;\n" .. insert .. ";\n" .. toggle .. " OFF"
end

--- SELECT that finds the row an INSERT just created when the database
--- generated its key: match every non-key value the INSERT was given, newest
--- key first. Columns in `skip` (types the database cannot compare with =,
--- such as SQL Server text and ntext) are left out. Returns nil when no column
--- is left to match on.
function M.build_insert_lookup(table_name, pks, values, skip, adapter_kind, opts)
  local NULL_SENTINEL = require("dadbod-grip.data").NULL_SENTINEL
  local types = opts and opts.types
  local pk_set = {}
  for _, pk in ipairs(pks) do pk_set[pk] = true end
  local where_parts = {}
  for col, val in pairs(values) do
    if not pk_set[col] and not (skip and skip[col])
      and val and val ~= "" and val ~= NULL_SENTINEL then
      table.insert(where_parts, quote_ident(col) .. " = " .. M.value_sql(tostring(val), adapter_kind, types and types[col]))
    end
  end
  if #where_parts == 0 then return nil end
  table.sort(where_parts)
  local pk_cols = table.concat(vim.tbl_map(quote_ident, pks), ", ")
  return "SELECT " .. pk_cols .. " FROM " .. quote_ident(table_name)
    .. " WHERE " .. table.concat(where_parts, " AND ")
    .. " ORDER BY " .. quote_ident(pks[1]) .. " DESC LIMIT 1"
end

-- M.build_delete(table_name, pk_values, adapter_kind) → string
-- pk_values: { col = "val", ... }
function M.build_delete(table_name, pk_values, adapter_kind, opts)
  local types = opts and opts.types
  local where_parts = {}
  for col, val in pairs(pk_values) do
    table.insert(where_parts, key_sql(col, val, adapter_kind, types))
  end
  table.sort(where_parts)

  return string.format(
    "DELETE FROM %s WHERE %s",
    quote_ident(table_name),
    table.concat(where_parts, " AND ")
  )
end

-- M.preview_staged(table_name, updates, deletes, inserts, adapter_kind) → string
-- Generates a multi-line SQL preview of all staged changes.
-- updates: from data.get_updates(), deletes: from data.get_deletes(), inserts: from data.get_inserts()
function M.preview_staged(table_name, updates, deletes, inserts, adapter_kind, opts)
  local stmts = {}
  for _, del in ipairs(deletes) do
    table.insert(stmts, M.build_delete(table_name, del.pk_values, adapter_kind, opts) .. ";")
  end
  for _, upd in ipairs(updates) do
    table.insert(stmts, M.build_update(table_name, upd.pk_values, upd.changes, adapter_kind, opts) .. ";")
  end
  for _, ins in ipairs(inserts) do
    table.insert(stmts, M.build_insert(table_name, ins.values, ins.columns, adapter_kind, opts) .. ";")
  end
  if #stmts == 0 then return "-- no staged changes" end
  return table.concat(stmts, "\n")
end

-- ── staged changes of a grid state ─────────────────────────────────────────

--- The types and never-written columns of a grid state, as builder opts.
function M.state_opts(state)
  return { types = state.column_types, skip = state.generated_columns }
end

--- The statements that apply a grid state's staged changes: deletes first
--- (avoids FK conflicts with inserts), then updates, then inserts.
function M.build_apply(state, adapter_kind)
  local data = require("dadbod-grip.data")
  local opts = M.state_opts(state)
  local stmts = {}
  for _, del in ipairs(data.get_deletes(state)) do
    table.insert(stmts, M.build_delete(state.table_name, del.pk_values, adapter_kind, opts))
  end
  for _, upd in ipairs(data.get_updates(state)) do
    table.insert(stmts, M.build_update(state.table_name, upd.pk_values, upd.changes, adapter_kind, opts))
  end
  for _, ins in ipairs(data.get_inserts(state)) do
    table.insert(stmts, M.build_insert(state.table_name, ins.values, ins.columns, adapter_kind, opts))
  end
  return stmts
end

--- The statements that undo a grid state's staged deletes and updates once
--- applied: a deleted row goes back in whole, an update gets its old values.
--- Returns reverse, irreversible: the row indexes of deleted rows that cannot
--- be put back because a binary in them only reached the grid as a
--- "<binary N bytes>" placeholder.
function M.build_undo(state, adapter_kind)
  local data = require("dadbod-grip.data")
  local opts = M.state_opts(state)
  local reverse, irreversible = {}, {}
  local deletes = data.get_deletes(state)
  table.sort(deletes, function(a, b) return a.row_idx < b.row_idx end)
  for _, del in ipairs(deletes) do
    local values, placeholder = {}, false
    for _, col in ipairs(state.columns) do
      local v = data.original_value(state, del.row_idx, col)
      if type(v) == "string" and v:sub(1, #"<binary ") == "<binary " then placeholder = true end
      values[col] = v
    end
    if placeholder then
      table.insert(irreversible, del.row_idx)
    else
      table.insert(reverse, M.build_reinsert(state.table_name, values, state.columns, adapter_kind, opts))
    end
  end
  for _, upd in ipairs(data.get_updates(state)) do
    local old = {}
    for col in pairs(upd.changes) do old[col] = data.original_value(state, upd.row_idx, col) end
    table.insert(reverse, M.build_update(state.table_name, upd.pk_values, old, adapter_kind, opts))
  end
  return reverse, irreversible
end

return M
