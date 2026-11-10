-- Delete the selected saved profile through the real connection picker
-- callback, against isolated on-disk registries. Never touch home profiles,
-- Docker, or database clients. One case drives the native picker's D mapping.
local grip = require("dadbod-grip")
local paths = require("dadbod-grip.paths")
local ui = require("dadbod-grip.ui")
local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "") .. ": expected " .. vim.inspect(expected)
    .. ", got " .. vim.inspect(actual))
end

local function write(path, entries)
  paths.ensure_dir(vim.fn.fnamemodify(path, ":h"))
  vim.fn.writefile({ vim.json.encode(entries) }, path)
end

local function bytes(path)
  local fd = vim.uv.fs_open(path, "r", 384)
  if not fd then return nil end
  local size = assert(vim.uv.fs_fstat(fd)).size
  local content = size == 0 and "" or assert(vim.uv.fs_read(fd, size, 0))
  assert(vim.uv.fs_close(fd))
  return content
end

local function write_raw(path, content)
  paths.ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local fd = assert(vim.uv.fs_open(path, "w", 384))
  assert(vim.uv.fs_write(fd, content, 0))
  assert(vim.uv.fs_close(fd))
end

local function read(path)
  local content = assert(bytes(path), "registry exists")
  return vim.json.decode(content)
end

local function profile(id, name, url)
  return { id = id, name = name, url = url, type = "postgresql", env_file = "/fixture/credentials.env",
    mode = "ro", color = "orange", last_used = 17,
    attachments = { { alias = "fixture", dsn = "${FIXTURE_ATTACHMENT}" } } }
end

local function with_registry(fn)
  local root = vim.fn.tempname() .. "_connection_delete"
  local original = { project_root = paths.project_root, expand = vim.fn.expand, stdpath = vim.fn.stdpath,
    confirm = ui.confirm, notify = vim.notify, opts = grip.get_opts(), db = vim.g.db, dbs = vim.g.dbs }
  local modules = {}
  for _, name in ipairs({ "connections", "grip_picker", "sources.docker_localdb" }) do
    modules[name] = package.loaded["dadbod-grip." .. name]
  end
  local f = { root = root, local_path = root .. "/project/.grip/connections.json",
    global_path = root .. "/home/.grip/connections.json", custom_path = root .. "/custom/connections.json",
    discovered = {}, confirm = true, confirmations = 0, refreshes = 0, notices = {} }
  paths.ensure_dir(root .. "/project")
  paths.project_root = function() return root .. "/project" end
  vim.fn.expand = function(value, ...)
    if value == "~" then return root .. "/home" end
    return original.expand(value, ...)
  end
  vim.fn.stdpath = function(kind)
    if kind == "data" then return root .. "/data" end
    return original.stdpath(kind)
  end
  ui.confirm = function() f.confirmations = f.confirmations + 1; return f.confirm end
  vim.notify = function(message) table.insert(f.notices, message) end
  vim.g.db, vim.g.dbs = nil, nil
  grip.setup({})
  package.loaded["dadbod-grip.sources.docker_localdb"] = {
    fetch = function() return { connections = f.discovered } end,
  }
  package.loaded["dadbod-grip.grip_picker"] = { open = function(opts) f.picker = opts end }
  package.loaded["dadbod-grip.connections"] = nil
  f.connections = require("dadbod-grip.connections")
  function f.pick(predicate)
    f.connections.pick()
    for _, row in ipairs(f.picker.items) do if predicate(row) then return row end end
    error("selected row was not listed")
  end
  function f.delete(row)
    f.picker.on_delete(row, function(items) f.refreshes = f.refreshes + 1; f.refreshed = items end)
  end
  local ok, err = pcall(fn, f)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
  end
  paths.project_root, vim.fn.expand, vim.fn.stdpath = original.project_root, original.expand, original.stdpath
  ui.confirm, vim.notify = original.confirm, original.notify
  vim.g.db, vim.g.dbs = original.db, original.dbs
  grip.setup(original.opts)
  for _, name in ipairs({ "connections", "grip_picker", "sources.docker_localdb" }) do
    package.loaded["dadbod-grip." .. name] = modules[name]
  end
  vim.fn.delete(root, "rf")
  if not ok then error(err, 0) end
end

