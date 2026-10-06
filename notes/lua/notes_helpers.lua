-- Pure logic for the notes plugin: path validation, list/read/search shaping,
-- caps, and the compaction-reminder state machine. No `maki` global here so
-- the spec runs under plain luajit.

local M = {}

M.MAX_FILE_BYTES = 1024 * 1024
M.MAX_READ_BYTES = 20 * 1024
M.MAX_QUERY_CHARS = 1000
M.MAX_LIST_LIMIT = 100
M.MAX_SEARCH_FILES = 20
M.MAX_MATCHES_PER_FILE = 10
M.MAX_SCAN_FILES = 100
M.MAX_PATH_DEPTH = 8
M.HINT_LIST_CAP = 50
M.DEFAULT_REMIND_STEPS = { 0.4, 0.6, 0.8 }

M.NO_NOTES_MSG = "no notes in this session yet; use write to create one"
M.NO_MATCHES_MSG = "no notes match the query"
M.PATH_REQUIRED_ERR = "path is required"
M.PATH_ABSOLUTE_ERR = "path must be relative"
M.PATH_INVALID_ERR = "path must not contain empty, '.', or '..' components"
M.PATH_TOO_DEEP_FMT = "path is too deep (max %d components)"
M.TEXT_REQUIRED_ERR = "text is required"
M.QUERY_REQUIRED_ERR = "query is required"
M.TOO_BIG_FMT = "note would exceed the %d byte per-file cap; start another note file"
M.CAP_READ_HINT = "narrow the range with start_line/stop_line, or read a smaller note"
M.SCAN_CAPPED_FMT = "... (searched the first %d of %d files; narrow with a prefix)"

local config = { remind_steps = M.DEFAULT_REMIND_STEPS, reminder_text = nil }

