local helpers = require("notes_helpers")
local ToolView = require("maki.tool_view")
local ListPicker = require("maki.list_picker")
local Toast = require("maki.toast")

-- Matches safe_path's component cap, so every valid path is listable.
local WALK_DEPTH = helpers.MAX_PATH_DEPTH

local function render_content(content, path, ctx)
  local buf = maki.ui.buf()
  local tol = ctx:tool_output_lines()
  local view = ToolView.new(buf, {
    max_lines = (tol and tol.other) or 20,
    keep = "head",
  })
  buf:on("click", function()
    view:toggle()
  end)

  local ext = path and path:match("%.([^%.]+)$") or "txt"
  if not view:set_highlight(content, ext) then
    view:append_text(content)
  end
  view:finish()
  return buf
end

-- A toast and not a flash, so the feedback stays readable while the picker is
-- still on screen.
local function toast(msg)
  Toast.show(msg, { title = "notes" })
end

local function notes_dir(session_id)
  local dir, err = maki.session.data_dir({ session = session_id })
  if not dir then
    return nil, err
  end
  return dir
end

local function list_files(dir, prefix)
  local meta = maki.fs.metadata(dir)
  if not meta or not meta.is_dir then
    return {}
  end
  local entries, err = maki.fs.dir(dir, { depth = WALK_DEPTH })
  if not entries then
    return nil, err
  end
  local files = {}
  for _, entry in ipairs(entries) do
    local name, ftype = entry[1], entry[2]
    -- Root-level dotfiles are plugin state (the reminder marker), not notes.
    if ftype == "file" and name:sub(1, 1) ~= "." and (not prefix or name:sub(1, #prefix) == prefix) then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  return files
end

local function cmd_list(dir, input)
  local files, err = list_files(dir, input.prefix)
  if not files then
    return nil, err
  end
  local limit = helpers.clamp(input.limit, helpers.MAX_LIST_LIMIT, helpers.MAX_LIST_LIMIT)
  local entries = {}
  for i = 1, math.min(#files, limit) do
    local path = files[i]
    local meta = maki.fs.metadata(maki.fs.joinpath(dir, path))
    entries[i] = { path = path, bytes = meta and meta.size or 0, mtime = meta and meta.mtime }
  end
  return helpers.format_list(entries)
end

local function cmd_read(dir, input, ctx)
  local path, perr = helpers.safe_path(input.path)
  if not path then
    return nil, perr
  end
  local full = maki.fs.joinpath(dir, path)
  if not maki.fs.metadata(full) then
    return nil, "note not found: " .. path
  end
  local content, err = maki.fs.read(full)
  if not content then
    return nil, err
  end
  local formatted = helpers.read_slice(content, input.start_line, input.stop_line, path)
  return {
    llm_output = formatted,
    body = render_content(formatted, path, ctx),
  }
end

local function cmd_search(dir, input)
  local query, qerr = helpers.prepare_query(input.query)
  if not query then
    return nil, qerr
  end
  local files, err = list_files(dir, input.prefix)
  if not files then
    return nil, err
  end
  local max_files = helpers.clamp(input.max_files, helpers.MAX_SEARCH_FILES, helpers.MAX_SEARCH_FILES)
  local per_file = helpers.clamp(input.max_matches_per_file, helpers.MAX_MATCHES_PER_FILE, helpers.MAX_MATCHES_PER_FILE)
  local groups, scanned = {}, 0
  for _, path in ipairs(files) do
    if #groups >= max_files or scanned >= helpers.MAX_SCAN_FILES then
      break
    end
    scanned = scanned + 1
    local content = maki.fs.read(maki.fs.joinpath(dir, path))
    if content then
      local matches = helpers.search_lines(path, content, query, per_file)
      if #matches > 0 then
        groups[#groups + 1] = matches
      end
    end
  end
  local out = helpers.format_search(groups)
  local hint = helpers.scan_capped_hint(scanned, #files)
  if hint then
    out = out .. "\n" .. hint
  end
  return out
end

local function write_out(dir, input, replace, ctx)
  local path, perr = helpers.safe_path(input.path)
  if not path then
    return nil, perr
  end
  local existing = maki.fs.metadata(maki.fs.joinpath(dir, path))
  local err = helpers.check_size(replace and 0 or (existing and existing.size or 0), input.text)
  if err then
    return nil, err
  end
  local full = maki.fs.joinpath(dir, path)
  local ok, merr = maki.fs.mkdir(maki.fs.dirname(full), { parents = true })
  if not ok then
    return nil, merr
  end
  if replace then
    ok, err = maki.fs.write(full, input.text)
  else
    ok, err = maki.fs.append(full, input.text)
  end
  if not ok then
    return nil, err
  end
  return {
    llm_output = (replace and "wrote " or "appended to ") .. path,
    body = render_content(input.text, path, ctx),
  }
end

maki.api.register_tool({
  name = "notes",
  description = [[Persistent, session-scoped notes for state that must survive compaction. Use this for anything that only matters in this session: task progress, intermediate results, file offsets, decisions, gotchas. Use the built-in memory tool only for knowledge useful in future sessions on this project. Per-session state there pollutes every later session.

Files live under the session's notes dir and are deleted with the session.

- Strongly consistent: a read sees every earlier append/write immediately.
- `list [prefix] [limit]`: note paths with size and mtime.
- `read path [start_line] [stop_line]`: whole file, or a 1-based inclusive line range.
- `search query [prefix] [max_files] [max_matches_per_file]`: literal case-sensitive substring, reported as `path:line: text` lines.
- `append path text`: append verbatim, creating the file and parent dirs. Concurrent appends interleave.
- `write path text`: create or replace (last writer wins).

Paths are relative with no empty, '.', or '..' components, at most 8 levels deep. '~' is a literal name, never expanded. Limit-like args are clamped, never rejected. Each note is capped at 1 MiB, so start another file when one is full. There is no delete: the user removes notes via the /notes picker. Pass paths back exactly as list/search returned them.]],

  schema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        enum = { "list", "read", "search", "append", "write" },
        description = "The operation to run, see the command list above.",
        required = true,
      },
      path = {
        type = "string",
        description = "Relative note path, e.g. 'decisions.md'.",
      },
      text = {
        type = "string",
        description = "Content for append/write, appended verbatim.",
      },
      query = {
        type = "string",
        description = "Literal case-sensitive substring for search.",
      },
      prefix = {
        type = "string",
        description = "Restrict list/search to paths starting with this prefix.",
      },
      limit = {
        type = "integer",
        description = "Max entries for list (default 100).",
      },
      start_line = {
        type = "integer",
        description = "First line for read, 1-based inclusive.",
      },
      stop_line = {
        type = "integer",
        description = "Last line for read, 1-based inclusive.",
      },
      max_files = {
        type = "integer",
        description = "Max files with matches for search (default 20).",
      },
      max_matches_per_file = {
        type = "integer",
        description = "Max matches per file for search (default 10).",
      },
    },
  },

  header = function(input)
    local parts = { input.command or "" }
    if input.path then
      parts[#parts + 1] = input.path
    elseif input.query then
      parts[#parts + 1] = input.query
    end
    return table.concat(parts, " ")
  end,

  restore = function(input, output, _is_error, ctx)
    local content = (input.command == "append" or input.command == "write") and input.text or output
    return render_content(content, input.path, ctx)
  end,

  handler = function(input, ctx)
    local sid = ctx:session_id()
    if not sid then
      return { llm_output = "error: no session", is_error = true }
    end
    local dir, dir_err = notes_dir(sid)
    if not dir then
      return { llm_output = "error: " .. dir_err, is_error = true }
    end

    local result, err
    local cmd = input.command
    if cmd == "list" then
      result, err = cmd_list(dir, input)
    elseif cmd == "read" then
      result, err = cmd_read(dir, input, ctx)
    elseif cmd == "search" then
      result, err = cmd_search(dir, input)
    elseif cmd == "append" then
      result, err = write_out(dir, input, false, ctx)
    elseif cmd == "write" then
      result, err = write_out(dir, input, true, ctx)
    else
      err = "unknown command: " .. tostring(cmd)
    end
    if err then
      return { llm_output = "error: " .. err, is_error = true }
    end
    return result
  end,
})

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- Save session state that must survive compaction to **notes**, appending right after each milestone (a passing test, a design decision, a discovered layout). Use **memory** only for knowledge useful in future sessions on this project. Read notes back after a compaction before redoing work.",
})

local outstanding = {}
-- Keyed by task id; a subagent's state dies with the session that opened it.
local subagent_outstanding = {}

-- The reminder's hysteresis state does not survive a restart on its own, so
-- every fired nudge also plants a marker file holding the nudged step: a
-- restart otherwise re-arms the steps and the session gets nudged twice. The
-- marker lives in the session's notes dir, so the session delete that sweeps
-- the notes takes it too, and list_files hides it because it is not a note.
-- Only CompactionDone clears it: shutdown and reload fire SessionEnd, and
-- clearing there would defeat the marker; a session that drops below a step
-- re-arms it by itself on the next TurnComplete.
local REMINDER_MARKER = ".reminder"

local function marker_path(sid)
  local dir = notes_dir(sid)
  if not dir then
    return nil
  end
  return maki.fs.joinpath(dir, REMINDER_MARKER)
end

local function marker_set(sid, value)
  local full = marker_path(sid)
  if full and maki.fs.mkdir(maki.fs.dirname(full), { parents = true }) then
    maki.fs.write(full, value)
  end
end

local function marker_clear(sid)
  local full = marker_path(sid)
  if full then
    maki.fs.rm(full, { force = true })
  end
end

-- The save turn and the read-back ride `agent.compact.before`, which fires
-- inside the run it steers, so subagents get them too. The summary
-- instructions name the note filenames as of the compaction moment. Every
-- automatic ask offers a defer with a nudge to save; the host refuses it when
-- the window has no room for the turn and caps it to one per compaction, so
-- the layer keeps no state. The ask after that turn proceeds with the
-- read-back. Manual and overflow compactions only get the read-back. The
-- layer only adds its own fields so other compact.before layers keep theirs.
maki.api.set_slot("agent.compact.before", function(prev, value, ctx)
  local dir = notes_dir(ctx.session_id)
  local paths = dir and list_files(dir, nil)
  local hint = helpers.compact_hint(paths)
  local read_back = helpers.post_compact_text(paths)
  -- `instructions` and `continue` are one string each, so layers share them
  -- by appending: assigning would drop whatever an earlier layer put there.
  if hint then
    value.instructions = value.instructions and (value.instructions .. "\n\n" .. hint) or hint
  end
  if read_back then
    value.continue = value.continue and (value.continue .. "\n\n" .. read_back) or read_back
  end
  if value.reason == "auto" then
    local nudge = helpers.defer_text(value.context_size, ctx.context_window)
    value.defer = value.defer and (value.defer .. "\n\n" .. nudge) or nudge
  end
  return prev(value, ctx)
end)

maki.api.create_autocmd({ "TurnComplete", "CompactionDone", "SessionEnd" }, {
  callback = function(ev)
    local data = ev.data
    local sid = data and data.session_id
    if not sid then
      return
    end
    if ev.event == "SessionEnd" then
      outstanding[sid] = nil
      for task_id, entry in pairs(subagent_outstanding) do
        if entry.session == sid then
          subagent_outstanding[task_id] = nil
        end
      end
      return
    end
    if ev.event == "CompactionDone" then
      outstanding[sid] = nil
      marker_clear(sid)
      return
    end
    local steps = helpers.remind_steps()
    local task_id = data.id
    local state
    if task_id then
      local entry = subagent_outstanding[task_id]
      state = entry and entry.state or 0
    else
      -- Seed the in-memory state from the marker: a restart or a session
      -- switch wiped it, and the marker records which steps were already
      -- nudged.
      if outstanding[sid] == nil then
        local full = marker_path(sid)
        local content = full and maki.fs.read(full)
        outstanding[sid] = content and helpers.state_from_marker(content, steps) or 0
      end
      state = outstanding[sid]
    end
    local step, next_state = helpers.should_remind(state, data.context_size, data.context_window, steps)
    if task_id then
      -- A subagent does not outlive its run, so its state needs no marker.
      if next_state > 0 then
        subagent_outstanding[task_id] = { session = sid, state = next_state }
      else
        subagent_outstanding[task_id] = nil
      end
    else
      outstanding[sid] = next_state
      -- The marker always mirrors the current state, not just fired nudges, so
      -- a restart seeds exactly the steps that are re-armed right now.
      if next_state > 0 then
        marker_set(sid, tostring(steps[next_state]))
      else
        marker_clear(sid)
      end
    end
    if step then
      local text = helpers.reminder_text(data.context_size, data.context_window, step)
      maki.session.notify(text, { session = sid, task = task_id, wake = true, display = text })
    end
  end,
})

maki.api.register_command({
  name = "/notes",
  description = "View, edit, and delete this session's notes",
  handler = function()
    local sid, sid_err = maki.session.current()
    if not sid then
      maki.ui.flash("No session" .. (sid_err and ": " .. sid_err or ""))
      return
    end
    local dir, dir_err = notes_dir(sid)
    if not dir then
      maki.ui.flash(dir_err)
      return
    end

    local function build()
      return list_files(dir, nil)
    end

    local items = build()
    if #items == 0 then
      maki.ui.flash("No notes in this session yet")
      return
    end
    local last_cursor = 1
    while true do
      local event = ListPicker.open(items, {
        title = " Session Notes ",
        cursor = last_cursor,
        key = function(item)
          return item
        end,
        footer = {
          { "Enter", "open" },
          { "Ctrl+D", "delete" },
        },
      })

      if event.type == "close" then
        break
      end
      last_cursor = event.index

      local path = event.item
      if event.type == "choice" then
        if maki.ui.open_editor(maki.fs.joinpath(dir, path)) == 0 then
          items = build()
          if #items == 0 then
            break
          end
        end
      elseif event.type == "delete" then
        local ok, err = maki.fs.rm(maki.fs.joinpath(dir, path))
        if ok then
          toast("Deleted " .. path)
          items = build()
          if #items == 0 then
            break
          end
        else
          toast("Delete failed: " .. tostring(err))
        end
      end
    end
  end,
})
