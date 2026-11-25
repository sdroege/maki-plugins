-- Rejects `git -C <path>` commands. -C points git at a directory other than
-- the one the shell runs in; the bash tool input already carries a workdir
-- parameter for that, so the hint is to rerun the git command with the
-- directory as workdir, without -C.

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

-- Git global flags the scan keeps walking past while in global options
-- position; anything unknown ends the walk, because the subcommand is next.
local GLOBAL_FLAGS_NO_ARG = {
  ["--version"] = true,
  ["-v"] = true,
  ["--help"] = true,
  ["-h"] = true,
  ["--html-path"] = true,
  ["--man-path"] = true,
  ["--info-path"] = true,
  ["--paginate"] = true,
  ["--no-pager"] = true,
  ["-p"] = true,
  ["-P"] = true,
  ["--bare"] = true,
  ["--no-replace-objects"] = true,
  ["--no-lazy-fetch"] = true,
  ["--no-optional-locks"] = true,
  ["--no-advice"] = true,
}

local GLOBAL_FLAGS_WITH_ARG = {
  ["--git-dir"] = true,
  ["--work-tree"] = true,
  ["--namespace"] = true,
  ["--config-env"] = true,
  ["--exec-path"] = true,
}

-- The path of the first global -C, or nil. A trailing `git -C` has no path
-- token and returns "", so it still blocks. Attached `-Csub` and `-C=sub`
-- count too: git rejects their syntax, but the intent is the same and the
-- hint fixes it. Lowercase -c is config, not a directory.
local function c_dir(argv)
  local i = 1
  while i <= #argv do
    local tok = argv[i]
    if tok == "-C" then
      return argv[i + 1] or ""
    elseif tok:sub(1, 2) == "-C" then
      return (tok:sub(3):gsub("^=", "", 1))
    elseif tok == "-c" then
      i = i + 2
    elseif GLOBAL_FLAGS_NO_ARG[tok] then
      i = i + 1
    elseif tok:sub(1, 2) == "--" then
      if tok:find("=", 1, true) then
        i = i + 1
      elseif GLOBAL_FLAGS_WITH_ARG[tok] then
        i = i + 2
      else
        return nil
      end
    else
      return nil
    end
  end
  return nil
end

local function build_message(dir)
  if dir == "" then
    return "git -C is not allowed: -C points git at a directory other than the one you are running in. "
      .. "Call the bash tool again with its workdir parameter set to that directory, "
      .. "and run the same git command there without -C."
  end
  return "git -C " .. dir .. " is not allowed: it points git at a directory other than the one you are running in. "
    .. "Call the bash tool again with its workdir parameter set to " .. dir
    .. ", and run the same git command there without -C."
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
    elseif kind == "word" or kind == "string" or kind == "raw_string" or kind == "concatenated_string" then
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

-- The -C path of one `git` command node, or nil.
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
  if not prog or (prog.text ~= "git" and not prog.text:match("/git$")) then
    return nil
  end

  local argv = {}
  for j = i + 1, #tokens do
    argv[#argv + 1] = tokens[j].text
  end
  return c_dir(argv)
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
    local dir = nil
    for_each_command(root, function(node)
      if not dir then
        dir = offending_command(node, command)
      end
    end)
    if dir then
      return build_message(dir)
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
  c_dir = c_dir,
  build_message = build_message,
}