local function normalize_steps(list)
  if type(list) ~= "table" then
    return nil
  end
  local steps = {}
  for _, step in ipairs(list) do
    if type(step) == "number" and step == step and step > 0 and step <= 1 then
      steps[#steps + 1] = step
    end
  end
  table.sort(steps)
  return steps
end

function M.setup(opts)
  opts = type(opts) == "table" and opts or {}
  -- remind_at is the pre-steps single-threshold option; keep accepting it.
  local steps = normalize_steps(opts.remind_steps)
    or (type(opts.remind_at) == "number" and opts.remind_at > 0 and opts.remind_at <= 1
      and { opts.remind_at }
      or nil)
  if steps and #steps > 0 then
    config.remind_steps = steps
  end
  if type(opts.reminder_text) == "string" and opts.reminder_text ~= "" then
    config.reminder_text = opts.reminder_text
  end
  return config
end

function M.remind_steps()
  return config.remind_steps
end

function M.reminder_text(context_size, context_window, step)
  if config.reminder_text then
    return config.reminder_text
  end
  local pct = math.floor(context_size / context_window * 100 + 0.5)
  local steps = config.remind_steps
  if step == nil or step == steps[#steps] then
    return ("context is nearly full (%d%% of the window): save important session state to notes now, before a compaction drops it"):format(
      pct
    )
  end
  if step == steps[1] then
    return ("context is %d%% full: start a note now with important session state, so a later compaction cannot drop it"):format(
      pct
    )
  end
  return ("context is %d%% full: update (or start) your notes with important session state, so a compaction cannot drop it"):format(
    pct
  )
end

function M.safe_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, M.PATH_REQUIRED_ERR
  end
  if path:find("\0", 1, true) then
    return nil, M.PATH_INVALID_ERR
  end
  local first = path:sub(1, 1)
  if first == "/" or first == "\\" or path:match("^%a:") then
    return nil, M.PATH_ABSOLUTE_ERR
  end
  local parts = {}
  local start = 1
  while true do
    local slash = path:find("/", start, true)
    local seg = path:sub(start, slash and slash - 1 or #path)
    if seg == "" or seg == "." or seg == ".." then
      return nil, M.PATH_INVALID_ERR
    end
    parts[#parts + 1] = seg
    if not slash then
      break
    end
    start = slash + 1
  end
  if #parts > M.MAX_PATH_DEPTH then
    return nil, (M.PATH_TOO_DEEP_FMT):format(M.MAX_PATH_DEPTH)
  end
  return table.concat(parts, "/")
end

function M.clamp(v, default, cap)
  if type(v) ~= "number" or v ~= v or v < 1 then
    return default
  end
  return math.min(math.floor(v), cap)
end

local function split_lines(s)
  if s == "" then
    return {}
  end
  local lines = {}
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = s:sub(start)
      break
    end
    lines[#lines + 1] = s:sub(start, nl - 1)
    start = nl + 1
  end
  return lines
end

local function clamp_line(v, total)
  if type(v) ~= "number" or v ~= v or v < 1 then
    return nil
  end
  return math.min(math.floor(v), total)
end

function M.read_slice(content, start_line, stop_line, path)
  local lines = split_lines(content)
  local total = #lines
  if total == 0 then
    return ""
  end
  local explicit = start_line ~= nil or stop_line ~= nil
  local first = clamp_line(start_line, total) or 1
  local last = clamp_line(stop_line, total) or total
  if last < first then
    last = first
  end
  local picked = {}
  for i = first, last do
    picked[#picked + 1] = lines[i]
  end
  local body = table.concat(picked, "\n")
  if not explicit then
    return M.cap_read_output(body)
  end
  return M.cap_read_output(path .. " (lines " .. first .. "-" .. last .. " of " .. total .. "):\n" .. body)
end

function M.cap_read_output(s)
  if #s <= M.MAX_READ_BYTES then
    return s
  end
  -- Back off UTF-8 continuation bytes so the cut never splits a codepoint.
  local cut = M.MAX_READ_BYTES
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut) .. "\n... (output truncated at " .. M.MAX_READ_BYTES .. " bytes; " .. M.CAP_READ_HINT .. ")"
end

function M.prepare_query(query)
  if type(query) ~= "string" or query == "" then
    return nil, M.QUERY_REQUIRED_ERR
  end
  return query:sub(1, M.MAX_QUERY_CHARS)
end

function M.search_lines(path, content, query, max_matches)
  local matches = {}
  local line_nr = 0
  local start = 1
  while #matches < max_matches do
    local nl = content:find("\n", start, true)
    local line = content:sub(start, nl and nl - 1 or #content)
    line_nr = line_nr + 1
    if line:find(query, 1, true) then
      matches[#matches + 1] = path .. ":" .. line_nr .. ": " .. line
    end
    if not nl then
      break
    end
    start = nl + 1
  end
  return matches
end

function M.format_search(groups)
  local lines = {}
  for _, group in ipairs(groups) do
    for _, match in ipairs(group) do
      lines[#lines + 1] = match
    end
  end
  if #lines == 0 then
    return M.NO_MATCHES_MSG
  end
  return table.concat(lines, "\n")
end

-- When the scan cap stops the search before every file was read, say so:
-- stopping silently would read as "no more matches".
function M.scan_capped_hint(scanned, total)
  if scanned >= M.MAX_SCAN_FILES and total > scanned then
    return (M.SCAN_CAPPED_FMT):format(scanned, total)
  end
  return nil
end

function M.format_list(entries)
  if #entries == 0 then
    return M.NO_NOTES_MSG
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  local lines = {}
  for i, entry in ipairs(entries) do
    local updated = os.date("%Y-%m-%d %H:%M", math.floor(entry.mtime or 0))
    lines[i] = entry.path .. "  " .. entry.bytes .. " bytes  " .. updated
  end
  return table.concat(lines, "\n")
end

function M.check_size(existing_bytes, text)
  if type(text) ~= "string" or text == "" then
    return M.TEXT_REQUIRED_ERR
  end
  if existing_bytes + #text > M.MAX_FILE_BYTES then
    return M.TOO_BIG_FMT:format(M.MAX_FILE_BYTES)
  end
  return nil
end

-- Multi-step hysteresis. state counts how many steps have been crossed (and
-- thus nudged); a ToolDone that crosses several new steps at once fires only
-- the highest, so one event never spams several nudges. Falling below a step
-- re-arms it; the state simply tracks the steps the current fill satisfies.
-- Returns the newly crossed step to fire (nil when quiet) and the next state.
function M.should_remind(state, context_size, context_window, steps)
  state = state or 0
  if not context_size or not context_window or context_window <= 0 then
    return nil, state
  end
  local crossed = 0
  for i, step in ipairs(steps) do
    if context_size >= context_window * step then
      crossed = i
    end
  end
  if crossed > state then
    return steps[crossed], crossed
  end
  return nil, crossed
end

-- The marker file holds the highest crossed step (the hysteresis state), so a
-- restart seeds the state without re-nudging. A legacy marker ("1", planted
-- by the pre-steps single-threshold plugin at 80%) counts as the top step.
function M.state_from_marker(content, steps)
  local n = tonumber(content)
  if not n then
    return #steps
  end
  local state = 0
  for i, step in ipairs(steps) do
    if step <= n then
      state = i
    end
  end
  return state
end

function M.compact_hint(paths)
  if not paths or #paths == 0 then
    return nil
  end
  local shown = math.min(#paths, M.HINT_LIST_CAP)
  local names = {}
  for i = 1, shown do
    names[i] = paths[i]
  end
  local suffix = ""
  if shown < #paths then
    suffix = ", and " .. (#paths - shown) .. " more"
  end
  return "This session keeps notes that survive compaction unchanged: "
    .. table.concat(names, ", ")
    .. suffix
    .. ". Include in your summary the note filenames and an instruction to run `notes list` and read the relevant notes before redoing any work (the summary alone can miss filenames). Do not copy note contents into the summary."
end

-- Delivered as a woken observation right after CompactionDone, so the first
-- post-compaction turn starts by reading notes instead of redoing work. The
-- summary is passive text the model can skim; this is a fresh message that
-- names the files itself, so it does not depend on the summary carrying them.
function M.post_compact_text(paths)
  if not paths or #paths == 0 then
    return nil
  end
  local shown = math.min(#paths, M.HINT_LIST_CAP)
  local names = {}
  for i = 1, shown do
    names[i] = paths[i]
  end
  local suffix = ""
  if shown < #paths then
    suffix = ", and " .. (#paths - shown) .. " more"
  end
  return "Compaction just replaced this session's history with a summary, which can miss details. "
    .. "Notes that survived it: "
    .. table.concat(names, ", ")
    .. suffix
    .. ". Read the relevant ones with the `notes` tool before doing any work "
    .. "(e.g. `notes read <path>`; `notes list` shows them all), then continue the task."
end

return M
