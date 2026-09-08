-- Rejects `git diff` calls that would print a full external-diff patch,
-- unless `--no-ext-diff` is given or the flags suppress the patch.

local NO_EXT_DIFF = "--no-ext-diff"
local EXTERNAL_DIFF = "--ext-diff"

-- Diff flags that print no patch.
local SUPPRESS_FLAGS = {
  ["--stat"] = true,
  ["--numstat"] = true,
  ["--shortstat"] = true,
  ["--name-only"] = true,
  ["--name-status"] = true,
  ["--check"] = true,
  ["--summary"] = true,
  ["--raw"] = true,
  ["--no-patch"] = true,
  ["--quiet"] = true,
  ["-q"] = true,
}

-- Flags that force a patch even next to a suppress flag.
local PATCH_FLAGS = {
  ["-p"] = true,
  ["--patch"] = true,
  ["--patch-with-stat"] = true,
  ["--patch-with-raw"] = true,
}

-- Git global flags, before the subcommand.
local GLOBAL_FLAGS_WITH_ARG = {
  ["-C"] = true,
  ["-c"] = true,
  ["--git-dir"] = true,
  ["--work-tree"] = true,
  ["--exec-path"] = true,
}
local GLOBAL_FLAGS_NO_ARG = {
  ["--no-pager"] = true,
  ["--paginate"] = true,
  ["-p"] = true,
  ["--help"] = true,
  ["-h"] = true,
  ["--version"] = true,
}

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

-- Classify the tokens after the `diff` subcommand.
-- "patch" means the call prints a full diff, "allow" means it does not.
local function classify_diff_args(args)
  local has_patch = false
  local has_suppress = false
  for _, tok in ipairs(args) do
    if tok == "--" then
      break
    end
    if tok == NO_EXT_DIFF or tok == EXTERNAL_DIFF then
      return "allow"
    elseif PATCH_FLAGS[tok] then
      has_patch = true
    elseif SUPPRESS_FLAGS[tok] then
      has_suppress = true
    elseif tok:sub(1, 2) ~= "--" and tok:sub(1, 1) == "-" and #tok > 1 then
      for c in tok:sub(2):gmatch(".") do
        if c == "p" then
          has_patch = true
        elseif c == "q" then
          has_suppress = true
        end
      end
    end
  end
  if has_patch then
    return "patch"
  end
  if has_suppress then
    return "allow"
  end
  return "patch"
end

-- Index of the subcommand in git's argv (the tokens after `git`), or nil if
-- the globals run out first.
local function find_subcommand(argv)
  local i = 1
  while i <= #argv do
    local tok = argv[i]
    if GLOBAL_FLAGS_WITH_ARG[tok] then
      i = i + 2
    elseif GLOBAL_FLAGS_NO_ARG[tok] or tok:match("^%-%-[%w%-]+=") then
      i = i + 1
    else
      return i
    end
  end
  return nil
end

local function build_message(corrected)
  return "git diff would print a full external-diff patch. Run the same command with "
    .. NO_EXT_DIFF
    .. ":\n  "
    .. corrected
    .. "\nIf you only need the changed files or stats, use --stat, --numstat, --name-only, or --name-status."
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

-- The corrected text for one offending `git diff` command node plus its byte
-- range in the source, or nil if the command is not a patch-printing `git diff`.
local function corrected_command(node, source)
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
  local sub_idx = find_subcommand(argv)
  if not sub_idx or argv[sub_idx] ~= "diff" then
    return nil
  end

  local diff_args = {}
  for j = sub_idx + 1, #argv do
    diff_args[#diff_args + 1] = argv[j]
  end
  if classify_diff_args(diff_args) ~= "patch" then
    return nil
  end

  -- Splice `--no-ext-diff` right after the `diff` token, keeping the original
  -- quoting of everything else.
  local _, _, diff_end_byte = tokens[i + sub_idx].node:end_()
  local _, _, node_start_byte = node:start()
  local _, _, node_end_byte = node:end_()
  local text = node_text(node, source)
  local offset = diff_end_byte - node_start_byte
  local corrected = text:sub(1, offset) .. " " .. NO_EXT_DIFF .. text:sub(offset + 1)
  return corrected, node_start_byte, node_end_byte
end

-- Replace each {start, stop, text} range (1-based, document order) with the
-- corrected text.
local function splice(command, fixes)
  local out = command
  for k = #fixes, 1, -1 do
    local f = fixes[k]
    out = out:sub(1, f.start - 1) .. f.text .. out:sub(f.stop + 1)
  end
  return out
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
    local fixes = {}
    for_each_command(root, function(node)
      local corrected, start_byte, stop_byte = corrected_command(node, command)
      if corrected then
        fixes[#fixes + 1] = { start = start_byte + 1, stop = stop_byte, text = corrected }
      end
    end)
    if #fixes > 0 then
      return build_message(splice(command, fixes))
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
  classify_diff_args = classify_diff_args,
  find_subcommand = find_subcommand,
  build_message = build_message,
  splice = splice,
}
