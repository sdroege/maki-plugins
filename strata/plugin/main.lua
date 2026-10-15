-- Strata, a local OpenAI-compatible server on 127.0.0.1:8080 serving one
-- quantised model. It needs no key and charges nothing, so there is no
-- `auth` hook or `api_key_env`, and pricing is a real zero.
--
-- What the API reports is read from it: `list_models` takes the context
-- window from `meta.n_ctx` and vision support from
-- `architecture.input_modalities`, the llama.cpp shape GET /v1/models
-- answers. The curated row keeps what the endpoint cannot say: the tier,
-- the zero pricing and the thinking ladder. Strata's server maps clients'
-- effort spellings onto its template's low/medium/xhigh plus
-- enable_thinking=false (serve/frontend.py's EFFORT), and thinks by default
-- at xhigh, so no dialect is declared and the row spells its own ladder:
-- off sends "none", each named level sends itself ("high", "xhigh" and
-- "max" all mean the template's xhigh), and a mode the row leaves out snaps
-- to the nearest declared rung - maki's "minimal" lands on "low", never on
-- the server's "minimal" alias, which means off.

local parse = require("maki.provider_parse")

local MODELS_PATH = "/models"

local MODELS = {
  {
    prefixes = { "qwen3.8-flash-next-unsloth-ud-iq4_xs" },
    tier = "medium",
    supports_thinking = true,
    pricing = { input = 0, output = 0, cache_write = 0, cache_read = 0 },
    thinking_fields = {
      off = { reasoning_effort = "none" },
      low = { reasoning_effort = "low" },
      medium = { reasoning_effort = "medium" },
      high = { reasoning_effort = "high" },
      xhigh = { reasoning_effort = "xhigh" },
      max = { reasoning_effort = "max" },
    },
  },
}

local KNOWN = {}
for _, row in ipairs(MODELS) do
  KNOWN[row.prefixes[1]] = true
end

local function has_modality(modalities, name)
  if type(modalities) ~= "table" then
    return nil
  end
  for _, m in ipairs(modalities) do
    if m == name then
      return true
    end
  end
  return false
end

maki.provider.register({
  slug = "strata",
  display_name = "Strata",
  codec = "openai",
  base_url = "http://127.0.0.1:8080/v1",
  family = "generic",
  models = MODELS,

  -- Context window and vision come from the API, not the row: the server
  -- may start with another --max-context, or load a vision encoder. Only
  -- ids the row names are listed, which also drops any alias the server
  -- adds under its own id.
  list_models = function(ctx)
    local body, err = ctx.get_json(MODELS_PATH)
    if err then
      return nil, err
    end
    return parse.models(body, function(m)
      if type(m) ~= "table" or type(m.id) ~= "string" or KNOWN[m.id] == nil then
        return nil
      end
      local meta = type(m.meta) == "table" and m.meta or {}
      local arch = type(m.architecture) == "table" and m.architecture or {}
      return {
        id = m.id,
        context_window = parse.as_u32(meta.n_ctx),
        supports_vision = has_modality(arch.input_modalities, "image"),
      }
    end)
  end,
})
