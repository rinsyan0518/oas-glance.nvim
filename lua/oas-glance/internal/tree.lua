local scalar = require("oas-glance.internal.scalar")

local M = {}

local BOM = "\239\187\191"
local MAX_SYNTAX_DIAGNOSTICS = 100

local NODE_KINDS = {
  block_mapping = "map",
  flow_mapping = "map",
  flow_pair = "map",
  block_sequence = "seq",
  flow_sequence = "seq",
  plain_scalar = "scalar",
  single_quote_scalar = "scalar",
  double_quote_scalar = "scalar",
  block_scalar = "scalar",
  alias = "alias",
}

local SCALAR_STYLES = {
  plain_scalar = "plain",
  single_quote_scalar = "single",
  double_quote_scalar = "double",
}

local CORE_TAGS = {
  ["!"] = true,
  ["!!str"] = true,
  ["!!int"] = true,
  ["!!float"] = true,
  ["!!bool"] = true,
  ["!!null"] = true,
  ["!!map"] = true,
  ["!!seq"] = true,
  ["!!binary"] = true,
  ["!!timestamp"] = true,
  ["!!set"] = true,
  ["!!omap"] = true,
  ["!!pairs"] = true,
  ["!!merge"] = true,
}

---@class oas_glance.Pos
---@field file string?
---@field bufnr integer?
---@field row integer
---@field col integer
---@field end_row integer
---@field end_col integer

---@class oas_glance.Diagnostic
---@field level "error"|"warn"|"info"
---@field code string
---@field message string
---@field pos oas_glance.Pos
---@field count integer?

---@class oas_glance.Node
---@field kind "map"|"seq"|"scalar"|"alias"
---@field pos oas_glance.Pos
---@field value any
---@field raw string
---@field style string
---@field scalar_type string
---@field name string?
---@field package _ts TSNode?
---@field package _wrapper TSNode?
---@field package _doc oas_glance.Doc
---@field package _entries oas_glance.Entry[]?
---@field package _index table<string, oas_glance.Node>?
---@field package _items oas_glance.Node[]?
---@field package _resolved boolean?
---@field package _target oas_glance.Node?

---@class oas_glance.Entry
---@field key string
---@field key_pos oas_glance.Pos
---@field value oas_glance.Node
---@field package _is_merge boolean?

---@class oas_glance.Doc
---@field file string?
---@field bufnr integer?
---@field text string
---@field root oas_glance.Node?
---@field diagnostics oas_glance.Diagnostic[]
---@field lang_tree vim.treesitter.LanguageTree
---@field counters { materialised: integer, anchor_queries: integer }
---@field identity string?
---@field real_dir string?
---@field package _parsed string
---@field package _shift integer
---@field package _truncated boolean?
---@field package _nodes table<string, oas_glance.Node>
---@field package _anchors table<string, { first: integer, wrapper: TSNode }[]>?

---@param doc oas_glance.Doc
---@param ts TSNode
---@return string
local function source(doc, ts)
  local _, _, first = ts:start()
  local _, _, last = ts:end_()
  return doc._parsed:sub(first + 1, last)
end

---@param doc oas_glance.Doc
---@param row integer
---@param col integer
---@param end_row integer
---@param end_col integer
---@return oas_glance.Pos
local function make_pos(doc, row, col, end_row, end_col)
  return {
    file = doc.file,
    bufnr = doc.bufnr,
    row = row,
    col = row == 0 and col + doc._shift or col,
    end_row = end_row,
    end_col = end_row == 0 and end_col + doc._shift or end_col,
  }
end

---@param doc oas_glance.Doc
---@param ts TSNode
---@return oas_glance.Pos
local function ts_pos(doc, ts)
  local row, col, end_row, end_col = ts:range()
  return make_pos(doc, row, col, end_row, end_col)
end

