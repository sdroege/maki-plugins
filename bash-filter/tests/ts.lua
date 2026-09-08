-- Stand-in for maki.treesitter backed by the real libtree-sitter C API via
-- luajit ffi. Mirrors the exact API surface lua/git_diff.lua uses, so the
-- command-level tests exercise the real bash grammar parse.

local M = {}

local function self_dir()
  local src = debug.getinfo(2, "S").source:gsub("^@", "")
  return src:match("^(.*)/[^/]+$") or "."
end

local node_mt = {}
node_mt.__index = node_mt

local function new_node(n)
  return setmetatable({ n = n }, node_mt)
end

function node_mt:type()
  return M._ffi.string(M._C.ts_node_type(self.n))
end

function node_mt:named()
  return M._C.ts_node_is_named(self.n)
end

function node_mt:has_error()
  return M._C.ts_node_has_error(self.n)
end

function node_mt:start()
  local p = M._C.ts_node_start_point(self.n)
  return p.row, p.column, M._C.ts_node_start_byte(self.n)
end

function node_mt:end_()
  local p = M._C.ts_node_end_point(self.n)
  return p.row, p.column, M._C.ts_node_end_byte(self.n)
end

function node_mt:iter_children()
  local i = 0
  local count = M._C.ts_node_child_count(self.n)
  return function()
    if i < count then
      i = i + 1
      return new_node(M._C.ts_node_child(self.n, i - 1))
    end
  end
end

local tree_mt = { __index = {} }
function tree_mt.__index:root()
  return new_node(M._C.ts_tree_root_node(self.tree))
end

local parser_mt = { __index = {} }
function parser_mt.__index:parse(_range)
  if not self.tree then
    self.tree = M._C.ts_parser_parse_string(self.p, nil, self.source, #self.source)
    assert(self.tree, "parse failed")
  end
  return { setmetatable({ tree = self.tree }, tree_mt) }
end

-- ffi.load returns (nil, err) on some builds and raises on others; handle both.
local function try_load(ffi, name)
  local ok, res, extra = pcall(ffi.load, name)
  if ok then
    return res, res and nil or extra
  end
  return nil, res
end

function M.get_parser(source)
  local p = M._C.ts_parser_new()
  M._C.ts_parser_set_language(p, M._bash.tree_sitter_bash())
  return setmetatable({ p = p, source = source }, parser_mt)
end

function M.get_node_text(node, source)
  local _, _, start_byte = node:start()
  local _, _, end_byte = node:end_()
  return source:sub(start_byte + 1, end_byte)
end

-- Loads the shared libraries, building the grammar on first use.
-- Returns true, or nil and an error message.
function M.init()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil, "ffi not available (run under luajit)"
  end
  M._ffi = ffi
  ffi.cdef[[
typedef struct TSLanguage TSLanguage;
typedef struct TSParser TSParser;
typedef struct TSTree TSTree;
typedef struct TSNode {
  uint32_t context[4];
  const void *id;
  const struct TSTree *tree;
} TSNode;
typedef struct { uint32_t row; uint32_t column; } TSPoint;
TSParser *ts_parser_new(void);
void ts_parser_set_language(TSParser *self, const TSLanguage *language);
TSTree *ts_parser_parse_string(TSParser *self, TSTree *old_tree, const char *string, uint32_t length);
TSNode ts_tree_root_node(TSTree *self);
const char *ts_node_type(TSNode self);
bool ts_node_is_named(TSNode self);
bool ts_node_has_error(TSNode self);
uint32_t ts_node_child_count(TSNode self);
TSNode ts_node_child(TSNode self, uint32_t child_index);
uint32_t ts_node_start_byte(TSNode self);
uint32_t ts_node_end_byte(TSNode self);
TSPoint ts_node_start_point(TSNode self);
TSPoint ts_node_end_point(TSNode self);
TSLanguage *tree_sitter_bash(void);
  ]]
  local core, cerr = try_load(ffi, "tree-sitter")
  if not core then
    return nil, cerr
  end
  local dir = self_dir()
  local so = dir .. "/lib/libtree-sitter-bash.so"
  local bash, berr = try_load(ffi, so)
  if not bash then
    os.execute("sh " .. dir .. "/lib/build.sh")
    bash, berr = try_load(ffi, so)
    if not bash then
      return nil, berr
    end
  end
  -- The TSNode layout above must match the loaded libtree-sitter; a trivial
  -- parse catches a mismatch before it segfaults mid-test.
  do
    local p = core.ts_parser_new()
    core.ts_parser_set_language(p, bash.tree_sitter_bash())
    local tree = core.ts_parser_parse_string(p, nil, "echo hi", 7)
    local root_type = tree and ffi.string(core.ts_node_type(core.ts_tree_root_node(tree)))
    if root_type ~= "program" then
      return nil, "libtree-sitter ABI mismatch: root node type is not program"
    end
  end
  M._C = core
  M._bash = bash
  return true
end

return M
