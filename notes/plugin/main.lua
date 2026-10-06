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
  local state = maki.env.state_dir()
  if not state then
    return nil, "cannot resolve state dir"
  end
  return maki.fs.joinpath(state, "sessions", "notes", session_id)
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
  description = [[Persistent, session-scoped notes for state that must survive compaction. Use this for anything that only matters in this session: task progress, intermediate results, file offsets, decisions, gotchas. Use the built-in memory tool only for knowledge useful in future sessions on this project; per-session state there pollutes every later session.

Files live under the session's notes dir and are deleted with the session.

- Strongly consistent: a read sees every earlier append/write immediately.
- `list [prefix] [limit]`: note paths with size and mtime.
- `read path [start_line] [stop_line]`: whole file, or a 1-based inclusive line range.
- `search query [prefix] [max_files] [max_matches_per_file]`: literal case-sensitive substring; `path:line: text` lines.
- `append path text`: append verbatim; creates the file and parent dirs. Concurrent appends interleave.
- `write path text`: create or replace; last writer wins.

Paths are relative with no empty, '.', or '..' components, at most 8 levels deep; '~' is a literal name, never expanded. Limit-like args are clamped, never rejected. Each note is capped at 1 MiB; start another file when one is full. There is no delete: the user removes notes via the /notes picker. Pass paths back exactly as list/search returned them.]],

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

maki.api.register_prompt_hint({
  prompt = "compact",
  slot = "tool_usage",
  content = function(ctx)
    local sid = ctx and ctx.session_id
    if not sid then
      return nil
    end
    local dir = notes_dir(sid)
    if not dir then
      return nil
    end
    local paths = list_files(dir, nil)
    return helpers.compact_hint(paths)
  end,
})

local outstanding = {}

-- The reminder's hysteresis state does not survive a restart on its own, so
-- every fired nudge also plants a marker file holding the nudged step: a
-- restart otherwise re-arms the steps and the session gets nudged twice. The
-- marker lives in the session's notes dir, so the session delete that sweeps
-- the notes takes it too, and list_files hides it because it is not a note.
-- Only CompactionDone clears it: shutdown and reload fire SessionEnd, and
-- clearing there would defeat the marker; a session that drops below a step
-- re-arms it by itself on the next ToolDone.
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

maki.api.create_autocmd({ "ToolDone", "CompactionDone", "SessionEnd" }, {
  callback = function(ev)
    local sid = ev.data and ev.data.session_id
    if not sid then
      return
    end
    if ev.event ~= "ToolDone" then
      outstanding[sid] = nil
      if ev.event == "CompactionDone" then
        marker_clear(sid)
        -- The summary is passive text the model can skim past, so deliver the
        -- read-back instruction as a woken observation: the next turn starts
        -- by reading notes, not by redoing work. Naming the files here means
        -- this does not depend on the summary carrying them.
        local dir = notes_dir(sid)
        local paths = dir and list_files(dir, nil)
        local text = helpers.post_compact_text(paths)
        if text then
          maki.session.notify(text, { session = sid, wake = true, display = true })
        end
      end
      return
    end
    -- A subagent's ToolDone carries the subagent's own context usage, which
    -- says nothing about this session's.
    if ev.data.subagent then
      return
    end
    -- Seed the in-memory state from the marker: a restart or a session switch
    -- wiped it, and the marker records which steps were already nudged.
    if outstanding[sid] == nil then
      local full = marker_path(sid)
      local content = full and maki.fs.read(full)
      outstanding[sid] = content and helpers.state_from_marker(content, helpers.remind_steps()) or 0
    end
    local steps = helpers.remind_steps()
    local step, state = helpers.should_remind(outstanding[sid], ev.data.context_size, ev.data.context_window, steps)
    outstanding[sid] = state
    -- The marker always mirrors the current state, not just fired nudges, so
    -- a restart seeds exactly the steps that are re-armed right now.
    if state > 0 then
      marker_set(sid, tostring(steps[state]))
    else
      marker_clear(sid)
    end
    if step then
      maki.session.notify(
        helpers.reminder_text(ev.data.context_size, ev.data.context_window, step),
        { session = sid, wake = true, display = true }
      )
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