---@param doc oas_glance.Doc
---@param level "error"|"warn"|"info"
---@param code string
---@param message string
---@param pos oas_glance.Pos
local function add_diagnostic(doc, level, code, message, pos)
  doc.diagnostics[#doc.diagnostics + 1] = { level = level, code = code, message = message, pos = pos }
end

--- The indentation a block scalar's indicator counts from, -1 at the top level.
---@param wrapper TSNode?
---@return integer
local function parent_indent(wrapper)
  local parent = wrapper and wrapper:parent()
  if parent and (parent:type() == "block_mapping_pair" or parent:type() == "block_sequence_item") then
    local _, col = parent:start()
    return col
  end
  return -1
end

--- A block scalar's range can stop before the blank lines that keep chomping needs.
---@param doc oas_glance.Doc
---@param ts TSNode
---@return string
local function block_text(doc, ts)
  local _, _, last = ts:end_()
  local blanks = doc._parsed:match("^[ \t\r\n]*", last + 1)
  return source(doc, ts) .. (blanks:match("^(.*[\r\n])") or "")
end

local scalar_meta = {}

function scalar_meta.__index(node, key)
  if key == "raw" then
    local raw = source(rawget(node, "_doc"), rawget(node, "_ts"))
    rawset(node, "raw", raw)
    return raw
  end
  if (key == "value" or key == "scalar_type") and not rawget(node, "_decoded") then
    local style = rawget(node, "style")
    local value, scalar_type
    if style == "literal" or style == "folded" then
      local text = block_text(rawget(node, "_doc"), rawget(node, "_ts"))
      value, scalar_type = scalar.decode(text, style, parent_indent(rawget(node, "_wrapper")))
    else
      value, scalar_type = scalar.decode(node.raw, style)
    end
    rawset(node, "value", value)
    rawset(node, "scalar_type", scalar_type)
    rawset(node, "_decoded", true)
    return rawget(node, key)
  end
  return nil
end

---@param doc oas_glance.Doc
---@param pos oas_glance.Pos
---@return oas_glance.Node
local function empty_scalar(doc, pos)
  doc.counters.materialised = doc.counters.materialised + 1
  return { kind = "scalar", pos = pos, raw = "", style = "plain", scalar_type = "null", _doc = doc }
end

---@param wrapper TSNode
---@return TSNode?
local function content_of(wrapper)
  if NODE_KINDS[wrapper:type()] then
    return wrapper
  end
  for _, child in ipairs(wrapper:named_children()) do
    if NODE_KINDS[child:type()] then
      return child
    end
  end
  return nil
end

---@param doc oas_glance.Doc
---@param wrapper TSNode
local function note_custom_tags(doc, wrapper)
  for _, child in ipairs(wrapper:named_children()) do
    if child:type() == "tag" then
      local tag = source(doc, child)
      if not CORE_TAGS[tag] then
        add_diagnostic(doc, "info", "custom-tag", "custom tag " .. tag, ts_pos(doc, child))
      end
    end
  end
end

--- One node per source node, so an alias reaches the anchored node itself.
---@param doc oas_glance.Doc
---@param wrapper TSNode
---@return oas_glance.Node
local function make_node(doc, wrapper)
  local ts = content_of(wrapper)
  local id = (ts or wrapper):id()
  local known = doc._nodes[id]
  if known then
    return known
  end

  note_custom_tags(doc, wrapper)

  local node
  if not ts then
    node = empty_scalar(doc, ts_pos(doc, wrapper))
    node._wrapper = wrapper
  else
    doc.counters.materialised = doc.counters.materialised + 1
    local ts_type = ts:type()
    local kind = NODE_KINDS[ts_type]
    node = { kind = kind, pos = ts_pos(doc, ts), _ts = ts, _wrapper = wrapper, _doc = doc }
    if kind == "scalar" then
      node.style = SCALAR_STYLES[ts_type] or (source(doc, ts):sub(1, 1) == ">" and "folded" or "literal")
      setmetatable(node, scalar_meta)
    elseif kind == "alias" then
      node.name = source(doc, ts):sub(2)
    end
  end
  doc._nodes[id] = node
  return node
end

---@param doc oas_glance.Doc
---@param pair TSNode
---@return oas_glance.Entry
local function make_entry(doc, pair)
  local key_ts, value_ts
  if pair:type() == "flow_node" then
    key_ts = pair
  else
    key_ts = pair:field("key")[1]
    value_ts = pair:field("value")[1]
  end

  local _, _, end_row, end_col = pair:range()
  local end_pos = make_pos(doc, end_row, end_col, end_row, end_col)
  local key_node = key_ts and make_node(doc, key_ts) or empty_scalar(doc, end_pos)

  local key
  if key_node.kind == "scalar" then
    key = scalar.text(key_node.raw, key_node.style)
  else
    key = source(doc, key_ts)
    add_diagnostic(doc, "info", "complex-key", "complex key " .. key, key_node.pos)
  end

  return {
    key = key,
    key_pos = key_node.pos,
    value = value_ts and make_node(doc, value_ts) or empty_scalar(doc, end_pos),
    _is_merge = key == "<<" and key_node.style == "plain",
  }
end

--- Runs the anchor query at most once per document.
---@param doc oas_glance.Doc
---@return table<string, { first: integer, wrapper: TSNode }[]>
local function anchors_of(doc)
  if doc._anchors then
    return doc._anchors
  end
  doc.counters.anchor_queries = doc.counters.anchor_queries + 1

  local anchors = {}
  local query = vim.treesitter.query.parse("yaml", "(anchor (anchor_name) @name)")
  local root = doc.lang_tree:trees()[1]:root()
  for _, name_node in query:iter_captures(root, doc._parsed) do
    local anchor = name_node:parent()
    local wrapper = anchor and anchor:parent()
    if anchor and wrapper then
      local name = source(doc, name_node)
      local _, _, first = anchor:start()
      anchors[name] = anchors[name] or {}
      table.insert(anchors[name], { first = first, wrapper = wrapper })
    end
  end
  doc._anchors = anchors
  return anchors
end

---@param node oas_glance.Node
---@param cycle_code "alias-cycle"|"merge-cycle"
---@return oas_glance.Node?
local function resolve_alias(node, cycle_code)
  if node.kind ~= "alias" then
    return node
  end
  if node._resolved then
    return node._target
  end
  node._resolved = true

  local doc = node._doc
  local _, _, alias_first = node._ts:start()
  local found
  for _, anchor in ipairs(anchors_of(doc)[node.name] or {}) do
    if anchor.first < alias_first then
      found = anchor
    end
  end

  if not found then
    add_diagnostic(doc, "warn", "unknown-alias", "unknown alias *" .. node.name, node.pos)
    return nil
  end

  local _, _, wrapper_last = found.wrapper:end_()
  if alias_first < wrapper_last then
    local label = cycle_code == "merge-cycle" and "merge cycle at *" or "alias cycle at *"
    add_diagnostic(doc, "warn", cycle_code, label .. node.name, node.pos)
    return nil
  end

  node._target = resolve_alias(make_node(doc, found.wrapper), cycle_code)
  return node._target
end

--- The node an alias stands for, or the node itself. Nil for an alias that cannot be followed.
---@param node oas_glance.Node
---@return oas_glance.Node?
function M.resolve(node)
  return resolve_alias(node, "alias-cycle")
end

---@param doc oas_glance.Doc
---@param entry oas_glance.Entry
---@return oas_glance.Node[]
local function merge_sources(doc, entry)
  local value = resolve_alias(entry.value, "merge-cycle")
  if not value then
    return {}
  end

  local candidates = { value }
  if value.kind == "seq" then
    candidates = {}
    for _, item in ipairs(M.items(value)) do
      candidates[#candidates + 1] = resolve_alias(item, "merge-cycle")
    end
  end

  local sources = {}
  for _, candidate in ipairs(candidates) do
    if candidate.kind == "map" then
      sources[#sources + 1] = candidate
    else
      add_diagnostic(doc, "warn", "bad-merge", "merge value is not a mapping", candidate.pos)
    end
  end
  return sources
end

--- Applies duplicate keys (last wins) and merge keys (inserted at `<<`, explicit keys win).
---@param doc oas_glance.Doc
---@param direct oas_glance.Entry[]
---@return oas_glance.Entry[]
local function finish_entries(doc, direct)
  local explicit = {}
  for index, entry in ipairs(direct) do
    if not entry._is_merge then
      if explicit[entry.key] then
        add_diagnostic(doc, "info", "duplicate-key", "duplicate key " .. entry.key, entry.key_pos)
      end
      explicit[entry.key] = index
    end
  end

  local entries = {}
  local merged = {}
  for index, entry in ipairs(direct) do
    if entry._is_merge then
      for _, merge_source in ipairs(merge_sources(doc, entry)) do
        for _, inherited in ipairs(M.entries(merge_source)) do
          if not explicit[inherited.key] and not merged[inherited.key] then
            merged[inherited.key] = true
            entries[#entries + 1] = inherited
          end
        end
      end
    elseif explicit[entry.key] == index then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

--- Entries of a map in file order, through an alias. Anything else has none.
---@param node oas_glance.Node
---@return oas_glance.Entry[]
function M.entries(node)
  local target = M.resolve(node)
  if not target or target.kind ~= "map" then
    return {}
  end
  if target._entries then
    return target._entries
  end

  local doc = target._doc
  local direct = {}
  local ts = target._ts --[[@as TSNode]]
  if ts:type() == "flow_pair" then
    direct[1] = make_entry(doc, ts)
  else
    for _, child in ipairs(ts:named_children()) do
      local child_type = child:type()
      if child_type == "block_mapping_pair" or child_type == "flow_pair" or child_type == "flow_node" then
        direct[#direct + 1] = make_entry(doc, child)
      end
    end
  end

  local entries = finish_entries(doc, direct)
  target._entries = entries
  return entries
end

---@param node oas_glance.Node
---@param key string
---@return oas_glance.Node?
function M.get(node, key)
  local target = M.resolve(node)
  if not target or target.kind ~= "map" then
    return nil
  end
  if not target._index then
    local index = {}
    for _, entry in ipairs(M.entries(target)) do
      index[entry.key] = entry.value
    end
    target._index = index
  end
  return target._index[key]
end

--- Items of a seq in file order, through an alias. Anything else has none.
---@param node oas_glance.Node
---@return oas_glance.Node[]
function M.items(node)
  local target = M.resolve(node)
  if not target or target.kind ~= "seq" then
    return {}
  end
  if target._items then
    return target._items
  end

  local doc = target._doc
  local items = {}
  for _, child in ipairs(target._ts:named_children()) do
    local child_type = child:type()
    if child_type == "block_sequence_item" then
      local inner
      for _, candidate in ipairs(child:named_children()) do
        if candidate:type() == "flow_node" or candidate:type() == "block_node" then
          inner = candidate
          break
        end
      end
      items[#items + 1] = inner and make_node(doc, inner) or empty_scalar(doc, ts_pos(doc, child))
    elseif child_type == "flow_node" or child_type == "flow_pair" then
      items[#items + 1] = make_node(doc, child)
    end
  end
  target._items = items
  return items
end

--- The document a node belongs to.
---@param node oas_glance.Node
---@return oas_glance.Doc
function M.doc_of(node)
  return node._doc
end

--- The node's source text.
---@param node oas_glance.Node
---@return string
function M.source(node)
  return node._ts and source(node._doc, node._ts) or ""
end

--- Whether the node's source range holds a syntax error.
---@param node oas_glance.Node
---@return boolean
function M.node_has_error(node)
  local ts = node._wrapper or node._ts
  return ts ~= nil and ts:has_error()
end

--- Whether the yaml parser can be used.
---@return boolean ok
---@return ("missing"|"load")? kind
---@return string? reason
function M.parser_status()
  if #vim.api.nvim_get_runtime_file("parser/yaml.*", false) == 0 then
    return false, "missing"
  end
  local ok, added, err = pcall(vim.treesitter.language.add, "yaml")
  if not ok then
    return false, "load", tostring(added)
  end
  if not added then
    return false, "load", err or "unknown error"
  end
  return true
end

---@param text string
---@return vim.treesitter.LanguageTree parser
---@return TSTree? tree
local function run_parser(text)
  local parser = vim.treesitter.get_string_parser(text, "yaml")
  local trees = parser:parse()
  return parser, trees and trees[1]
end

---@param doc oas_glance.Doc
---@param root TSNode
local function collect_syntax_diagnostics(doc, root)
  if not root:has_error() then
    return
  end
  local query = vim.treesitter.query.parse("yaml", "[(ERROR) (MISSING)] @problem")
  local total = 0
  local first_over
  for _, problem in query:iter_captures(root, doc._parsed) do
    total = total + 1
    if total <= MAX_SYNTAX_DIAGNOSTICS then
      local message = problem:missing() and ("missing " .. problem:type()) or "unexpected token"
      add_diagnostic(doc, "error", "syntax", message, ts_pos(doc, problem))
    elseif not first_over then
      first_over = problem
    end
  end
  if first_over then
    local rest = total - MAX_SYNTAX_DIAGNOSTICS
    local message = string.format("%d more syntax errors", rest)
    add_diagnostic(doc, "error", "syntax-rest", message, ts_pos(doc, first_over))
    doc.diagnostics[#doc.diagnostics].count = rest
  end
  -- A MISSING node at the stream level is reported by has_error() but reachable by neither a query nor a walk.
  if total == 0 then
    local _, _, end_row, end_col = root:range()
    local pos = make_pos(doc, end_row, end_col, end_row, end_col)
    add_diagnostic(doc, "error", "syntax", "unexpected token", pos)
  end
end

--- The parser stops at a NUL byte without reporting an error.
---@param doc oas_glance.Doc
local function note_nul_byte(doc)
  local nul = doc._parsed:find("\0", 1, true)
  if not nul then
    return
  end
  doc._truncated = true
  local before = doc._parsed:sub(1, nul - 1)
  local _, row = before:gsub("\n", "")
  local col = #before:match("[^\n]*$")
  local pos = make_pos(doc, row, col, row, col)
  add_diagnostic(doc, "error", "nul-byte", "NUL byte: the text after it was not read", pos)
end

--- Why a document could not be opened. `n` is the line count for kind "lines".
---@class oas_glance.OpenError
---@field kind string
---@field reason string?
---@field n integer?

--- Parses text. On failure returns nil and `{ kind, reason }`, with kind "missing", "load" or "parse".
---@param text string
---@param opts? { file?: string, bufnr?: integer }
---@return oas_glance.Doc?
---@return oas_glance.OpenError?
function M.parse(text, opts)
  opts = opts or {}
  local ok, kind, reason = M.parser_status()
  if not ok then
    return nil, { kind = kind, reason = reason }
  end

  local parsed, shift = text, 0
  local parser, ts_tree = run_parser(parsed)
  if ts_tree and vim.startswith(text, BOM) and ts_tree:root():has_error() then
    parsed, shift = text:sub(#BOM + 1), #BOM
    parser, ts_tree = run_parser(parsed)
  end
  if not ts_tree then
    return nil, { kind = "parse", reason = "the parser returned no tree" }
  end

  local doc = {
    file = opts.file,
    bufnr = opts.bufnr,
    text = text,
    diagnostics = {},
    lang_tree = parser,
    counters = { materialised = 0, anchor_queries = 0 },
    _parsed = parsed,
    _shift = shift,
    _nodes = {},
  }

  local root = ts_tree:root()
  collect_syntax_diagnostics(doc, root)
  note_nul_byte(doc)

  local documents = 0
  for _, child in ipairs(root:named_children()) do
    if child:type() == "document" then
      documents = documents + 1
      if documents == 1 then
        for _, wrapper in ipairs(child:named_children()) do
          local wrapper_type = wrapper:type()
          if wrapper_type == "flow_node" or wrapper_type == "block_node" then
            doc.root = make_node(doc, wrapper)
            break
          end
        end
      else
        add_diagnostic(doc, "info", "second-document", "only the first YAML document is shown", ts_pos(doc, child))
      end
    end
  end
  return doc
end

--- Whether the parsed tree holds any error, or the parser did not read the whole text.
---@param doc oas_glance.Doc
---@return boolean
function M.has_error(doc)
  return doc._truncated == true or doc.lang_tree:trees()[1]:root():has_error()
end

--- The most lines the pinned parser handles in block style. Its scanner stores rows in 16 bits.
M.LINE_LIMIT = 32768

--- Lines as Neovim counts them, so a final newline does not start another line.
---@param text string
---@return integer
function M.line_count(text)
  if text == "" then
    return 0
  end
  local count = select(2, text:gsub("\n", ""))
  if text:sub(-1) ~= "\n" then
    count = count + 1
  end
  return count
end

--- The line count when the text is block-style YAML over the limit and its tree has an error, else nil.
---@param text string The text the parser saw.
---@param has_error boolean Checked first, so a valid document costs nothing.
---@return integer?
function M.line_limit(text, has_error)
  if not has_error then
    return nil
  end
  local count = M.line_count(text)
  if count <= M.LINE_LIMIT then
    return nil
  end
  local pos = text:sub(1, #BOM) == BOM and #BOM + 1 or 1
  while true do
    local first = text:find("[^ \t\r\n]", pos)
    if not first then
      return nil
    end
    local char = text:sub(first, first)
    if char ~= "#" then
      -- Flow style, which includes JSON, is not affected by the limit.
      return (char ~= "{" and char ~= "[") and count or nil
    end
    local line_end = text:find("\n", first, true)
    if not line_end then
      return nil
    end
    pos = line_end + 1
  end
end

return M
