-- Tests for lua/blocked_hosts.lua: unit checks on URL/host extraction and
-- the webfetch input check (no grammar needed), then command-level checks
-- against the real tree-sitter bash grammar like command_spec.lua.
-- Run: luajit tests/blocked_hosts_spec.lua

local spec_dir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]+$") or "."
package.path = spec_dir .. "/../lua/?.lua;" .. spec_dir .. "/?.lua;" .. package.path

local m = require("blocked_hosts")

local failures = 0
local count = 0

local function check(cond, msg)
  count = count + 1
  if not cond then
    failures = failures + 1
    print("FAIL " .. msg)
  end
end

local PROXY = "routify-file-proxy-sg.oss-ap-southeast-1.aliyuncs.com"
local URL = "https://" .. PROXY
  .. "/proxy_temp_file/production/2026-11-17/trace_2101816517606713132222414e0d5e"
  .. "/requestId_41638a5b2f434149bd47c6bd753e5c62/e34aeae2f37cb65ede91abbb65b39e7c"
  .. "?Expires=1814775315&OSSAccessKeyId=LTAI5tKoG9A3DkwGD635QVZr&Signature=8f6NAqz9jIZ48rLx6Pm5C3S5Vzs%3D"

-- host_of: host extraction
local host_cases = {
  { URL, PROXY },
  -- One case covering scheme, userinfo, port, and case folding at once.
  { "HTTP://u:p@Routify-File-Proxy-SG.OSS-AP-SOUTHEAST-1.ALIYUNCS.COM:443/x", PROXY },
  { PROXY .. "/proxy_temp_file/x", PROXY },
  { "-sSL", nil },
  -- A schemeless fetcher argument resolves like curl/wget read it: the text
  -- before the path is the "host". It only matters that is_blocked_host
  -- says no to such names.
  { "file.txt", "file.txt" },
  { "https://localhost/x", nil },
  -- Data tokens must not resolve to a host.
  { "Referer: https://" .. PROXY .. "/x", nil },
  { '{"u":"https://' .. PROXY .. '/"}', nil },
}
for _, c in ipairs(host_cases) do
  check(m.host_of(c[1]) == c[2],
    ("host_of(%q) = %s, want %s"):format(c[1], tostring(m.host_of(c[1])), tostring(c[2])))
end

-- is_blocked_host
for _, h in ipairs({
  PROXY,
  "routify-file-proxy.aliyuncs.com",
}) do
  check(m.is_blocked_host(h), "blocked host not blocked: " .. h)
end
for _, h in ipairs({
  "dashscope-intl.aliyuncs.com",
  "oss-ap-southeast-1.aliyuncs.com",
  "routify-file-proxy.example.com",
  PROXY .. ".evil.com",
  "not" .. PROXY,
  nil,
}) do
  check(not m.is_blocked_host(h), "blocked host false positive: " .. tostring(h))
end

-- check_webfetch
for _, url in ipairs({
  URL,
  "http://" .. PROXY .. "/x",
}) do
  check(type(m.check_webfetch({ url = url })) == "string", "webfetch not blocked: " .. url)
end
for _, input in ipairs({
  { url = "https://huggingface.co/Qwen/Qwen3.8-Flash-Next" },
  { url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models" },
  { url = "https://evil.com/?u=" .. PROXY .. "/x" },
  { url = "https://example.com/" .. PROXY .. "/x" },
  { url = 42 },
  nil,
}) do
  check(m.check_webfetch(input) == nil,
    "webfetch wrongly blocked: " .. tostring(type(input) == "table" and input.url or input))
end

-- Command-level tests need the real bash grammar (tests/ts.lua).
local ts = require("ts")
local ok, err = ts.init()
if not ok then
  print("skipped command-level tests: " .. err)
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
    "curl " .. URL,
    'curl -sSL "' .. URL .. '" -o /tmp/f',
    "wget " .. URL,
    "wget2 -q " .. URL,
    "sudo curl " .. URL,
    "curl " .. URL .. " | jq .",
    "/usr/bin/curl " .. URL,
    "FOO=bar curl " .. URL,
    "curl https://" .. PROXY:upper() .. "/x",
    "curl " .. PROXY .. "/proxy_temp_file/x",
    -- Unquoted & splits the list and breaks the parse after the fetcher; the
    -- curl node with its host token must still be caught.
    "curl -O " .. URL .. " > /tmp/out.txt",
  }

  local allow_cases = {
    "curl https://example.com/x",
    "wget https://qianwen-res.oss-accelerate.aliyuncs.com/Qwen3.8-Flash-Next/architecture.png",
    "curl https://example.com/" .. PROXY .. "/x",
    "curl https://example.com/?u=" .. PROXY .. "/x",
    "curl -H 'Referer: https://" .. PROXY .. "/x' https://example.com",
    "curl -X POST -d '{\"u\":\"https://" .. PROXY .. "/\"}' https://api.example.com",
    "grep -r '" .. PROXY .. "' ~/.local/state/maki/sessions",
    "git log --oneline",
  }

  for _, cmd in ipairs(block_cases) do
    warnings = {}
    local reason = m.filter({ command = cmd }, nil)
    count = count + 1
    if type(reason) ~= "string" then
      failures = failures + 1
      print(("FAIL block %q: not blocked (reason=%s)"):format(cmd, tostring(reason)))
    elseif not reason:find(PROXY, 1, true) then
      failures = failures + 1
      print(("FAIL block %q: reason misses the host.\n%s"):format(cmd, reason))
    end
  end

  for _, cmd in ipairs(allow_cases) do
    warnings = {}
    local reason = m.filter({ command = cmd }, nil)
    count = count + 1
    if reason ~= nil then
      failures = failures + 1
      print(("FAIL allow %q: blocked: %s"):format(cmd, reason))
    end
  end

  -- Unparseable commands with no fetcher evidence fail open, with a warning.
  warnings = {}
  local bad = m.filter({ command = "grep '" .. URL .. "' sessions.log |" }, nil)
  count = count + 1
  if bad ~= nil then
    failures = failures + 1
    print("FAIL fail-open: unparseable command was blocked: " .. tostring(bad))
  elseif #warnings == 0 then
    failures = failures + 1
    print("FAIL fail-open: no warning logged for unparseable command")
  end
end

if failures > 0 then
  print(("\n%d/%d test(s) failed"):format(failures, count))
  os.exit(1)
end
print(("all %d blocked_hosts tests passed"):format(count))
