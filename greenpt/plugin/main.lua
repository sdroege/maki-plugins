-- GreenPT, an OpenAI-compatible endpoint with no API for model metadata, so
-- the curated table is the catalogue and `list_models` only drops an id the
-- API no longer lists. Model list, prices, context windows and limits come
-- from https://docs.greenpt.ai/model-cards (the "Model changes" list there
-- tracks every release, price change and deprecation) and
-- https://docs.greenpt.ai/models for what `GET /v1/models` answers. Keep the
-- table in sync with the recommended catalogue when those pages change. A
-- "New model" line in the Model changes list is only curatable once a model
-- card backs it: the metis entry of 30 September 2026 has no card, no
-- /v1/models listing and no changelog mention, and there is no such model.

local parse = require("maki.provider_parse")

local MODELS_PATH = "/models"
local API_KEY_ENV = "GREENPT_API_KEY"

-- Prices are GreenPT's list in EUR per 1M tokens, from the model cards page,
-- stored in maki's dollar fields as-is. GreenPT bills no cache write, so
-- cache_write is 0.0. It enables reasoning by default: omitting the effort
-- field leaves thinking on. No built-in effort dialect matches that shape
-- (off must send "none" and the levels run minimal..high, while "standard"
-- omits the field on off and every other dialect misses levels or adds ones
-- GreenPT rejects), so no dialect is declared and each row spells its own
-- ladder: a level the row names is sent as a reasoning_effort of the same
-- name, "off" sends "none", and a mode the row leaves out sends no field at
-- all, leaving GreenPT's own default in charge. Which `reasoning_effort`
-- values each model accepts, and which reject `"none"`, is documented at
-- https://docs.greenpt.ai/reasoning; the rows' ladders follow it.
local function efforts(...)
  local fields = {}
  for _, name in ipairs({ ... }) do
    fields[name] = { reasoning_effort = name == "off" and "none" or name }
  end
  return fields
end

local MODELS = {
  {
    prefixes = { "glm-5.3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 1.10, output = 4.40, cache_write = 0.0, cache_read = 0.275 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "kimi-k3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 3.30, output = 16.50, cache_write = 0.0, cache_read = 0.825 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "deepseek-v4.1-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.22, output = 1.10, cache_write = 0.0, cache_read = 0.011 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "glm-5.3-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 0.11, output = 0.44, cache_write = 0.0, cache_read = 0.022 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Reasons whether asked or not and accepts no "none", so off clamps to
    -- minimal, the lowest rung of its ladder.
    prefixes = { "minimax-m2.5" },
    tier = "medium",
    context_window = 196608,
    max_output_tokens = 65536,
    supports_thinking = true,
    requires_thinking = true,
    pricing = { input = 0.33, output = 1.32, cache_write = 0.0, cache_read = 0.0825 },
    thinking_fields = efforts("minimal", "low", "medium", "high"),
  },
}

local KNOWN = {}
for _, row in ipairs(MODELS) do
  KNOWN[row.prefixes[1]] = true
end

maki.provider.register({
  slug = "greenpt",
  display_name = "GreenPT",
  codec = "openai",
  base_url = "https://api.greenpt.ai/v1",
  models = MODELS,

  auth = function()
    local key = maki.uv.os_getenv(API_KEY_ENV)
    if not key or key == "" then
      return nil, "set " .. API_KEY_ENV .. " to use greenpt"
    end
    return { headers = { Authorization = "Bearer " .. key } }
  end,

  -- /models also lists embedding, speech and rerank model ids. Anything the
  -- table does not list is filtered out as we can't know from the models list
  -- what kind of model is behind the id.
  list_models = function(ctx)
    local body, err = ctx.get_json(MODELS_PATH)
    if err then
      return nil, err
    end
    return parse.models(body, function(m)
      if type(m) ~= "table" or type(m.id) ~= "string" or KNOWN[m.id] == nil then
        return nil
      end
      return { id = m.id }
    end)
  end,
})
