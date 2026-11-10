-- Exercise actual write callers and immutable-result timing with disposable SQLite.
dofile("tests/minimal_init.lua")
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, data, ui = require("dadbod-grip.db"), require("dadbod-grip.data"), require("dadbod-grip.ui")
local history, editor = require("dadbod-grip.history"), require("dadbod-grip.editor")
local pass, fail = 0, 0
local confirm, ui_confirm, notify, show_error = vim.fn.confirm, ui.confirm, vim.notify, editor.show_error
local original_opts = vim.deepcopy(grip.get_opts())
vim.fn.confirm = function() return 1 end
ui.confirm = function() return true end
vim.notify = function() end
editor.show_error = function() end
local fixture = vim.fn.tempname() .. ".sqlite"
local url = "sqlite:" .. fixture
local seed = [[CREATE TABLE writes(id INTEGER PRIMARY KEY, value TEXT UNIQUE);
INSERT INTO writes VALUES(1,'one'),(2,'two');
CREATE TABLE parents(id INTEGER PRIMARY KEY, value TEXT);
INSERT INTO parents VALUES(1,'parent-one'),(2,'parent-two');
CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id), value TEXT);
INSERT INTO children VALUES(1,1,'child-one'),(2,2,'child-two');]]
local function cleanup()
  local buffers = {}
  for b in pairs(view._sessions) do buffers[#buffers + 1] = b end
  for _, b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, b, {force=true}) end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
  end
end
local function test(name, fn)
  cleanup()
  vim.fn.delete(fixture)
  vim.fn.system({"sqlite3", fixture}, seed)
  assert(vim.v.shell_error == 0, "fixture seed failed")
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      out[#out + 1] = {win=w, text=table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false), "\n")}
    end
  end
  return out
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false), "\n") end
local function grid()
  local buf = vim.api.nvim_get_current_buf()
  return buf, assert(view._sessions[buf], "current buffer is not a grid")
end
local function open(sql)
  grip.open(sql or "writes", url, {from_pad=true})
  return grid()
end
local function invoke(action)
  local map = vim.fn.maparg(require("dadbod-grip.keymaps").get(action), "n", false, true)
  assert(type(map.callback) == "function", "missing mapping " .. action)
  map.callback()
end
local function count()
  local r = assert(db.query("SELECT COUNT(*) FROM writes", url))
  return tonumber(r.rows[1][1])
