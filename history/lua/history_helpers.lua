-- Pure logic for the history plugin: window/item shaping, filters,
-- truncation, and search. No `maki` global here so the spec runs under plain
-- luajit.

local M = {}

M.MAX_QUERY_CHARS = 1000
M.DEFAULT_ITEM_LIMIT = 20
M.MAX_ITEM_LIMIT = 50
M.DEFAULT_PREVIEW_CHARS = 200
M.MAX_PREVIEW_CHARS = 2000
M.DEFAULT_READ_CHARS = 2000
M.MAX_READ_CHARS = 20000
M.DEFAULT_SEARCH_LIMIT = 20
M.MAX_SEARCH_LIMIT = 20
M.SNIPPET_CHARS = 120

M.CURRENT_WINDOW = "current"
M.MAIN_SUB = "main"

M.QUERY_REQUIRED_ERR = "query is required"
M.WINDOW_ITEM_REQUIRED_ERR = "window and item are required"
M.NO_MATCHES_MSG = "no matches"
M.WINDOW_NOT_FOUND_FMT = "window not found: %s"
M.ITEM_NOT_FOUND_FMT = "item not found: %s/%s"

local function safe_cut_end(s, cut)
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return cut
end

local function safe_cut_start(s, from)
  while from <= #s do
    local b = s:byte(from)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    from = from + 1
  end
  return from
end

function M.clamp(v, default, cap)
  if type(v) ~= "number" or v ~= v or v < 1 then
    return default
  end
  return math.min(math.floor(v), cap)
end

function M.prepare_query(query)
  if type(query) ~= "string" or query == "" then
    return nil, M.QUERY_REQUIRED_ERR
  end
  return query:sub(1, M.MAX_QUERY_CHARS)
end

function M.find_window(windows, id)
  for _, window in ipairs(windows or {}) do
    if window.id == id then
      return window
    end
  end
  return nil
end