test("global selection deletes only that global profile despite a same-name local profile", function()
  with_registry(function(f)
    write(f.local_path, { profile("local-id", "same", "${LOCAL_URL}") })
    local survivor = profile("global-survivor", "keep", "${KEEP_URL}")
    write(f.global_path, { profile("global-id", "same", "${GLOBAL_URL}"), survivor })
    local before = bytes(f.local_path)
    f.delete(f.pick(function(c) return c.id == "global-id" end))
    eq(read(f.global_path), { survivor }, "only selected global removed, surviving fields preserved")
    eq(bytes(f.local_path), before, "unselected local file byte-identical")
    eq(f.refreshes, 1, "successful deletion refreshes once")
  end)
end)

test("local selection leaves a same-name global profile byte-identical", function()
  with_registry(function(f)
    local survivor = profile("local-survivor", "keep", "${KEEP_URL}")
    write(f.local_path, { profile("local-id", "same", "${LOCAL_URL}"), survivor })
    write(f.global_path, { profile("global-id", "same", "${GLOBAL_URL}") })
    local before = bytes(f.global_path)
    f.delete(f.pick(function(c) return c.id == "local-id" end))
    eq(read(f.local_path), { survivor }, "selected local removed, surviving fields preserved")
    eq(bytes(f.global_path), before, "unselected global file byte-identical")
  end)
end)

test("deleting a global-only profile does not create a project registry", function()
  with_registry(function(f)
    write(f.global_path, { profile("global-id", "only", "${GLOBAL_URL}") })
    f.delete(f.pick(function(c) return c.id == "global-id" end))
    eq(read(f.global_path), {}, "global profile removed")
    eq(bytes(f.local_path), nil, "no project shadow or empty registry created")
  end)
end)

test("same-URL local override is deleted locally even when it has a global display source", function()
  with_registry(function(f)
    write(f.local_path, { profile("local-id", "local", "${SHARED_URL}") })
    write(f.global_path, { profile("global-id", "global", "${SHARED_URL}") })
    local before = bytes(f.global_path)
    local row = f.pick(function(c) return c.id == "local-id" end)
    eq(row.source, "global", "exercise existing shared-URL badge behavior")
    f.delete(row)
    eq(read(f.local_path), {}, "local override removed")
    eq(bytes(f.global_path), before, "global original untouched")
  end)
end)

test("a captured global row stays global if a local override is added afterward", function()
  with_registry(function(f)
    write(f.global_path, { profile("global-id", "same", "${SHARED_URL}") })
    local row = f.pick(function(c) return c.id == "global-id" end)
    write(f.local_path, { profile("local-id", "same", "${SHARED_URL}") })
    local before = bytes(f.local_path)
    f.delete(row)
    eq(read(f.global_path), {}, "captured global profile removed from its original registry")
    eq(bytes(f.local_path), before, "new local override untouched")
  end)
end)

for _, scope in ipairs({ "local", "global" }) do
  test("duplicate names in " .. scope .. " registry delete only the selected URL/ID", function()
    with_registry(function(f)
      local path = scope == "local" and f.local_path or f.global_path
      local survivor = profile("keep", "same", "${KEEP_URL}")
      write(path, { profile("delete", "same", "${DELETE_URL}"), survivor })
      f.delete(f.pick(function(c) return c.id == "delete" end))
      eq(read(path), { survivor }, "same-name peer preserved")
    end)
  end)
end

test("legacy profiles without IDs are selected by their unique URL, never by shared name", function()
  with_registry(function(f)
    local survivor = { name = "same", url = "${KEEP_URL}", mode = "ro" }
    write(f.local_path, { { name = "same", url = "${DELETE_URL}" }, survivor })
    f.delete(f.pick(function(c) return c.url == "${DELETE_URL}" end))
    eq(read(f.local_path), { survivor }, "legacy same-name peer preserved")
  end)
end)

test("duplicate indistinguishable persisted identities refuse deletion without rewriting", function()
  with_registry(function(f)
    write(f.local_path, { profile("dup", "same", "${DUP_URL}"), profile("dup", "same", "${DUP_URL}") })
    local before = bytes(f.local_path)
    f.delete(f.pick(function(c) return c.id == "dup" end))
    eq(bytes(f.local_path), before, "ambiguous identity does not delete or deduplicate records")
    eq(f.refreshes, 0, "refused deletion does not report success by refreshing")
  end)
end)

