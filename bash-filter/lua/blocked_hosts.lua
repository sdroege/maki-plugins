-- Rejects fetches to the routify file proxy: hosts like
-- routify-file-proxy-sg.oss-ap-southeast-1.aliyuncs.com whose signed
-- /proxy_temp_file/production/.../trace_.../?Expires=&OSSAccessKeyId=&Signature=
-- URLs leak from the model-serving infrastructure into model context. The
-- model then tries to fetch them as if they were real sources; they always
-- answer HTTP 403. Only fetch tools are checked, so commands that merely
-- quote such a URL (grep, rg, echo) keep working.

-- A routify-file-proxy label (the region suffix varies) on aliyuncs.com.
local BLOCKED_HOST = "^routify%-file%-proxy[%w%.%-]*%.aliyuncs%.com$"

-- Commands whose URL arguments this filter rejects.
local FETCHERS = {
  curl = true,
  wget = true,
  wget2 = true,
}

-- Program basename, so /usr/bin/curl matches like curl does.
local function basename(prog)
  return prog:match("([^/]+)$") or prog
end

-- The lowercased host of a URL-shaped token: strips an optional scheme,
-- userinfo, and port, and stops at the path. A schemeless token resolves to
-- its host-before-path text, mirroring how curl and wget read bare arguments;
-- flags and plain words have no dot there and yield nil.
local function host_of(tok)
  if type(tok) ~= "string" then
    return nil
  end
  local rest = tok:match("^[%a][%w+%.%-]*://(.+)$") or tok
  local authority = rest:match("^([^/%?#]+)")
  if not authority then
    return nil
  end
  authority = authority:match("@(.+)$") or authority
  local host = authority:match("^%[(.-)%]") or authority:match("^([^:]+)") or authority
  host = host:lower()
  if not host:find(".", 1, true) then
    return nil
  end
  return host
end

local function is_blocked_host(host)
  return host ~= nil and host:match(BLOCKED_HOST) ~= nil
end

local function build_message(host)
  return "Blocked host " .. host .. ": routify file-proxy URLs on aliyuncs.com are not real "
    .. "sources. They are file links leaked by model-serving infrastructure and always answer "
    .. "HTTP 403. Do not retry them or invent similar URLs. Fetch the actual upstream instead "
    .. "(project homepage, repository, or docs site), or search with websearch."
end

-- The block reason for a webfetch tool input, or nil. Exported for the
-- tool.webfetch.input layer in main.lua.
local function check_webfetch(input)
  local url = type(input) == "table" and input.url
  if type(url) ~= "string" then
    return nil
  end
  local host = host_of(url)
  if is_blocked_host(host) then
    return build_message(host)
  end
  return nil
end

-- A token is rejected only when the blocked host *is* its host, never when
-- the token merely contains the host in a path, a query, or a POST body.
local function blocked_token(argv)
  for _, tok in ipairs(argv) do
    local host = host_of(tok)
    if is_blocked_host(host) then
      return build_message(host)
    end
  end
  return nil
end

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

-- The block reason of one `curl`/`wget` command node, or nil.
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
  if not prog or not FETCHERS[basename(prog.text)] then
    return nil
  end
  local argv = {}
  for j = i + 1, #tokens do
    argv[#argv + 1] = tokens[j].text
  end
  return blocked_token(argv)
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
      -- Keep scanning: an unquoted & in a signed URL errors only the trailing
      -- fragment, and blocking needs positive host evidence in a fetcher
      -- token, so error recovery cannot cause a false block.
      maki.log.warn("bash-filter: parse error, scanning command nodes anyway: " .. command)
    end
    local blocked = nil
    for_each_command(root, function(node)
      if not blocked then
        blocked = offending_command(node, command)
      end
    end)
    return blocked
  end)
  if not ok then
    maki.log.warn("bash-filter: " .. tostring(reason) .. ", allowing command: " .. command)
    return nil
  end
  return reason
end

return {
  filter = filter,
  check_webfetch = check_webfetch,
  host_of = host_of,
  is_blocked_host = is_blocked_host,
}
