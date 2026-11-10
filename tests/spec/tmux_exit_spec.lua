-- Real child exit codes are recorded before the tmux launcher terminates.
local pass, fail = 0, 0
for _, case in ipairs({
  { "normal exit", { "bash", "-c", "exit 0" }, 0 },
  { "failed process", { "bash", "-c", "exit 7" }, 7 },
  { "signalled process", { "bash", "-c", 'kill -TERM "$$"' }, 143 },
  { "missing process", { "/nonexistent/grip-e2e-command" }, 127 },
}) do
  local receipt = vim.fn.tempname()
  local ok, err = pcall(function()
    local command = { "bash", "-e", "tests/fixtures/record_exit.sh", receipt }
    vim.list_extend(command, case[2])
    local result = vim.system(command, { text = true }):wait()
    assert(result.code == case[3], "unexpected launcher exit: " .. result.code .. ": " .. result.stderr)
    local recorded = vim.fn.readfile(receipt)
    assert(#recorded == 1 and recorded[1] == "exit:" .. case[3] .. ":done", "child status was not recorded")
  end)
  vim.fn.delete(receipt)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. case[1] .. ": " .. tostring(err)) end
end
print(string.format("tmux_exit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
