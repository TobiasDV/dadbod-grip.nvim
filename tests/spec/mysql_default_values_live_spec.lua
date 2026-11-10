-- Run only against the explicitly assigned test database. All writes target
-- per-process probe tables, which are dropped even when an assertion fails.
local url = vim.env.GRIP_TEST_MYSQL_URL
if not url or url == "" then
  print("SKIP: mysql_default_values_live_spec (GRIP_TEST_MYSQL_URL not set)")
  print("mysql_default_values_live_spec: 0 passed, 0 failed (skipped)")
  return
end
assert(vim.fn.executable("mysql") == 1, "mysql test client unavailable")
local mysql = require("dadbod-grip.adapters.mysql")
local pass, fail = 0, 0
local name = "grip_default_lex_" .. vim.uv.os_getpid()
local table_name = '"' .. name .. '"'
local odd_name = '"' .. name .. ' DEFAULT VALUES"'
local version = assert(mysql.query("SELECT VERSION()", url)).rows[1][1]
local mariadb = version:find("MariaDB", 1, true) ~= nil

local function test(label, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label .. ": " .. tostring(err)) end
end

local function eq(actual, expected)
  assert(actual == expected, "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function last_payload()
  return assert(mysql.query("SELECT payload FROM " .. table_name .. " ORDER BY id DESC LIMIT 1", url)).rows[1][1]
end

local ok, err = pcall(function()
  -- The query path does no compatibility translation. Use it for fixture DDL
  -- so the baseline can create identifiers that its execute path corrupts.
  assert(mysql.query("CREATE TABLE " .. table_name .. " (id INT AUTO_INCREMENT PRIMARY KEY, "
    .. "payload VARCHAR(200) DEFAULT 'fixture-default', \"DEFAULT VALUES\" VARCHAR(200))", url))
  assert(mysql.query("CREATE TABLE " .. odd_name .. " (id INT AUTO_INCREMENT PRIMARY KEY)", url))

  test("quoted data keeps DEFAULT VALUES and escaped delimiters", function()
    assert(mysql.execute("INSERT INTO " .. table_name .. " (payload) VALUES ('it''s; DEFAULT VALUES; tail')", url))
    eq(last_payload(), "it's; DEFAULT VALUES; tail")
  end)

  test("backslash text and keyword-like data remain literal", function()
    assert(mysql.execute("INSERT INTO " .. table_name .. " (payload) VALUES ('back\\slash DEFAULT VALUES')", url))
    eq(last_payload(), "back\\slash DEFAULT VALUES")
  end)

  for _, syntax in ipairs({ "DEFAULT VALUES", "dEfAuLt vAlUeS", "DEFAULT\n\tVALUES",
    "DEFAULT/* keep DEFAULT VALUES; */VALUES", "DEFAULT-- keep DEFAULT VALUES;\nVALUES",
    "DEFAULT# keep DEFAULT VALUES;\nVALUES" }) do
    test("default row executes: " .. syntax, function()
      local result = assert(mysql.execute("INSERT INTO " .. table_name .. " " .. syntax, url))
      eq(result.affected, 1)
      eq(last_payload(), "fixture-default")
    end)
  end

  test("batch translates real syntax and preserves a semicolon inside data", function()
    local result = assert(mysql.execute("INSERT INTO " .. table_name .. " DEFAULT VALUES; INSERT INTO "
      .. table_name .. " (payload) VALUES ('DEFAULT VALUES; INSERT INTO t DEFAULT VALUES')", url))
    eq(result.affected, 1)
    eq(last_payload(), "DEFAULT VALUES; INSERT INTO t DEFAULT VALUES")
  end)

  test("ANSI quoted identifiers remain exact", function()
    assert(mysql.execute("INSERT INTO " .. table_name .. " (\"DEFAULT VALUES\") VALUES ('ansi')", url))
    local result = assert(mysql.query("SELECT \"DEFAULT VALUES\" FROM " .. table_name .. " ORDER BY id DESC LIMIT 1", url))
    eq(result.rows[1][1], "ansi")
  end)

  test("backtick identifiers remain exact", function()
    assert(mysql.execute("INSERT INTO " .. table_name .. " (`DEFAULT VALUES`) VALUES ('backtick')", url))
    local result = assert(mysql.query("SELECT `DEFAULT VALUES` FROM " .. table_name .. " ORDER BY id DESC LIMIT 1", url))
    eq(result.rows[1][1], "backtick")
  end)

  test("table identifier and actual syntax are distinguished", function()
    local result = assert(mysql.execute("INSERT INTO " .. odd_name .. " DEFAULT VALUES", url))
    eq(result.affected, 1)
    eq(assert(mysql.query("SELECT COUNT(*) FROM " .. odd_name, url)).rows[1][1], "1")
  end)

  test("MySQL executable comment contents remain untouched", function()
    assert(mysql.execute("/*! INSERT INTO " .. table_name .. " (payload) VALUES ('DEFAULT VALUES') */", url))
    eq(last_payload(), "DEFAULT VALUES")
  end)

  test("unsupported syntax inside executable comments stays a server error", function()
    local result, message = mysql.execute("/*! INSERT INTO " .. table_name .. " DEFAULT VALUES */", url)
    eq(result, nil)
    assert(message and message:find("1064", 1, true), "original SQL syntax error expected")
  end)

  test("genuine SQL errors surface without becoming successful inserts", function()
    local before = assert(mysql.query("SELECT COUNT(*) FROM " .. table_name, url)).rows[1][1]
    local result, message = mysql.execute("INSERT INTO " .. table_name .. " DEFAULT VALUES nonsense", url)
    eq(result, nil)
    assert(message and message:find("1064", 1, true), "SQL syntax error expected")
    eq(assert(mysql.query("SELECT COUNT(*) FROM " .. table_name, url)).rows[1][1], before)
  end)

  if mariadb then
    test("MariaDB executable comment contents remain untouched", function()
      assert(mysql.execute("/*M! INSERT INTO " .. table_name .. " (payload) VALUES ('DEFAULT VALUES') */", url))
      eq(last_payload(), "DEFAULT VALUES")
    end)
    test("MariaDB RETURNING keeps default-row compatibility", function()
      assert(mysql.execute("INSERT INTO " .. table_name .. " DEFAULT VALUES RETURNING id", url))
      eq(last_payload(), "fixture-default")
    end)
  end
end)

local _, cleanup_error = mysql.query("DROP TABLE IF EXISTS " .. table_name .. ", " .. odd_name, url)
if not ok then fail = fail + 1; print("FAIL: fixture setup: " .. tostring(err)) end
if cleanup_error then fail = fail + 1; print("FAIL: fixture cleanup: " .. tostring(cleanup_error)) end
print("mysql_default_values_live_spec server: " .. version)
print(string.format("mysql_default_values_live_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
