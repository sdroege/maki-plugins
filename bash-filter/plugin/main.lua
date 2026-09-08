local git_diff = require("git_diff")

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
