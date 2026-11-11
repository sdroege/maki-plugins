local helpers = require("history_helpers")
local ToolView = require("maki.tool_view")
local output_limits = require("maki.output_limits")
local truncate = require("maki.truncate")

local function render_content(content, ctx)
  local buf = maki.ui.buf()
  local tol = ctx:tool_output_lines()
  local view = ToolView.new(buf, {
    max_lines = (tol and tol.other) or 20,
    keep = "head",
  })
  buf:on("click", function()
    view:toggle()
  end)
  if not view:set_highlight(content, "txt") then
    view:append_text(content)
  end
  view:finish()
  return buf
end

local function session_id(ctx)
  local sid = ctx:session_id()
  if not sid then
    return nil, "no session"
  end
  return sid
end

local function windows(ctx)
  local sid, err = session_id(ctx)
  if not sid then
    return nil, err
  end
  local windows, err = maki.session.windows({ session = sid })
  if not windows then
    return nil, err
  end
  return windows
end

local function resolve_window(windows, window_id)
  local id = window_id or helpers.CURRENT_WINDOW
  local window = helpers.find_window(windows, id)
  if not window then
    return nil, helpers.WINDOW_NOT_FOUND_FMT:format(tostring(id))
  end
  return window
end

-- One window with its messages and subagents, the shape the helpers take.
-- Reading a window never touches the others, so a big session costs only the
-- window the model asked for.
local function read_window(ctx, window)
  local sid, err = session_id(ctx)
  if not sid then
    return nil, err
  end
  local messages, err = maki.session.messages({ session = sid, window = window.id })
  if not messages then
    return nil, err
  end
  local subagents, err = maki.session.subagents({ session = sid, window = window.id })
  if not subagents then
    return nil, err
  end
  return {
    id = window.id,
    kind = window.kind,
    created_at = window.created_at,
    messages = messages,
    subagents = subagents,
  }
end

local function cmd_list_items(ctx, windows, input)
  local meta, err = resolve_window(windows, input.window)
  if not meta then
    return nil, err
  end
  local window, err = read_window(ctx, meta)
  if not window then
    return nil, err
  end
  return helpers.format_items(window.id, helpers.flatten_items(window), {
    role = input.role,
    sub = input.sub,
    limit = helpers.clamp(input.limit, helpers.DEFAULT_ITEM_LIMIT, helpers.MAX_ITEM_LIMIT),
    max_chars_per_item = helpers.clamp(
      input.max_chars_per_item,
      helpers.DEFAULT_PREVIEW_CHARS,
      helpers.MAX_PREVIEW_CHARS
    ),
  })
end

local function cmd_read_item(ctx, windows, input)
  if not input.item then
    return nil, helpers.ITEM_REQUIRED_ERR
  end
  local window_id, item = helpers.split_item(windows, input.item, input.window)
  local meta, err = resolve_window(windows, window_id)
  if not meta then
    return nil, err
  end
  local window, err = read_window(ctx, meta)
  if not window then
    return nil, err
  end
  return helpers.read_item(window.id, helpers.flatten_items(window), item, input.offset_chars, input.limit_chars)
end

