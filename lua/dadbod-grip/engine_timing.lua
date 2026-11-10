-- Opt-in DuckDB profiler LATENCY. A fresh private artifact belongs to one run.
local M = {}
local capabilities = {}
local heads = { SELECT = true, WITH = true, FROM = true, VALUES = true, TABLE = true,
  INSERT = true, UPDATE = true, DELETE = true, MERGE = true, CREATE = true,
  ALTER = true, DROP = true, TRUNCATE = true, COPY = true }

local function metadata(status, reason)
  return { status = status, reason = reason, adapter = "duckdb", source = "duckdb_profile", scope = "statement" }
end

--- Conservative lexical guard, not a SQL parser. Batches and profiling/session
--- controls keep their normal execution, with no claim about a batch total.
--- Return the single statement without its terminal delimiter/trailing comments
--- so the existing nested-value SELECT wrapper can safely hold it.
function M.statement(sql)
  if type(sql) ~= "string" then
    return nil, "unsupported_statement"
  end
  local i, n, terminal, head = 1, #sql
  while i <= n do
    local c, pair = sql:sub(i, i), sql:sub(i, i + 1)
    if c:match("%s") then i = i + 1
    elseif pair == "--" then
      i = (sql:find("[\r\n]", i + 2) or n) + 1
    elseif pair == "/*" then
      local depth = 1
      i = i + 2
      while i <= n and depth > 0 do
        pair = sql:sub(i, i + 1)
        if pair == "/*" then depth = depth + 1; i = i + 2
        elseif pair == "*/" then depth = depth - 1; i = i + 2
        else i = i + 1 end
      end
      if depth > 0 then return nil, "unsupported_statement" end
    elseif terminal then return nil, "multiple_statements"
    elseif c == ";" then terminal = i; i = i + 1
    else
      if not head then head = sql:sub(i):match("^(%a+)") end
      if c == "'" or c == '"' then
        local quote, closed = c, false
        local escaped = quote == "'" and sql:sub(i - 1, i - 1):upper() == "E"
        i = i + 1
        while i <= n do
          c = sql:sub(i, i)
          if c == "\\" and escaped then i = i + 2
          elseif c == quote then
            if sql:sub(i + 1, i + 1) == quote then i = i + 2
            else i = i + 1; closed = true; break end
          else i = i + 1 end
        end
        if not closed then return nil, "unsupported_statement" end
      elseif c == "$" then
        local tag = sql:sub(i):match("^(%$[%w_]*%$)")
        if tag then
          local close = sql:find(tag, i + #tag, true)
          if not close then return nil, "unsupported_statement" end
          i = close + #tag
        else i = i + 1 end
      else i = i + 1 end
    end
  end
  if not head or not heads[head:upper()] then return nil, "unsupported_statement" end
  return terminal and sql:sub(1, terminal - 1) or sql
end

function M.unsupported(reason) return metadata("unsupported", reason) end

function M.prepare(sql, opts)
  if not (type(opts) == "table" and opts.engine_timing == true) then return nil end
  local statement, reason = M.statement(sql)
  if not statement then return { value = metadata("unsupported", reason), prefix = "" } end
  local dir = vim.fn.tempname() .. "_grip_profile"
  local made = vim.uv.fs_mkdir(dir, 448) -- 0700: a profile can contain SQL text.
  if not made then return { value = metadata("unavailable", "profile_setup_failed"), prefix = "" } end
  local path = dir .. "/profile.json"
  return { dir = dir, path = path, payload = sql,
    prefix = "SET enable_profiling = 'json';\nSET profiling_output = '"
      .. require("dadbod-grip.sql").escape_literal(path) .. "';\nSET profiling_coverage = 'ALL';\n" }
end

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function read_profile(profile, code)
  if profile.value then return profile.value end
  if code ~= 0 then return metadata("unavailable", "query_failed") end
  local ok, lines = pcall(vim.fn.readfile, profile.path, "b")
  if not ok then return metadata("unavailable", "profile_missing") end
  local decoded, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(value) ~= "table" then return metadata("unavailable", "profile_malformed") end
  if type(value.query_name) ~= "string" or trim(value.query_name) ~= trim(profile.payload) then
    return metadata("unavailable", "statement_mismatch")
  end
  local seconds = value.latency
  if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge
      or seconds * 1000 == math.huge then return metadata("unavailable", "invalid_duration") end
  local result = metadata("available")
  result.elapsed_ms = seconds * 1000
  return result
end

--- Cleanup also runs if a caller is interrupted or a Lua callback raises.
function M.run(profile, fn)
  if not profile then return fn() end
  local ok, stdout, stderr, code = pcall(fn)
  local parsed, value = pcall(read_profile, profile, code)
  if profile.dir then vim.fn.delete(profile.dir, "rf") end
  if not ok then error(stdout, 0) end
  if not parsed then value = metadata("unavailable", "profile_malformed") end
  return stdout, stderr, code, value
end

--- A pure, in-memory metadata probe, once per executable identity. Never probe
--- using the user's SQL, database, attachments, extensions, or init file.
function M.options(opts)
  if not (type(opts) == "table" and opts.engine_timing == true) then return nil end
  local adapters = require("dadbod-grip.adapters")
  local client = vim.fn.exepath("duckdb")
  local stat = vim.uv.fs_stat(client)
  local key = client .. (stat and (":" .. stat.size .. ":" .. stat.mtime.sec .. ":" .. stat.mtime.nsec) or "")
  local cached = capabilities[key]
  if cached == true then return opts end
  if cached then return nil, vim.deepcopy(cached) end
  local profile = M.prepare("SELECT 1 AS _grip_profile_capability", opts)
  if not profile.path then return nil, profile.value end
  local _, stderr, code, value = M.run(profile, function()
    return adapters.run_cmd({ client, "-init", vim.fn.has("win32") == 1 and "NUL" or "/dev/null", "-bail", "-csv", "-header" },
      math.min(adapters.configured_timeout(10000), 5000),
      { stdin = profile.prefix .. profile.payload, terminate_on_interrupt = true })
  end)
  if code == 130 or code == 124 or (stderr or ""):find("command timed out", 1, true) then
    return nil, nil, stderr ~= "" and stderr or "profiling capability probe interrupted or timed out"
  end
  if code == 0 and value.status == "available" then capabilities[key] = true; return opts end
  local unsupported = (stderr or ""):lower():find("unrecognized configuration", 1, true)
    or (stderr or ""):lower():find("unknown configuration", 1, true)
  local absent = metadata(unsupported and "unsupported" or "unavailable",
    unsupported and "profiling_settings_unsupported" or "profiling_capability_unavailable")
  capabilities[key] = absent
  return nil, absent
end

return M
