-- Inference Cooperative (inference.coop), a member-governed gateway in
-- front of several providers. Model ids are `<provider>/<model>`, so a maki
-- spec reads `inference-coop/greenpt/glm-5.3`. The gateway has no model
-- metadata API beyond the OpenAI /models list, so the curated table is the
-- catalogue and `list_models` only drops an id the gateway no longer lists.
--
-- Model, context window, vision and rate data from the co-op's public docs:
-- https://git.inference.coop/co-op/docs/src/branch/main/models.md (the
-- member-facing model list) and the LiteLLM config it names as the
-- authoritative pricing source,
-- https://git.inference.coop/code/litellm/src/branch/main/config.yaml.
-- Keep the table in sync with those when the co-op adds models or rates
-- change.

local parse = require("maki.provider_parse")

local MODELS_PATH = "/models"
local API_KEY_ENV = "INFERENCE_COOP_API_KEY"

-- Prices are per 1M tokens and are what the co-op pays the provider, not
-- what a member pays: members get a monthly allowance. Recorded anyway, so
-- maki's cost sums track co-op spend. The rows carry the co-op's own dollar
-- rates, and where a provider's own price list (GreenPT's at
-- https://docs.greenpt.ai/model-cards, Regolo's embedded in
-- https://regolo.ai/models) disagrees, the co-op's sources win: the rows
-- record what the co-op actually pays and what its spend records show. No
-- provider bills a cache write, so cache_write is 0.0, and an unlisted cache
-- read is 0.0 too. The co-op arrives at its dollar rates differently per
-- provider: greenpt/* rows are GreenPT's EUR list stored unconverted in its
-- config's dollar fields, so those rows match GreenPT's list by
-- construction, while regolo/* rows are Regolo's EUR list converted at
-- 1.16, and the rows record those converted dollar figures.
-- The gateway forwards to OpenAI-compatible endpoints that reason by
-- default, and no built-in effort dialect matches that shape (off must send
-- "none" while "standard" omits the field on off), so no dialect is declared
-- and each row spells its own ladder: a level the row names is sent as a
-- reasoning_effort of the same name, "off" sends "none", and a mode the row
-- leaves out sends no field at all, leaving the model's default in charge.
-- Models that reason whether asked or not declare requires_thinking, so off
-- clamps to the lowest rung of their ladder.
local function efforts(...)
  local fields = {}
  for _, name in ipairs({ ... }) do
    fields[name] = { reasoning_effort = name == "off" and "none" or name }
  end
  return fields
end

local MODELS = {
  {
    -- The co-op's default model.
    prefixes = { "greenpt/deepseek-v4.1-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.22, output = 1.10, cache_write = 0.0, cache_read = 0.011 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "tinfoil/deepseek-v4-1-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.65, output = 1.45, cache_write = 0.0, cache_read = 0.13 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "greenpt/glm-5.3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 1.10, output = 4.40, cache_write = 0.0, cache_read = 0.275 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Text-only: models.md shows no vision and the LiteLLM config spells
    -- "Text-only (no vision)". Replaced tinfoil/glm-5-3-flash, which
    -- Tinfoil deprecated 2026-10-09.
    prefixes = { "tinfoil/glm-5.3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 1.80, output = 5.75, cache_write = 0.0, cache_read = 0.45 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "greenpt/glm-5.3-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 0.11, output = 0.44, cache_write = 0.0, cache_read = 0.022 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Replaced PublicAI (removed 2026-10-16; billing never operational) as
    -- the co-op's Apertus provider: same open weights, EU ZDR + renewables.
    -- Context is the co-op's measured 262K; Regolo's catalogue advertises
    -- 30K input, which the gateway demonstrably exceeds. Prices are the
    -- co-op's dollar rates (Regolo's EUR list at 1.16).
    prefixes = { "regolo/apertus-70b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 1.16, output = 3.944, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- The gateway forces chat_template_kwargs: {enable_thinking: false} for
    -- this id (LiteLLM config); without it the reasoning phase eats the
    -- whole token budget and the content comes back empty.
    prefixes = { "regolo/qwen3.5-122b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.696, output = 3.944, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Added 2026-11-13. Hybrid instruct + reasoning Small 4 (119B) with
    -- vision and tool calling. Context is the co-op's measured 262K; the
    -- LiteLLM config still declares Regolo's catalogued 60K, which the
    -- gateway demonstrably exceeds (docs commit 808e5450, 2026-11-13).
    prefixes = { "regolo/mistral-small-4-119b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.20, output = 0.70, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Added 2026-11-13. Dense multimodal Gemma 4 (31B) with native function
    -- calling. Context is the co-op's measured 262K, not the config's 100K.
    prefixes = { "regolo/gemma4-31b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.40, output = 0.60, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Reasons whether asked or not and accepts no "none", so off clamps to
    -- low, the lowest rung of its ladder.
    prefixes = { "tinfoil/gpt-oss-120b" },
    tier = "weak",
    context_window = 131072,
    requires_thinking = true,
    pricing = { input = 0.15, output = 0.60, cache_write = 0.0, cache_read = 0.0 },
    thinking_fields = efforts("low", "medium", "high"),
  },
}

local KNOWN = {}
for _, row in ipairs(MODELS) do
  KNOWN[row.prefixes[1]] = true
end

maki.provider.register({
  slug = "inference-coop",
  display_name = "Inference Cooperative",
  codec = "openai",
  base_url = "https://gateway.inference.coop/v1",
  api_key_env = API_KEY_ENV,
  -- No output cap is declared, so no max_tokens is sent: the gateway's
  -- upstreams enforce their own limits, and no row states one.
  max_output_tokens = false,
  models = MODELS,

  -- /models also lists the speech models (whisper, voxtral-tts). Anything
  -- the table does not list is filtered out as we can't know from the
  -- models list what kind of model is behind the id.
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
