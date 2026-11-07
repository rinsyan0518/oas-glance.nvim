local tree = require("oas-glance.internal.tree")

local M = {}

---@class oas_glance.ParsedRef
---@field target string The ref as written, for display.
---@field reason string? Set when the text alone shows the ref is broken.
---@field is_local boolean?
---@field path string? The file part of an external ref.
---@field pointer string? The percent-decoded fragment.
---@field key string? The canonical key, known from the text only for a local ref.
---@field name string?
---@field file string? The file name of an external ref.

---@class oas_glance.RefResult
---@field reason string? Set on failure.
---@field node oas_glance.Node?
---@field doc oas_glance.Doc?
---@field key string?
---@field keys string[]? Every key on a followed chain.
---@field diagnostics oas_glance.Diagnostic[]?
---@field ignored oas_glance.Node[]?

local CONTROL = "[%z\1-\31\127]"

--- Decodes `%XX` escapes, or returns nil when a `%` is not followed by two hex digits.
---@param text string
---@return string?
local function percent_decode(text)
  if text:gsub("%%%x%x", ""):find("%", 1, true) then
    return nil
  end
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param pointer string
---@return string[]
local function pointer_segments(pointer)
  local segments = {}
  for segment in pointer:gmatch("/([^/]*)") do
    segments[#segments + 1] = segment:gsub("~1", "/"):gsub("~0", "~")
  end
  return segments
end

---@param parsed oas_glance.ParsedRef
local function set_display_name(parsed)
  local segments = pointer_segments(parsed.pointer)
  local last = segments[#segments]
  if parsed.is_local then
    parsed.name = last or "#"
    return
  end
  local file = parsed.path:match("[^/]*$")
  parsed.file = file
  parsed.name = last or file:gsub("%.[^.]*$", "")
end

--- The text checks. They touch no file and no tree.
---@param value any The `$ref` value. Anything but a non-empty string is unsupported.
---@param identity string The referring document's identity, for a local ref's key.
---@param display? string The text to show for a non-string value.
---@return oas_glance.ParsedRef
function M.check_text(value, identity, display)
  if type(value) ~= "string" or value == "" then
    return { target = type(value) == "string" and value or display or tostring(value), reason = "unsupported ref" }
  end
  -- No real document needs one, and refusing them keeps such text away from any command.
  if value:find(CONTROL) then
    return { target = value, reason = "not allowed" }
  end

  local scheme = value:match("^(%a[%w+.-]*):")
  if scheme then
    local lowered = scheme:lower()
    local remote = lowered == "http" or lowered == "https"
    return { target = value, reason = remote and "remote not loaded" or "not allowed" }
  end

  local raw_path, raw_fragment = value:match("^([^#]*)#?(.*)$")
  local path, fragment = percent_decode(raw_path), percent_decode(raw_fragment)
  if not path or not fragment then
    return { target = value, reason = "unsupported ref" }
  end
  if path:find(CONTROL) or fragment:find(CONTROL) then
    return { target = value, reason = "not allowed" }
  end
  if fragment ~= "" and fragment:sub(1, 1) ~= "/" then
    return { target = value, reason = "unsupported ref" }
  end

  local parsed = { target = value, path = path, pointer = fragment, is_local = path == "" }
  if parsed.is_local then
    parsed.key = identity .. "#" .. parsed.pointer
  end
  set_display_name(parsed)
  return parsed
end

--- The `$ref` value of a node, and its display text if it is not a string.
---@param node oas_glance.Node
---@return any value
---@return string? display
function M.ref_value(node)
  local target = tree.resolve(node)
  if target and target.kind == "scalar" and target.scalar_type == "string" then
    return target.value
  end
  return nil, tree.source(node)
end

--- Walks a pointer through aliases, not through `$ref`s.
---@param doc oas_glance.Doc
---@param pointer string
---@return oas_glance.Node?
---@return string? reason
function M.walk(doc, pointer)
  local function failed()
    return nil, tree.has_error(doc) and "parse failed" or "no such pointer"
  end

  local node = doc.root and tree.resolve(doc.root)
  if not node then
    return failed()
  end
  for _, segment in ipairs(pointer_segments(pointer)) do
    local child
    if node.kind == "seq" then
      -- RFC 6901 allows no leading zero in an array index.
      local index = (segment == "0" or segment:match("^[1-9]%d*$")) and tonumber(segment)
      child = index and tree.items(node)[index + 1]
    else
      child = tree.get(node, segment)
    end
    node = child and tree.resolve(child)
    if not node then
      return failed()
    end
  end
  return node
end

--- The open checks for one ref that passed its text checks.
---@param workspace oas_glance.Workspace
---@param from oas_glance.Doc
---@param parsed oas_glance.ParsedRef
---@return oas_glance.RefResult
function M.open(workspace, from, parsed)
  if parsed.reason then
    return { reason = parsed.reason }
  end

  local doc = from
  if not parsed.is_local then
    local loaded, load_reason = workspace:load_external(from, parsed.path)
    if not loaded then
      return { reason = load_reason }
    end
    doc = loaded
  end

  local node, reason = M.walk(doc, parsed.pointer)
  if not node then
    return { reason = reason, doc = doc, diagnostics = doc.diagnostics }
  end
  return { node = node, doc = doc, key = doc.identity .. "#" .. parsed.pointer, diagnostics = doc.diagnostics }
end

--- The target's `$ref` if the chain continues through it. A 3.1 Schema's siblings are content and end the chain.
---@param node oas_glance.Node
---@param opts { version: "3.0"|"3.1", reference_object?: boolean }
---@return oas_glance.Node? hop
---@return boolean? siblings_ignored
local function next_hop(node, opts)
  if node.kind ~= "map" then
    return nil
  end
  local ref = tree.get(node, "$ref")
  if not ref then
    return nil
  end
  local has_siblings = #tree.entries(node) > 1
  if has_siblings and opts.version ~= "3.0" and not opts.reference_object then
    return nil
  end
  return ref, has_siblings and opts.version == "3.0"
end

--- Opens a ref and follows a chain of refs with no content between them.
--- `ignored` in the result holds the `$ref` nodes of hops whose siblings were ignored, also on failure.
---@param workspace oas_glance.Workspace
---@param from oas_glance.Doc
---@param parsed oas_glance.ParsedRef
---@param opts { version: "3.0"|"3.1", reference_object?: boolean } The root document's version, for every hop.
---@return oas_glance.RefResult
function M.follow(workspace, from, parsed, opts)
  assert(opts and opts.version, "refs.follow needs the root document's version")
  local seen, keys, ignored = {}, {}, {}
  local current, doc = parsed, from
  while true do
    local result = M.open(workspace, doc, current)
    result.ignored = ignored
    if result.reason then
      return result
    end
    if seen[result.key] then
      return { reason = "ref cycle", doc = result.doc, diagnostics = result.diagnostics, ignored = ignored }
    end
    seen[result.key] = true
    keys[#keys + 1] = result.key
    if #keys > workspace.max_depth then
      return { reason = "too deep", doc = result.doc, diagnostics = result.diagnostics, ignored = ignored }
    end

    local hop, siblings_ignored = next_hop(result.node, opts)
    if not hop then
      result.key = keys[1]
      result.keys = keys
      return result
    end
    if siblings_ignored then
      ignored[#ignored + 1] = hop
    end
    doc = result.doc --[[@as oas_glance.Doc]]
    local value, display = M.ref_value(hop)
    current = M.check_text(value, doc.identity, display)
  end
end

return M