-- The item list of a window: its messages in order, then each subagent's
-- messages in order. Main items are numbered by position in the window's
-- log, stable because archives are immutable and the current window only
-- shrinks via a rewrite that archives first. A subagent's items are keyed
-- by its spawn slot and position within its transcript ("s2/3"), both
-- stable once the transcript attaches, so the ids survive the main log
-- growing between calls.
function M.flatten_items(window)
  local items = {}
  for i, msg in ipairs(window.messages or {}) do
    items[#items + 1] = { id = tostring(i), role = msg.role, content = msg.content, sub = M.MAIN_SUB }
  end
  for si, subagent in ipairs(window.subagents or {}) do
    local nr = subagent.nr or si
    for i, msg in ipairs(subagent.messages or {}) do
      items[#items + 1] = {
        id = "s" .. nr .. "/" .. i,
        role = msg.role,
        content = msg.content,
        sub = subagent.name,
      }
    end
  end
  return items
end

-- Compact one-line rendering of a tool_use input, JSON-ish without a host
-- JSON dependency.
function M.serialize(v)
  local t = type(v)
  if t == "string" then
    return v
  end
  if t == "number" or t == "boolean" then
    return tostring(v)
  end
  if t ~= "table" then
    return tostring(v)
  end
  local parts = {}
  if #v > 0 or next(v) == nil then
    for i = 1, #v do
      parts[i] = M.serialize(v[i])
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. M.serialize(v[k])
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.render_message(msg)
  local parts = {}
  for _, block in ipairs(msg.content or {}) do
    local t = block.type
    if t == "text" then
      parts[#parts + 1] = block.text
    elseif t == "thinking" then
      parts[#parts + 1] = "[thinking] " .. block.thinking
    elseif t == "redacted_thinking" then
      parts[#parts + 1] = "[redacted thinking]"
    elseif t == "tool_use" then
      parts[#parts + 1] = "tool_use " .. block.name .. ": " .. M.serialize(block.input)
    elseif t == "tool_result" then
      parts[#parts + 1] = "tool_result" .. (block.is_error and " (error)" or "") .. ": " .. block.content
    elseif t == "image" then
      parts[#parts + 1] = "[image omitted]"
    else
      parts[#parts + 1] = "[" .. tostring(t) .. "]"
    end
  end
  return table.concat(parts, "\n")
end

local function one_line(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.preview(text, max_chars)
  text = one_line(text)
  if #text <= max_chars then
    return text
  end
  return text:sub(1, safe_cut_end(text, max_chars)) .. "..."
end

function M.format_windows(windows)
  local lines = {}
  for _, window in ipairs(windows or {}) do
    local items = M.flatten_items(window)
    -- Rendered length, so the number matches what read_item can return.
    local chars = 0
    for _, item in ipairs(items) do
      chars = chars + #M.render_message(item)
    end
    lines[#lines + 1] =
      window.id .. "  " .. #items .. " items  " .. chars .. " chars  " .. os.date("%Y-%m-%d %H:%M", window.created_at or 0)
  end
  return table.concat(lines, "\n")
end

local function item_label(window_id, item)
  local sub = item.sub ~= M.MAIN_SUB and (", " .. item.sub) or ""
  return window_id .. "/" .. item.id .. ", " .. item.role .. sub
end

function M.format_items(window_id, items, opts)
  local lines = {}
  for _, item in ipairs(items) do
    if #lines >= opts.limit then
      break
    end
    if (not opts.role or item.role == opts.role) and (not opts.sub or item.sub == opts.sub) then
      lines[#lines + 1] = item_label(window_id, item)
        .. ", "
        .. M.preview(M.render_message(item), opts.max_chars_per_item)
    end
  end
  if #lines == 0 then
    return M.NO_MATCHES_MSG
  end
  return table.concat(lines, "\n")
end

function M.read_item(window_id, items, item_id, offset_chars, limit_chars)
  local id = tostring(item_id or "")
  local item
  for _, it in ipairs(items) do
    if it.id == id then
      item = it
      break
    end
  end
  if not item then
    return nil, M.ITEM_NOT_FOUND_FMT:format(window_id, id)
  end
  local rendered = M.render_message(item)
  if #rendered == 0 then
    return item_label(window_id, item) .. ":\n(empty item)"
  end
  local offset = type(offset_chars) == "number" and math.max(0, math.floor(offset_chars)) or 0
  local limit = M.clamp(limit_chars, M.DEFAULT_READ_CHARS, M.MAX_READ_CHARS)
  if offset >= #rendered then
    return nil,
      M.ITEM_NOT_FOUND_FMT:format(window_id, id)
        .. " (offset "
        .. offset
        .. " is past the end of "
        .. #rendered
        .. " chars)"
  end
  local last = safe_cut_end(rendered, math.min(offset + limit, #rendered))
  local body = rendered:sub(offset + 1, last)
  if offset == 0 and last >= #rendered then
    return item_label(window_id, item) .. ":\n" .. body
  end
  return item_label(window_id, item)
    .. " (chars "
    .. (offset + 1)
    .. "-"
    .. last
    .. " of "
    .. #rendered
    .. "):\n"
    .. body
end

function M.snippet(text, match_start, match_end)
  local half = math.floor(M.SNIPPET_CHARS / 2)
  local from = safe_cut_start(text, math.max(1, match_start - half))
  local to = safe_cut_end(text, math.min(#text, match_end + half))
  local prefix = from > 1 and "..." or ""
  local suffix = to < #text and "..." or ""
  return prefix .. one_line(text:sub(from, to)) .. suffix
end

function M.format_search(windows, opts)
  local lines = {}
  for _, window in ipairs(windows or {}) do
    if #lines >= opts.limit then
      break
    end
    if not opts.window or window.id == opts.window then
      local items = M.flatten_items(window)
      for _, item in ipairs(items) do
        if #lines >= opts.limit then
          break
        end
        if (not opts.role or item.role == opts.role) and (not opts.sub or item.sub == opts.sub) then
          local rendered = M.render_message(item)
          local s, e = rendered:find(opts.query, 1, true)
          if s then
            -- Count the rest of the matches so the model knows whether one
            -- read_item covers the item or only the first hit.
            local count = 1
            local from = e + 1
            while true do
              local s2, e2 = rendered:find(opts.query, from, true)
              if not s2 then
                break
              end
              count = count + 1
              from = e2 + 1
            end
            local prefix = count > 1 and ("(" .. count .. " matches) ") or ""
            lines[#lines + 1] = item_label(window.id, item) .. ", " .. prefix .. M.snippet(rendered, s, e)
          end
        end
      end
    end
  end
  if #lines == 0 then
    return M.NO_MATCHES_MSG
  end
  return table.concat(lines, "\n")
end

return M
