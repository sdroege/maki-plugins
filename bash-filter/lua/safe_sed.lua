-- Whitelist for auto-accepting read-only `sed` calls. A command is safe when
-- it is a single `sed` invocation whose script only prints: `[addr[,addr]]p`
-- commands, nothing else. No `-i`, no s/d/w/e/r commands, no redirects, no
-- substitutions, so nothing is written and nothing is executed.
--
-- The script is only trusted when the shell cannot rewrite it on the way to
-- sed (see `literal_script`): an unquoted token with escapes or expansions
-- decodes into a different script than the one validated here. Anything the
-- parser is unsure about stays in front of the user instead.

local SAFE_SHORT = { n = true, E = true, r = true }

local SAFE_LONG = {
  ["--quiet"] = true,
  ["--silent"] = true,
  ["--regexp-extended"] = true,
}

local REDIRECT_TYPES = {
  file_redirect = true,
  heredoc_redirect = true,
  herestring_redirect = true,
}

-- Expansions that can execute something; a plain $VAR in a file name is fine.
local UNSAFE_EXPANSIONS = {
  command_substitution = true,
  process_substitution = true,
  arithmetic_expansion = true,
}

local function unquote(s)
  local q = s:sub(1, 1)
  if (q == '"' or q == "'") and #s >= 2 and s:sub(-1) == q then
    return s:sub(2, -2)
  end
  return s
end

local function node_text(node, source)
  return maki.treesitter.get_node_text(node, source)
end

local function has_unsafe_expansion(node)
  if UNSAFE_EXPANSIONS[node:type()] then
    return true
  end
  for child in node:iter_children() do
    if has_unsafe_expansion(child) then
      return true
    end
  end
  return false
end

