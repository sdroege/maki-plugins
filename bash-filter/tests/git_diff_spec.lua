-- Standalone tests for the pure parts of lua/git_diff.lua.
-- Run: sh tests/run.sh (luajit only; maki's host dialect)

package.path = "lua/?.lua;" .. package.path
local m = require("git_diff")

local failures = 0

local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(label, tostring(got), tostring(want)))
  end
end

local function classify(...)
  return m.classify_diff_args({ ... })
end

-- classify_diff_args
check("bare diff", classify(), "patch")
check("--cached", classify("--cached"), "patch")
check("rev arg", classify("HEAD"), "patch")
check("--stat", classify("--stat"), "allow")
check("--numstat", classify("--numstat"), "allow")
check("--shortstat", classify("--shortstat"), "allow")
check("--name-only", classify("--name-only"), "allow")
check("--name-status", classify("--name-status"), "allow")
check("--check", classify("--check"), "allow")
check("--summary", classify("--summary"), "allow")
check("--raw", classify("--raw"), "allow")
check("--no-patch", classify("--no-patch"), "allow")
check("--quiet", classify("--quiet"), "allow")
check("-q", classify("-q"), "allow")
check("-p", classify("-p"), "patch")
check("--patch", classify("--patch"), "patch")
check("--stat with -p", classify("--stat", "-p"), "patch")
check("--stat with --patch-with-stat", classify("--stat", "--patch-with-stat"), "patch")
check("-pq", classify("-pq"), "patch")
check("--no-ext-diff", classify("--no-ext-diff"), "allow")
check("-p with --no-ext-diff", classify("-p", "--no-ext-diff"), "allow")
check("--ext-diff", classify("--ext-diff"), "allow")
check("--no-ext-diff after rev", classify("HEAD", "--no-ext-diff"), "allow")
check("--stat after -- is a pathspec", classify("--", "--stat"), "patch")
check("--no-ext-diff after -- is a pathspec", classify("--", "--no-ext-diff"), "patch")
check("unknown long flag", classify("--foo"), "patch")
check("unknown short flag", classify("-x"), "patch")
check("two diffs worth of args", classify("--cached", "--", "src/main.c"), "patch")

-- find_subcommand
check("plain", m.find_subcommand({ "diff" }), 1)
check("diff with args", m.find_subcommand({ "diff", "--stat" }), 1)
check("-C takes arg", m.find_subcommand({ "-C", "sub", "diff" }), 3)
check("-c takes arg", m.find_subcommand({ "-c", "k=v", "diff" }), 3)
check("--no-pager", m.find_subcommand({ "--no-pager", "diff" }), 2)
check("--git-dir= form", m.find_subcommand({ "--git-dir=/x", "diff" }), 2)
check("status", m.find_subcommand({ "status" }) and "found" or "nil", "found")
check("empty argv", m.find_subcommand({}) and "found" or "nil", "nil")
check("dangling -C", m.find_subcommand({ "-C" }) and "found" or "nil", "nil")

-- build_message
local msg = m.build_message("git diff --no-ext-diff --cached")
check("message names fix", msg:find("git diff --no-ext-diff --cached", 1, true) ~= nil, true)
check("message header", msg:find("Run the same command with --no-ext-diff:", 1, true) ~= nil, true)
check("message tail", msg:find("If you only need the changed files", 1, true) ~= nil, true)

-- splice
local s1 = m.splice("git diff && git log --oneline", {
  { start = 1, stop = 8, text = "git diff --no-ext-diff" },
})
check("splice keeps rest of line", s1, "git diff --no-ext-diff && git log --oneline")
local s2 = m.splice("git diff && git diff --cached", {
  { start = 1, stop = 8, text = "git diff --no-ext-diff" },
  { start = 13, stop = 29, text = "git diff --no-ext-diff --cached" },
})
check("splice two fixes", s2, "git diff --no-ext-diff && git diff --no-ext-diff --cached")
check("splice no fixes", m.splice("git diff", {}), "git diff")

if failures > 0 then
  print(("\n%d test(s) failed"):format(failures))
  os.exit(1)
end
print("all tests passed")
