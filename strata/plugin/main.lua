-- Strata, a local OpenAI-compatible server on 127.0.0.1:8080 serving one
-- model at a time. It needs no key and charges nothing, so there is no
-- `auth` hook or `api_key_env`, and pricing is a real zero.
--
-- What the API reports is read from it: `list_models` takes the context
-- window from `meta.n_ctx` and vision support from
-- `architecture.input_modalities`, the llama.cpp shape GET /v1/models
-- answers. Only the models the server lists are offered, so the picker
-- follows whatever model is loaded and drops the image model.
--
-- Strata's server maps clients' effort spellings onto its template's
-- low/medium/xhigh plus enable_thinking=false (serve/frontend.py's EFFORT),
-- and thinks by default at xhigh. The standard dialect sends "none" for off,
-- and the per-model effort list below snaps maki's "minimal" to "low", never
-- to the server's "minimal" alias, which means off. The server maps the
-- levels its family does not take (Qwen's high/xhigh/max all mean xhigh,
-- DeepSeek's xhigh/max mean max).

local parse = require("maki.provider_parse")

local MODELS_PATH = "/models"

local ZERO_PRICING = { input = 0, output = 0, cache_write = 0, cache_read = 0 }

-- The levels the server accepts. "minimal" is left out on purpose: the
-- server reads it as off, so maki's minimal snaps down to low.
local EFFORT_SUPPORTED = { "low", "medium", "high", "xhigh", "max" }

-- Qwen3.6-35B-A3B is the small member of the family; everything else Strata
-- serves is the medium tier.
local WEAK_PREFIX = "qwen3.6-35b-a3b"

local function tier_for(id)
  if id:sub(1, #WEAK_PREFIX) == WEAK_PREFIX then
    return "weak"
  end
  return "medium"
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
  -- No output cap is declared, so no max_tokens is sent: Strata fills
  -- whatever room the context has left, and a client-sent cap only adds
  -- a refusal path - the server rejects prompt + max_tokens over the
  -- context unless --fit-max-tokens is on, and maki's prompt estimate
  -- can read lower than the server's own count.
  max_output_tokens = false,
  openai = {
    thinking = { dialect = "standard", requires_support = true },
  },

  -- Only the models the server lists are offered. The image model is
  -- dropped by its output modality, and an alias is dropped because the
  -- model it points at is listed under its own id.
  list_models = function(ctx)
    local body, err = ctx.get_json(MODELS_PATH)
    if err then
      return nil, err
    end
    return parse.models(body, function(m)
      if type(m) ~= "table" or type(m.id) ~= "string" or m.alias_of ~= nil then
        return nil
      end
      local meta = type(m.meta) == "table" and m.meta or {}
      local arch = type(m.architecture) == "table" and m.architecture or {}
      local outputs = arch.output_modalities
      if type(outputs) == "table" and not has_modality(outputs, "text") then
        return nil
      end
      return {
        id = m.id,
        context_window = parse.as_u32(meta.n_ctx),
        supports_vision = has_modality(arch.input_modalities, "image"),
        supports_thinking = true,
        pricing = ZERO_PRICING,
        tier = tier_for(m.id),
        effort = { supported = EFFORT_SUPPORTED, send_off = true },
      }
    end)
  end,
})
