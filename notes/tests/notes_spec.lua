-- Standalone tests for the pure parts of lua/notes_helpers.lua.
-- Run: sh tests/run.sh (luajit only; maki's host dialect)

package.path = "lua/?.lua;" .. package.path
local h = require("notes_helpers")

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

-- safe_path
check("plain path", (h.safe_path("decisions.md")), "decisions.md")
check("nested path", (h.safe_path("design/api.md")), "design/api.md")
check_nil("absolute rejected", (select(1, h.safe_path("/etc/passwd"))))
check("absolute err", (select(2, h.safe_path("/etc/passwd"))), h.PATH_ABSOLUTE_ERR)
check_nil("leading backslash rejected", (select(1, h.safe_path("\\escape"))))
check_nil("drive letter rejected", (select(1, h.safe_path("C:notes"))))
check_nil("parent escape rejected", (select(1, h.safe_path("../escape.md"))))
check("parent escape err", (select(2, h.safe_path("../escape.md"))), h.PATH_INVALID_ERR)
check_nil("dot component rejected", (select(1, h.safe_path("a/./b"))))
check_nil("empty component rejected", (select(1, h.safe_path("a//b"))))
check_nil("trailing slash rejected", (select(1, h.safe_path("a/b/"))))
check_nil("empty path rejected", (select(1, h.safe_path(""))))
check("empty path err", (select(2, h.safe_path(""))), h.PATH_REQUIRED_ERR)
check_nil("nul rejected", (select(1, h.safe_path("a\0b"))))
check("tilde stays literal", (h.safe_path("~/tilde.md")), "~/tilde.md")
check("depth cap allowed", (h.safe_path("a/b/c/d/e/f/g/h.md")), "a/b/c/d/e/f/g/h.md")
check_nil("too deep rejected", (select(1, h.safe_path("a/b/c/d/e/f/g/h/i.md"))))
check("too deep err", (select(2, h.safe_path("a/b/c/d/e/f/g/h/i.md"))), (h.PATH_TOO_DEEP_FMT):format(h.MAX_PATH_DEPTH))

-- clamp
check("clamp default on nil", h.clamp(nil, 20, 50), 20)
check("clamp default on zero", h.clamp(0, 20, 50), 20)
check("clamp default on nan", h.clamp(0 / 0, 20, 50), 20)
check("clamp floors", h.clamp(9.7, 20, 50), 9)
check("clamp caps", h.clamp(999, 20, 50), 50)

-- read_slice line ranges
check("slice whole file", h.read_slice("a\nb\nc", nil, nil, "n.md"), "a\nb\nc")
check("slice from line", h.read_slice("a\nb\nc", 2, nil, "n.md"), "n.md (lines 2-3 of 3):\nb\nc")
check("slice range", h.read_slice("a\nb\nc\nd", 2, 3, "n.md"), "n.md (lines 2-3 of 4):\nb\nc")
check("slice start past eof clamps", h.read_slice("a\nb", 10, nil, "n.md"), "n.md (lines 2-2 of 2):\nb")
check("slice stop past eof clamps", h.read_slice("a\nb\nc", 1, 10, "n.md"), "n.md (lines 1-3 of 3):\na\nb\nc")
check("slice empty file", h.read_slice("", nil, nil, "n.md"), "")
check("slice single line file", h.read_slice("only", nil, nil, "n.md"), "only")

-- cap_read_output
local big = ("x"):rep(h.MAX_READ_BYTES + 100)
check("cap leaves small output", h.cap_read_output("small"), "small")
check(
  "cap kicks in",
  h.cap_read_output(big):sub(h.MAX_READ_BYTES + 1),
  "\n... (output truncated at " .. h.MAX_READ_BYTES .. " bytes; " .. h.CAP_READ_HINT .. ")"
)
local split_safe = "a" .. ("é"):rep(h.MAX_READ_BYTES / 2 + 1)
local capped = h.cap_read_output(split_safe)
check("cap never splits a codepoint", capped:sub(h.MAX_READ_BYTES - 2, h.MAX_READ_BYTES - 1), "é")

-- prepare_query
check("query passes through", h.prepare_query("find me"), "find me")
check("query truncated to cap", h.prepare_query(("q"):rep(h.MAX_QUERY_CHARS + 10)), ("q"):rep(h.MAX_QUERY_CHARS))
check("query required", (select(2, h.prepare_query(""))), h.QUERY_REQUIRED_ERR)
check_nil("query nil rejected", (select(1, h.prepare_query(nil))))

-- search_lines
local content = "alpha\nbeta gamma\nalphabetic\nno match here\nalpha again"
local matches = h.search_lines("notes.md", content, "alpha", 10)
check("search finds all", #matches, 3)
check("search formats", matches[1], "notes.md:1: alpha")
check("search numbers lines", matches[3], "notes.md:5: alpha again")
check("search respects cap", #h.search_lines("n.md", content, "a", 2), 2)
check("search no match", #h.search_lines("n.md", content, "zzz", 10), 0)

-- format_search
check("format empty groups", h.format_search({}), h.NO_MATCHES_MSG)
check("format flattens groups", h.format_search({ { "a:1: x" }, { "b:2: y", "b:3: z" } }), "a:1: x\nb:2: y\nb:3: z")

-- scan_capped_hint
check_nil("scan hint below cap", h.scan_capped_hint(10, 50))
check_nil("scan hint at cap with nothing left", h.scan_capped_hint(h.MAX_SCAN_FILES, h.MAX_SCAN_FILES))
check(
  "scan hint at cap",
  h.scan_capped_hint(h.MAX_SCAN_FILES, h.MAX_SCAN_FILES + 5),
  (h.SCAN_CAPPED_FMT):format(h.MAX_SCAN_FILES, h.MAX_SCAN_FILES + 5)
)

-- format_list
local zero_date = os.date("%Y-%m-%d %H:%M", 0)
check("list empty", h.format_list({}), h.NO_NOTES_MSG)
check(
  "list sorts and formats",
  h.format_list({
    { path = "b.md", bytes = 10, mtime = 0 },
    { path = "a.md", bytes = 5, mtime = 0 },
  }),
  "a.md  5 bytes  " .. zero_date .. "\nb.md  10 bytes  " .. zero_date
)
check("list nil mtime", h.format_list({ { path = "a.md", bytes = 1, mtime = nil } }), "a.md  1 bytes  " .. zero_date)

-- check_size
check_nil("size under cap", h.check_size(0, ("x"):rep(h.MAX_FILE_BYTES)))
check("size over cap", h.check_size(0, ("x"):rep(h.MAX_FILE_BYTES + 1)), h.TOO_BIG_FMT:format(h.MAX_FILE_BYTES))
check("append over cap", h.check_size(h.MAX_FILE_BYTES - 5, "xxxxxx"), h.TOO_BIG_FMT:format(h.MAX_FILE_BYTES))
check("empty text rejected", h.check_size(0, ""), h.TEXT_REQUIRED_ERR)
check("nil text rejected", h.check_size(0, nil), h.TEXT_REQUIRED_ERR)

-- should_remind hysteresis
local steps = { 0.3, 0.6, 0.8 }
local fire, state
fire, state = h.should_remind(nil, 30, 100, steps)
check("fires at first step", fire, 0.3)
check("state after first step", state, 1)
fire, state = h.should_remind(state, 40, 100, steps)
check("quiet between steps", fire, nil)
check("keeps state between steps", state, 1)
fire, state = h.should_remind(state, 70, 100, steps)
check("fires at second step", fire, 0.6)
check("state after second step", state, 2)
fire, state = h.should_remind(state, 95, 100, steps)
check("fires at top step", fire, 0.8)
check("state after top step", state, 3)
fire, state = h.should_remind(state, 96, 100, steps)
check("quiet while satisfied", fire, nil)
-- One event that jumps several steps fires only the highest.
fire, state = h.should_remind(0, 85, 100, steps)
check("jump fires highest only", fire, 0.8)
check("jump state", state, 3)
-- Falling below a step re-arms it, but not the ones still satisfied.
fire, state = h.should_remind(state, 50, 100, steps)
check("below top re-arms it", state, 1)
check("no fire on the drop itself", fire, nil)
fire, state = h.should_remind(state, 61, 100, steps)
check("refires second after re-arm", fire, 0.6)
fire, state = h.should_remind(state, 20, 100, steps)
check("below all steps re-arms fully", state, 0)
fire, state = h.should_remind(state, 31, 100, steps)
check("refires first after full re-arm", fire, 0.3)
fire = select(1, h.should_remind(0, 100, 0, steps))
check("ignores zero window", fire, nil)
fire = select(1, h.should_remind(0, nil, 100, steps))
check("ignores nil size", fire, nil)

-- reminder_text per step (before setup overrides anything)
check(
  "first step text",
  h.reminder_text(41, 100, 0.4),
  "context is 41% full: start a note now with important session state, so a later compaction cannot drop it"
)
check(
  "second step text",
  h.reminder_text(61, 100, 0.6),
  "context is 61% full: update (or start) your notes with important session state, so a compaction cannot drop it"
)
check(
  "top step text",
  h.reminder_text(83, 100, 0.8),
  "context is nearly full (83% of the window): save important session state to notes now, before a compaction drops it"
)

-- state_from_marker
check("marker state for legacy marker", h.state_from_marker("1", steps), 3)
check("marker state for top step", h.state_from_marker("0.8", steps), 3)
check("marker state for first step", h.state_from_marker("0.3", steps), 1)
check("marker state below all steps", h.state_from_marker("0.1", steps), 0)
check("marker state for garbage", h.state_from_marker("junk", steps), 3)

-- setup
check("default steps", table.concat(h.remind_steps(), ","), "0.4,0.6,0.8")
h.setup({ remind_at = 0.9, reminder_text = "custom" })
check("single fraction becomes one step", table.concat(h.remind_steps(), ","), "0.9")
check("custom reminder text", h.reminder_text(95, 100), "custom")
fire = select(1, h.should_remind(nil, 85, 100, h.remind_steps()))
check("setup fraction applied", fire, nil)
h.setup({ remind_steps = { 0.5, 0.2 } })
check("steps sorted", table.concat(h.remind_steps(), ","), "0.2,0.5")
h.setup({ remind_steps = { 2, "x" } })
check("setup ignores bad steps", table.concat(h.remind_steps(), ","), "0.2,0.5")
h.setup({ remind_at = 2 })
check("setup ignores bad fraction", table.concat(h.remind_steps(), ","), "0.2,0.5")
h.setup("junk")
check("setup ignores non-table", table.concat(h.remind_steps(), ","), "0.2,0.5")

-- compact_hint
check_nil("hint no files", h.compact_hint({}))
check_nil("hint nil files", h.compact_hint(nil))
check(
  "hint names files",
  h.compact_hint({ "a.md", "b.md" }),
  "This session keeps notes that survive compaction unchanged: a.md, b.md. Include in your summary the note filenames and an instruction to run `notes list` and read the relevant notes before redoing any work (the summary alone can miss filenames). Do not copy note contents into the summary."
)
local many = {}
for i = 1, h.HINT_LIST_CAP + 7 do
  many[i] = "n" .. i .. ".md"
end
check("hint caps file list", h.compact_hint(many):match("n50%.md, and 7 more%."), "n50.md, and 7 more.")

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
