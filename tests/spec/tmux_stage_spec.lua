-- A real shell coordinator with a fake tmux boundary; never contacts a socket.
local pass, fail = 0, 0
for _, case in ipairs({
  { "no-prompt", 0, 0 },
  { "old-prompt-in-grid", 0, 0 },
  { "complete-with-prompt", 0, 1 },
  { "stage-during-capture", 0, 1 },
  { "late-prompt", 0, 1 },
  { "sticky-prompt", 0, 1 },
  { "failed-stage", 7, 0 },
  { "never-stage", 124, 0 },
  { "prompt-without-stage", 124, 1 },
  { "capture-error", 9, 0 },
}) do
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/bin", "p")
  vim.fn.writefile(vim.fn.readfile("tests/fixtures/fake_tmux_stage.sh"), root .. "/bin/tmux")
  vim.fn.setfperm(root .. "/bin/tmux", "rwx------")
  local ok, err = pcall(function()
    local result = vim.system({ "timeout", "0.6s", "bash", "tests/fixtures/wait_tmux_stage.sh",
      "fixture-session", "fixture-import-staged" }, { text = true, env = {
        PATH = root .. "/bin:/usr/bin:/bin",
        GRIP_FAKE_TMUX_ROOT = root,
        GRIP_FAKE_TMUX_CASE = case[1],
      } }):wait()
    assert(result.code == case[2], "unexpected coordinator exit: " .. result.code .. ": " .. result.stderr)
    local calls = vim.fn.filereadable(root .. "/calls") == 1 and vim.fn.readfile(root .. "/calls") or {}
    local enters, waits, complete, last_capture = 0, 0, false, nil
    for _, call in ipairs(calls) do
      if call:match("^capture:") then last_capture = call end
      if call == "wait:stage" then waits = waits + 1 end
      if call == "send:Enter" then
        enters = enters + 1
        assert(last_capture == "capture:prompt", "Enter was sent without a current hit-enter prompt")
      end
      if call == "stage-complete" then complete = true end
    end
    assert(enters == case[3], "incorrect prompt acknowledgement count: " .. enters)
    assert(vim.fn.filereadable(root .. "/current-prompt") == 0, "completed stage left a current hit-enter prompt open")
    assert(waits == 1 or (case[1] == "capture-error" and waits == 0), "stage signal was not consumed exactly once")
    assert((result.code == 0) == complete, "prompt/timeout was mistaken for actual stage completion")
    if vim.fn.filereadable(root .. "/waiter") == 1 then
      local pid = tonumber(vim.fn.readfile(root .. "/waiter")[1])
      assert(vim.wait(300, function() return not vim.uv.kill(pid, 0) end, 5), "stage waiter survived coordinator exit")
    end
  end)
  vim.fn.delete(root, "rf")
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. case[1] .. ": " .. tostring(err)) end
end
print(string.format("tmux_stage_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