-- Tokens of one command node, or nil when the command is anything but plain
-- words: redirects, env assignments and unknown nodes all disqualify it.
local function collect_tokens(node, source)
  local tokens = {}
  for child in node:iter_children() do
    local kind = child:type()
    if REDIRECT_TYPES[kind] or kind == "variable_assignment" then
      return nil
    elseif kind == "command_name" then
      if has_unsafe_expansion(child) then
        return nil
      end
      for inner in child:iter_children() do
        if inner:named() then
          tokens[#tokens + 1] = { text = unquote(node_text(inner, source)), node = inner }
        end
      end
    elseif kind == "word" or kind == "string" or kind == "raw_string"
      or kind == "concatenation" or kind == "concatenated_string" then
      if has_unsafe_expansion(child) then
        return nil
      end
      tokens[#tokens + 1] = { text = unquote(node_text(child, source)), node = child }
    elseif child:named() then
      return nil
    end
  end
  return tokens
end

-- One address: a line number, `$`, a `+N`/`-N` relative offset, or a
-- `/regex/` (with `\/` escapes). Returns the index past the address, or nil.
local function parse_address(s, i)
  local num = s:match("^%d+", i)
  if num then
    return i + #num
  end
  local c = s:sub(i, i)
  if c == "$" then
    return i + 1
  end
  local rel = s:match("^[+-]%d+", i)
  if rel then
    return i + #rel
  end
  if c == "/" then
    local j = i + 1
    while j <= #s do
      local ch = s:sub(j, j)
      if ch == "\\" then
        j = j + 2
      elseif ch == "/" then
        return j + 1
      else
        j = j + 1
      end
    end
  end
  return nil
end

-- The whole script must be `[addr[,addr]]p` commands joined by `;` or
-- newline, with horizontal whitespace tolerated around the separators.
local function valid_script(s)
  s = s:match("^%s*(.-)%s*$")
  if s == "" then
    return false
  end
  local i = 1
  while true do
    local j = parse_address(s, i)
    if j then
      i = j
      if s:sub(i, i) == "," then
        i = i + 1
        local j2 = parse_address(s, i)
        if not j2 then
          return false
        end
        i = j2
      end
    end
    if s:sub(i, i) ~= "p" then
      return false
    end
    i = i + 1
    i = i + #s:match("^[\t ]*", i)
    local c = s:sub(i, i)
    if c == "" then
      return true
    end
    if c == ";" or c == "\n" then
      i = i + 1
      i = i + #s:match("^[\t ]*", i)
    else
      return false
    end
  end
end

-- What the shell hands sed for this token, when it cannot change on the
-- way: a single-quoted string is literal as it stands, and a word or
-- double-quoted string with no backslash, dollar, glob or brace character
-- decodes to itself. Anything else - an escape, an expansion, a
-- concatenation - could become a script that was never validated, so it
-- is rejected and the call prompts instead.
local function literal_script(token)
  local kind = token.node:type()
  if kind == "raw_string" then
    return token.text
  end
  if kind ~= "word" and kind ~= "string" then
    return nil
  end
  if token.text:find("[\\$]") then
    return nil
  end
  if kind == "word" and token.text:find("[*?%[{}~]") then
    return nil
  end
  return token.text
end

-- The script expressions of a sed argv (tokens[1] is the program name), or
-- nil when any flag is not whitelisted. With `-e`/`--expression` every
-- positional argument is a file; otherwise the first positional is the
-- script, accepted only through `literal_script`.
local function parse_args(tokens)
  local scripts = {}
  local had_expr = false
  local script_seen = false
  local files_only = false
  local i = 2
  while i <= #tokens do
    local token = tokens[i]
    local t = token.text
    if files_only then
      i = i + 1
    elseif t == "--" then
      files_only = true
      i = i + 1
    elseif t == "-e" or t == "--expression" then
      local s = tokens[i + 1]
      if not s then
        return nil
      end
      local script = literal_script(s)
      if not script then
        return nil
      end
      had_expr = true
      scripts[#scripts + 1] = script
      i = i + 2
    elseif t:sub(1, 13) == "--expression=" then
      -- The value rides in the same token. Only a single-quoted whole
      -- token keeps escapes literal; in any other form a backslash or
      -- dollar could decode into an unvalidated script.
      if token.node:type() ~= "raw_string" and t:find("[\\$]", 14) then
        return nil
      end
      had_expr = true
      scripts[#scripts + 1] = unquote(t:sub(14))
      i = i + 1
    elseif SAFE_LONG[t] then
      i = i + 1
    elseif t:sub(1, 2) == "--" then
      return nil
    elseif t:sub(1, 1) == "-" and #t > 1 then
      for c in t:sub(2):gmatch(".") do
        if not SAFE_SHORT[c] then
          return nil
        end
      end
      i = i + 1
    elseif not had_expr and not script_seen then
      local script = literal_script(token)
      if not script then
        return nil
      end
      script_seen = true
      scripts[#scripts + 1] = script
      i = i + 1
    else
      i = i + 1
    end
  end
  if #scripts == 0 then
    return nil
  end
  return scripts
end

-- One scope string (a single pipeline stage, as the host splits it) is a safe
-- sed call. Fails closed: any parse problem means "not whitelisted".
local function is_safe_sed_command(command)
  if type(command) ~= "string" or command:match("^%s*$") then
    return false
  end
  local ok, result = pcall(function()
    local parser = maki.treesitter.get_parser(command, "bash")
    if not parser then
      maki.log.warn("bash-filter: bash grammar unavailable, not auto-allowing: " .. command)
      return false
    end
    local root = parser:parse()[1]:root()
    if root:has_error() then
      maki.log.warn("bash-filter: parse error, not auto-allowing: " .. command)
      return false
    end
    local cmds = {}
    for child in root:iter_children() do
      if child:named() then
        cmds[#cmds + 1] = child
      end
    end
    if #cmds ~= 1 or cmds[1]:type() ~= "command" then
      return false
    end
    local tokens = collect_tokens(cmds[1], command)
    if not tokens or #tokens == 0 then
      return false
    end
    -- Exactly `sed`: vouching for any `*/sed` path would vouch for whatever
    -- binary happens to sit there, so absolute or relative paths prompt.
    if tokens[1].text ~= "sed" then
      return false
    end
    local scripts = parse_args(tokens)
    if not scripts then
      return false
    end
    for _, s in ipairs(scripts) do
      if not valid_script(s) then
        return false
      end
    end
    return true
  end)
  if not ok then
    maki.log.warn("bash-filter: " .. tostring(result) .. ", not auto-allowing: " .. command)
    return false
  end
  return result
end

-- Every scope the prompt would ask about must be a safe sed: maki already
-- split the command per pipeline stage and dropped the stages an allow rule
-- claimed, so the remaining ones are exactly the sed stages to vouch for.
local function all_safe(scopes)
  if type(scopes) ~= "table" or #scopes == 0 then
    return false
  end
  for _, scope in ipairs(scopes) do
    if not is_safe_sed_command(scope) then
      return false
    end
  end
  return true
end

return {
  all_safe = all_safe,
  is_safe_sed_command = is_safe_sed_command,
  valid_script = valid_script,
}
