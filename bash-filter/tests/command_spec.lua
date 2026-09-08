-- Command-level tests: run git_diff.filter against full bash commands, exactly
-- the way the bash tool passes them ({ command = "..." }), using the real
-- tree-sitter bash grammar (tests/ts.lua).
-- Run: luajit tests/command_spec.lua

local spec_dir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]+$") or "."
package.path = spec_dir .. "/../lua/?.lua;" .. spec_dir .. "/?.lua;" .. package.path

local failures = 0

local function skip(msg)
  print("skipped: " .. msg)
  os.exit(0)
end

local ts = require("ts")
local ok, err = ts.init()
if not ok then
  skip(err)
end

-- Stand-in for the maki global so the filter runs outside the host.
local warnings = {}
maki = {
  treesitter = ts,
  log = {
    warn = function(msg) warnings[#warnings + 1] = msg end,
    error = function(msg) warnings[#warnings + 1] = msg end,
    info = function() end,
  },
}

local m = require("git_diff")

-- The filter must block these and suggest exactly the corrected command.
local block_cases = {
  { "git diff", "git diff --no-ext-diff" },
  { "git diff main..HEAD", "git diff --no-ext-diff main..HEAD" },
  { "git diff HEAD~3..HEAD", "git diff --no-ext-diff HEAD~3..HEAD" },
  { "git diff 'main..HEAD'", "git diff --no-ext-diff 'main..HEAD'" },
  { "git diff -- main..HEAD", "git diff --no-ext-diff -- main..HEAD" },
  { "git diff --stat -p", "git diff --no-ext-diff --stat -p" },
  { "git -C /the/directory diff", "git -C /the/directory diff --no-ext-diff" },
  { "git diff && git log --oneline", "git diff --no-ext-diff && git log --oneline" },
  { "git diff > /tmp/out.txt", "git diff --no-ext-diff > /tmp/out.txt" },
  { "sudo git diff", "sudo git diff --no-ext-diff" },
  { "/usr/bin/git diff", "/usr/bin/git diff --no-ext-diff" },
}

-- The filter must leave these alone.
local allow_cases = {
  "git diff --no-ext-diff",
  "git diff --ext-diff main..HEAD",
  "git diff --stat main..HEAD",
  "git diff -q main..HEAD",
  "git status",
  "echo git diff",
}

for _, c in ipairs(block_cases) do
  warnings = {}
  local reason = m.filter({ command = c[1] }, nil)
  if type(reason) ~= "string" then
    failures = failures + 1
    print(("FAIL block %q: not blocked (reason=%s)"):format(c[1], tostring(reason)))
  elseif not reason:find("  " .. c[2] .. "\n", 1, true) then
    failures = failures + 1
    print(("FAIL block %q: corrected command missing.\n%s"):format(c[1], reason))
  end
end

for _, cmd in ipairs(allow_cases) do
  warnings = {}
  local reason = m.filter({ command = cmd }, nil)
  if reason ~= nil then
    failures = failures + 1
    print(("FAIL allow %q: blocked: %s"):format(cmd, reason))
  end
end

-- Unparseable commands fail open, with a warning.
warnings = {}
local bad = m.filter({ command = "git diff |" }, nil)
if bad ~= nil then
  failures = failures + 1
  print("FAIL fail-open: unparseable command was blocked: " .. tostring(bad))
elseif #warnings == 0 then
  failures = failures + 1
  print("FAIL fail-open: no warning logged for unparseable command")
end

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print(("all %d command-level tests passed"):format(#block_cases + #allow_cases + 1))
