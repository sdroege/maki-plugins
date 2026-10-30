local git_diff = require("git_diff")
local safe_sed = require("safe_sed")

local FILTERS = {
  git_diff.filter,
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
