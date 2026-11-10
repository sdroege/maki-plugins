-- Rejects `rg` calls that are easy to mistake for something else or that run
-- external programs:
--   -r/--replace    replacement mode, not recursive (rg is recursive by default)
--   --pre           runs a command for every searched file
--   --hostname-bin  runs a command to determine the hostname

local WRAPPER_WORDS = {
  ["time"] = true,
  ["nohup"] = true,
  ["exec"] = true,
  ["command"] = true,
  ["sudo"] = true,
}

local REDIRECT_TYPES = {
  file_redirect = true,
  heredoc_redirect = true,
  herestring_redirect = true,
}

-- Short options that take a value. Inside a bundle the first one consumes the
-- rest, so `-er` is -e with the value "r", not --replace.
local SHORT_WITH_ARG = {
  e = true,
  f = true,
  E = true,
  m = true,
  j = true,
  g = true,
  d = true,
  t = true,
  T = true,
  A = true,
  B = true,
  C = true,
  M = true,
}

-- Long options that take a value from the next token.
local LONG_WITH_ARG = {
  ["--after-context"] = true,
  ["--before-context"] = true,
  ["--color"] = true,
  ["--colors"] = true,
  ["--context"] = true,
  ["--context-separator"] = true,
  ["--dfa-size-limit"] = true,
  ["--encoding"] = true,
  ["--engine"] = true,
  ["--field-context-separator"] = true,
  ["--field-match-separator"] = true,
  ["--file"] = true,
  ["--generate"] = true,
  ["--glob"] = true,
  ["--hostname-bin"] = true,
  ["--hyperlink-format"] = true,
  ["--iglob"] = true,
  ["--ignore-file"] = true,
  ["--max-columns"] = true,
  ["--max-count"] = true,
  ["--max-depth"] = true,
  ["--max-filesize"] = true,
  ["--path-separator"] = true,
  ["--pre"] = true,
  ["--pre-glob"] = true,
  ["--regexp"] = true,
  ["--regex-size-limit"] = true,
  ["--replace"] = true,
  ["--sort"] = true,
  ["--sortr"] = true,
  ["--threads"] = true,
  ["--type"] = true,
  ["--type-add"] = true,
  ["--type-clear"] = true,
  ["--type-not"] = true,
}

-- Long options that run an external program.
local EXEC_LONG = {
  ["--pre"] = true,
  ["--hostname-bin"] = true,
}

local MESSAGES = {
  ["--replace"] = "rg -r is --replace REPLACEMENT, not recursive. rg searches recursively by default. "
    .. "Re-run without -r/--replace and its replacement argument, e.g. `rg PATTERN PATH`.",
  ["--pre"] = "rg --pre runs an external command for every searched file, which bypasses the bash tool's command checks. "
    .. "Re-run without --pre/--pre-glob and search the files directly.",
  ["--hostname-bin"] = "rg --hostname-bin runs an external command to determine the hostname. "
    .. "Re-run without it.",
}

-- The first forbidden flag in the argument list after `rg`, or nil. Short -r
-- reports as --replace so callers see one canonical name.
local function forbidden_flag(args)
  local i = 1
  while i <= #args do
    local tok = args[i]
    if tok == "--" then
      return nil
    elseif tok:sub(1, 2) == "--" then
      local name = tok:match("^([^=]+)")
      if name == "--replace" or EXEC_LONG[name] then
        return name
      end
      if LONG_WITH_ARG[name] and name == tok then
        i = i + 1
      end
    elseif tok:sub(1, 1) == "-" and #tok > 1 then
      local body = tok:sub(2)
      for k = 1, #body do
        local c = body:sub(k, k)
        if c == "r" then
          return "--replace"
        elseif SHORT_WITH_ARG[c] then
          -- The rest of the bundle, or the next token, is this option's value.
          if k == #body then
            i = i + 1
          end
          break
        end
      end
    end
    i = i + 1
  end
  return nil
end

local function build_message(flag)
  return MESSAGES[flag]
end

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

local function collect_tokens(node, source)
  local tokens = {}
  for child in node:iter_children() do
    local kind = child:type()
    if REDIRECT_TYPES[kind] then
      break
    elseif kind == "command_name" then
      for inner in child:iter_children() do
        if inner:named() then
          tokens[#tokens + 1] = { text = unquote(node_text(inner, source)), node = inner }
        end
      end
    elseif kind == "word" or kind == "string" or kind == "concatenated_string" then
      tokens[#tokens + 1] = { text = unquote(node_text(child, source)), node = child }
    end
  end
  return tokens
end

local function for_each_command(node, visit)
  if node:type() == "command" then
    visit(node)
    return
  end
  for child in node:iter_children() do
    if child:named() then
      for_each_command(child, visit)
    end
  end
end

-- The forbidden flag of one `rg` command node, or nil.
local function offending_command(node, source)
  local tokens = collect_tokens(node, source)
  local i = 1
  while i <= #tokens do
    local t = tokens[i].text
    if t:match("^%w[%w_%-]*=") or WRAPPER_WORDS[t] then
      i = i + 1
    else
      break
    end
  end
  local prog = tokens[i]
  if not prog or (prog.text ~= "rg" and not prog.text:match("/rg$")) then
    return nil
  end

  local argv = {}
  for j = i + 1, #tokens do
    argv[#argv + 1] = tokens[j].text
  end
  return forbidden_flag(argv)
end

local function filter(input, _ctx)
  local command = input.command
  if type(command) ~= "string" or command:match("^%s*$") then
    return nil
  end
  local ok, reason = pcall(function()
    local parser = maki.treesitter.get_parser(command, "bash")
    if not parser then
      maki.log.warn("bash-filter: bash grammar unavailable, allowing command")
      return
    end
    local root = parser:parse()[1]:root()
    if root:has_error() then
      maki.log.warn("bash-filter: parse error, allowing command: " .. command)
      return
    end
    local flag = nil
    for_each_command(root, function(node)
      if not flag then
        flag = offending_command(node, command)
      end
    end)
    if flag then
      return build_message(flag)
    end
  end)
  if not ok then
    maki.log.warn("bash-filter: " .. tostring(reason) .. ", allowing command: " .. command)
    return nil
  end
  return reason
end

return {
  filter = filter,
  forbidden_flag = forbidden_flag,
  build_message = build_message,
}