test("deletion preserves unrelated duplicate URLs in the owning registry", function()
  with_registry(function(f)
    local one = profile("one", "one", "${KEEP_URL}")
    local two = profile("two", "two", "${KEEP_URL}")
    write(f.local_path, { profile("delete", "delete", "${DELETE_URL}"), one, two })
    f.delete(f.pick(function(c) return c.id == "delete" end))
    eq(read(f.local_path), { one, two }, "unselected records are not deduplicated")
  end)
end)

for _, scope in ipairs({ "local", "global", "custom" }) do
  test("deletion preserves all survivor extension fields in the " .. scope .. " registry", function()
    with_registry(function(f)
      local path = scope == "global" and f.global_path or scope == "custom" and f.custom_path or f.local_path
      if scope == "custom" then grip.setup({ connections_path = path }) end
      local survivor = profile("keep", "keep", "sqlite:keep")
      survivor.label = "preserve-this"
      survivor.custom = { owner = "fixture", flags = { true, false }, empty_object = vim.empty_dict(), empty_array = {} }
      survivor.source = "extension-source"
      write(path, { profile("delete", "delete", "sqlite:delete"), survivor })
      f.delete(f.pick(function(c) return c.id == "delete" end))
      eq(read(path), { survivor }, "surviving fields and JSON shapes remain intact")
    end)
  end)
end