local function cmd_search(ctx, windows, input)
  local query, err = helpers.prepare_query(input.query)
  if not query then
    return nil, err
  end
  local loaded = {}
  for _, meta in ipairs(windows) do
    if not input.window or meta.id == input.window then
      local window, err = read_window(ctx, meta)
      if not window then
        return nil, err
      end
      loaded[#loaded + 1] = window
    end
  end
  return helpers.format_search(loaded, {
    query = query,
    window = input.window,
    role = input.role,
    sub = input.sub,
    limit = helpers.clamp(input.limit, helpers.DEFAULT_SEARCH_LIMIT, helpers.MAX_SEARCH_LIMIT),
  })
end

maki.api.register_tool({
  name = "history",
  kind = "read",
  description = [[Read the session's own transcript, including archived windows and subagent transcripts. Use it to recall exact earlier wording (user requests, error messages, tool outputs) instead of guessing or re-running tools, to check what a subagent actually found, and to recover dropped conversation after a compaction.

- `list_windows`: id, what sealed it (compaction or rewind), and creation time per window, current first.
- `list_items [window] [role] [sub] [limit] [max_chars_per_item]`: one line per item, `window/item, role[, sub], preview`. Main-thread items are numbered by position in the window's log, subagent items by their position among the window's subagents and position within their transcript (`s2/3`); both are stable across calls. `sub` filters by thread: "main" or a subagent name (the task description that spawned it).
- `read_item [window] item [offset_chars] [limit_chars]`: full render of one item - text, thinking, tool_use (name and input), tool_result (resolved), images as `[image omitted]`. `item` may be the whole `window/item` label from `list_items` or `search`; the label names its own window.
- `search query [window] [role] [sub] [limit]`: literal case-sensitive substring; `window/item, role[, sub], snippet` lines, with `(N matches)` when an item matches more than once.

Windows are `"current"` plus archive ids from `list_windows`; an archive is immutable, sealed by the compaction or rewind that dropped its turns. Pass ids back exactly as returned. Items are ordered by position in the window's log; the in-flight turn appears in the current window once completed. Unknown ids answer a clean not-found, limit-like arguments are clamped, never rejected.]],

  schema = {
    type = "object",
    properties = {
      command = {
        type = "string",
        enum = { "list_windows", "list_items", "read_item", "search" },
        description = "The operation to run, see the command list above.",
        required = true,
      },
      window = {
        type = "string",
        description = 'Window id: "current" or an archive id from list_windows. Defaults to the current window, or to the window in a "window/item" item.',
      },
      item = {
        type = "string",
        description = 'Item id from list_items or search: a position like "12" on the main thread, "s2/3" for subagent 2, item 3, or the whole "1/12" label. Pass back exactly as returned.',
      },
      offset_chars = {
        type = "integer",
        description = "First char of the item for read_item, 0-based.",
      },
      limit_chars = {
        type = "integer",
        description = "Max chars of the item for read_item (default 2000).",
      },
      role = {
        type = "string",
        enum = { "user", "assistant" },
        description = "Filter items by role.",
      },
      sub = {
        type = "string",
        description = 'Filter items by thread: "main" or a subagent name.',
      },
      limit = {
        type = "integer",
        description = "Max lines returned (list_items default 20, search default 20).",
      },
      max_chars_per_item = {
        type = "integer",
        description = "Max preview chars per item for list_items (default 200).",
      },
      query = {
        type = "string",
        description = "Literal case-sensitive substring for search.",
      },
    },
  },

  header = function(input)
    local parts = { input.command or "" }
    if input.window then
      parts[#parts + 1] = input.window
    end
    if input.item then
      parts[#parts + 1] = tostring(input.item)
    end
    return table.concat(parts, " ")
  end,

  restore = function(_input, output, _is_error, ctx)
    return render_content(output, ctx)
  end,

  handler = function(input, ctx)
    local result
    local err
    local cmd = input.command
    if cmd == "list_windows" then
      result, err = windows(ctx)
      if result then
        result = helpers.format_windows(result)
      end
    else
      local all, windows_err = windows(ctx)
      if not all then
        return { llm_output = "error: " .. windows_err, is_error = true }
      end
      if cmd == "list_items" then
        result, err = cmd_list_items(ctx, all, input)
      elseif cmd == "read_item" then
        result, err = cmd_read_item(ctx, all, input)
      elseif cmd == "search" then
        result, err = cmd_search(ctx, all, input)
      else
        err = "unknown command: " .. tostring(cmd)
      end
    end
    if err then
      return { llm_output = "error: " .. err, is_error = true }
    end
    local max_lines, max_bytes = output_limits.resolve({}, ctx)
    local truncated = helpers.truncation_note(result, truncate(result, max_lines, max_bytes))
    return { llm_output = truncated, body = render_content(truncated, ctx) }
  end,
})

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- Recall exact earlier wording (user requests, error messages, tool outputs) or check what a subagent found with **history**, which reads the session's full transcript, including archived windows, instead of re-running tools or guessing.",
})

-- The summary guidance and the read-back after compaction both ride
-- `agent.compact.before`, so they sit behind every compaction the same
-- way: auto and manual `/compact`, overflow, idle or mid-run. A notify
-- instead rides session activity: one answer late after an auto
-- compaction, a started turn for `/compact` on an idle session. A layer on
-- an agent.* slot costs every permission, which is the price of the
-- uniform placement (plugin.toml).
maki.api.set_slot("agent.compact.before", function(prev, value, ctx)
  local instructions =
    "The archived transcript stays readable with the history tool. The summary must still stand on its own, but exact details (full outputs, exact wording) can be left to history search and read_item instead of copying them into the summary."
  local own =
    "a compaction dropped the older turns from the context; use the history tool to search or read them back instead of redoing work"
  -- `instructions` and `continue` are one string each, so layers share them
  -- by appending: assigning would drop whatever an earlier layer put there.
  value.instructions = value.instructions and (value.instructions .. "\n\n" .. instructions)
    or instructions
  value.continue = value.continue and (value.continue .. "\n\n" .. own) or own
  return prev(value, ctx)
end)
