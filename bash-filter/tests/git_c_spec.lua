-- Tests for lua/git_c.lua: the pure -C scan plus full bash commands through
-- the real tree-sitter grammar (tests/ts.lua).
-- Run: sh tests/run.sh (luajit only; maki's host dialect)

local spec_dir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]+$") or "."
package.path = spec_dir .. "/../lua/?.lua;" .. spec_dir .. "/?.lua;" .. package.path

local failures = 0

local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(label, tostring(got), tostring(want)))
  end
end

local m = require("git_c")

local function argvs(...)
  return m.c_dir({ ... })
end

-- c_dir
check("-C sub", argvs("-C", "sub", "log"), "sub")
check("first global", argvs("--no-pager", "-C", "sub", "log"), "sub")
check("after config", argvs("-c", "core.abbrev=8", "-C", "sub", "log"), "sub")
check("after short singles", argvs("-p", "-P", "-C", "sub", "log"), "sub")
check("after assigned long", argvs("--git-dir=.git", "-C", "sub", "log"), "sub")
check("after valued long", argvs("--work-tree", "/tmp", "-C", "sub", "log"), "sub")
check("attached -Csub", argvs("-Csub", "log"), "sub")
check("attached -C=sub", argvs("-C=sub", "log"), "sub")
check("trailing -C", argvs("-C"), "")
check("path with =", argvs("-C", "a=b", "log"), "a=b")
check("subcommand first", argvs("log", "-C", "sub"), nil)
check("diff -C", argvs("diff", "-C"), nil)
check("unknown long", argvs("--unknown", "-C", "sub", "log"), nil)
check("config -c", argvs("-c", "color.ui=always", "log"), nil)
check("empty argv", argvs(), nil)

-- Command-level tests need the grammar; the pure tests above run either way.
local ts = require("ts")
local ok, err = ts.init()
if not ok then
  print("skipped command-level git_c tests: " .. tostring(err))
else
  local warnings = {}
  maki = {
    treesitter = ts,
    log = {
      warn = function(msg) warnings[#warnings + 1] = msg end,
      error = function(msg) warnings[#warnings + 1] = msg end,
      info = function() end,
    },
  }

  local block_cases = {
    { "git -C sub log --oneline", { "git -C sub", "sub", "workdir" } },
    { "git -Csub log", { "sub", "workdir" } },
    { "git -C=sub log", { "sub", "workdir" } },
    { "git --no-pager -C sub log", { "sub", "workdir" } },
    { "git -c core.abbrev=8 -C sub status", { "sub", "workdir" } },
    { "git -C 'sub dir' status", { "sub dir", "workdir" } },
    { "git -C \"sub dir\" status", { "sub dir", "workdir" } },
    { "git -C", { "workdir", "that directory" } },
    { "sudo git -C sub log", { "sub", "workdir" } },
    { "/usr/bin/git -C sub log", { "sub", "workdir" } },
    { "X=1 git -C sub log", { "sub", "workdir" } },
    { "git -C sub log | wc -l", { "sub", "workdir" } },
    { "git status && git -C sub log", { "sub", "workdir" } },
  }

  local allow_cases = {
    "git status",
    "git -c color.ui=always log",
    "git --no-pager log",
    "git --work-tree /tmp log",
    "git diff -C --stat",
    "git log -C -C",
    "git config user.name",
    "echo git -C sub log",
  }

  for _, c in ipairs(block_cases) do
    warnings = {}
    local reason = m.filter({ command = c[1] }, nil)
    if type(reason) ~= "string" then
      failures = failures + 1
      print(("FAIL block %q: not blocked (reason=%s)"):format(c[1], tostring(reason)))
    else
      for _, needle in ipairs(c[2]) do
        if not reason:find(needle, 1, true) then
          failures = failures + 1
          print(("FAIL block %q: message missing %q.\n%s"):format(c[1], needle, reason))
        end
      end
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
  local bad = m.filter({ command = "git -C |" }, nil)
  if bad ~= nil then
    failures = failures + 1
    print("FAIL fail-open: unparseable command was blocked: " .. tostring(bad))
  elseif #warnings == 0 then
    failures = failures + 1
    print("FAIL fail-open: no warning logged for unparseable command")
  end
end

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all git_c tests passed")
