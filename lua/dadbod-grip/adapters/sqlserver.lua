-- adapters/sqlserver.lua: SQL Server adapter (sqlcmd CLI).
-- All functions return (result, err).

local adapters = require("dadbod-grip.adapters")
local db_util  = require("dadbod-grip.db")
local sql_util = require("dadbod-grip.sql")
local esc = sql_util.escape_literal

local M = {}

local DEFAULT_TIMEOUT = 30000
local MAX_VALUE_WIDTH = 8000

local function decode_query_value(value)
  return (value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Parse a dadbod-style SQL Server URL and its TLS query options.
--- Both sqlserver:// and mssql:// are accepted by the shared URL parser.
--- @return table|nil parsed
--- @return string|nil err
local function parse_url(url)
  local base, query = url:match("^(.-)%?(.*)$")
  local parsed = sql_util.parse_dadbod_url(base or url, "1433")
  if not parsed then return nil, "Invalid SQL Server URL: " .. sql_util.redact_url(url) end

  local params = {}
  for part in (query or ""):gmatch("[^&]+") do
    local key, value = part:match("^([^=]+)=?(.*)$")
    if key then params[decode_query_value(key):lower()] = decode_query_value(value) end
  end

  local encrypt = (params.encrypt or "mandatory"):lower()
  local encrypt_aliases = {
    optional = "optional", o = "optional", ["false"] = "optional", no = "optional", ["0"] = "optional",
    mandatory = "mandatory", m = "mandatory", ["true"] = "mandatory", yes = "mandatory", ["1"] = "mandatory",
    strict = "strict", s = "strict",
  }
  parsed.encrypt = encrypt_aliases[encrypt]
  if not parsed.encrypt then
    return nil, "SQL Server encrypt must be optional, mandatory, or strict"
  end

  local trust = (params.trust_server_certificate or "false"):lower()
  if trust == "true" or trust == "yes" or trust == "1" then
    parsed.trust_server_certificate = true
  elseif trust ~= "false" and trust ~= "no" and trust ~= "0" and trust ~= "" then
    return nil, "SQL Server trust_server_certificate must be true or false"
  end

  parsed.server_certificate = params.server_certificate
  if parsed.server_certificate == "" then parsed.server_certificate = nil end
  if parsed.server_certificate and parsed.encrypt == "optional" then
    return nil, "SQL Server server_certificate requires mandatory or strict encryption"
  end
  if parsed.server_certificate and parsed.trust_server_certificate then
    return nil, "SQL Server server_certificate cannot be combined with trust_server_certificate=true"
  end
  return parsed
end

--- Split a possibly schema-qualified table name; unqualified names are "dbo".
local function split_table_name(table_name, default_schema)
  return sql_util.split_table_name(table_name, default_schema or "dbo")
end

--- Build connection-only argv. Statements arrive in a script file (-i).
local function sqlcmd_args(parsed, opts)
  local server = parsed.host or "127.0.0.1"
  if parsed.port and parsed.port ~= "" then
    server = server .. "," .. parsed.port
  end

  local args = {
    "sqlcmd",
    "-S", server,
    -- Supplying -N makes sqlcmd validate the server certificate unless the
    -- URL explicitly opts into -C. Mandatory is the secure default.
    "-N" .. ({ optional = "o", mandatory = "m", strict = "s" })[parsed.encrypt or "mandatory"],
  }
  if opts and opts.json then
    -- JSON rows carry their own column names. -y 0 prints no header and no
    -- width limit, so a value of any length stays on its row's one line.
    vim.list_extend(args, { "-y", "0" })
  else
    -- Without -y, (max) columns are cut to 256 characters. 8000 is the widest
    -- that still prints the header row the parser reads. Microsoft's ODBC
    -- sqlcmd refuses -W next to -y, so columns arrive padded and
    -- parse_sqlcmd_table trims them.
    vim.list_extend(args, { "-y", tostring(MAX_VALUE_WIDTH) })
  end
  vim.list_extend(args, {
    "-s", "\t",
    -- No $(var) substitution: a value containing "$(" is sent as written.
    "-x",
    -- Without -b sqlcmd exits 0 even when the server rejects the statement, so
    -- every `code ~= 0` guard below would be dead and a refused DROP would be
    -- reported as a success.
    "-b",
  })

  if parsed.trust_server_certificate then args[#args + 1] = "-C" end
  if parsed.server_certificate then
    args[#args + 1] = "-J"
    args[#args + 1] = parsed.server_certificate
  end

  if parsed.dbname and parsed.dbname ~= "" then
    table.insert(args, 4, parsed.dbname)
    table.insert(args, 4, "-d")
  end

  if parsed.user and parsed.user ~= "" then
    table.insert(args, 4, parsed.user)
    table.insert(args, 4, "-U")
  else
    table.insert(args, 4, "-E")
  end

  return args
end

--- Prefix the session settings required by ordinary query execution.
local function sqlcmd_script(sql_str, opts)
  opts = opts or {}
  -- On the first line of the user's SQL, so the server's "Line N" in an
  -- error is the line they wrote.
  local session = "SET QUOTED_IDENTIFIER ON; "
  if opts.nocount ~= false then session = session .. "SET NOCOUNT ON; " end
  -- go-sqlcmd ignores a last line with no newline when it reads the script
  -- from stdin; terminating it keeps the script valid however it is fed.
  return session .. sql_str .. "\n"
end

--- Write `script` to a private temp file for sqlcmd -i. Statements never go
--- through stdin: Microsoft's ODBC sqlcmd breaks a line it reads from a pipe
--- every ~4096 bytes, which put a newline inside long string literals.
local function script_file(script)
  local path = vim.fn.tempname() .. ".sql"
  local f = assert(io.open(path, "wb"))
  f:write(script)
  f:close()
  return path
end

--- opts.env for one sqlcmd invocation: SQLCMDPASSWORD carrying the password so
--- it never appears in argv (visible via `ps`) -- the env-var equivalent of the
--- -P flag this replaces. No percent-decoding, same verbatim contract as
--- sqlcmd_args. Set (even to "") whenever a user is given, mirroring the old
--- -P/-P "" pairing with -U; empty when there is no user, since that means
--- -E integrated auth, which ignores any password.
local function sqlcmd_env(parsed)
  if not parsed.user or parsed.user == "" then return {} end
  return { SQLCMDPASSWORD = parsed.pass or "" }
end

--- Run `script` through sqlcmd -i, blocking, and remove the file afterwards.
local function run_script(parsed, script, timeout_ms, opts)
  local path = script_file(script)
  local args = sqlcmd_args(parsed, opts)
  vim.list_extend(args, { "-i", path })
  local stdout, stderr, code = adapters.run_cmd(args,
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    { env = sqlcmd_env(parsed) })
  os.remove(path)
  return stdout, stderr, code
end

--- Build and run the sqlcmd command, blocking.
local function sqlcmd(parsed, sql_str, timeout_ms, opts)
  return run_script(parsed, sqlcmd_script(sql_str, opts), timeout_ms, opts)
end

--- Run GO-separated batches as one sqlcmd script. `-Q` can only carry one
--- batch, and SET SHOWPLAN_TEXT has to be alone in its own.
local function sqlcmd_batch(parsed, batches, timeout_ms)
  return run_script(parsed, table.concat(batches, "\nGO\n") .. "\nGO\n", timeout_ms)
end

--- Message for a non-zero sqlcmd exit. With -b the server's "Msg 208, ..." text
--- lands on stdout and stderr stays empty (stderr only carries client-side
--- failures), so stdout is the fallback before the bare exit code.
--- A batch that fails at run time (rather than at compile time) has already
--- printed the earlier statements' "(N rows affected)" by then, so report from
--- the server message onwards; output with no such line is passed through whole.
local function sqlcmd_error(stdout, stderr, code)
  if stderr and stderr ~= "" then return stderr end
  local out = vim.trim(stdout or "")
  if out ~= "" then
    local lines = vim.split(out, "\n", { plain = true })
    for i, line in ipairs(lines) do
      if line:match("^Msg %d") then
        return table.concat(lines, "\n", i)
      end
    end
    return out
  end
  return "sqlcmd exited with code " .. tostring(code)
end

--- Parse sqlcmd's tab-separated text output. Fields are trimmed and NULL
--- reads as "", so trailing spaces and the text 'NULL' do not survive: grids
--- built from this are read-only (see M.query); JSON pages carry exact values.
local function parse_sqlcmd_table(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  -- Blank lines stay until the header is found: an unnamed column, as in
  -- SELECT COUNT(*), prints a blank header line.
  local lines = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    if not vim.trim(line):match("^%(%d+ rows? affected%)$") then
      table.insert(lines, line)
    end
  end

  local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      field = vim.trim(field)
      if field == "NULL" then field = "" end
      table.insert(fields, field)
    end
    return fields
  end

  -- A result set is a header line, a line of dashes, then its rows. A batch
  -- can print several, and PRINT output before them; the last one is the
  -- result, as in a query editor.
  local function is_separator(line)
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      if not vim.trim(field):match("^%-+$") then return false end
    end
    return true
  end
  local sep_at
  for i = 1, #lines do
    if vim.trim(lines[i]) ~= "" and is_separator(lines[i]) then sep_at = i end
  end
  if not sep_at then
    local messages = {}
    for _, line in ipairs(lines) do
      if vim.trim(line) ~= "" then messages[#messages + 1] = line end
    end
    return { columns = {}, rows = {}, messages = #messages > 0 and messages or nil }
  end

  local columns = split(lines[sep_at - 1] or "")
  local rows = {}
  for i = sep_at + 1, #lines do
    if vim.trim(lines[i]) ~= "" then
      local row = split(lines[i])
      -- sqlcmd prints a CLR value such as geography as its raw bytes, and a
      -- NUL among them would break rendering the grid.
      for k, field in ipairs(row) do
        row[k] = field:gsub("%z", "")
      end
      while #row < #columns do table.insert(row, "") end
      table.insert(rows, row)
    end
  end

  return { columns = columns, rows = rows }
end

--- Translate the LIMIT/OFFSET tail emitted by the shared query builder into
--- SQL Server's OFFSET/FETCH syntax. The adapter boundary is the only place
--- that knows the dialect, so every initial query and requery gets the fix.
local function normalize_query_sql(sql_str)
  local base, limit, offset = sql_str:match(
    "^(.-)%s+[Ll][Ii][Mm][Ii][Tt]%s+(%d+)%s+[Oo][Ff][Ff][Ss][Ee][Tt]%s+(%d+)%s*;?%s*$")
  if not base then
    base, limit = sql_str:match("^(.-)%s+[Ll][Ii][Mm][Ii][Tt]%s+(%d+)%s*;?%s*$")
    offset = "0"
  end
  if not base then return sql_str end

  -- OFFSET/FETCH requires an outer ORDER BY. Ignore any ORDER BY inside the
  -- raw-query wrapper; it does not satisfy SQL Server's outer SELECT.
  local lower = base:lower()
  local raw_alias_end = lower:find("%)%s+as%s+_grip")
  local outer = raw_alias_end and lower:sub(raw_alias_end) or lower
  if not outer:find("%sorder%s+by%s") then
    base = base .. " ORDER BY (SELECT NULL)"
  end
  return string.format("%s OFFSET %s ROWS FETCH NEXT %s ROWS ONLY", base, offset, limit)
end

-- ── JSON pages ───────────────────────────────────────────────────────────
-- A grid page is read as JSON produced by the server, with sqlcmd only
-- carrying it: one FOR JSON object per row, so a tab, newline or value of any
-- length arrives escaped on one line. The batch first describes the result
-- set: that gives the column order, the columns of an empty page and the
-- types, and the server uses the same description to format each column
-- (see PAGE_BATCH) before the rows are built.

--- The quote_ident-style name at `pos` ("dbo"."my ""table"""), or nil.
local function quoted_name_at(s, pos)
  local stop = pos
  while true do
    local _, e = s:find('^"[^"]*"', stop)
    if not e then _, e = s:find("^%.", stop) end
    if not e then break end
    stop = e + 1
  end
  if stop == pos then return nil end
  return s:sub(pos, stop - 1)
end

--- Binaries larger than this many bytes arrive as "<binary N bytes>", which
--- the grid shows as binary and the editor refuses, instead of as hex: a page
--- of documents would otherwise ship megabytes and freeze the editor.
local MAX_BINARY_BYTES = 8000

-- One batch, run with -y 0:
-- 1. The description, wrapped in a scalar SELECT: a top-level FOR JSON comes
--    back cut into rows of about 2000 characters, a scalar subquery as one
--    value on one line.
-- 2. The rows, as a FOR JSON object each, built by dynamic SQL from that same
--    description so every column gets the server's formatting: binaries as 0x
--    hex (or the placeholder past MAX_BINARY_BYTES), and the CLR types FOR JSON
--    refuses (geography, geometry, hierarchyid) as their text.
-- When the description fails (a view over a dropped column, say), its columns
-- have no name and @cols comes out NULL or empty, so EXEC is skipped and
-- parse_json_page sends the caller to the text path, which reports the
-- server's own error.
-- Placeholders: the statement, MAX_BINARY_BYTES, the row source, the FROM tail.
local PAGE_BATCH = [[
DECLARE @q nvarchar(max) = N'%s';
DECLARE @cols nvarchar(max) = STUFF((
  SELECT N', ' + CASE
      WHEN system_type_name LIKE N'%%binary%%' OR system_type_name IN (N'image', N'timestamp')
        THEN N'CASE WHEN DATALENGTH(' + ref + N') > %d'
          + N' THEN CONCAT(N''<binary '', DATALENGTH(' + ref + N'), N'' bytes>'')'
          + N' ELSE CONVERT(varchar(max), CONVERT(varbinary(max), ' + ref + N'), 1) END'
      WHEN system_type_name IN (N'geography', N'geometry', N'hierarchyid')
        THEN N'CAST(' + ref + N' AS nvarchar(max))'
      ELSE ref
    END + N' AS ' + QUOTENAME(name)
  FROM (SELECT name, system_type_name, column_ordinal, N'%s.' + QUOTENAME(name) AS ref
        FROM sys.dm_exec_describe_first_result_set(@q, NULL, 0)) AS d
  ORDER BY column_ordinal
  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SELECT (SELECT name, system_type_name, is_nullable, is_updateable, is_identity_column
  FROM sys.dm_exec_describe_first_result_set(@q, NULL, 0)
  ORDER BY column_ordinal FOR JSON PATH, INCLUDE_NULL_VALUES);
IF @cols <> N'' EXEC (N'SELECT (SELECT ' + @cols + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) ' + N'%s');]]

--- "nvarchar" for "nvarchar(max)".
local function base_type(type_name)
  return (type_name:match("^%a+") or ""):lower()
end

--- Rewrite a query.build_sql statement (SELECT * over a quoted table or over
--- the `(...) AS _grip` wrapper) into PAGE_BATCH. Its WHERE, ORDER BY and
--- paging stay as they are. Returns nil for any other statement.
local function json_page_sql(sql_str)
  local body = sql_str:gsub("[%s;]+$", "")
  local from_kw, source_pos = body:match(
    "^%s*[Ss][Ee][Ll][Ee][Cc][Tt]%s+%*%s+()[Ff][Rr][Oo][Mm]%s+()")
  if not from_kw then return nil end

  local source
  if body:sub(source_pos, source_pos) == "(" then
    if not body:find("%)%s+[Aa][Ss]%s+_grip%f[^%w_]") then return nil end
    source = "_grip"
  else
    source = quoted_name_at(body, source_pos)
    if not source then return nil end
  end

  return string.format(PAGE_BATCH, esc(body), MAX_BINARY_BYTES, esc(source), esc(body:sub(from_kw)))
end

--- Index of the quote closing the JSON string that opens at `pos`.
local function json_string_end(s, pos)
  local i = pos + 1
  while true do
    local c = s:find('["\\]', i)
    if not c then return nil end
    if s:sub(c, c) == '"' then return c end
    i = c + 2
  end
end

--- Decode one FOR JSON row: a flat object with no whitespace between tokens.
--- Numbers keep their exact text (a bigint or decimal would not survive a Lua
--- number), bits become 1/0 and null becomes "", as in the text output; the
--- third result marks the positions that held a real empty string.
--- Returns keys, values, empties; nil for anything else, such as the nested
--- object a dotted column alias produces or a row cut off at the -y width.
local function decode_json_row(line)
  if line:sub(1, 1) ~= "{" then return nil end
  local keys, values, empties = {}, {}, {}
  local pos = 2
  while true do
    if line:sub(pos, pos) ~= '"' then return nil end
    local key_end = json_string_end(line, pos)
    if not key_end or line:sub(key_end + 1, key_end + 1) ~= ":" then return nil end
    local ok, key = pcall(vim.json.decode, line:sub(pos, key_end))
    if not ok then return nil end

    pos = key_end + 2
    local value, value_end
    local c = line:sub(pos, pos)
    if c == '"' then
      value_end = json_string_end(line, pos)
      if not value_end then return nil end
      ok, value = pcall(vim.json.decode, line:sub(pos, value_end))
      if not ok then return nil end
      if value == "" then empties[#keys + 1] = true end
    else
      local literal = line:match("^%a+", pos)
      if literal == "null" then value = ""
      elseif literal == "true" then value = "1"
      elseif literal == "false" then value = "0"
      elseif not literal then
        literal = line:match("^%-?%d[%d%.eE+%-]*", pos)
        value = literal
      end
      if not value then return nil end
      value_end = pos + #literal - 1
    end

    keys[#keys + 1] = key
    values[#values + 1] = value
    pos = value_end + 1
    local sep = line:sub(pos, pos)
    if sep == "}" then
      if pos ~= #line then return nil end
      return keys, values, empties
    end
    if sep ~= "," then return nil end
    pos = pos + 1
  end
end

--- Types SQL Server cannot compare with =, reported so value lookups such as
--- sql.build_insert_lookup leave them out.
local INCOMPARABLE_TYPES = {
  text = true, ntext = true, image = true, xml = true, geography = true, geometry = true,
}

-- ── query pad SQL ────────────────────────────────────────────────────────
-- A raw query is paged by wrapping it: SELECT * FROM (<query>) AS _grip.
-- SQL Server refuses a lot inside that wrapper (ORDER BY without TOP, CTEs,
-- several statements, EXEC, ...), so plan_query decides per query whether
-- it can be wrapped or must run as written.

--- Top-level-aware tokens of a T-SQL batch. Comments are dropped; literals,
--- quoted names, words and punctuation carry their nesting depth.
local function scan_tsql(sql_str)
  local toks, i, n, depth = {}, 1, #sql_str, 0
  local function quoted(open_at, close)
    local j = open_at + 1
    while j <= n do
      if sql_str:sub(j, j) == close then
        if sql_str:sub(j + 1, j + 1) ~= close then return j end
        j = j + 2
      else
        j = j + 1
      end
    end
    return n
  end
  while i <= n do
    local c, two = sql_str:sub(i, i), sql_str:sub(i, i + 1)
    if two == "--" then
      i = (sql_str:find("\n", i, true) or n) + 1
    elseif two == "/*" then
      local nest, j = 1, i + 2
      while j <= n and nest > 0 do
        local t = sql_str:sub(j, j + 1)
        if t == "/*" then nest, j = nest + 1, j + 2
        elseif t == "*/" then nest, j = nest - 1, j + 2
        else j = j + 1 end
      end
      i = j
    elseif c == "'" then
      local e = quoted(i, "'")
      toks[#toks + 1] = { kind = "literal", s = i, e = e, depth = depth }
      i = e + 1
    elseif c == "[" or c == '"' then
      local e = quoted(i, c == "[" and "]" or '"')
      toks[#toks + 1] = { kind = "name", s = i, e = e, depth = depth, text = sql_str:sub(i, e) }
      i = e + 1
    elseif c:match("[%w_@#$\128-\255]") then
      local s2, e2 = sql_str:find("^[%w_@#$\128-\255]+", i)
      local text = sql_str:sub(s2, e2)
      toks[#toks + 1] = { kind = "word", s = s2, e = e2, depth = depth, text = text, word = text:upper() }
      i = e2 + 1
    else
      if c == ")" then depth = depth - 1 end
      if c:match("[%(%);,%.]") then toks[#toks + 1] = { kind = c, s = i, e = i, depth = depth } end
      if c == "(" then depth = depth + 1 end
      i = i + 1
    end
  end
  return toks
end

--- [a]]b] / "a""b" / a → a]b / a"b / a
local function unquote_name(text)
  local open = text:sub(1, 1)
  if open == "[" then return text:sub(2, -2):gsub("%]%]", "]") end
  if open == '"' then return text:sub(2, -2):gsub('""', '"') end
  return text
end

-- First words the generic code already routes (mutation preview, DDL confirm).
local ROUTED_ELSEWHERE = {
  UPDATE = true, DELETE = true, INSERT = true, ALTER = true, DROP = true, CREATE = true,
  BEGIN = true, COMMIT = true, ROLLBACK = true,
}
-- First words that make a statement rather than a table name: anything else
-- ("order lines", a typo) stays a table name, as the sidebar passes them.
local STATEMENT_WORDS = {
  SELECT = true, WITH = true, EXEC = true, EXECUTE = true, DECLARE = true, PRINT = true,
  SET = true, IF = true, WHILE = true, USE = true, RAISERROR = true, THROW = true,
  TRUNCATE = true, MERGE = true, DBCC = true, WAITFOR = true, GRANT = true, REVOKE = true,
  DENY = true, OPEN = true, FETCH = true, CLOSE = true, DEALLOCATE = true,
}
local WRITE_WORDS = {
  INSERT = true, UPDATE = true, DELETE = true, MERGE = true, TRUNCATE = true, DROP = true,
  ALTER = true, CREATE = true, GRANT = true, REVOKE = true, DENY = true,
}

--- Plain trailing ORDER BY items ([alias.]column [ASC|DESC]) as grid sorts,
--- or nil when any item is something else (an expression, an ordinal).
local function order_by_sorts(toks, from)
  local sorts, item = {}, {}
  local function close_item()
    local last_name, dir, expect_name = nil, "ASC", true
    for _, t in ipairs(item) do
      if expect_name and (t.kind == "name" or (t.kind == "word" and t.word ~= "ASC" and t.word ~= "DESC")) then
        last_name, expect_name = unquote_name(t.text), false
      elseif not expect_name and t.kind == "." then
        expect_name = true
      elseif not expect_name and t.kind == "word" and (t.word == "ASC" or t.word == "DESC") and dir == "ASC" then
        dir = t.word
      else
        return false
      end
    end
    if not last_name or expect_name or last_name:match("^%d") then return false end
    sorts[#sorts + 1] = { column = last_name, dir = dir }
    item = {}
    return true
  end
  for k = from, #toks do
    local t = toks[k]
    if t.kind == ";" then break end
    if t.depth ~= 0 then return nil end
    if t.kind == "," then
      if not close_item() then return nil end
    else
      item[#item + 1] = t
    end
  end
  if not close_item() then return nil end
  return sorts
end

-- Rows per result set for a batch run as written, which no wrapper pages.
local AS_WRITTEN_ROW_CAP = 1000

--- "SET ROWCOUNT 1000; " for a batch it is safe to cap, else "". ROWCOUNT
--- also limits INSERT, UPDATE, DELETE, SELECT INTO and whatever a procedure
--- does, so batches that write, fill a table or EXEC are left alone.
function M.row_cap_prefix(sql_str)
  for _, t in ipairs(scan_tsql(sql_str or "")) do
    if t.kind == "word" and (WRITE_WORDS[t.word] or t.word == "INTO" or t.word == "EXEC" or t.word == "EXECUTE") then
      return ""
    end
  end
  return "SET ROWCOUNT " .. AS_WRITTEN_ROW_CAP .. "; "
end
M.AS_WRITTEN_ROW_CAP = AS_WRITTEN_ROW_CAP

--- How the query pad should run `sql_str` on SQL Server. Returns nil for what
--- the generic code handles (a bare table name, UPDATE/DELETE/INSERT, DDL),
--- else a plan:
---   { kind = "select", sql = <wrappable query>, sorts = { {column, dir} } }
---   { kind = "passthrough", writes = <the batch writes>, prefix = <row cap or nil> }:
---     run as written.
function M.plan_query(sql_str)
  local trimmed = vim.trim(sql_str or "")
  if trimmed == "" then return nil end
  local toks = scan_tsql(trimmed)
  local first
  for _, t in ipairs(toks) do
    if t.kind == "word" or t.kind == "name" then first = t break end
  end
  if not first then return nil end
  if first.kind == "name" or (not trimmed:find("%s") and first.s == 1) then return nil end

  local writes = false
  for _, t in ipairs(toks) do
    if t.kind == "word" and WRITE_WORDS[t.word] then writes = true end
  end
  if ROUTED_ELSEWHERE[first.word] or not STATEMENT_WORDS[first.word] then return nil end
  if first.word == "WITH" and writes then return nil end
  local cap = M.row_cap_prefix(trimmed)
  local passthrough = { kind = "passthrough", writes = writes, prefix = cap ~= "" and cap or nil }
  if first.word ~= "SELECT" then return passthrough end

  -- Anything after a top-level ';' or a GO line is another statement.
  for k, t in ipairs(toks) do
    if t.kind == ";" and t.depth == 0 and toks[k + 1] then return passthrough end
  end
  for line in trimmed:gmatch("[^\n]+") do
    if line:match("^%s*[Gg][Oo]%s*%d*%s*$") then return passthrough end
  end

  local order_at, has_top = nil, false
  for k, t in ipairs(toks) do
    if t.depth == 0 and t.kind == "word" then
      if t.word == "INTO" or t.word == "OPTION" or t.word == "COMPUTE" then return passthrough end
      if t.word == "FOR" and toks[k + 1] and toks[k + 1].kind == "word"
          and (toks[k + 1].word == "JSON" or toks[k + 1].word == "XML" or toks[k + 1].word == "BROWSE") then
        return passthrough
      end
      if t.word == "TOP" or t.word == "OFFSET" then has_top = true end
      if t.word == "ORDER" and toks[k + 1] and toks[k + 1].word == "BY" then order_at = k end
    end
  end

  local body = trimmed:gsub("[%s;]+$", "")
  if not order_at or has_top then
    return { kind = "select", sql = body, sorts = {} }
  end
  local sorts = order_by_sorts(toks, order_at + 2)
  if not sorts then return passthrough end
  return { kind = "select", sql = vim.trim(trimmed:sub(1, toks[order_at].s - 1)), sorts = sorts }
end

--- Character types: the grid's "" can be a real empty string in these.
local TEXT_TYPES = {
  char = true, varchar = true, nchar = true, nvarchar = true, text = true, ntext = true,
}

--- FOR JSON prints floats as 1.500000000000000e+000; show the shortest
--- decimal that reads back the same. Everything else arrives as the grid
--- shows it (binaries already as hex, see PAGE_BATCH).
local function json_cell(value, type_name)
  if value == "" then return value end
  local base = base_type(type_name)
  if base == "float" or base == "real" then
    local n = tonumber(value)
    if not n then return nil end
    for _, fmt in ipairs({ "%.15g", "%.16g", "%.17g" }) do
      local s = string.format(fmt, n)
      if tonumber(s) == n then return s end
    end
  end
  return value
end

--- The { name, type } list the description in a PAGE_BATCH printed: its first output
--- line that is a JSON array. nil when there is none or a column has no name,
--- as when the server cannot describe the statement.
local function described_columns(raw)
  for line in (raw or ""):gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line:sub(1, 1) == "[" then
      local ok, list = pcall(vim.json.decode, line)
      if not ok or type(list) ~= "table" or #list == 0 then return nil end
      local columns = {}
      for i, entry in ipairs(list) do
        if type(entry.name) ~= "string" or entry.name == "" then return nil end
        local type_name = entry.system_type_name
        columns[i] = {
          name = entry.name,
          type = type(type_name) == "string" and type_name or "",
          nullable = entry.is_nullable ~= false,
          -- Computed, rowversion and period columns: no INSERT or UPDATE takes them.
          -- IDENTITY is not updateable either, but undo writes it back.
          generated = entry.is_updateable == false and entry.is_identity_column ~= true,
        }
      end
      return columns
    end
  end
  return nil
end

--- Parse the output of a json_page_sql batch into { columns, rows, types }.
--- Returns nil when the describe line is missing or any row does not decode
--- into exactly the described columns; the caller then uses the text output.
local function parse_json_page(raw)
  local described = described_columns(raw)
  if not described then return nil end
  local columns, types = {}, {}
  for i, col in ipairs(described) do
    columns[i], types[i] = col.name, col.type
  end

  -- Every row is one line starting with "{". Other lines are the describe
  -- array and server messages such as "Warning: Null value is eliminated by
  -- an aggregate".
  local rows, empty_cells = {}, {}
  for line in raw:gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line:sub(1, 1) == "{" then
      local keys, values, empties = decode_json_row(line)
      if not keys or #keys ~= #columns then return nil end
      local row = {}
      for i, key in ipairs(keys) do
        if key ~= columns[i] then return nil end
        row[i] = json_cell(values[i], types[i])
        if not row[i] then return nil end
      end
      rows[#rows + 1] = row
      if next(empties) then empty_cells[#rows] = empties end
    end
  end
  local incomparable
  local column_types, generated, required_text = {}, {}, {}
  for i, col in ipairs(described) do
    local base = base_type(col.type)
    if INCOMPARABLE_TYPES[base] then
      incomparable = incomparable or {}
      incomparable[col.name] = true
    end
    column_types[col.name] = col.type
    if col.generated then generated[col.name] = true end
    if TEXT_TYPES[base] and not col.nullable then required_text[col.name] = true end
  end
  return {
    columns = columns, rows = rows, types = types, incomparable = incomparable,
    column_types = column_types, generated = generated, required_text = required_text,
    empty_cells = empty_cells,
  }
end

local function run_query(sql_str, url, timeout_ms)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end

  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end

  local query_sql = normalize_query_sql(sql_str)
  local page_sql = json_page_sql(query_sql)
  if page_sql then
    local stdout, stderr, code = sqlcmd(parsed, page_sql, timeout_ms, { json = true })
    if code == 0 then
      local page = parse_json_page(stdout)
      if page then return page, nil end
    else
      local err = sqlcmd_error(stdout, stderr, code)
      -- FOR JSON still refuses a user-defined CLR type, which the text output
      -- can show; any other error would fail on the text path too.
      if not err:find("FOR JSON", 1, true) then return nil, err end
    end
  end

  local stdout, stderr, code = sqlcmd(parsed, query_sql, timeout_ms)
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end
  local result = parse_sqlcmd_table(stdout)
  result.text = true
  return result, nil
end

--- Non-blocking twin of run_query: same argv, same output parser, same guards.
--- Delivers (result, err) to `callback` instead of returning them.
local function run_query_async(sql_str, url, timeout_ms, callback)
  -- Both guards below deliver via vim.schedule: run_cmd_async's contract is
  -- that the callback never fires on the calling tick, and a caller must not
  -- be able to tell a guard rejection from a spawn failure by that timing
  -- difference.
  if vim.fn.executable("sqlcmd") == 0 then
    vim.schedule(function()
      callback(nil, "sqlcmd not found. Install Microsoft sqlcmd tools.")
    end)
    return
  end

  local parsed, parse_err = parse_url(url)
  if not parsed then
    vim.schedule(function() callback(nil, parse_err) end)
    return
  end

  local path = script_file(sqlcmd_script(normalize_query_sql(sql_str)))
  local args = sqlcmd_args(parsed)
  vim.list_extend(args, { "-i", path })
  adapters.run_cmd_async(args,
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    function(stdout, stderr, code)
      os.remove(path)
      if code ~= 0 then
        callback(nil, sqlcmd_error(stdout, stderr, code))
        return
      end
      callback(parse_sqlcmd_table(stdout), nil)
    end, { env = sqlcmd_env(parsed) })
end

function M.query(sql_str, url)
  local parsed, err = run_query(sql_str, url)
  if not parsed then return nil, err end
  return {
    rows = parsed.rows,
    columns = parsed.columns,
    primary_keys = {},
    readonly = parsed.text or nil,
    readonly_reason = parsed.text and "plain text output" or nil,
    incomparable_columns = parsed.incomparable,
    -- Only the JSON path knows these; the text path leaves them nil and the
    -- grid keeps treating "" as NULL there.
    column_types = parsed.column_types,
    generated_columns = parsed.generated,
    required_text_columns = parsed.required_text,
    empty_cells = parsed.empty_cells,
  }, nil
end

--- SQL Server has no read-only session for a client to request, so
--- `"mode": "ro"` is enforced on grip's side only: the grid, the DDL guards,
--- and execute() below. A statement that reaches the server through query()
--- instead, such as EXEC or a GO-separated batch, is limited only by the
--- login's permissions. See adapters.readonly_caveat.
function M.readonly_caveat(_url)
  return "SQL Server has no read-only session, so EXEC or a batch from the"
    .. " query pad still runs"
end

function M.execute(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  if adapters.session_opts().readonly then
    return nil, "read-only connection: statement not run"
  end
  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end
  local stdout, stderr, code = sqlcmd(parsed, sql_str, nil, { nocount = false })
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end
  local n = stdout:match("%((%d+) rows? affected%)") or stderr:match("%((%d+) rows? affected%)") or "0"
  return { affected = tonumber(n) or 0, message = stdout:gsub("%s+$", "") }, nil
end

function M.ping(url)
  if vim.fn.executable("sqlcmd") == 0 then return false end
  local parsed = parse_url(url)
  if not parsed then return false end
  local _, _, code = sqlcmd(parsed, "SELECT 1", 5000)
  return code == 0
end

function M.list_tables(url)
  local result, err = run_query([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      CASE TABLE_TYPE WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE IN ('BASE TABLE', 'VIEW')
    ORDER BY TABLE_SCHEMA, table_type DESC, TABLE_NAME
  ]], url)
  if not result then return nil, err end
  local out = {}
  for _, row in ipairs(result.rows) do
    table.insert(out, { name = row[1] or "", type = row[2] or "table" })
  end
  return out, nil
end

--- Reverse FK lookup: which tables reference table_name?
--- One schema-aware sys.foreign_keys query, so a qualified target
--- ("dbo.users") is resolved server-side instead of going through db.lua's
--- bare-name scan, which ddl._filter_referencing has to discard as ambiguous.
--- Returns { {table, column, ref_column, composite?}, ... }, err.
function M.get_referencing_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      cs.name AS child_schema,
      ct.name AS child_table,
      cc.name AS fk_column,
      rc.name AS ref_column,
      fk.name AS constraint_name
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables ct ON ct.object_id = fk.parent_object_id
    JOIN sys.schemas cs ON cs.schema_id = ct.schema_id
    JOIN sys.tables pt ON pt.object_id = fk.referenced_object_id
    JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
    JOIN sys.columns cc ON cc.object_id = fkc.parent_object_id
      AND cc.column_id = fkc.parent_column_id
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
      AND rc.column_id = fkc.referenced_column_id
    WHERE ps.name = '%s'
      AND pt.name = '%s'
    ORDER BY cs.name, ct.name, fk.name, fkc.constraint_column_id
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end

  local entries = {}
  for _, row in ipairs(result.rows) do
    local child_schema = row[1] or "dbo"
    local child_tbl = row[2] or ""
    -- Same naming as list_tables: dbo is implicit, other schemas are qualified.
    local full_name = (child_schema == "dbo") and child_tbl or (child_schema .. "." .. child_tbl)
    table.insert(entries, {
      table      = full_name,
      column     = row[3] or "",
      ref_column = row[4] or "",
      key        = row[5] or "",
    })
  end
  return db_util.group_referencing_fks(entries), nil
end

--- The length/precision-suffixed data_type expression, interpolated into both
--- get_column_info and SCHEMA_BATCH_SQL so the two can never drift: callers must
--- get the same string whether a table came from the batch or a per-table call.
--- SQL Server reports CHARACTER_MAXIMUM_LENGTH = -1 for the MAX types
--- (nvarchar(max), varbinary(max)), hence the dedicated arm ahead of the
--- positive-length one.
local DATA_TYPE_EXPR = [[
      DATA_TYPE +
        CASE
          WHEN CHARACTER_MAXIMUM_LENGTH = -1 THEN '(max)'
          WHEN CHARACTER_MAXIMUM_LENGTH IS NOT NULL AND CHARACTER_MAXIMUM_LENGTH > 0
            THEN '(' + CAST(CHARACTER_MAXIMUM_LENGTH AS varchar(20)) + ')'
          WHEN NUMERIC_PRECISION IS NOT NULL AND DATA_TYPE NOT IN ('int','bigint','smallint','tinyint','bit')
            THEN '(' + CAST(NUMERIC_PRECISION AS varchar(20)) +
                 CASE WHEN NUMERIC_SCALE > 0 THEN ',' + CAST(NUMERIC_SCALE AS varchar(20)) ELSE '' END + ')'
          ELSE ''
        END AS data_type]]

function M.get_column_info(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      COLUMN_NAME,
%s,
      IS_NULLABLE,
      COALESCE(COLUMN_DEFAULT, '') AS column_default,
      ''
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '%s'
      AND TABLE_NAME = '%s'
    ORDER BY ORDINAL_POSITION
  ]], DATA_TYPE_EXPR, esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return nil, err end

  local cols = {}
  for _, row in ipairs(result.rows) do
    table.insert(cols, {
      column_name = row[1] or "",
      data_type = row[2] or "",
      is_nullable = row[3] or "",
      column_default = row[4] or "",
      constraints = row[5] or "",
    })
  end
  return cols, nil
end

function M.get_primary_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT kcu.COLUMN_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
    ORDER BY kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local pks = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then table.insert(pks, row[1]) end
  end
  return pks, nil
end

function M.get_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      kcu.COLUMN_NAME,
      ccu.TABLE_NAME AS ref_table,
      ccu.COLUMN_NAME AS ref_column
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
      ON rc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND rc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    JOIN INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE ccu
      ON ccu.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME
      AND ccu.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
    ORDER BY kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local fks = {}
  for _, row in ipairs(result.rows) do
    table.insert(fks, {
      column = row[1] or "",
      ref_table = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

--- The one schema-batch statement, shared by get_schema_batch and
--- get_schema_batch_async so the two paths can never query different things.
--- data_type comes from the same DATA_TYPE_EXPR get_column_info uses.
local SCHEMA_BATCH_SQL = string.format([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      COLUMN_NAME,
%s,
      IS_NULLABLE
    FROM INFORMATION_SCHEMA.COLUMNS
    ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
  ]], DATA_TYPE_EXPR)

--- Turn SCHEMA_BATCH_SQL's parsed rows into the completion cache format.
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- The single parser for both the blocking and non-blocking paths.
local function parse_schema_batch(result)
  if not result then return nil end
  local tables = {}
  for _, row in ipairs(result.rows) do
    local tname = row[1] or ""
    tables[tname] = tables[tname] or {}
    table.insert(tables[tname], {
      column_name = row[2] or "",
      data_type = row[3] or "",
      is_nullable = row[4] or "",
    })
  end
  return tables
end

function M.get_schema_batch(url)
  local result = run_query(SCHEMA_BATCH_SQL, url)
  return parse_schema_batch(result)
end

--- Async variant: same statement, same parser, non-blocking spawn.
--- Calls callback(tables), or callback(nil) when sqlcmd is missing or fails.
--- Used to pre-warm the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  run_query_async(SCHEMA_BATCH_SQL, url, nil, function(result)
    callback(parse_schema_batch(result))
  end)
end

function M.get_indexes(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      i.name AS index_name,
      CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY'
           WHEN i.is_unique = 1 THEN 'UNIQUE'
           ELSE 'INDEX' END AS index_type,
      STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.objects o ON o.object_id = i.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND i.name IS NOT NULL
    GROUP BY i.name, i.is_primary_key, i.is_unique
    ORDER BY i.is_primary_key DESC, i.name
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local indexes = {}
  for _, row in ipairs(result.rows) do
    local cols = {}
    for col in (row[3] or ""):gmatch("([^,]+)") do table.insert(cols, vim.trim(col)) end
    table.insert(indexes, { name = row[1] or "", type = row[2] or "INDEX", columns = cols })
  end
  return indexes, nil
end

function M.get_constraints(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      tc.CONSTRAINT_NAME,
      tc.CONSTRAINT_TYPE,
      COALESCE(cc.CHECK_CLAUSE, '') AS definition
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    LEFT JOIN INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
      ON cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    WHERE tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
      AND tc.CONSTRAINT_TYPE IN ('CHECK', 'UNIQUE')
    ORDER BY tc.CONSTRAINT_TYPE, tc.CONSTRAINT_NAME
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local constraints = {}
  for _, row in ipairs(result.rows) do
    table.insert(constraints, { name = row[1] or "", type = row[2] or "", definition = row[3] or "" })
  end
  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      SUM(row_count) AS row_estimate,
      SUM(reserved_page_count) * 8192 AS size_bytes
    FROM sys.dm_db_partition_stats ps
    JOIN sys.objects o ON o.object_id = ps.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND ps.index_id IN (0, 1)
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result or not result.rows[1] then return nil, err or "No stats found" end
  return {
    row_estimate = tonumber(result.rows[1][1]) or 0,
    size_bytes = tonumber(result.rows[1][2]) or 0,
  }, nil
end

--- SHOWPLAN_TEXT has to be the only statement in its batch, so the plan cannot
--- go through run_query's single script (which also prefixes SET NOCOUNT ON):
--- the server answers every such attempt with "The SET SHOWPLAN statements must
--- be the only statements in the batch". Two GO-separated batches instead.
function M.explain(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end

  local stdout, stderr, code = sqlcmd_batch(parsed,
    { "SET SHOWPLAN_TEXT ON", normalize_query_sql(sql_str) })
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end

  local result = parse_sqlcmd_table(stdout)
  local header = result.columns[1]
  local lines = {}
  for _, row in ipairs(result.rows) do
    local line = table.concat(row, " | ")
    -- SHOWPLAN emits one result set per statement and sqlcmd repeats the
    -- StmtText header for each, so the header shows up again mid-plan.
    if line ~= header then table.insert(lines, line) end
  end
  return { lines = lines }, nil
end

M._parse_url = parse_url
M._parse_sqlcmd_table = parse_sqlcmd_table
M._sqlcmd_args = sqlcmd_args
M._sqlcmd_env = sqlcmd_env
M._sqlcmd_script = sqlcmd_script
M._normalize_query_sql = normalize_query_sql
M._json_page_sql = json_page_sql
M._decode_json_row = decode_json_row
M._parse_json_page = parse_json_page

return M
