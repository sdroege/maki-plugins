-- Spec for plugin/main.lua's reminder hysteresis against a fake maki host:
-- the marker file must keep the reminder quiet across a restart, re-arm only
-- on a compaction or a drop below a step, and never surface as a note.
-- Run: sh tests/run.sh (luajit only; maki's host dialect)

package.path = "lua/?.lua;" .. package.path

local failures = 0

local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(label, tostring(got), tostring(want)))
  end
end

local function check_nil(label, got)
  if got ~= nil then
    failures = failures + 1
    print(("FAIL %s: got %s, want nil"):format(label, tostring(got)))
  end
end

-- In-memory stand-in for the maki.fs surface main.lua touches.
local disk = { files = {}, dirs = {} }
local STATE = { dir = "/state" }
local notifications = {}

local function fs()
  local self = {}
  function self.joinpath(...)
    return table.concat({ ... }, "/")
  end
  function self.dirname(path)
    local parent = (path:gsub("/[^/]*$", ""))
    return parent ~= path and parent or nil
  end
  function self.metadata(path)
    if disk.dirs[path] then
      return { is_dir = true }
    end
    local content = disk.files[path]
    if content ~= nil then
      return { is_dir = false, size = #content, mtime = 0 }
    end
    return nil
  end
  function self.dir(root, opts)
    local depth = (opts and opts.depth) or 1
    local prefix = root .. "/"
    local entries = {}
    for path, ftype in pairs(disk.dirs) do
      local rel = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or nil
      if rel and #rel > 0 and select(2, rel:gsub("/", "/")) < depth then
        entries[#entries + 1] = { rel, "directory" }
      end
    end
    for path in pairs(disk.files) do
      local rel = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or nil
      if rel and #rel > 0 and select(2, rel:gsub("/", "/")) + 1 <= depth then
        entries[#entries + 1] = { rel, "file" }
      end
    end
    return entries
  end
  function self.mkdir(path)
    while path and not disk.dirs[path] do
      disk.dirs[path] = true
      path = self.dirname(path)
    end
    return true
  end
  function self.write(path, content)
    disk.files[path] = content
    return true
  end
  function self.append(path, content)
    disk.files[path] = (disk.files[path] or "") .. content
    return true
  end
  function self.read(path)
    return disk.files[path]
  end
  function self.rm(path, opts)
    if disk.files[path] or disk.dirs[path] then
      disk.files[path] = nil
      disk.dirs[path] = nil
      return true
    end
    if opts and opts.force then
      return true
    end
    return nil, "not found: " .. path
  end
  return self
end

local api = { autocmds = {}, tools = {} }

local maki = {
  env = { state_dir = function()
    return STATE.dir
  end },
  fs = fs(),
  api = {
    register_tool = function(tool)
      api.tools[tool.name] = tool
    end,
    register_prompt_hint = function() end,
    register_command = function() end,
    create_autocmd = function(events, opts)
      for _, name in ipairs(events) do
        api.autocmds[name] = opts.callback
      end
    end,
  },
  session = {
    notify = function(text, opts)
      notifications[#notifications + 1] = { text = text, opts = opts }
    end,
    current = function()
      return "S1"
    end,
  },
  ui = {
    flash = function() end,
    buf = function()
      return { on = function() end }
    end,
    open_editor = function()
      return 1
    end,
  },
}
_G.maki = maki

package.preload["maki.tool_view"] = function()
  return {
    new = function()
      return {
        set_highlight = function()
          return false
        end,
        append_text = function() end,
        finish = function() end,
      }
    end,
  }
end
package.preload["maki.list_picker"] = function()
  return { open = function() end }
end
package.preload["maki.toast"] = function()
  return { show = function() end }
end

-- A restart is a fresh process: fresh Lua state, same disk.
local function restart()
  api.autocmds = {}
  api.tools = {}
  dofile("plugin/main.lua")
end

local function fire(event, data)
  local callback = api.autocmds[event]
  if callback then
    callback({ event = event, data = data })
  end
end

local function tooldone(sid, size, window, subagent)
  fire("ToolDone", {
    session_id = sid,
    context_size = size,
    context_window = window,
    subagent = subagent,
  })
end

local function marker(sid)
  return "/state/sessions/notes/" .. sid .. "/.reminder"
end

local ctx = setmetatable({}, {
  __index = function(_, key)
    if key == "session_id" then
      return function()
        return "S1"
      end
    end
    if key == "tool_output_lines" then
      return function() end
    end
  end,
})

restart()

restart()

-- Crossing each step fires one nudge and updates the marker.
tooldone("S1", 42, 100)
check("first step notifies", #notifications, 1)
check("first step text", notifications[1].text:find("42% full", 1, true) ~= nil, true)
check("notify targets session", notifications[1].opts.session, "S1")
check("notify wakes", notifications[1].opts.wake, true)
check("notify displays", notifications[1].opts.display, true)
check("marker holds first step", disk.files[marker("S1")], "0.4")

tooldone("S1", 40, 100)
check("quiet between steps", #notifications, 1)
tooldone("S1", 65, 100)
check("second step notifies", #notifications, 2)
check("second step text", notifications[2].text:find("65% full", 1, true) ~= nil, true)
check("marker holds second step", disk.files[marker("S1")], "0.6")

-- A jump over several steps fires only the highest.
tooldone("S1", 90, 100)
check("jump notifies top only", #notifications, 3)
check("top step text", notifications[3].text:find("nearly full", 1, true) ~= nil, true)
check("marker holds top step", disk.files[marker("S1")], "0.8")

-- Hysteresis: quiet while the crossing stays outstanding.
tooldone("S1", 92, 100)
check("quiet while outstanding", #notifications, 3)

-- A subagent's ToolDone says nothing about this session.
tooldone("S1", 95, 100, true)
check("subagent ignored", #notifications, 3)

-- Falling below the top re-arms it but not the lower steps; the marker
-- shrinks with the state so a restart cannot resurrect a stale step.
tooldone("S1", 50, 100)
check("marker shrinks with state", disk.files[marker("S1")], "0.4")
tooldone("S1", 65, 100)
check("refires only the re-armed step", #notifications, 4)
check("second step refire text", notifications[4].text:find("65% full", 1, true) ~= nil, true)
tooldone("S1", 90, 100)
check("top refires after second", #notifications, 5)

-- The marker keeps the reminder quiet across a restart.
restart()
tooldone("S1", 90, 100)
check("restart stays quiet", #notifications, 5)

-- SessionEnd must not clear the marker: shutdown and reload fire it too.
fire("SessionEnd", { session_id = "S1", reason = "shutdown" })
tooldone("S1", 90, 100)
check("session end keeps the marker quiet", #notifications, 5)
check("marker still there", disk.files[marker("S1")], "0.8")

-- CompactionDone re-arms: context dropped, next crossing notifies again.
fire("CompactionDone", { session_id = "S1" })
check_nil("compaction clears marker", disk.files[marker("S1")])
tooldone("S1", 85, 100)
check("compaction re-arms", #notifications, 6)

-- A restart replants nothing: the re-armed reminder fires once more.
restart()
tooldone("S1", 85, 100)
check("restart after compaction stays quiet", #notifications, 6)

-- Markers are per session: S2 fires from scratch while S1 stays quiet.
tooldone("S2", 42, 100)
check("other session fires", #notifications, 7)
check("other session marker", disk.files[marker("S2")], "0.4")
tooldone("S1", 90, 100)
check("first session still quiet", #notifications, 7)

-- A stale marker clears on the first ToolDone below every step.
tooldone("S1", 20, 100)
check_nil("stale marker cleared", disk.files[marker("S1")])
tooldone("S1", 42, 100)
check("fires after stale clear", #notifications, 8)

-- The marker never surfaces as a note.
local tool = api.tools["notes"]
local out = tool.handler({ command = "append", path = "a.md", text = "hello" }, ctx)
check_nil("append works", out.is_error)
local listing = tool.handler({ command = "list" }, ctx)
check_nil("list hides the marker", listing:find(".reminder", 1, true))
check("list shows the note", listing:find("a.md", 1, true) ~= nil, true)

-- Without a state dir the reminder falls back to in-memory hysteresis.
STATE.dir = nil
restart()
tooldone("S3", 85, 100)
check("fires without state dir", #notifications, 9)
tooldone("S3", 90, 100)
check("hysteresis without state dir", #notifications, 9)
tooldone("S3", 50, 100)
tooldone("S3", 85, 100)
check("re-arms without state dir", #notifications, 10)
STATE.dir = "/state"

-- A legacy marker from the single-threshold plugin ("1", planted at 80%)
-- counts as the top step, so upgrading does not re-nudge old sessions.
disk.files[marker("S4")] = "1"
restart()
tooldone("S4", 90, 100)
check("legacy marker stays quiet", #notifications, 10)
tooldone("S4", 20, 100)
check_nil("legacy marker cleared below all steps", disk.files[marker("S4")])

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
