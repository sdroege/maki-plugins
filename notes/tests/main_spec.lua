-- Spec for plugin/main.lua against a fake maki host: the marker file must
-- keep the TurnComplete reminder quiet across a restart, re-arm only on a
-- compaction or a drop below a step, and never surface as a note, and the
-- agent.compact.before layer must defer every automatic ask of a main
-- session with a nudge and offer the notes read-back in the same verdict.
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
-- What the ToolView stub was asked to render, newest last.
local viewed = {}
local exts = {}

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

local api = { autocmds = {}, tools = {}, slots = {} }

local CTX_USAGE
local CTX_ERR

local maki = {
  -- Gate for context_usage: answer as a host new enough to have ctx:context().
  version = setmetatable({
    gt = function()
      return true
    end,
  }, {
    __call = function()
      return { major = 0, minor = 7, patch = 5 }
    end,
  }),
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
    set_slot = function(name, fn)
      api.slots[name] = fn
    end,
  },
  session = {
    notify = function(text, opts)
      notifications[#notifications + 1] = { text = text, opts = opts }
    end,
    current = function()
      return "S1"
    end,
    data_dir = function(opts)
      if not STATE.dir then
        return nil, "cannot resolve state dir"
      end
      return STATE.dir .. "/sessions/data/" .. ((opts and opts.session) or "S1") .. "/notes"
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
        set_highlight = function(_, text, ext)
          viewed[#viewed + 1] = text
          exts[#exts + 1] = ext
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
  api.slots = {}
  dofile("plugin/main.lua")
end

local function fire(event, data)
  local callback = api.autocmds[event]
  if callback then
    callback({ event = event, data = data })
  end
end

local function turncomplete(sid, size, window, id)
  fire("TurnComplete", {
    session_id = sid,
    context_size = size,
    context_window = window,
    id = id,
  })
end

local function compact_before(value, ctx)
  local pass_through = function(v) return v end
  return api.slots["agent.compact.before"](pass_through, value, ctx)
end

local function marker(sid)
  return "/state/sessions/data/" .. sid .. "/notes/.reminder"
end

local ctx = setmetatable({}, {
  __index = function(_, key)
    if key == "session_id" then
      return function()
        return "S1"
      end
    end
    if key == "context" then
      return function()
        if CTX_ERR then
          return nil, CTX_ERR
        end
        return CTX_USAGE
      end
    end
    if key == "tool_output_lines" then
      return function() end
    end
  end,
})

restart()

-- Crossing each step fires one nudge and updates the marker.
turncomplete("S1", 42, 100)
check("first step notifies", #notifications, 1)
check("first step text", notifications[1].text:find("42% used", 1, true) ~= nil, true)
check("notify targets session", notifications[1].opts.session, "S1")
check("notify wakes", notifications[1].opts.wake, true)
check("notify displays", notifications[1].opts.display, notifications[1].text)
check("marker holds first step", disk.files[marker("S1")], "0.4")

turncomplete("S1", 40, 100)
check("quiet between steps", #notifications, 1)
turncomplete("S1", 65, 100)
check("second step notifies", #notifications, 2)
check("second step text", notifications[2].text:find("65% used", 1, true) ~= nil, true)
check("marker holds second step", disk.files[marker("S1")], "0.6")

-- The last save step keeps its urgency, and a jump over several steps
-- fires only the highest: the compact ask replaces the save ask.
turncomplete("S1", 83, 100)
check("last save step notifies", #notifications, 3)
check("nearly full text", notifications[3].text:find("nearly full", 1, true) ~= nil, true)
check("marker holds last save step", disk.files[marker("S1")], "0.8")
turncomplete("S1", 90, 100)
check("jump notifies compact step", #notifications, 4)
check("compact step text", notifications[4].text:find("call compact", 1, true) ~= nil, true)
check("marker holds compact step", disk.files[marker("S1")], "0.85")

-- Hysteresis: quiet while the crossing stays outstanding.
turncomplete("S1", 92, 100)
check("quiet while outstanding", #notifications, 4)

-- A subagent's TurnComplete carries its own gauge and task id, so the nudge
-- goes to that subagent and leaves the parent's state and marker alone.
turncomplete("S9", 55, 100, "T1")
check("subagent first step notifies", #notifications, 5)
check("subagent nudge targets the task", notifications[5].opts.task, "T1")
check("subagent nudge targets the session", notifications[5].opts.session, "S9")
check("subagent nudge wakes", notifications[5].opts.wake, true)
check_nil("subagent leaves no marker", disk.files[marker("S9")])
turncomplete("S9", 59, 100, "T1")
check("subagent hysteresis holds", #notifications, 5)
turncomplete("S9", 99, 100, "T1")
check("subagent top step notifies", #notifications, 6)
check("subagent top text", notifications[6].text:find("call compact", 1, true) ~= nil, true)
turncomplete("S9", 99, 100, "T1")
check("subagent stays quiet at the top", #notifications, 6)

-- SessionEnd drops the subagent's state with the session that opened it.
fire("SessionEnd", { session_id = "S9" })
turncomplete("S9", 42, 100, "T1")
check("subagent state dies with the session", #notifications, 7)

-- Falling below the top re-arms it but not the lower steps; the marker
-- shrinks with the state so a restart cannot resurrect a stale step.
turncomplete("S1", 50, 100)
check("marker shrinks with state", disk.files[marker("S1")], "0.4")
turncomplete("S1", 65, 100)
check("refires only the re-armed step", #notifications, 8)
check("second step refire text", notifications[8].text:find("65% used", 1, true) ~= nil, true)
turncomplete("S1", 90, 100)
check("top refires after second", #notifications, 9)

-- The marker keeps the reminder quiet across a restart.
restart()
turncomplete("S1", 90, 100)
check("restart stays quiet", #notifications, 9)

-- SessionEnd must not clear the marker: shutdown and reload fire it too.
fire("SessionEnd", { session_id = "S1", reason = "shutdown" })
turncomplete("S1", 90, 100)
check("session end keeps the marker quiet", #notifications, 9)
check("marker still there", disk.files[marker("S1")], "0.85")

-- CompactionDone re-arms: context dropped, next crossing notifies again.
fire("CompactionDone", { session_id = "S1" })
check_nil("compaction clears marker", disk.files[marker("S1")])
turncomplete("S1", 85, 100)
check("compaction re-arms", #notifications, 10)

-- A restart replants nothing: the re-armed reminder fires once more.
restart()
turncomplete("S1", 85, 100)
check("restart after compaction stays quiet", #notifications, 10)

-- Markers are per session: S2 fires from scratch while S1 stays quiet.
turncomplete("S2", 42, 100)
check("other session fires", #notifications, 11)
check("other session marker", disk.files[marker("S2")], "0.4")
turncomplete("S1", 90, 100)
check("first session still quiet", #notifications, 11)

-- A stale marker clears on the first TurnComplete below every step.
turncomplete("S1", 20, 100)
check_nil("stale marker cleared", disk.files[marker("S1")])
turncomplete("S1", 42, 100)
check("fires after stale clear", #notifications, 12)

-- The marker never surfaces as a note. `text` is the name this tool advertised
-- before it took maki's `content`, so it is the legacy spelling proven here.
local tool = api.tools["notes"]
local out = tool.handler({ command = "append", path = "a.md", text = "hello" }, ctx)
check_nil("append works", out.is_error)
local listing = tool.handler({ command = "list" }, ctx)
check_nil("list hides the marker", listing:find(".reminder", 1, true))
check("list shows the note", listing:find("a.md", 1, true) ~= nil, true)

-- Both spellings reach the disk under either name. A live call arrives with the
-- canonical keys because the host resolves the schema aliases before the handler
-- runs, so the fake host exercises the plugin's own raw-input fallbacks.
local NOTES = "/state/sessions/data/S1/notes/"
check("content is canonical", type(tool.schema.properties.content), "table")
check("content keeps the legacy name", tool.schema.properties.content.alias, "text")
check("path is canonical", type(tool.schema.properties.path), "table")
check("path takes maki's alias", tool.schema.properties.path.alias, "file_path")
check(
  "command hint names the commands",
  tool.schema.properties.command.hint:find("list, read, search, append or write", 1, true) ~= nil,
  true
)
check("command hint points away from edit", tool.schema.properties.command.hint:find("no edit", 1, true) ~= nil, true)
check_nil(
  "append through file_path",
  tool.handler({ command = "append", file_path = "alias.md", content = "via alias" }, ctx).is_error
)
check("append reached the file", disk.files[NOTES .. "alias.md"], "via alias")
check_nil(
  "write through the legacy text",
  tool.handler({ command = "write", path = "alias.md", text = "replaced" }, ctx).is_error
)
check("write replaced the body", disk.files[NOTES .. "alias.md"], "replaced")
check(
  "no body at all errors",
  tool.handler({ command = "write", path = "x.md" }, ctx).is_error,
  true
)

-- `header` and `restore` see the raw model input on rerender and session load,
-- where no alias is resolved.
check("header reads the aliased path", tool.header({ command = "append", file_path = "alias.md" }), "append alias.md")
tool.restore({ command = "write", file_path = "alias.md", content = "replaced" }, "wrote alias.md", false, ctx)
check("restore renders the legacy body", viewed[#viewed], "replaced")
check("restore highlights the aliased path", exts[#exts], "md")

-- context_usage reports the calling agent's own gauge, pairing with compact.
local usage = api.tools["context_usage"]
check("context_usage registered", usage ~= nil, true)
CTX_USAGE = { size = 42300, window = 200000 }
check("usage output", usage.handler({}, ctx), "context 42300 / 200000 tokens (21% used)")
CTX_ERR = "ctx:context needs a handler ctx"
local missing = usage.handler({}, ctx)
check("missing gauge errors", missing.is_error, true)
check("error reaches the model", missing.llm_output:find("handler ctx", 1, true) ~= nil, true)
CTX_ERR = nil
CTX_USAGE = { size = 100 }
check("no window errors", usage.handler({}, ctx).is_error, true)
CTX_USAGE = nil

-- Without a state dir the reminder falls back to in-memory hysteresis.
STATE.dir = nil
restart()
turncomplete("S3", 85, 100)
check("fires without state dir", #notifications, 13)
turncomplete("S3", 90, 100)
check("hysteresis without state dir", #notifications, 13)
turncomplete("S3", 50, 100)
turncomplete("S3", 85, 100)
check("re-arms without state dir", #notifications, 14)
STATE.dir = "/state"

-- A legacy marker from the single-threshold plugin ("1", planted at 80%)
-- counts as the top step, so upgrading does not re-nudge old sessions.
disk.files[marker("S4")] = "1"
restart()
turncomplete("S4", 90, 100)
check("legacy marker stays quiet", #notifications, 14)
turncomplete("S4", 20, 100)
check_nil("legacy marker cleared below all steps", disk.files[marker("S4")])

-- agent.compact.before: an automatic ask defers with a nudge and carries the
-- notes read-back in the same verdict; the once cap and the delivery are the
-- host's. S1 still holds a.md from the marker test above.
restart()
local main_ctx = { session_id = "S1", context_window = 10000 }
local noted = #notifications
local verdict = compact_before({ reason = "auto", context_size = 8500, usable = 9000 }, main_ctx)
check("auto defers with the save nudge", verdict.defer:find("save any session state", 1, true) ~= nil, true)
check(
  "defer nudge says it is a pause, not a step",
  verdict.defer:find("compaction is paused", 1, true) ~= nil and verdict.defer:find("nearly full", 1, true) == nil,
  true
)
check("nudge names the fill", verdict.defer:find("85% of the window", 1, true) ~= nil, true)
check(
  "nudge puts the compaction after this turn",
  verdict.defer:find("Compaction runs automatically after this turn", 1, true) ~= nil,
  true
)
check(
  "nudge asks for the save in this turn, not an answer",
  verdict.defer:find("in this turn", 1, true) ~= nil and verdict.defer:find("no tool calls", 1, true) == nil,
  true
)
check("read-back rides the same verdict", verdict.continue:find("a.md", 1, true) ~= nil, true)
check("read-back says read first", verdict.continue:find("before doing any work", 1, true) ~= nil, true)
check(
  "summary instructions name the notes",
  verdict.instructions
    and verdict.instructions:find("a.md", 1, true) ~= nil
    and verdict.instructions:find("with the `notes` tool", 1, true) ~= nil,
  true
)
check("the layer notifies nobody", #notifications, noted)

-- A manual /compact and an overflow recovery are obeyed, only read back.
verdict = compact_before({ reason = "manual", context_size = 6000, usable = 9000, request_instructions = "tidy up" }, main_ctx)
check_nil("manual never defers", verdict.defer)
check("manual reads back", verdict.continue:find("a.md", 1, true) ~= nil, true)
check("manual summary instructions name the notes", verdict.instructions:find("a.md", 1, true) ~= nil, true)
verdict = compact_before({ reason = "overflow", context_size = 10000, usable = 9000 }, main_ctx)
check_nil("overflow never defers", verdict.defer)
check("overflow reads back", verdict.continue:find("a.md", 1, true) ~= nil, true)

-- `continue` and `defer` are one string each shared by every compact.before
-- layer, so the layer appends to what an earlier layer wrote instead of
-- replacing it.
verdict = compact_before({ reason = "manual", context_size = 6000, usable = 9000, continue = "an earlier layer spoke" }, main_ctx)
check("keeps another layer's continue", verdict.continue:find("an earlier layer spoke", 1, true) ~= nil, true)
check("appends the read-back after it", verdict.continue:find("an earlier layer spoke") < verdict.continue:find("a.md"), true)
verdict = compact_before({ reason = "auto", context_size = 8500, usable = 9000, defer = "an earlier layer spoke" }, main_ctx)
check("keeps another layer's defer", verdict.defer:find("an earlier layer spoke", 1, true) ~= nil, true)
check(
  "appends the nudge after it",
  verdict.defer:find("an earlier layer spoke") < verdict.defer:find("automatic compaction is paused"),
  true
)

-- A subagent gets the same save turn and read-back as the main session.
local sub_ctx = { session_id = "S1", task_id = "T7", context_window = 10000 }
verdict = compact_before({ reason = "auto", context_size = 8500, usable = 9000 }, sub_ctx)
check("subagent defers too", verdict.defer ~= nil, true)
check("subagent reads back the session notes", verdict.continue:find("a.md", 1, true) ~= nil, true)
check("subagent notifies nobody", #notifications, noted)

-- The layer is stateless, so every auto ask carries the same offer, and
-- without notes the read-back is simply empty. The host refuses a defer that
-- leaves no room for the save turn.
verdict = compact_before({ reason = "auto", context_size = 9000, usable = 9000 }, main_ctx)
check("every auto ask defers", verdict.defer ~= nil, true)
local s2_ctx = { session_id = "S2", context_window = 10000 }
verdict = compact_before({ reason = "auto", context_size = 8500, usable = 9000 }, s2_ctx)
check("defers without notes too", verdict.defer ~= nil, true)
check_nil("no read-back without notes", verdict.continue)
check_nil("no summary instructions without notes", verdict.instructions)

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
