local git_diff = require("git_diff")
local git_c = require("git_c")
local rg = require("rg")
local safe_sed = require("safe_sed")
local blocked_hosts = require("blocked_hosts")

local FILTERS = {
  git_diff.filter,
  git_c.filter,
  rg.filter,
  blocked_hosts.filter,
}

maki.api.set_slot("tool.bash.input", function(prev, input, ctx)
  for _, filter in ipairs(FILTERS) do
    local reason = filter(input, ctx)
    if reason then
      return nil, reason
    end
  end
  return prev(input, ctx)
end)

-- Routify file-proxy URLs are hallucinated fetch targets that always 403.
-- webfetch is not bash, so the FILTERS loop above never sees it; reject the
-- blocked host before the permission prompt fires.
maki.api.set_slot("tool.webfetch.input", function(prev, input, ctx)
  local reason = blocked_hosts.check_webfetch(input)
  if reason then
    return nil, reason
  end
  return prev(input, ctx)
end)

-- Auto-accept whitelisted read-only sed calls (e.g. `sed -n '123,456p' file`).
-- The host splits a command into one scope per pipeline stage and only the
-- scopes no allow rule claims reach this layer, so `git log -p | sed -n
-- '400,900p'` is allowed exactly when the sed stage is whitelisted and every
-- other stage was already allowed by the existing rules.
maki.api.set_slot("permission.prompt", function(prev, req, ctx)
  if req.tool == "bash" and safe_sed.all_safe(req.scopes) then
    return { decision = "allow" }
  end
  return prev(req, ctx)
end)
