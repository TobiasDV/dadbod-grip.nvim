-- Independent behavior-level cases. Observe execute's real stdin boundary;
-- never call a rewrite helper or derive expectations from its implementation.
local adapters = require("dadbod-grip.adapters")
local mysql = require("dadbod-grip.adapters.mysql")
local pass, fail = 0, 0
local original_run, original_executable = adapters.run_cmd, vim.fn.executable
local sent, calls, reply, reply_error, reply_code
vim.fn.executable = function(name)
  if name == "mysql" then return 1 end
  return original_executable(name)
end
adapters.run_cmd = function(argv, _, opts)
  calls = calls + 1
  sent = { argv = argv, stdin = opts.stdin, env = opts.env }
  return reply or "ROW_COUNT()\n1\n", reply_error or "", reply_code or 0
end
local function test(id, fn)
  sent, calls, reply, reply_error, reply_code = nil, 0, nil, nil, nil
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. id .. ": " .. tostring(err)) end
end
local function eq(got, want)
  assert(vim.deep_equal(got, want), "expected " .. vim.inspect(want) .. ", got " .. vim.inspect(got))
end
local function execute(input)
  local result, err = mysql.execute(input, "mysql://fixture:stdin-only-test@127.0.0.1/adversarial")
  assert(result, err)
  eq(calls, 1)
  assert(not table.concat(sent.argv, " "):find("stdin-only-test", 1, true), "password leaked to argv")
  eq(sent.env.MYSQL_PWD, "stdin-only-test")
  local prefix = "SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\n"
  local suffix = "\n; SELECT ROW_COUNT();"
  eq(sent.stdin:sub(1, #prefix), prefix)
  eq(sent.stdin:sub(-#suffix), suffix)
  return sent.stdin:sub(#prefix + 1, -#suffix - 1), result
end

for i, input in ipairs({
  [[UPDATE t SET payload='DEFAULT VALUES']],
  [[INSERT INTO t(payload) VALUES('escaped '' quote; DEFAULT VALUES; tail')]],
  [[INSERT INTO t(`DEFAULT VALUES`) VALUES('safe')]],
  [[INSERT INTO "DEFAULT VALUES"(payload) VALUES('safe')]],
  [[UPDATE `odd``DEFAULT VALUES` SET payload='safe']],
  [[UPDATE "odd""DEFAULT VALUES" SET payload='safe']],
  "UPDATE t SET payload='safe' /* DEFAULT VALUES */",
  "UPDATE t SET payload='safe' -- DEFAULT VALUES\n",
  "UPDATE t SET payload='safe' # DEFAULT VALUES\n",
  [[/*!80000 INSERT INTO t DEFAULT VALUES */]],
  [[/*M!100100 INSERT INTO t DEFAULT VALUES */]],
  [[SELECT DEFAULT VALUES]],
  [[UPDATE t DEFAULT VALUES]],
  [[INSERT INTO t(DEFAULT) VALUES(1)]],
  [[INSERT INTO t DEFAULT VALUES_suffix]],
  [[INSERT INTO t DEFAULT_VALUES]],
  [[INSERT INTO t () VALUES ()]],
}) do
  test(string.format("M%02d protected SQL remains byte-for-byte", i), function()
    local actual = execute(input)
    eq(actual, input:gsub("[%s;]+$", ""))
  end)
end

test("M18 mixed-case real insert translates", function()
  local actual = execute("iNsErT InTo `t` dEfAuLt VaLuEs")
  eq(actual, "iNsErT InTo `t` () VALUES ()")
end)
test("M19 whitespace-separated real insert translates", function()
  local actual = execute("INSERT INTO t DEFAULT\n\tVALUES")
  assert(not actual:find("DEFAULT", 1, true), actual)
  assert(actual:match("INSERT INTO t%s+%(%)%s+VALUES%s+%(%)"), actual)
end)
test("M20 comments between real default-values tokens survive", function()
  local actual = execute("INSERT /* lead */ INTO `t` DEFAULT /* keep exactly */ VALUES")
  assert(actual:find("INSERT /* lead */ INTO `t`", 1, true), actual)
  assert(actual:find("/* keep exactly */", 1, true), actual)
  assert(not actual:find("DEFAULT", 1, true), actual)
  local _, empty_pairs = actual:gsub("%(%s*%)", "")
  eq(empty_pairs, 2)
end)
test("M21 batch rewrites real syntax and protects semicolons in data", function()
  local actual = execute([[INSERT INTO t(payload) VALUES('x; DEFAULT VALUES'); INSERT INTO t DEFAULT VALUES]])
  eq(actual, [[INSERT INTO t(payload) VALUES('x; DEFAULT VALUES'); INSERT INTO t () VALUES ()]])
end)
test("M22 server error stays an error with no automatic retry", function()
  reply, reply_error, reply_code = "", "ERROR 1064 synthetic syntax error", 1
  local result, err = mysql.execute("not valid DEFAULT VALUES", "mysql://fixture@127.0.0.1/adversarial")
  eq(result, nil)
  eq(err, reply_error)
  eq(calls, 1)
  assert(sent.stdin:find("not valid DEFAULT VALUES", 1, true), "erroring non-INSERT text was rewritten")
end)
test("M23 count is taken from last ROW_COUNT result", function()
  reply = "ROW_COUNT()\n72\nother\n0\nROW_COUNT()\n3\n"
  local _, result = execute("INSERT INTO t DEFAULT VALUES")
  eq(result.affected, 3)
end)

test("M24 optimizer-hint client command makes rewriting ambiguous", function()
  local input = "INSERT /*+ " .. string.char(92) .. "d // */ INTO t DEFAULT VALUES"
  local actual = execute(input)
  eq(actual, input)
end)

adapters.run_cmd, vim.fn.executable = original_run, original_executable
print(string.format("safety_adversarial_mysql_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
