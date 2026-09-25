-- Standalone tests for the pure parts of lua/history_helpers.lua.
-- Run: sh tests/run.sh (luajit only; maki's host dialect)

package.path = "lua/?.lua;" .. package.path
local h = require("history_helpers")

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

local function msg(role, text)
  return { role = role, content = { { type = "text", text = text } } }
end

local function window(id, messages, subagents)
  return { id = id, created_at = 0, messages = messages, subagents = subagents or {} }
end

-- flatten_items
local sub = { name = "research", nr = 1, messages = { msg("user", "find the api"), msg("assistant", "found it") } }
local w = window("1", { msg("user", "fix the bug"), msg("assistant", "on it") }, { sub })
local items = h.flatten_items(w)
check("flatten main then subagents", #items, 4)
check("flatten labels main", items[1].sub, h.MAIN_SUB)
check("flatten labels subagent", items[3].sub, "research")
check("flatten keeps role", items[3].role, "user")
check("flatten main ids", items[2].id, "2")
check("flatten subagent ids", items[3].id, "s1/1")
check("flatten subagent ids per transcript", items[4].id, "s1/2")
check("flatten empty window", #h.flatten_items(window("1", {}, {})), 0)
check("flatten nil subagents", #h.flatten_items({ id = "1", messages = { msg("user", "x") } }), 1)
check(
  "flatten falls back to list position without nr",
  h.flatten_items(window("1", {}, { { name = "legacy", messages = { msg("user", "old") } } }))[1].id,
  "s1/1"
)

local grown = window("1", { msg("user", "a"), msg("assistant", "b"), msg("user", "c") }, { sub })
local grown_items = h.flatten_items(grown)
check("subagent ids survive main growth", grown_items[4].id, "s1/1")
check("main ids grow with the log", grown_items[3].id, "3")

-- find_window
check("find_window hits", (h.find_window({ w }, "1")).id, "1")
check_nil("find_window misses", h.find_window({ w }, "2"))
check_nil("find_window nil list", h.find_window(nil, "1"))

-- render_message
check("render text", h.render_message(msg("user", "hello")), "hello")
check(
  "render thinking",
  h.render_message({ role = "assistant", content = { { type = "thinking", thinking = "hmm" } } }),
  "[thinking] hmm"
)
check(
  "render tool_use",
  h.render_message({
    role = "assistant",
    content = { { type = "tool_use", id = "t1", name = "bash", input = { command = "ls", timeout = 5 } } },
  }),
  "tool_use bash: {command=ls, timeout=5}"
)
check(
  "render tool_result",
  h.render_message({
    role = "user",
    content = { { type = "tool_result", tool_use_id = "t1", content = "done" } },
  }),
  "tool_result: done"
)
check(
  "render error tool_result",
  h.render_message({
    role = "user",
    content = { { type = "tool_result", tool_use_id = "t1", content = "boom", is_error = true } },
  }),
  "tool_result (error): boom"
)
check(
  "render image omitted",
  h.render_message({ role = "user", content = { { type = "image", source = {} } } }),
  "[image omitted]"
)
check(
  "render redacted thinking",
  h.render_message({ role = "assistant", content = { { type = "redacted_thinking", data = "xx" } } }),
  "[redacted thinking]"
)
check("render unknown block", h.render_message({ role = "user", content = { { type = "mystery" } } }), "[mystery]")
check(
  "render joins blocks",
  h.render_message({
    role = "assistant",
    content = { { type = "text", text = "a" }, { type = "text", text = "b" } },
  }),
  "a\nb"
)
check("render empty content", h.render_message({ role = "user", content = {} }), "")

-- serialize
check("serialize string", h.serialize("s"), "s")
check("serialize number", h.serialize(5), "5")
check("serialize bool", h.serialize(true), "true")
check("serialize empty table", h.serialize({}), "[]")
check("serialize array", h.serialize({ "a", 1 }), "[a, 1]")
check("serialize nested", h.serialize({ b = 2, a = { "x" } }), "{a=[x], b=2}")

-- preview
check("preview short", h.preview("short text", 20), "short text")
check("preview collapses whitespace", h.preview("a\n  b\tc", 200), "a b c")
check("preview caps", #h.preview(("ab"):rep(200), 20) <= 23, true)
check("preview keeps whole codepoints", h.preview(("é"):rep(16), 5), "éé...")

-- format_items
local list_opts = { limit = 20, max_chars_per_item = 200 }
check(
  "format_items labels and ids",
  h.format_items("current", items, list_opts),
  "current/1, user, fix the bug\ncurrent/2, assistant, on it\ncurrent/s1/1, user, research, find the api\ncurrent/s1/2, assistant, research, found it"
)
check(
  "format_items role filter",
  h.format_items("current", items, {
    role = "assistant",
    limit = 20,
    max_chars_per_item = 200,
  }),
  "current/2, assistant, on it\ncurrent/s1/2, assistant, research, found it"
)
check(
  "format_items sub filter",
  h.format_items("current", items, { sub = "research", limit = 20, max_chars_per_item = 200 }),
  "current/s1/1, user, research, find the api\ncurrent/s1/2, assistant, research, found it"
)
check(
  "format_items main filter",
  h.format_items("current", items, { sub = "main", limit = 20, max_chars_per_item = 200 }),
  "current/1, user, fix the bug\ncurrent/2, assistant, on it"
)
local limited = h.format_items("current", items, { limit = 2, max_chars_per_item = 200 })
check("format_items limit line count", select(2, limited:gsub("\n", "\n")) + 1, 2)
check_nil("format_items limit drops the tail", limited:find("s1/"))
check(
  "format_items no matches",
  h.format_items("current", items, { role = "bogus", limit = 20, max_chars_per_item = 200 }),
  h.NO_MATCHES_MSG
)
check(
  "format_items preview caps",
  h.format_items(
    "current",
    h.flatten_items(window("current", { msg("user", ("y"):rep(300)) })),
    { limit = 20, max_chars_per_item = 50 }
  ):sub(-3),
  "..."
)

-- read_item
local short_items = h.flatten_items(window("current", { msg("assistant", ("z"):rep(100)) }))
local long = window("current", { msg("assistant", ("z"):rep(30000)) })
local long_items = h.flatten_items(long)
check(
  "read_item full under cap",
  h.read_item("current", short_items, 1, nil, h.MAX_READ_CHARS),
  "current/1, assistant:\n" .. ("z"):rep(100)
)
local long_read = h.read_item("current", long_items, 1, nil, nil)
check("read_item long slices header", long_read:sub(1, 45), "current/1, assistant (chars 1-2000 of 30000):")
check("read_item long slices body length", #long_read, 45 + 1 + 2000)
check(
  "read_item slice",
  h.read_item("current", long_items, 1, 10, 5),
  "current/1, assistant (chars 11-15 of 30000):\nzzzzz"
)
check(
  "read_item offset past end",
  (select(2, h.read_item("current", long_items, 1, 30000, 100))),
  h.ITEM_NOT_FOUND_FMT:format("current", 1) .. " (offset 30000 is past the end of 30000 chars)"
)
check_nil("read_item unknown item", (select(1, h.read_item("current", long_items, 99, nil, nil))))
check(
  "read_item unknown item err",
  (select(2, h.read_item("current", long_items, 99, nil, nil))),
  h.ITEM_NOT_FOUND_FMT:format("current", 99)
)
check("read_item offset clamps negative", h.read_item("current", long_items, 1, -5, 5):sub(1, 10), "current/1,")
check(
  "read_item with sub label",
  h.read_item("1", items, "s1/1", nil, h.MAX_READ_CHARS),
  "1/s1/1, user, research:\nfind the api"
)
check("read_item accepts a numeric id", h.read_item("current", long_items, 1, nil, nil):sub(1, 16), "current/1, assis")
check(
  "read_item empty item",
  h.read_item("current", h.flatten_items(window("current", { { role = "user", content = {} } })), 1, nil, nil),
  "current/1, user:\n(empty item)"
)

-- snippet
check("snippet covers short text", h.snippet("the quick brown fox", 5, 9), "the quick brown fox")
check("snippet start ellipsis", h.snippet(("p"):rep(200) .. "match", 201, 205), "..." .. ("p"):rep(60) .. "match")
check("snippet end ellipsis", h.snippet("match" .. ("p"):rep(200), 1, 5), "match" .. ("p"):rep(60) .. "...")
check(
  "snippet both ellipses",
  h.snippet(("p"):rep(200) .. "match" .. ("p"):rep(200), 201, 205),
  "..." .. ("p"):rep(60) .. "match" .. ("p"):rep(60) .. "..."
)
check("snippet collapses newlines", h.snippet("a\nb\nmatch\nc", 6, 10), "a b match c")

-- format_search
local two_windows = {
  window("current", { msg("user", "deploy failed loudly"), msg("assistant", "checking logs now") }),
  window("1", { msg("user", "old deploy note") }, {
    { name = "research", nr = 1, messages = { msg("assistant", "deploy config found") } },
  }),
}
check(
  "search across windows",
  h.format_search(two_windows, { query = "deploy", limit = 20 }),
  "current/1, user, deploy failed loudly\n1/1, user, old deploy note\n1/s1/1, assistant, research, deploy config found"
)
check(
  "search scoped to window",
  h.format_search(two_windows, { query = "deploy", window = "current", limit = 20 }),
  "current/1, user, deploy failed loudly"
)
check(
  "search role filter",
  h.format_search(two_windows, { query = "deploy", role = "assistant", limit = 20 }),
  "1/s1/1, assistant, research, deploy config found"
)
check(
  "search sub filter",
  h.format_search(two_windows, { query = "deploy", sub = "main", limit = 20 }),
  "current/1, user, deploy failed loudly\n1/1, user, old deploy note"
)
check(
  "search limit",
  h.format_search(two_windows, { query = "deploy", limit = 2 }),
  "current/1, user, deploy failed loudly\n1/1, user, old deploy note"
)
check(
  "search per-item match count",
  h.format_search(
    { window("current", { msg("assistant", "deploy now, deploy again, and deploy once more") }) },
    { query = "deploy", limit = 20 }
  ),
  "current/1, assistant, (3 matches) deploy now, deploy again, and deploy once more"
)
check("search no match", h.format_search(two_windows, { query = "zzz", limit = 20 }), h.NO_MATCHES_MSG)
check("search case sensitive", h.format_search(two_windows, { query = "Deploy", limit = 20 }), h.NO_MATCHES_MSG)

-- prepare_query / clamp
check("query passes through", h.prepare_query("find me"), "find me")
check("query truncated to cap", h.prepare_query(("q"):rep(h.MAX_QUERY_CHARS + 10)), ("q"):rep(h.MAX_QUERY_CHARS))
check("query required", (select(2, h.prepare_query(""))), h.QUERY_REQUIRED_ERR)
check("clamp default on nil", h.clamp(nil, 20, 50), 20)
check("clamp caps", h.clamp(999, 20, 50), 50)
check("clamp floors", h.clamp(9.7, 20, 50), 9)

-- format_windows
local zero_date = os.date("%Y-%m-%d %H:%M", 0)
check(
  "format_windows",
  h.format_windows({
    window("current", { msg("user", "a") }, { { name = "s", messages = { msg("user", "b") } } }),
    window("1", {}),
  }),
  "current  2 items  2 chars  " .. zero_date .. "\n1  0 items  0 chars  " .. zero_date
)
check("format_windows empty", h.format_windows({}), "")
check("format_windows nil", h.format_windows(nil), "")

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