for _, position in ipairs({ "first", "middle", "last", "only" }) do
  test("raw deletion of " .. position .. " entry preserves every surviving record byte", function()
    with_registry(function(f)
      local one = [[{ "id": "one", "name": "one", "url": "sqlite:one", "custom": {"big": 18446744073709551615, "text": "comma, bracket] and escaped\"quote"} }]]
      local two = [[{"id":"two","name":"two","url":"sqlite:two","extra":[[],{},null,false]}]]
      local three = [[{ "id":"three", "name":"three", "url":"sqlite:three", "label":"preserve" }]]
      local records = position == "only" and { two } or { one, two, three }
      local selected = position == "first" and "one" or position == "last" and "three" or "two"
      write_raw(f.local_path, "[\n  " .. table.concat(records, ",\n  ") .. "\n]\n")
      f.delete(f.pick(function(c) return c.id == selected end))
      local remaining = read(f.local_path)
      eq(#remaining, #records - 1, "exactly one record removed")
      local raw = bytes(f.local_path)
      for _, literal in ipairs(records) do
        local decoded = vim.json.decode(literal)
        if decoded.id ~= selected then
          assert(raw:find(literal, 1, true), "unselected literal survives without reconstruction")
        end
      end
      assert(not raw:find("_registry_path", 1, true), "internal registry provenance is never persisted")
    end)
  end)
end

test("deletion preserves valid unselected JSON records outside the profile schema", function()
  with_registry(function(f)
    local annotation = [[{"custom":{"owner":"fixture"},"label":"annotation without a URL"}]]
    local raw = "[" .. annotation .. ",null,false,7,[1,2],"
      .. [[{"id":"delete","name":"delete","url":"sqlite:delete"}]] .. "]"
    paths.ensure_dir(vim.fn.fnamemodify(f.local_path, ":h"))
    vim.fn.writefile({ raw }, f.local_path)
    f.delete(f.pick(function(c) return c.id == "delete" end))
    eq(bytes(f.local_path), "[" .. annotation .. ",null,false,7,[1,2]]\n",
      "only the selected profile and its separator are removed")
  end)
end)

test("a malformed or non-array top-level registry refuses stale deletion without writing", function()
  with_registry(function(f)
    write(f.local_path, { profile("delete", "delete", "sqlite:delete") })
    local row = f.pick(function(c) return c.id == "delete" end)
    for _, raw in ipairs({ "", "{", "null", "false", "42", '"text"',
      [[{"1":{"id":"delete","name":"delete","url":"sqlite:delete"}}]],
      [=[[{"id":"delete","name":"delete","url":"sqlite:delete"},]]=],
      '[\0{"id":"delete","name":"delete","url":"sqlite:delete"}]' }) do
      write_raw(f.local_path, raw)
      local before = bytes(f.local_path)
      f.delete(row)
      eq(bytes(f.local_path), before, "invalid top-level input stays byte-identical")
    end
    eq(f.refreshes, 0, "refused registry never reports a successful refresh")
  end)
end)

test("stale identity does not remove its same-name same-URL replacement", function()
  with_registry(function(f)
    write(f.global_path, { profile("old", "same", "${GLOBAL_URL}") })
    local row = f.pick(function(c) return c.id == "old" end)
    write(f.global_path, { profile("replacement", "same", "${GLOBAL_URL}") })
    local before = bytes(f.global_path)
    f.delete(row)
    eq(bytes(f.global_path), before, "replacement untouched")
    eq(bytes(f.local_path), nil, "no fallback local mutation")
    eq(f.refreshes, 0, "no success refresh for stale identity")
  end)
end)

test("an ID whose URL changed is stale and cannot remove the changed profile", function()
  with_registry(function(f)
    write(f.local_path, { profile("same-id", "same", "${OLD_URL}") })
    local row = f.pick(function(c) return c.id == "same-id" end)
    write(f.local_path, { profile("same-id", "same", "${NEW_URL}") })
    local before = bytes(f.local_path)
    f.delete(row)
    eq(bytes(f.local_path), before, "changed URL preserved")
    eq(f.refreshes, 0, "no success refresh for stale URL")
  end)
end)

for _, scope in ipairs({ "local", "global", "custom" }) do
  test("rounded numeric identity cannot delete a stale replacement in " .. scope .. " registry", function()
    with_registry(function(f)
      local path = scope == "global" and f.global_path or scope == "custom" and f.custom_path or f.local_path
      if scope == "custom" then grip.setup({ connections_path = path }) end
      write_raw(path, '[{"id":9007199254740992,"name":"same","url":"sqlite:fixture"}]')
      local row = f.pick(function(c) return c.name == "same" end)
      eq(type(row.id), "number", "exercise reader-exposed numeric identity")
      write_raw(path, '[{"id":9007199254740993,"name":"same","url":"sqlite:fixture"}]')
      local before = bytes(path)
      f.delete(row)
      eq(bytes(path), before, "different exact numeric ID cannot be treated as the selected identity")
      eq(f.refreshes, 0, "refused numeric identity does not report success")
    end)
  end)
end

test("picker refuses unsupported persisted identity types without writing", function()
  for _, literal in ipairs({ "17", "true", "false", "null", '{"opaque":"fixture"}', "[]", '""' }) do
    with_registry(function(f)
      write_raw(f.local_path, '[{"id":' .. literal .. ',"name":"same","url":"sqlite:fixture"}]')
      local row = f.pick(function(c) return c.name == "same" end)
      local before = bytes(f.local_path)
      f.delete(row)
      eq(bytes(f.local_path), before, "unsupported selected ID remains untouched: " .. literal)
      eq(f.refreshes, 0, "unsupported ID cannot report success")
    end)
  end
end)

test("name-only compatibility cannot bypass an unsupported persisted identity", function()
  for _, literal in ipairs({ "17", "true", "false", "null", '{"opaque":"fixture"}', "[]", '""' }) do
    with_registry(function(f)
      write_raw(f.local_path, '[{"id":' .. literal .. ',"name":"same","url":"sqlite:fixture"}]')
      local before = bytes(f.local_path)
      eq(f.connections.remove("same"), false, "legacy call refuses unsupported ID: " .. literal)
      eq(bytes(f.local_path), before, "legacy call leaves unsupported identity byte-identical")
    end)
  end
end)

test("an unselected numeric-ID profile survives safe deletion of a string-ID peer", function()
  with_registry(function(f)
    local survivor = '{"id":9007199254740993,"name":"keep","url":"sqlite:keep","label":"untouched"}'
    write_raw(f.local_path, '[{"id":"delete","name":"delete","url":"sqlite:delete"},' .. survivor .. ']')
    f.delete(f.pick(function(c) return c.id == "delete" end))
    eq(bytes(f.local_path), "[" .. survivor .. "]", "unsupported unselected identity is preserved verbatim")
    eq(f.refreshes, 1, "safe peer deletion succeeds")
  end)
end)

test("configured registry deletion touches neither default local nor global registry", function()
  with_registry(function(f)
    write(f.local_path, { profile("local", "same", "${SHARED_URL}") })
    write(f.global_path, { profile("global", "same", "${SHARED_URL}") })
    local survivor = profile("keep", "same", "${KEEP_URL}")
    write(f.custom_path, { profile("custom", "same", "${SHARED_URL}"), survivor })
    grip.setup({ connections_path = f.custom_path })
    local before_local, before_global = bytes(f.local_path), bytes(f.global_path)
    f.delete(f.pick(function(c) return c.id == "custom" end))
    eq(read(f.custom_path), { survivor }, "only selected custom profile removed")
    eq(bytes(f.local_path), before_local, "default local file untouched")
    eq(bytes(f.global_path), before_global, "global file untouched")
  end)
end)

test("changing connections_path invalidates a captured row without deleting from either registry", function()
  with_registry(function(f)
    write(f.local_path, { profile("same-id", "same", "${SHARED_URL}") })
    write(f.custom_path, { profile("same-id", "same", "${SHARED_URL}") })
    local row = f.pick(function(c) return c.id == "same-id" end)
    local before_local, before_custom = bytes(f.local_path), bytes(f.custom_path)
    grip.setup({ connections_path = f.custom_path })
    f.delete(row)
    eq(bytes(f.local_path), before_local, "old registry untouched")
    eq(bytes(f.custom_path), before_custom, "new registry untouched")
    eq(f.refreshes, 0, "changed registry cannot report success")
  end)
end)

test("cancelling deletion leaves both files byte-identical", function()
  with_registry(function(f)
    write(f.local_path, { profile("local", "same", "${LOCAL_URL}") })
    write(f.global_path, { profile("global", "same", "${GLOBAL_URL}") })
    f.confirm = false
    local before_local, before_global = bytes(f.local_path), bytes(f.global_path)
    f.delete(f.pick(function(c) return c.id == "global" end))
    eq(bytes(f.local_path), before_local, "cancel preserved local file")
    eq(bytes(f.global_path), before_global, "cancel preserved global file")
    eq(f.refreshes, 0, "cancel does not refresh")
  end)
end)

test("an unsaved active connection cannot delete a same-name saved profile", function()
  with_registry(function(f)
    write(f.local_path, { profile("local", "vim.g.db", "${LOCAL_URL}") })
    vim.g.db = "postgresql://fixture@invalid.example/ephemeral"
    local before = bytes(f.local_path)
    f.delete(f.pick(function(c) return c.url == vim.g.db end))
    eq(bytes(f.local_path), before, "ephemeral row cannot delete a saved namesake")
    eq(bytes(f.global_path), nil, "no global registry created")
    eq(f.confirmations, 0, "ephemeral row is not offered stored-profile deletion")
  end)
end)

test("discovered-only connections cannot delete same-name saved profiles", function()
  with_registry(function(f)
    write(f.local_path, { profile("local", "same", "${LOCAL_URL}") })
    f.discovered = { { name = "same", url = "postgresql://fixture@invalid.example/discovered", source = "docker" } }
    local before = bytes(f.local_path)
    f.delete(f.pick(function(c) return c.source == "docker" end))
    eq(bytes(f.local_path), before, "discovered-only row cannot delete namesake")
    eq(f.confirmations, 0, "no deletion confirmation for transient discovery")
  end)
end)

test("discovered collision can remove only its saved backing profile", function()
  with_registry(function(f)
    local url = "postgresql://fixture@invalid.example/discovered"
    write(f.local_path, { profile("saved", "saved name", url) })
    write(f.global_path, { profile("unrelated", "live name", "${GLOBAL_URL}") })
    f.discovered = { { name = "live name", url = url, source = "docker" } }
    local before = bytes(f.global_path)
    f.delete(f.pick(function(c) return c.url == url end))
    eq(read(f.local_path), {}, "saved backing removed by identity, despite displayed discovery name")
    eq(bytes(f.global_path), before, "global namesake unaffected")
    eq(#f.discovered, 1, "discovered container untouched")
  end)
end)

test("sentinel and local-file rows ignore deletion", function()
  with_registry(function(f)
    write(f.local_path, { profile("saved", "same", "${LOCAL_URL}") })
    f.connections.pick()
    local before = bytes(f.local_path)
    for _, flag in ipairs({ "_new", "_temp", "_section_header", "_local_file" }) do
      f.delete({ name = "same", url = "${LOCAL_URL}", [flag] = true })
    end
    eq(bytes(f.local_path), before, "all non-profile rows ignored")
    eq(f.confirmations, 0, "non-profile rows do not confirm deletion")
  end)
end)

test("built-in dismissal writes only its isolated hidden flag", function()
  with_registry(function(f)
    write(f.local_path, { profile("saved", "same", "${LOCAL_URL}") })
    f.connections.pick()
    local before = bytes(f.local_path)
    f.delete({ name = "same", url = "sqlite:/fixture/scratch.db", _builtin_id = "sqlite_scratch" })
    eq(vim.fn.filereadable(f.root .. "/data/grip/sqlite_scratch.hidden"), 1, "starter dismissal persisted")
    eq(bytes(f.local_path), before, "starter dismissal did not delete namesake")
  end)
end)

test("demo dismissal and cancellation preserve saved profiles", function()
  with_registry(function(f)
    write(f.local_path, { profile("saved", "Softrear Portal", "${LOCAL_URL}") })
    f.connections.pick()
    local before = bytes(f.local_path)
    f.confirm = false
    f.delete({ name = "Softrear Portal", url = "sqlite:/fixture/demo.db", _is_demo = true })
    eq(bytes(f.root .. "/data/grip/softrear.hidden"), nil, "cancel does not dismiss demo")
    f.confirm = true
    f.delete({ name = "Softrear Portal", url = "sqlite:/fixture/demo.db", _is_demo = true })
    eq(vim.fn.filereadable(f.root .. "/data/grip/softrear.hidden"), 1, "demo dismissal persisted")
    eq(bytes(f.local_path), before, "demo namesake untouched")
  end)
end)

test("name-only compatibility removes a unique local match and leaves global untouched", function()
  with_registry(function(f)
    write(f.local_path, { profile("local", "same", "${LOCAL_URL}") })
    write(f.global_path, { profile("global", "same", "${GLOBAL_URL}") })
    local before = bytes(f.global_path)
    eq(f.connections.remove("same"), true, "unique local name removed")
    eq(read(f.local_path), {}, "local profile removed")
    eq(bytes(f.global_path), before, "legacy API never falls back to global by name")
  end)
end)

test("name-only compatibility refuses duplicate names without rewriting", function()
  with_registry(function(f)
    write(f.local_path, { profile("one", "same", "${ONE_URL}"), profile("two", "same", "${TWO_URL}") })
    local before = bytes(f.local_path)
    eq(f.connections.remove("same"), false, "ambiguous legacy name refused")
    eq(bytes(f.local_path), before, "ambiguous legacy call preserves file")
  end)
end)

test("name-only missing match does not create or rewrite a registry", function()
  with_registry(function(f)
    write(f.global_path, { profile("global", "global only", "${GLOBAL_URL}") })
    local before = bytes(f.global_path)
    eq(f.connections.remove("global only"), false, "global-only legacy name refused")
    eq(bytes(f.local_path), nil, "missing legacy match does not create a local registry")
    eq(bytes(f.global_path), before, "global registry untouched")
  end)
end)

test("native picker D mapping deletes the selected global profile and renders the survivor", function()
  with_registry(function(f)
    write(f.local_path, { profile("local", "same-native-profile", "postgresql://fixture@local/keep") })
    write(f.global_path, { profile("global", "same-native-profile", "postgresql://fixture@global/remove") })
    local row = f.pick(function(c) return c.id == "global" end)
    local selected_index
    for index, item in ipairs(f.picker.items) do if item == row then selected_index = index end end
    package.loaded["dadbod-grip.grip_picker"] = nil
    f.connections.pick()
    local buf = vim.api.nvim_get_current_buf()
    local function press(key)
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if mapping.lhs == key then mapping.callback(); return end
      end
      error("native picker mapping missing: " .. key)
    end
    for _ = 2, selected_index do press("j") end
    local initial = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local _, initial_count = initial:gsub("same%-native%-profile", "")
    eq(initial_count, 2, "both namesakes rendered before deletion")
    local before = bytes(f.local_path)
    press("D")
    eq(read(f.global_path), {}, "native picker removed global row")
    eq(bytes(f.local_path), before, "native picker preserved local namesake")
    local rendered = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local _, remaining_count = rendered:gsub("same%-native%-profile", "")
    eq(remaining_count, 1, "only the surviving namesake rendered after refresh")
  end)
end)

print(string.format("\nconnection_delete_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
