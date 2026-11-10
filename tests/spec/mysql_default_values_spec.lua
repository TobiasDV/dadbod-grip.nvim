-- DEFAULT VALUES compatibility must never rewrite data delivered over stdin.
local mysql = require("dadbod-grip.adapters.mysql")
local adapters = require("dadbod-grip.adapters")
local pass, fail = 0, 0

local function eq(actual, expected, message)
  assert(actual == expected, (message or "") .. ": expected "
    .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function execute(sql, response, session)
  local run_cmd, executable, session_opts = adapters.run_cmd, vim.fn.executable, adapters.session_opts
  local seen = { calls = 0 }
  adapters.run_cmd = function(args, timeout, opts)
    seen.calls = seen.calls + 1
    seen.args, seen.timeout, seen.opts = args, timeout, opts
    return unpack(response or { "ROW_COUNT()\n1\n", "", 0 })
  end
  vim.fn.executable = function(name) return name == "mysql" and 1 or executable(name) end
  adapters.session_opts = function() return session or {} end
  local ok, result, err = pcall(mysql.execute, sql,
    "mysql://fixture_user:fixture_password@fixture.invalid/fixture_db")
  adapters.run_cmd, vim.fn.executable, adapters.session_opts = run_cmd, executable, session_opts
  assert(ok, result)
  return seen, result, err
end

local function expected_stdin(sql, readonly)
  local header = "SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\n"
  if readonly then header = header .. "SET SESSION TRANSACTION READ ONLY;\n" end
  -- Existing execute transport trims terminal delimiters before ROW_COUNT().
  return header .. sql:gsub("[%s;]+$", "") .. "\n; SELECT ROW_COUNT();"
end

local conversions = {
  { "INSERT INTO t DEFAULT VALUES", "INSERT INTO t () VALUES ()" },
  { "insert into t default values", "insert into t () VALUES ()" },
  { "iNsErT InTo t DeFaUlT vAlUeS", "iNsErT InTo t () VALUES ()" },
  { "INSERT\tINTO\nt\r\nDEFAULT\t\nVALUES;", "INSERT\tINTO\nt\r\n()\t\nVALUES ();" },
  { "/* DEFAULT VALUES; */ INSERT INTO t DEFAULT/*keep*/VALUES -- DEFAULT VALUES\n",
    "/* DEFAULT VALUES; */ INSERT INTO t ()/*keep*/VALUES () -- DEFAULT VALUES\n" },
  { "INSERT INTO t DEFAULT-- keep DEFAULT VALUES;\nVALUES",
    "INSERT INTO t ()-- keep DEFAULT VALUES;\nVALUES ()" },
  { "INSERT INTO t DEFAULT# keep DEFAULT VALUES;\nVALUES",
    "INSERT INTO t ()# keep DEFAULT VALUES;\nVALUES ()" },
  { 'INSERT INTO "DEFAULT VALUES"."a""b" DEFAULT VALUES',
    'INSERT INTO "DEFAULT VALUES"."a""b" () VALUES ()' },
  { "INSERT INTO `DEFAULT VALUES`.`a``b` DEFAULT VALUES",
    "INSERT INTO `DEFAULT VALUES`.`a``b` () VALUES ()" },
  { "INSERT INTO 数据 DEFAULT VALUES", "INSERT INTO 数据 () VALUES ()" },
  { "INSERT IGNORE INTO t DEFAULT VALUES", "INSERT IGNORE INTO t () VALUES ()" },
  { "INSERT LOW_PRIORITY IGNORE INTO t DEFAULT VALUES", "INSERT LOW_PRIORITY IGNORE INTO t () VALUES ()" },
  { "INSERT t DEFAULT VALUES", "INSERT t () VALUES ()" },
  { "BEGIN; INSERT INTO t DEFAULT VALUES; INSERT INTO t VALUES ('DEFAULT VALUES;'); COMMIT;",
    "BEGIN; INSERT INTO t () VALUES (); INSERT INTO t VALUES ('DEFAULT VALUES;'); COMMIT;" },
  { "INSERT INTO t DEFAULT VALUES; INSERT INTO t default/**/values;",
    "INSERT INTO t () VALUES (); INSERT INTO t ()/**/VALUES ();" },
  { "INSERT INTO t PARTITION (`p0`,p1) DEFAULT VALUES",
    "INSERT INTO t PARTITION (`p0`,p1) () VALUES ()" },
  { "INSERT INTO t DEFAULT VALUES ON DUPLICATE KEY UPDATE v='DEFAULT VALUES'",
    "INSERT INTO t () VALUES () ON DUPLICATE KEY UPDATE v='DEFAULT VALUES'" },
  { "INSERT INTO t DEFAULT VALUES RETURNING id, 'DEFAULT VALUES'",
    "INSERT INTO t () VALUES () RETURNING id, 'DEFAULT VALUES'" },
  { "INSERT /*+ NO_INDEX_MERGE(t) */ INTO t DEFAULT VALUES",
    "INSERT /*+ NO_INDEX_MERGE(t) */ INTO t () VALUES ()" },
}

for i, case in ipairs(conversions) do
  test("execute translates default-row INSERT " .. i .. " without changing other bytes", function()
    local seen, result, err = execute(case[1])
    eq(err, nil, "no error")
    eq(result.affected, 1, "affected count retained")
    eq(seen.calls, 1, "exactly one invocation")
    eq(seen.opts.stdin, expected_stdin(case[2]), "stdin SQL")
  end)
end

local preserved = {
  "INSERT INTO t (v) VALUES ('DEFAULT VALUES')",
  "INSERT INTO t (v) VALUES ('a''; DEFAULT VALUES; INSERT INTO x DEFAULT VALUES')",
  'INSERT INTO "DEFAULT VALUES" ("DEFAULT VALUES") VALUES (1)',
  "INSERT INTO `DEFAULT VALUES` (`a``DEFAULT VALUES`) VALUES (1)",
  "UPDATE t SET v='DEFAULT VALUES' WHERE id=1",
  "SELECT 'DEFAULT VALUES; INSERT INTO t DEFAULT VALUES'",
  "SELECT 1; -- INSERT INTO t DEFAULT VALUES\nSELECT 2",
  "SELECT 1; # INSERT INTO t DEFAULT VALUES\nSELECT 2",
  "/* INSERT INTO t DEFAULT VALUES */ SELECT 1",
  "INSERT INTO t () VALUES ()",
  "INSERT INTO t SELECT DEFAULT VALUES",
  "UPDATE t SET v=DEFAULT VALUES",
  "INSERT INTO t DEFAULT_VALUES",
  "INSERT INTO t MYDEFAULT VALUES",
  "INSERT INTO t DEFAULT VALUES_SUFFIX",
  "INSERT INTO t DEFAULT VALUES$extra",
  "INSERT INTO t DEFAULT VALUES后缀",
  "INSERT INTO t DEFAULT VALUE",
  "INSERT INTO t DEFAULT VALUES nonsense",
  "INSERT INTO t (v) DEFAULT VALUES",
  "INSERT INTO t DEFAULT--not_a_comment\nVALUES",
  "INSERT INTO t DEFAULT VALUES--",
  "/*! INSERT INTO t DEFAULT VALUES */",
  "/*M! INSERT INTO t DEFAULT VALUES */",
  "INSERT /*! IGNORE */ INTO t DEFAULT VALUES",
  "INSERT INTO t DEFAULT /*!50000 VALUES */",
  "INSERT INTO t DEFAULT /*M! VALUES */ VALUES",
  "INSERT INTO t DEFAULT /* nested /* DEFAULT VALUES */ */ VALUES",
  "INSERT INTO t DEFAULT VALUES /* unfinished",
  "INSERT INTO t VALUES ('unfinished DEFAULT VALUES",
  "INSERT INTO t VALUES ('escaped\\'; INSERT INTO x DEFAULT VALUES;')",
  'INSERT INTO "escaped\\"; INSERT INTO x DEFAULT VALUES;" VALUES (1)',
  "INSERT INTO `escaped\\`; INSERT INTO x DEFAULT VALUES;` VALUES (1)",
  "SET sql_mode=''; INSERT INTO t VALUES ('a\\'; INSERT INTO x DEFAULT VALUES;')",
  "INSERT INTO t DEFAULT VALUES; SET @@SESSION.sql_mode=''; INSERT INTO t DEFAULT VALUES",
  "DELIMITER $$\nCREATE PROCEDURE p() BEGIN; INSERT INTO t DEFAULT VALUES; END$$",
  "INSERT /*+ \\d // */ INTO t DEFAULT VALUES",
  "INSERT INTO t DEFAULT VALUES; INSERT /*+ \\d // */ INTO t DEFAULT VALUES",
}

for i, input in ipairs(preserved) do
  test("execute preserves non-target/ambiguous SQL " .. i, function()
    local seen = execute(input)
    eq(seen.opts.stdin, expected_stdin(input), "stdin SQL unchanged")
    eq(seen.calls, 1, "no automatic retry")
  end)
end

test("rewrite retains private stdin/password transport and read-only setup", function()
  local seen = execute("INSERT INTO t DEFAULT VALUES", nil, { readonly = true })
  eq(seen.opts.stdin, expected_stdin("INSERT INTO t () VALUES ()", true), "read-only session")
  eq(seen.opts.env.MYSQL_PWD, "fixture_password", "password stays in environment")
  local argv = table.concat(seen.args, " ")
  assert(not argv:find("fixture_password", 1, true), "password leaked into argv")
  assert(not argv:find("INSERT", 1, true), "SQL leaked into argv")
end)

test("server SQL errors pass through unchanged with no retry", function()
  local seen, result, err = execute("INSERT INTO missing DEFAULT VALUES",
    { "", "ERROR 1146: fixture table is missing", 1 })
  eq(result, nil, "failed statement")
  eq(err, "ERROR 1146: fixture table is missing", "original server error")
  eq(seen.calls, 1, "one attempt only")
end)

for _, code in ipairs({ 124, 130 }) do
  test("interrupted/timed-out execution is never retried: " .. code, function()
    local seen, result, err = execute("INSERT INTO t DEFAULT VALUES",
      { "", "fixture interrupted: database outcome unknown", code })
    eq(result, nil, "no success result")
    eq(err, "fixture interrupted: database outcome unknown", "uncertainty preserved")
    eq(seen.calls, 1, "one attempt only")
  end)
end

test("ROW_COUNT parsing still uses the final result set", function()
  local _, result, err = execute("INSERT INTO t DEFAULT VALUES",
    { "ROW_COUNT()\n99\nROW_COUNT()\n3\n", "", 0 })
  eq(err, nil, "no error")
  eq(result.affected, 3, "final count")
end)

print(string.format("mysql_default_values_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
