-- Tests for lua/rg.lua: the pure flag scan plus full bash commands through the
-- real tree-sitter grammar (tests/ts.lua).
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

local m = require("rg")

local function flags(...)
  return m.forbidden_flag({ ... })
end

-- forbidden_flag
check("-r", flags("-r"), "--replace")
check("-r with value", flags("-r", "x"), "--replace")
check("-r attached value", flags("-rX"), "--replace")
check("-nr bundle", flags("-nr"), "--replace")
check("--replace", flags("--replace"), "--replace")
check("--replace=value", flags("--replace=x"), "--replace")
check("--replace with value", flags("--replace", "x"), "--replace")
check("--pre", flags("--pre", "cat"), "--pre")
check("--pre=value", flags("--pre=cat"), "--pre")
check("--hostname-bin", flags("--hostname-bin", "/bin/hostname"), "--hostname-bin")
check("--hostname-bin=value", flags("--hostname-bin=/bin/hostname"), "--hostname-bin")
check("plain pattern", flags("pattern"), nil)
check("other short flag", flags("-n"), nil)
check("-e value -r", flags("-e", "-r"), nil)
check("-e attached r", flags("-er"), nil)
check("--regexp value -r", flags("--regexp", "-r"), nil)
check("--glob value --pre", flags("--glob", "--pre", "x"), nil)
check("after --", flags("--", "-r"), nil)
check("after -- pre", flags("--", "--pre"), nil)
check("--no-replace", flags("--no-replace"), nil)
check("--no-pre", flags("--no-pre"), nil)
check("long with = then -r", flags("--glob=*.lua", "-r"), "--replace")
check("long value then -r", flags("--glob", "*.lua", "-r"), "--replace")

-- Command-level tests need the grammar; the pure tests above run either way.
local ts = require("ts")
local ok, err = ts.init()
if not ok then
  print("skipped command-level rg tests: " .. tostring(err))
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
    { "rg -r foo", { "--replace", "recursively" } },
    { "rg -r foo .", { "--replace", "recursively" } },
    { "rg -rn foo", { "--replace", "recursively" } },
    { "rg -i -r foo", { "--replace", "recursively" } },
    { "rg --replace foo", { "--replace", "recursively" } },
    { "rg --replace=foo bar", { "--replace", "recursively" } },
    { "rg --pre cat foo", { "--pre", "external command" } },
    { "rg --pre=cat foo", { "--pre", "external command" } },
    { "rg --hostname-bin /bin/hostname foo", { "--hostname-bin", "external command" } },
    { "rg --hostname-bin=/bin/hostname foo", { "--hostname-bin", "external command" } },
    { "sudo rg -r foo", { "--replace", "recursively" } },
    { "/usr/bin/rg -r foo", { "--replace", "recursively" } },
    { "rg -r foo && rg --pre cat bar", { "--replace", "recursively" } },
  }

  local allow_cases = {
    "rg foo",
    "rg -n foo",
    "rg -e -r",
    "rg -er",
    "rg --glob -r foo",
    "rg --glob --pre foo",
    "rg -e --pre",
    "rg --no-pre foo",
    "rg -- -r",
    "rg -- --pre",
    "echo rg -r",
    "git diff",
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
end

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all rg tests passed")