end
-- Pass through to the real adapter. Removing a caller's write wrapper must fail
-- this assertion before it can execute SQL, rather than testing a fake database.
local function observed_write(fn)
  local execute, calls = db.execute, 0
  db.execute = function(...)
    calls = calls + 1
    local ws = floats()
    assert(#ws == 1 and ws[1].text:find("writing",1,true), "DB write needs exactly one writing float")
    vim.wait(35, function() return false end, 5)
    return execute(...)
  end
  local ok, err = pcall(fn)
  db.execute = execute
  assert(ok, err)
  assert(calls == 1, "write must execute exactly once")
  assert(#floats() == 0, "write float leaked")
end
local function stage(buf, session)
  view.apply_edit(buf, data.add_change(session.state,1,"value","changed"))
end
local function owned_write(buf, session)
  local ms = session._write_times and session._write_times[session.state.rows]
  assert(ms and ms >= 30, "successful result lost client write time")
  assert(text(buf):find("Write: ",1,true) and text(buf):find(" client",1,true), "distinct Write label missing")
  assert(text(buf):find(require("dadbod-grip.result_hints").query_time(session._query_times[session.state.rows], math.huge),1,true),
    "post-write SELECT lost its own Query duration")
  return ms
end

test("preview query, schema and staging share one float without executing SQL", function()
  local query, pks, cols, change = db.query, db.get_primary_keys, db.get_column_info, data.add_change
  local function covered()
    local ws = floats()
    assert(#ws == 1 and ws[1].text:find("previewing",1,true), "preview phase needs exactly one preview float")
  end
  db.query = function(...) covered(); return query(...) end
  db.get_primary_keys = function(...) covered(); return pks(...) end
  db.get_column_info = function(...) covered(); return cols(...) end
  data.add_change = function(...) covered(); return change(...) end
  local ok, err = pcall(open, "UPDATE writes SET value='changed' WHERE id=1")
  db.query, db.get_primary_keys, db.get_column_info, data.add_change = query,pks,cols,change
  assert(ok, err)
  local _, s = grid()
  assert(s.pending_mutation and data.count_staged(s.state) == 1, "preview did not preserve staging")
  assert(count() == 2 and #floats() == 0, "preview changed database or leaked float")
end)

test("original mutation executes once and reopened result owns separate Write and Query times", function()
  open("INSERT INTO writes VALUES(3,'three')")
  observed_write(function() invoke("grid_apply") end)
  local buf, s = grid()
  assert(count() == 3 and not s.pending_mutation, "mutation did not commit")
  owned_write(buf,s)
  local entries = history.list(5)
  local found
  for _, e in ipairs(entries) do if e.type == "insert" and e.url == url then found = e end end
  assert(found and found.elapsed_ms >= 30, "mutation history lost client write duration")
end)

test("newer table opened during mutation reload survives the old SELECT completion", function()
  open("INSERT INTO children VALUES(3,1,'third')")
  local query,changed = db.query,false
  local current_win=vim.api.nvim_get_current_win()
  local newer,newer_text
  db.query=function(...)
    local r,e=query(...)
    if not changed then
      changed=true
      grip.open("parents",url,{reuse_win=current_win,from_pad=true})
      newer=vim.api.nvim_get_current_buf()
      newer_text=text(newer)
    end
    return r,e
  end
  local ok,err=pcall(invoke,"grid_apply")
  db.query=query
  assert(ok,err)
  assert(vim.api.nvim_get_current_buf()==newer and text(newer)==newer_text,
    "old mutation reload replaced a newer table open")
  assert(not text(newer):find("Write:",1,true), "newer result inherited old mutation time")
end)

for _, target in ipairs({"pinned original window","new sibling"}) do
  test("mutation reload preserves " .. target .. " ownership and focus", function()
    local _,source=open("INSERT INTO children VALUES(3,1,'third')")
    source.pinned=true
    local win=vim.api.nvim_get_current_win()
    local query,changed=db.query,false
    local newer,newer_text
    db.query=function(...)
      local r,e=query(...)
      if not changed then
        changed=true
        grip.open("parents",url,target=="new sibling" and {force_split=true,from_pad=true}
          or {reuse_win=win,from_pad=true})
        newer=vim.api.nvim_get_current_buf()
        newer_text=text(newer)
      end
      return r,e
    end
    local ok,err=pcall(invoke,"grid_apply")
    db.query=query
    assert(ok,err)
    assert(vim.api.nvim_get_current_buf()==newer and text(newer)==newer_text,"mutation reload replaced/focused newer target")
  end)
end

test("mutation completion preserves a newer sibling window and its focus", function()
  local source,s=open("INSERT INTO children VALUES(3,1,'third')")
  local execute=db.execute
  local sibling,sibling_text
  db.execute=function(...)
    local r,e=execute(...)
    grip.open("parents",url,{force_split=true,from_pad=true})
    sibling=vim.api.nvim_get_current_buf()
    sibling_text=text(sibling)
    return r,e
  end
  local ok,err=pcall(invoke,"grid_apply")
  db.execute=execute
  assert(ok,err)
  assert(vim.api.nvim_get_current_buf()==sibling and text(sibling)==sibling_text, "mutation completion replaced/focused newer sibling")
  assert(view._sessions[source]==s and not s.pending_mutation, "known committed mutation remained executable")
end)

test("staged apply owns its immediate refreshed result and history duration", function()
  local buf, s = open()
  stage(buf,s)
  observed_write(function() invoke("grid_apply") end)
  assert(not data.has_changes(s.state), "success left staging")
  owned_write(buf,s)
  local entry = history.list(1)[1]
  assert(entry.type == "dml" and entry.elapsed_ms >= 30, "staged history missing write duration")
end)

test("import is local staging and only apply starts a write clock", function()
  local buf, s = open()
  local lines = {"id,value"}
  for i=10,109 do lines[#lines+1] = i .. ",import-" .. i end
  vim.fn.setreg('+', table.concat(lines,"\n"))
  grip.do_import("")
  assert(data.count_staged(s.state) == 100 and count() == 2 and #floats() == 0, "import wrote before apply")
  observed_write(function() invoke("grid_apply") end)
  assert(count() == 102, "bulk import did not commit all rows")
  owned_write(buf,s)
end)

test("failed mutation preserves pending SQL and closes its write float", function()
  local buf,s = open("INSERT INTO writes VALUES(1,'duplicate')")
  local pending, before = s.pending_mutation, text(buf)
  observed_write(function() invoke("grid_apply") end)
  assert(s.pending_mutation == pending and text(buf) == before and count() == 2, "failure changed preview")
  assert(not s._write_times or not s._write_times[s.state.rows], "failed write published a duration")
end)

test("failed staged transaction preserves edits and prior query timing without claiming rollback", function()
  local buf,s = open()
  local before_ms = s.elapsed_ms
  view.apply_edit(buf,data.add_change(s.state,1,"value","two"))
  local message
  editor.show_error = function(_,lines) message = table.concat(lines,"\n") end
  local ok,err = pcall(function() observed_write(function() invoke("grid_apply") end) end)
  editor.show_error = function() end
  assert(ok,err)
  assert(data.has_changes(s.state) and s.elapsed_ms == before_ms, "failed apply changed staging/time")
  assert(assert(db.query("SELECT value FROM writes WHERE id=1",url)).rows[1][1] == "one", "failed SQLite transaction changed rows")
  assert(message and not message:find("rolled back",1,true), "failure made an unconditional rollback claim")
end)

test("unexpected write exception closes float and preserves pending mutation", function()
  local _,s = open("INSERT INTO writes VALUES(3,'three')")
  local execute,calls = db.execute,0
  db.execute = function()
    calls = calls+1
    assert(#floats() == 1, "throwing write did not own a float")
    error("intentional write exception")
  end
  local ok,err = pcall(invoke,"grid_apply")
  db.execute = execute
  assert(not ok and tostring(err):find("intentional write exception",1,true), "write exception was swallowed")
  assert(calls == 1 and #floats() == 0 and s.pending_mutation and count() == 2, "exception retried/changed state/leaked float")
end)

test("cancelled apply creates no float or write and preserves staging", function()
  local buf,s = open()
  stage(buf,s)
  vim.fn.confirm = function() return 2 end
  invoke("grid_apply")
  vim.fn.confirm = function() return 1 end
  assert(data.has_changes(s.state) and count() == 2 and #floats() == 0, "cancel changed staging or leaked float")
  assert(not s._write_times or not s._write_times[s.state.rows], "cancel published timing")
end)

test("transaction undo gets its own write clock and refreshed ownership", function()
  local buf,s = open()
  stage(buf,s)
  invoke("grid_apply")
  assert(#s._txn_undo_stack == 1, "missing transaction undo")
  observed_write(function() invoke("grid_undo") end)
  assert(#s._txn_undo_stack == 0 and s.state.rows[1][2] == "one", "undo did not restore committed value")
  owned_write(buf,s)
end)

test("raw DDL fallback gets a write clock and executes only once", function()
  observed_write(function() grip.open("CREATE TABLE created(id INTEGER)",url) end)
  assert(db.query("SELECT * FROM created",url), "DDL was not executed")
end)

test("two-argument GripRename command uses the write clock", function()
  open()
  observed_write(function() vim.cmd("GripRename value renamed") end)
  assert(db.query("SELECT renamed FROM writes",url), "GripRename did not rename the column")
end)

test("GripRename completion preserves FK navigation and parent staging during its write", function()
  local buf,s=open("children")
  local execute=db.execute
  local expected,expected_text
  db.execute=function(...)
    local r,e=execute(...)
    local pos=assert(s._render.byte_positions[1].parent_id)
    vim.api.nvim_win_set_cursor(0,{s._render.data_start,pos.start})
    invoke("grid_fk_follow")
    view.apply_edit(buf,data.add_change(s.state,1,"value","parent-staged"))
    expected,expected_text=s.state,text(buf)
    return r,e
  end
  local ok,err=pcall(vim.cmd,"GripRename value renamed")
  db.execute=execute
  assert(ok,err)
  assert(s.state==expected and text(buf)==expected_text,"rename completion refreshed unrelated parent state")
end)

test("confirmed DDL helper does not refresh a newer FK result on completion", function()
  local buf,s=open("children")
  local execute,input=db.execute,ui.input
  local expected,expected_text
  ui.input=function() return "renamed" end
  db.execute=function(...)
    local r,e=execute(...)
    local pos=assert(s._render.byte_positions[1].parent_id)
    vim.api.nvim_win_set_cursor(0,{s._render.data_start,pos.start})
    invoke("grid_fk_follow")
    view.apply_edit(buf,data.add_change(s.state,1,"value","parent-staged"))
    expected,expected_text=s.state,text(buf)
    return r,e
  end
  local ok,err=pcall(function()
    require("dadbod-grip.ddl").rename_column("children","value",url,function() s.on_refresh(buf) end)
    vim.fn.maparg("y","n",false,true).callback()
  end)
  db.execute,ui.input=execute,input
  assert(ok,err)
  assert(s.state==expected and text(buf)==expected_text,"DDL callback refreshed unrelated parent state")
end)

for _, reason in ipairs({"command timed out","sqlite3 exited with code 124", "duckdb exited with code 130",
    "query interrupted; database outcome unknown", "query interrupted; database outcome unknown; process completion unknown"}) do
  test("unconfirmed write wait keeps pending mutation and reports unknown outcome: " .. reason, function()
    local buf,s = open("INSERT INTO writes VALUES(3,'three')")
    local before,execute,notify_fn = text(buf),db.execute,vim.notify
    local calls,message = 0,nil
    -- Force the adapter's precise boundary response; the native lock probe also
    -- exercises a real interrupted wait whose child later commits successfully.
    db.execute = function() calls=calls+1; return nil,reason end
    vim.notify = function(msg) message=msg end
    local ok,err = pcall(invoke,"grid_apply")
    db.execute,vim.notify = execute,notify_fn
    assert(ok,err)
    assert(calls == 1 and s.pending_mutation and text(buf) == before and #floats() == 0, "unconfirmed write changed state/retried/leaked float")
    assert(message and message:find("database outcome is unknown",1,true) and message:find(reason,1,true),
      "unconfirmed write was reported as a known failure: " .. tostring(message))
    assert(message:find("Refresh before retrying",1,true), "missing check-before-retry guidance")
  end)
end

test("ordinary database rejection keeps its original failure reason", function()
  local result,err = require("dadbod-grip.write").execute("INSERT INTO writes VALUES(1,'duplicate')",url)
  assert(not result and err:find("UNIQUE constraint failed",1,true) and not err:find("outcome is unknown",1,true),
    "ordinary database error misclassified as unknown outcome")
end)

for _, case in ipairs({
  {name="rename column", method="rename_column", args={"writes","value",url}, answers={"renamed"}, check="SELECT renamed FROM writes"},
  {name="rename table", method="rename_table", args={"writes",url}, answers={"renamed"}, check="SELECT * FROM renamed"},
  {name="add column", method="add_column", args={"writes",url}, answers={"added","text",""}, check="SELECT added FROM writes"},
  {name="drop column", method="drop_column", args={"writes","value",url}, answers={"value"}, check="SELECT id FROM writes"},
  {name="drop table", method="drop_table", args={"writes",url}, answers={"writes"}, check="SELECT name FROM sqlite_master WHERE name='writes'", empty=true},
  {name="create table", method="create_table", args={url}, answers={"created","id","INTEGER"}, check="SELECT id FROM created"},
}) do
  test("confirmed DDL helper " .. case.name .. " owns exactly one write clock", function()
    local input, index = ui.input,0
    ui.input = function() index=index+1; return case.answers[index] end
    local ok,err = pcall(function()
      require("dadbod-grip.ddl")[case.method](unpack(case.args))
      local accept = vim.fn.maparg("y","n",false,true)
      assert(type(accept.callback) == "function", "DDL confirmation missing")
      observed_write(accept.callback)
    end)
    ui.input = input
    assert(ok,err)
    local result = assert(db.query(case.check,url))
    if case.empty then assert(#result.rows == 0, "DDL did not change schema") end
  end)
end

test("nested write borrows the outer float and measures only its client call", function()
  local execute, calls = db.execute,0
  local outer
  db.execute = function(...)
    calls=calls+1
    vim.wait(90,function() return false end,5)
    local ws = floats()
    assert(#ws == 1 and ws[1].win == outer, "nested write created a second float")
    assert(ws[1].text:find("writing",1,true), "nested phase label missing")
    return execute(...)
  end
  local ok,err = pcall(ui.blocking,"outer operation",function()
    local outer_start = vim.uv.hrtime()
    outer = floats()[1].win
    vim.wait(120,function() return false end,5)
    local result,e,ms = require("dadbod-grip.write").execute("INSERT INTO writes VALUES(3,'three')",url)
    local total_ms = math.floor((vim.uv.hrtime() - outer_start) / 1e6)
    assert(result and not e and ms >= 80 and ms <= total_ms - 80, "write measurement includes outer wait or loses returns")
  end)
  db.execute = execute
  assert(ok,err)
  assert(calls == 1 and count() == 3 and #floats() == 0, "nested write retried or leaked float")
end)

if vim.fn.executable("duckdb") == 1 then
  test("local file writeback owns a write clock and a distinct refreshed result time", function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({"id,value","1,one","2,two"},file)
    local ok,err = pcall(function()
      grip.open(file,nil,{write=true,from_pad=true})
      local buf,s = grid()
      stage(buf,s)
      observed_write(function() invoke("grid_apply") end)
      assert(table.concat(vim.fn.readfile(file),"\n"):find("changed",1,true), "file was not written")
      owned_write(buf,s)
      local entry = history.list(1)[1]
      assert(entry.type == "writeback" and entry.elapsed_ms >= 30, "writeback history missing duration")
    end)
    vim.fn.delete(file)
    assert(ok,err)
  end)

  test("uncertain file write shows its full reason and preserved staging in the real error popup", function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({"id,value","1,one","2,two"},file)
    local execute = db.execute
    local ok,err = pcall(function()
      grip.open(file,nil,{write=true,from_pad=true})
      local buf,s = grid()
      stage(buf,s)
      db.execute = function() return nil,"command timed out" end
      editor.show_error = show_error
      invoke("grid_apply")
      local ws = floats()
      assert(#ws == 1 and ws[1].text:find("database outcome is unknown",1,true)
        and ws[1].text:find("command timed out",1,true), "unknown write popup lost its reason")
      assert(data.has_changes(s.state), "unconfirmed file write cleared staging")
    end)
    db.execute,editor.show_error = execute,function() end
    vim.fn.delete(file)
    assert(ok,err)
  end)
end

test("write time stays with matching rows through metadata and later SELECT", function()
  local buf,s = open()
  stage(buf,s)
  observed_write(function() invoke("grid_apply") end)
  local original = s.state
  owned_write(buf,s)
  view.switch_view(buf,"columns")
  assert(not text(buf):find("Write:",1,true), "metadata inherited write time")
  view.switch_view(buf,"records")
  owned_write(buf,s)
  s.on_refresh(buf)
  assert(not text(buf):find("Write:",1,true), "unrelated SELECT inherited write time")
  view.render(buf,original)
  owned_write(buf,s)
end)

test("successful write with failed refresh preserves prior result and duration", function()
  local buf,s = open()
  local before_rows, before_ms = s.state.rows, s.elapsed_ms
  stage(buf,s)
  -- Let the real write run, then fail only the refresh SELECT.
  local query = db.query
  db.query = function() return nil,"intentional refresh failure" end
  local ok,err = pcall(function() observed_write(function() invoke("grid_apply") end) end)
  db.query = query
  assert(ok,err)
  assert(s.state.rows == before_rows and s.elapsed_ms == before_ms, "failed refresh replaced result time")
  assert(not text(buf):find("Write:",1,true), "failed refresh attached write time to old rows")
  assert(assert(db.query("SELECT value FROM writes WHERE id=1",url)).rows[1][1] == "changed", "write did not commit")
end)

test("newer nested SELECT cannot inherit an older write completion", function()
  local buf,s = open()
  stage(buf,s)
  local query, nested = db.query,false
  db.query = function(...)
    local r,e = query(...)
    if not nested then nested=true; s.on_refresh(buf) end
    return r,e
  end
  local ok,err = pcall(function() invoke("grid_apply") end)
  db.query = query
  assert(ok,err)
  assert(not text(buf):find("Write:",1,true), "stale write completion attached duration to newer rows")
end)

test("a closed grid cannot receive its write refresh completion", function()
  local buf,s = open()
  stage(buf,s)
  local query = db.query
  db.query = function(...)
    local r,e = query(...)
    vim.api.nvim_buf_delete(buf,{force=true})
    return r,e
  end
  local ok,err = pcall(function() invoke("grid_apply") end)
  db.query = query
  assert(ok,err)
  assert(not view._sessions[buf] and not vim.api.nvim_buf_is_valid(buf), "closed grid resurrected")
  assert(not next(s._write_times), "closed session received stale write timing")
  assert(assert(db.query("SELECT value FROM writes WHERE id=1",url)).rows[1][1] == "changed", "write did not commit")
end)

for _, action in ipairs({"FK","metadata","requery","closed","sibling","new edit"}) do
  test("write completion preserves navigation during execute: " .. action, function()
    local buf,s = open("children")
    stage(buf,s)
    local execute = db.execute
    local changed,expected_state,expected_text,sibling
    db.execute = function(...)
      local r,e = execute(...)
      if not changed then
        changed = true
        if action == "FK" then
          local pos = assert(s._render.byte_positions[1].parent_id)
          vim.api.nvim_win_set_cursor(0,{s._render.data_start,pos.start})
          invoke("grid_fk_follow")
          view.apply_edit(buf,data.add_change(s.state,1,"value","parent-staged"))
        elseif action == "metadata" then view.switch_view(buf,"columns")
        elseif action == "requery" then
          s.on_requery(buf,require("dadbod-grip.query").toggle_sort(s.query_spec,"id"))
          view.apply_edit(buf,data.add_change(s.state,1,"value","new-query-staged"))
        elseif action == "closed" then vim.api.nvim_buf_delete(buf,{force=true})
        elseif action == "new edit" then view.apply_edit(buf,data.add_change(s.state,2,"value","newly-staged"))
        else
          grip.open("parents",url,{force_split=true,from_pad=true})
          sibling = vim.api.nvim_get_current_buf()
        end
        expected_state = s.state
        expected_text = action ~= "closed" and text(sibling or buf)
      end
      return r,e
    end
    local ok,err = pcall(invoke,"grid_apply")
    db.execute = execute
    assert(ok,err)
    if action == "closed" then
      assert(not view._sessions[buf] and not vim.api.nvim_buf_is_valid(buf), "closed owner resurrected")
    elseif action == "sibling" then
      assert(vim.api.nvim_get_current_buf() == sibling and text(sibling) == expected_text, "write completion changed sibling")
    else
      assert(s.state == expected_state and text(buf) == expected_text, "stale write completion replaced navigated state/staging")
    end
    assert(assert(db.query("SELECT value FROM children WHERE id=1",url)).rows[1][1] == "changed", "original write did not commit")
  end)
end

for _, action in ipairs({"FK","metadata","new edit"}) do
  test("write SELECT refresh preserves newer input: " .. action, function()
    local buf,s = open("children")
    stage(buf,s)
    local query = db.query
    local changed,expected_state,expected_text
    db.query = function(...)
      local r,e = query(...)
      if not changed then
        changed=true
        if action == "FK" then
          local pos=assert(s._render.byte_positions[1].parent_id)
          vim.api.nvim_win_set_cursor(0,{s._render.data_start,pos.start})
          invoke("grid_fk_follow")
        elseif action == "metadata" then view.switch_view(buf,"columns")
        else view.apply_edit(buf,data.add_change(s.state,2,"value","newly-staged")) end
        expected_state,expected_text=s.state,text(buf)
      end
      return r,e
    end
    local ok,err=pcall(invoke,"grid_apply")
    db.query=query
    assert(ok,err)
    assert(s.state == expected_state and text(buf) == expected_text, "write refresh overwrote newer view/edit")
    assert(not text(buf):find("Write:",1,true), "stale refresh published Write duration")
  end)
end

test("failed later write preserves the earlier result's owned Write time", function()
  local buf,s = open()
  stage(buf,s)
  observed_write(function() invoke("grid_apply") end)
  local rows,ms = s.state.rows,s._write_times[s.state.rows]
  view.apply_edit(buf,data.add_change(s.state,1,"value","two"))
  observed_write(function() invoke("grid_apply") end)
  assert(s.state.rows == rows and s._write_times[rows] == ms and data.has_changes(s.state), "failure replaced timing/staging")
  owned_write(buf,s)
end)

test("hiding Write display keeps the underlying measured duration", function()
  local buf,s = open()
  stage(buf,s)
  observed_write(function() invoke("grid_apply") end)
  local ms = s._write_times[s.state.rows]
  -- This branch consumes the option supplied by the separate visibility change.
  local get_opts = grip.get_opts
  grip.get_opts = function() return vim.tbl_extend("force",get_opts(),{show_result_time=false}) end
  view.render(buf,s.state)
  local hidden = not text(buf):find("Write:",1,true)
  grip.get_opts = get_opts
  view.render(buf,s.state)
  assert(hidden and s._write_times[s.state.rows] == ms, "visibility changed write measurement")
  owned_write(buf,s)
end)

cleanup()
vim.fn.delete(fixture)
vim.fn.confirm, ui.confirm, vim.notify, editor.show_error = confirm,ui_confirm,notify,show_error
grip.setup(original_opts)
print(string.format("write_timing_spec: %d passed, %d failed", pass,fail))
if fail > 0 then os.exit(1) end
