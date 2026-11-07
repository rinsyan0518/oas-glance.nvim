local refs = require("oas-glance.internal.refs")
local tree = require("oas-glance.internal.tree")

local M = {}

local UNTAGGED = "(untagged)"

local METHODS = {
  get = true,
  put = true,
  post = true,
  delete = true,
  options = true,
  head = true,
  patch = true,
  trace = true,
}

-- Keywords a Schema reads. Anything else goes to `extra`.
local SCHEMA_KEYWORDS = {
  ["$ref"] = true,
  title = true,
  description = true,
  type = true,
  format = true,
  enum = true,
  const = true,
  default = true,
  example = true,
  examples = true,
  deprecated = true,
  readOnly = true,
  writeOnly = true,
  minimum = true,
  maximum = true,
  exclusiveMinimum = true,
  exclusiveMaximum = true,
  minLength = true,
  maxLength = true,
  minItems = true,
  maxItems = true,
  uniqueItems = true,
  pattern = true,
  multipleOf = true,
  properties = true,
  required = true,
  additionalProperties = true,
  patternProperties = true,
  items = true,
  prefixItems = true,
  allOf = true,
  oneOf = true,
  anyOf = true,
  ["not"] = true,
  discriminator = true,
}

---@class oas_glance.Document
---@field version "3.0"|"3.1"
---@field raw_version string
---@field info table
---@field servers table[]
---@field tags table[]
---@field groups table[]
---@field webhooks table[]
---@field schemas table[]
---@field diagnostics oas_glance.Diagnostic[]
---@field package _workspace oas_glance.Workspace
---@field package _doc oas_glance.Doc
---@field package _root oas_glance.Node
---@field _schemas table<oas_glance.Node, table>
---@field _operations table<table, table>
---@field package _broken_seen table<string, boolean>
---@field package _siblings_seen table<string, boolean>
---@field package _other_docs oas_glance.Doc[]
---@field package _security_schemes table<string, table|false>

---@param node oas_glance.Node?
---@return oas_glance.Node?
local function resolved(node)
  return node and tree.resolve(node)
end

---@param node oas_glance.Node
---@param key string
---@return oas_glance.Node?
local function field(node, key)
  return resolved(tree.get(node, key))
end

--- Text of a scalar: the decoded string, or the raw spelling of anything else. A null has none.
---@param node oas_glance.Node?
---@return string?
local function text_of(node)
  local target = resolved(node)
  if not target or target.kind ~= "scalar" or target.scalar_type == "null" then
    return nil
  end
  return target.scalar_type == "string" and target.value or target.raw
end

---@param node oas_glance.Node
---@param key string
---@return string?
local function text_field(node, key)
  return text_of(tree.get(node, key))
end

---@param node oas_glance.Node
---@param key string
---@return boolean?
local function bool_field(node, key)
  local target = field(node, key)
  if target and target.kind == "scalar" and target.scalar_type == "bool" then
    return target.value
  end
  return nil
end

---@param node oas_glance.Node
---@param key string
---@return string?
local function number_raw(node, key)
  local target = field(node, key)
  if target and target.kind == "scalar" and (target.scalar_type == "int" or target.scalar_type == "float") then
    return target.raw
  end
  return nil
end

---@param node oas_glance.Node
---@param level "warn"|"info"
---@param code string
---@param message string
---@param pos? oas_glance.Pos
local function add_diagnostic(node, level, code, message, pos)
  local diagnostics = tree.doc_of(node).diagnostics
  diagnostics[#diagnostics + 1] = { level = level, code = code, message = message, pos = pos or node.pos }
end

--- A value kept for display. Non-scalars keep only their node.
---@param node oas_glance.Node
---@return table?
local function literal(node)
  local target = tree.resolve(node)
  if not target then
    return nil
  end
  if target.kind ~= "scalar" then
    return { type = target.kind, text = tree.source(target), node = target }
  end
  return { type = target.scalar_type, text = text_of(target) or "null", node = target }
end

--- The node's entries, or a diagnostic when it should have been a mapping.
---@param node oas_glance.Node?
---@param what string
---@return oas_glance.Entry[]
local function map_entries(node, what)
  local target = resolved(node)
  if not target then
    return {}
  end
  if target.kind ~= "map" then
    add_diagnostic(target, "warn", "structure", what .. " is not a mapping")
    return {}
  end
  return tree.entries(target)
end

--- The node's items, or a diagnostic when it should have been a sequence.
---@param node oas_glance.Node?
---@param what string
---@return oas_glance.Node[]
local function seq_items(node, what)
  local target = resolved(node)
  if not target then
    return {}
  end
  if target.kind ~= "seq" then
    add_diagnostic(target, "warn", "structure", what .. " is not a list")
    return {}
  end
  return tree.items(target)
end

---@param document oas_glance.Document
---@param doc oas_glance.Doc?
local function note_doc(document, doc)
  if not doc or doc == document._doc or vim.tbl_contains(document._other_docs, doc) then
    return
  end
  document._other_docs[#document._other_docs + 1] = doc
end

--- A broken ref at one source position is one problem, however often it is reached.
---@param document oas_glance.Document
---@param pos oas_glance.Pos
---@param target string
---@param reason string
local function add_broken(document, pos, target, reason)
  local key = string.format("%s:%s:%d:%d", pos.file or "", pos.bufnr or "", pos.row, pos.col)
  if document._broken_seen[key] then
    return
  end
  document._broken_seen[key] = true
  local diagnostics = document.diagnostics
  diagnostics[#diagnostics + 1] =
    { level = "error", code = "broken-ref", message = target .. "  " .. reason, pos = pos }
end

--- One info diagnostic per source position, however often the `$ref` is reached.
---@param document oas_glance.Document
---@param ref_node oas_glance.Node
local function add_ref_siblings(document, ref_node)
  local pos = ref_node.pos
  local key = string.format("%s:%s:%d:%d", pos.file or "", pos.bufnr or "", pos.row, pos.col)
  if document._siblings_seen[key] then
    return
  end
  document._siblings_seen[key] = true
  add_diagnostic(ref_node, "info", "ref-siblings", "$ref siblings are ignored in OpenAPI 3.0")
  note_doc(document, tree.doc_of(ref_node))
end

---@param document oas_glance.Document
---@param ignored oas_glance.Node[]?
local function add_ignored_hops(document, ignored)
  for _, ref_node in ipairs(ignored or {}) do
    add_ref_siblings(document, ref_node)
  end
end

---@param node oas_glance.Node A `$ref` value.
---@return oas_glance.ParsedRef
local function parse_ref(node)
  local value, display = refs.ref_value(node)
  return refs.check_text(value, tree.doc_of(node).identity, display)
end

--- Follows a Reference Object. Returns the target, or a `broken` table in its place.
---@param document oas_glance.Document
---@param node oas_glance.Node? A resolved or unresolved value.
---@return oas_glance.Node? target
---@return { target: string, reason: string, name: string?, pos: oas_glance.Pos }? broken
---@return { summary: string?, description: string? }? overrides
local function deref(document, node)
  local target = resolved(node)
  if not target or target.kind ~= "map" then
    return target
  end
  local ref_node = tree.get(target, "$ref")
  if not ref_node then
    return target
  end

  local overrides
  if #tree.entries(target) > 1 then
    if document.version == "3.0" then
      add_ref_siblings(document, ref_node)
    else
      overrides = { summary = text_field(target, "summary"), description = text_field(target, "description") }
    end
  end

  local parsed = parse_ref(ref_node)
  local result = refs.follow(
    document._workspace,
    tree.doc_of(ref_node),
    parsed,
    { reference_object = true, version = document.version }
  )
  note_doc(document, result.doc)
  add_ignored_hops(document, result.ignored)
  if result.reason then
    add_broken(document, ref_node.pos, parsed.target, result.reason)
    return nil, { target = parsed.target, reason = result.reason, name = parsed.name, pos = ref_node.pos }
  end
  return result.node, nil, overrides
end

---@param node oas_glance.Node A `$ref` value.
---@return table
local function make_ref(node)
  local parsed = parse_ref(node)
  return {
    target = parsed.target,
    status = parsed.reason and "broken" or "closed",
    reason = parsed.reason,
    name = parsed.name,
    file = parsed.file,
    key = parsed.key,
    pos = node.pos,
    _parsed = parsed,
    _doc = tree.doc_of(node),
  }
end

--- With both keywords the tighter bound is kept, and the exclusive one wins a tie.
---@param node oas_glance.Node
---@param inclusive_key string
---@param exclusive_key string
---@param is_tighter fun(a: number, b: number): boolean
---@return { value: string, exclusive: boolean }?
local function read_bound(node, inclusive_key, exclusive_key, is_tighter)
  local inclusive = number_raw(node, inclusive_key)
  local exclusive_flag = bool_field(node, exclusive_key)
  if exclusive_flag ~= nil then
    return inclusive and { value = inclusive, exclusive = exclusive_flag } or nil
  end

  local exclusive = number_raw(node, exclusive_key)
  if inclusive and exclusive then
    if
      is_tighter(tonumber(inclusive) --[[@as number]], tonumber(exclusive) --[[@as number]])
    then
      return { value = inclusive, exclusive = false }
    end
    return { value = exclusive, exclusive = true }
  end
  if exclusive then
    return { value = exclusive, exclusive = true }
  end
  return inclusive and { value = inclusive, exclusive = false } or nil
end

---@param a number
---@param b number
---@return boolean
local function greater(a, b)
  return a > b
end

---@param a number
---@param b number
---@return boolean
local function less(a, b)
  return a < b
end

---@param node oas_glance.Node
---@param min_key string
---@param max_key string
---@return { min: string?, max: string? }?
local function read_range(node, min_key, max_key)
  local min, max = number_raw(node, min_key), number_raw(node, max_key)
  if not min and not max then
    return nil
  end
  return { min = min, max = max }
end

---@param node oas_glance.Node
---@return string[]
local function read_types(node)
  local type_node = field(node, "type")
  if not type_node then
    return {}
  end
  if type_node.kind == "seq" then
    local types = {}
    for _, item in ipairs(tree.items(type_node)) do
      types[#types + 1] = text_of(item)
    end
    return types
  end
  local text = text_of(type_node)
  if text then
    return { text }
  end
  add_diagnostic(type_node, "warn", "structure", "type is neither a name nor a list")
  return {}
end

---@param node oas_glance.Node?
---@return table[]
local function read_literals(node)
  local literals = {}
  for _, item in ipairs(node and tree.items(node) or {}) do
    literals[#literals + 1] = literal(item)
  end
  return literals
end

local build_schema

---@param document oas_glance.Document
---@param items oas_glance.Node[]
---@param depth integer
---@return table[]
local function build_schema_list(document, items, depth)
  local schemas = {}
  for _, item in ipairs(items) do
    schemas[#schemas + 1] = build_schema(document, item, depth)
  end
  return schemas
end

---@param document oas_glance.Document
---@param schema table
---@param node oas_glance.Node
---@param depth integer
local function read_object_keywords(document, schema, node, depth)
  schema.required = {}
  local required_set = {}
  for _, item in ipairs(seq_items(tree.get(node, "required"), "required")) do
    local name = text_of(item)
    if name then
      schema.required[#schema.required + 1] = name
      required_set[name] = true
    end
  end

  schema.properties = {}
  for _, entry in ipairs(map_entries(tree.get(node, "properties"), "properties")) do
    schema.properties[#schema.properties + 1] = {
      name = entry.key,
      required = required_set[entry.key] == true,
      schema = build_schema(document, entry.value, depth + 1),
      pos = entry.key_pos,
    }
  end

  schema.pattern_properties = {}
  for _, entry in ipairs(map_entries(tree.get(node, "patternProperties"), "patternProperties")) do
    schema.pattern_properties[#schema.pattern_properties + 1] = {
      pattern = entry.key,
      schema = build_schema(document, entry.value, depth + 1),
      pos = entry.key_pos,
    }
  end

  local additional = field(node, "additionalProperties")
  if additional then
    if additional.kind == "scalar" and additional.scalar_type == "bool" then
      schema.additional = additional.value
    else
      schema.additional = build_schema(document, additional, depth + 1)
    end
  end
end

---@param document oas_glance.Document
---@param schema table
---@param node oas_glance.Node
---@param depth integer
local function read_nested_keywords(document, schema, node, depth)
  local items = tree.get(node, "items")
  if items then
    schema.items = build_schema(document, items, depth + 1)
  end
  schema.prefix_items = build_schema_list(document, seq_items(tree.get(node, "prefixItems"), "prefixItems"), depth + 1)

  local not_node = tree.get(node, "not")
  if not_node then
    schema.not_schema = build_schema(document, not_node, depth + 1)
  end

  schema.compositions = {}
  schema.extra = {}
  for _, entry in ipairs(tree.entries(node)) do
    if entry.key == "allOf" or entry.key == "oneOf" or entry.key == "anyOf" then
      schema.compositions[#schema.compositions + 1] = {
        kind = entry.key,
        members = build_schema_list(document, seq_items(entry.value, entry.key), depth + 1),
      }
    elseif not SCHEMA_KEYWORDS[entry.key] and not (entry.key == "nullable" and document.version == "3.0") then
      schema.extra[#schema.extra + 1] = { key = entry.key, node = entry.value, text = tree.source(entry.value) }
    end
  end

  local discriminator = field(node, "discriminator")
  if discriminator and discriminator.kind == "map" then
    local mapping = {}
    for _, entry in ipairs(map_entries(tree.get(discriminator, "mapping"), "mapping")) do
      mapping[#mapping + 1] = { value = entry.key, target = text_of(entry.value) }
    end
    schema.discriminator = { property = text_field(discriminator, "propertyName"), mapping = mapping }
  end
end

---@param document oas_glance.Document
---@param schema table
---@param node oas_glance.Node
local function read_scalar_keywords(document, schema, node)
  schema.title = text_field(node, "title")
  schema.description = text_field(node, "description")
  schema.format = text_field(node, "format")
  schema.deprecated = bool_field(node, "deprecated")
  schema.read_only = bool_field(node, "readOnly")
  schema.write_only = bool_field(node, "writeOnly")
  schema.unique = bool_field(node, "uniqueItems")
  schema.pattern = text_field(node, "pattern")
  schema.multiple_of = number_raw(node, "multipleOf")
  schema.length = read_range(node, "minLength", "maxLength")
  schema.item_count = read_range(node, "minItems", "maxItems")
  schema.min = read_bound(node, "minimum", "exclusiveMinimum", greater)
  schema.max = read_bound(node, "maximum", "exclusiveMaximum", less)

  schema.types = read_types(node)
  if document.version == "3.0" and bool_field(node, "nullable") and not vim.tbl_contains(schema.types, "null") then
    schema.types[#schema.types + 1] = "null"
  end

  schema.enum = read_literals(field(node, "enum"))
  local const = tree.get(node, "const")
  schema.const = const and literal(const)
  local default = tree.get(node, "default")
  schema.default = default and literal(default)

  schema.examples = read_literals(field(node, "examples"))
  local example = tree.get(node, "example")
  if example then
    schema.examples[#schema.examples + 1] = literal(example)
  end
end

--- Builds one Schema per source node, and loads nothing. Refs stay closed.
---@param document oas_glance.Document
---@param node oas_glance.Node
---@param depth integer
---@return table
function build_schema(document, node, depth)
  local target = tree.resolve(node)
  if not target then
    return { pos = node.pos, problem = true }
  end
  local known = document._schemas[target]
  if known then
    return known
  end
  if depth > document._workspace.max_depth then
    return { pos = target.pos, too_deep = true }
  end

  local schema = { pos = target.pos, problem = tree.node_has_error(target) }
  document._schemas[target] = schema

  if target.kind == "scalar" and target.scalar_type == "bool" then
    schema.boolean = target.value
    return schema
  end
  if target.kind ~= "map" then
    add_diagnostic(target, "warn", "structure", "schema is not a mapping or a boolean")
    schema.problem = true
    return schema
  end

  local ref_node = tree.get(target, "$ref")
  if ref_node then
    schema.ref = make_ref(ref_node)
    if #tree.entries(target) > 1 and document.version == "3.0" then
      add_ref_siblings(document, ref_node)
      return schema
    end
  end

  read_scalar_keywords(document, schema, target)
  read_object_keywords(document, schema, target, depth)
  read_nested_keywords(document, schema, target, depth)
  return schema
end

---@param value string
---@return string?
local function version_of(value)
  return value:match("^(3%.[01])$") or value:match("^(3%.[01])%.")
end

--- Reads the version keys. A non-scalar value counts as no such key, and `openapi` decides over `swagger`.
---@param doc oas_glance.Doc
---@return { kind: "ok"|"swagger"|"unsupported"|"not_openapi", version: string?, raw_version: string? }
function M.classify(doc)
  local root = resolved(doc.root)
  if not root or root.kind ~= "map" then
    return { kind = "not_openapi" }
  end

  local openapi = text_field(root, "openapi")
  if openapi then
    local version = version_of(openapi)
    if version then
      return { kind = "ok", version = version, raw_version = openapi }
    end
    return { kind = "unsupported", version = openapi }
  end

  local swagger = text_field(root, "swagger")
  if swagger == "2.0" then
    return { kind = "swagger", version = swagger }
  end
  if swagger then
    return { kind = "unsupported", version = swagger }
  end
  return { kind = "not_openapi" }
end

---@param node oas_glance.Node?
---@param what string
---@return string[]
local function text_list_of(node, what)
  local list = {}
  for _, item in ipairs(seq_items(node, what)) do
    list[#list + 1] = text_of(item)
  end
  return list
end

---@param node oas_glance.Node
---@param key string
---@return string[]
local function text_list(node, key)
  return text_list_of(tree.get(node, key), key)
end

---@param path string
---@param item oas_glance.Node
---@return table[]
local function read_operation_refs(path, item)
  local operations = {}
  for _, entry in ipairs(tree.entries(item)) do
    if METHODS[entry.key] then
      local operation = tree.resolve(entry.value)
      if operation and operation.kind == "map" then
        operations[#operations + 1] = {
          method = entry.key,
          path = path,
          summary = text_field(operation, "summary") or text_field(item, "summary"),
          tags = text_list(operation, "tags"),
          deprecated = bool_field(operation, "deprecated") == true,
          problem = tree.node_has_error(operation),
          pos = entry.key_pos,
          node = operation,
          path_item = item,
        }
      else
        add_diagnostic(
          entry.value,
          "warn",
          "structure",
          "operation " .. entry.key .. " is not a mapping",
          entry.key_pos
        )
      end
    end
  end
  return operations
end

--- Rows for one `paths` or `webhooks` entry. A path item's `$ref` loads here, because the list needs its methods.
---@param document oas_glance.Document
---@param entry oas_glance.Entry
---@param section "paths"|"webhooks" Set on each row, so a row has a key that survives a reload.
---@return table[]
local function read_path_item(document, entry, section)
  local item, broken = deref(document, entry.value)
  if broken then
    return {
      {
        path = entry.key,
        section = section,
        tags = {},
        problem = true,
        pos = broken.pos,
        broken = { target = broken.target, reason = broken.reason },
      },
    }
  end
  if not item or item.kind ~= "map" then
    add_diagnostic(entry.value, "warn", "structure", "path item " .. entry.key .. " is not a mapping", entry.key_pos)
    return {}
  end
  local operations = read_operation_refs(entry.key, item)
  for _, operation in ipairs(operations) do
    operation.section = section
  end
  return operations
end

--- Top-level tags first, then first seen, then untagged. An operation appears under each of its tags.
---@param document oas_glance.Document
---@param operations table[]
---@return table[]
local function build_groups(document, operations)
  local by_tag = {}
  local order = {}
  local function group_for(tag, description)
    if not by_tag[tag] then
      by_tag[tag] = { tag = tag, description = description, operations = {} }
      order[#order + 1] = by_tag[tag]
    end
    return by_tag[tag]
  end

  for _, tag in ipairs(document.tags) do
    group_for(tag.name, tag.description)
  end

  local untagged = {}
  for _, operation in ipairs(operations) do
    if #operation.tags == 0 then
      untagged[#untagged + 1] = operation
    end
    for _, tag in ipairs(operation.tags) do
      table.insert(group_for(tag).operations, operation)
    end
  end
  if #untagged > 0 then
    table.insert(order, { tag = UNTAGGED, operations = untagged })
  end

  return vim.tbl_filter(function(group)
    return #group.operations > 0
  end, order)
end

---@param node oas_glance.Node
---@return table[]
local function read_servers(node)
  local servers = {}
  for _, item in ipairs(seq_items(tree.get(node, "servers"), "servers")) do
    local server = tree.resolve(item)
    if server and server.kind == "map" then
      local variables, defaults = {}, {}
      for _, entry in ipairs(map_entries(tree.get(server, "variables"), "variables")) do
        local variable = tree.resolve(entry.value)
        local default = variable and variable.kind == "map" and text_field(variable, "default") or nil
        variables[#variables + 1] = { name = entry.key, default = default }
        defaults[entry.key] = default
      end
      servers[#servers + 1] = {
        url = text_field(server, "url"),
        description = text_field(server, "description"),
        variables = variables,
        variable_defaults = defaults,
      }
    else
      add_diagnostic(item, "warn", "structure", "a server is not a mapping")
    end
  end
  return servers
end

---@param root oas_glance.Node
---@return table
local function read_info(root)
  local info = field(root, "info")
  if not info then
    return {}
  end
  if info.kind ~= "map" then
    add_diagnostic(info, "warn", "structure", "info is not a mapping")
    return {}
  end
  return {
    title = text_field(info, "title"),
    version = text_field(info, "version"),
    summary = text_field(info, "summary"),
    description = text_field(info, "description"),
    pos = info.pos,
  }
end

---@param root oas_glance.Node
---@return table[]
local function read_tags(root)
  local tags = {}
  for _, item in ipairs(seq_items(tree.get(root, "tags"), "tags")) do
    local tag = tree.resolve(item)
    local name = tag and text_field(tag, "name")
    if tag and name then
      tags[#tags + 1] = { name = name, description = text_field(tag, "description") }
    else
      add_diagnostic(item, "warn", "structure", "a tag has no name")
    end
  end
  return tags
end

---@param root oas_glance.Node
---@return table[]
local function read_schema_refs(root)
  local components = field(root, "components")
  local schemas = {}
  if not components then
    return schemas
  end
  for _, entry in ipairs(map_entries(tree.get(components, "schemas"), "components/schemas")) do
    local target = tree.resolve(entry.value)
    schemas[#schemas + 1] = {
      name = entry.key,
      key = tree.doc_of(root).identity .. "#/components/schemas/" .. entry.key:gsub("~", "~0"):gsub("/", "~1"),
      pos = entry.key_pos,
      node = entry.value,
      problem = target == nil or tree.node_has_error(target),
    }
  end
  return schemas
end

--- Builds the thin Document for the list. Only path-item refs load files here.
---@param workspace oas_glance.Workspace
---@param doc oas_glance.Doc
---@return oas_glance.Document?
---@return { kind: string, version: string?, raw_version: string? } classification
function M.load(workspace, doc)
  local classification = M.classify(doc)
  if classification.kind ~= "ok" then
    return nil, classification
  end

  local root = resolved(doc.root) --[[@as oas_glance.Node]]
  local document = {
    version = classification.version,
    raw_version = classification.raw_version,
    diagnostics = doc.diagnostics,
    _workspace = workspace,
    _doc = doc,
    _root = root,
    _schemas = {},
    _operations = {},
    _broken_seen = {},
    _siblings_seen = {},
    _other_docs = {},
    _security_schemes = {},
  }
  document.info = read_info(root)
  document.servers = read_servers(root)
  document.tags = read_tags(root)

  local operations = {}
  local paths = tree.get(root, "paths")
  if paths then
    for _, entry in ipairs(map_entries(paths, "paths")) do
      vim.list_extend(operations, read_path_item(document, entry, "paths"))
    end
  elseif document.version == "3.0" then
    add_diagnostic(root, "warn", "structure", "the document has no paths")
  end
  document.groups = build_groups(document, operations)

  document.webhooks = {}
  if document.version == "3.1" then
    for _, entry in ipairs(map_entries(tree.get(root, "webhooks"), "webhooks")) do
      vim.list_extend(document.webhooks, read_path_item(document, entry, "webhooks"))
    end
  end

  document.schemas = read_schema_refs(root)
  return document, classification
end

--- Every diagnostic so far, from the document and from each file it has loaded.
---@param document oas_glance.Document
---@return oas_glance.Diagnostic[]
function M.diagnostics(document)
  local all = vim.list_slice(document.diagnostics)
  for _, doc in ipairs(document._other_docs) do
    vim.list_extend(all, doc.diagnostics)
  end
  return all
end

--- The memoised Schema of a listed schema. A listed `$ref` builds as one closed ref.
---@param document oas_glance.Document
---@param schema_ref { node: oas_glance.Node }
---@return table
function M.schema(document, schema_ref)
  return build_schema(document, schema_ref.node, 0)
end

--- Adds a ref that is broken from its text, once it is rendered. Its source position counts once.
---@param document oas_glance.Document
---@param ref table
function M.report_broken(document, ref)
  if ref.status == "broken" and ref.reason then
    add_broken(document, ref.pos, ref.target, ref.reason)
  end
end

--- Opens a closed ref. On failure the ref becomes broken and joins the diagnostics.
---@param document oas_glance.Document
---@param ref table
---@return table? schema
---@return string? reason
function M.open_ref(document, ref)
  if ref.status == "broken" then
    return nil, ref.reason
  end
  if ref.status == "open" then
    return ref._schema
  end

  local result = refs.follow(document._workspace, ref._doc, ref._parsed, { version = document.version })
  note_doc(document, result.doc)
  add_ignored_hops(document, result.ignored)
  if result.reason then
    ref.status = "broken"
    ref.reason = result.reason
    add_broken(document, ref.pos, ref.target, result.reason)
    return nil, result.reason
  end

  ref.status = "open"
  ref.key = result.key
  ref.keys = result.keys
  ref._schema = build_schema(document, result.node, 0)
  return ref._schema
end

---@param document oas_glance.Document
---@param node oas_glance.Node?
---@return table[]
local function read_examples(document, node)
  local examples = {}
  local example = node and tree.get(node, "example")
  if example then
    examples[1] = { value = literal(example), pos = example.pos }
  end
  for _, entry in ipairs(map_entries(node and tree.get(node, "examples"), "examples")) do
    local target, broken = deref(document, entry.value)
    if broken then
      examples[#examples + 1] = { name = entry.key, broken = broken, pos = entry.key_pos }
    elseif target and target.kind == "map" then
      local value = tree.get(target, "value")
      examples[#examples + 1] = {
        name = entry.key,
        summary = text_field(target, "summary"),
        value = value and literal(value),
        pos = entry.key_pos,
      }
    end
  end
  return examples
end

---@param document oas_glance.Document
---@param node oas_glance.Node?
---@return table[]
local function read_content(document, node)
  local content = {}
  for _, entry in ipairs(map_entries(node, "content")) do
    local media = tree.resolve(entry.value)
    if media and media.kind == "map" then
      local schema = tree.get(media, "schema")
      content[#content + 1] = {
        name = entry.key,
        schema = schema and build_schema(document, schema, 0),
        examples = read_examples(document, media),
        pos = entry.key_pos,
      }
    else
      add_diagnostic(entry.value, "warn", "structure", "media type " .. entry.key .. " is not a mapping", entry.key_pos)
    end
  end
  return content
end

--- Fields shared by a parameter and a header.
---@param document oas_glance.Document
---@param target oas_glance.Node
---@param overrides table?
---@return table
local function read_parameter_like(document, target, overrides)
  local schema = tree.get(target, "schema")
  return {
    required = bool_field(target, "required") == true,
    deprecated = bool_field(target, "deprecated") == true,
    description = overrides and overrides.description or text_field(target, "description"),
    schema = schema and build_schema(document, schema, 0),
    content = read_content(document, tree.get(target, "content")),
    pos = target.pos,
  }
end

---@param document oas_glance.Document
---@param node oas_glance.Node
---@return table?
local function read_parameter(document, node)
  local target, broken, overrides = deref(document, node)
  if broken then
    return { name = broken.name, broken = broken, pos = broken.pos }
  end
  if not target or target.kind ~= "map" then
    add_diagnostic(node, "warn", "structure", "a parameter is not a mapping")
    return nil
  end
  local parameter = read_parameter_like(document, target, overrides)
  parameter.name = text_field(target, "name")
  parameter["in"] = text_field(target, "in")
  parameter.style = text_field(target, "style")
  parameter.explode = bool_field(target, "explode")
  parameter.allow_reserved = bool_field(target, "allowReserved")
  local example = tree.get(target, "example")
  parameter.example = example and literal(example)
  parameter.examples = {}
  for _, entry in ipairs(read_examples(document, target)) do
    if entry.name then
      parameter.examples[#parameter.examples + 1] = entry
    end
  end
  return parameter
end

--- Path-level parameters first, and the operation wins on the same name and location.
---@param document oas_glance.Document
---@param path_item oas_glance.Node
---@param operation oas_glance.Node
---@return table[]
local function read_parameters(document, path_item, operation)
  local parameters = {}
  local positions = {}
  for _, owner in ipairs({ path_item, operation }) do
    for _, item in ipairs(seq_items(tree.get(owner, "parameters"), "parameters")) do
      local parameter = read_parameter(document, item)
      if parameter then
        local key = not parameter.broken and (tostring(parameter.name) .. "\0" .. tostring(parameter["in"]))
        if key and positions[key] then
          parameters[positions[key]] = parameter
        else
          parameters[#parameters + 1] = parameter
          if key then
            positions[key] = #parameters
          end
        end
      end
    end
  end
  return parameters
end

---@param document oas_glance.Document
---@param node oas_glance.Node?
---@return table?
local function read_request_body(document, node)
  if not node then
    return nil
  end
  local target, broken, overrides = deref(document, node)
  if broken then
    return { broken = broken, pos = broken.pos }
  end
  if not target or target.kind ~= "map" then
    add_diagnostic(node, "warn", "structure", "requestBody is not a mapping")
    return nil
  end
  return {
    description = overrides and overrides.description or text_field(target, "description"),
    required = bool_field(target, "required") == true,
    content = read_content(document, tree.get(target, "content")),
    pos = target.pos,
  }
end

---@param document oas_glance.Document
---@param node oas_glance.Node?
---@return table[]
local function read_headers(document, node)
  local headers = {}
  for _, entry in ipairs(map_entries(node, "headers")) do
    local target, broken, overrides = deref(document, entry.value)
    if broken then
      headers[#headers + 1] = { name = entry.key, broken = broken, pos = entry.key_pos }
    elseif target and target.kind == "map" then
      local header = read_parameter_like(document, target, overrides)
      header.name = entry.key
      header.pos = entry.key_pos
      headers[#headers + 1] = header
    else
      add_diagnostic(entry.value, "warn", "structure", "header " .. entry.key .. " is not a mapping", entry.key_pos)
    end
  end
  return headers
end

---@param document oas_glance.Document
---@param node oas_glance.Node?
---@return table[]
local function read_responses(document, node)
  local responses = {}
  for _, entry in ipairs(map_entries(node, "responses")) do
    local target, broken, overrides = deref(document, entry.value)
    if broken then
      responses[#responses + 1] = { status = entry.key, broken = broken, pos = entry.key_pos }
    elseif target and target.kind == "map" then
      responses[#responses + 1] = {
        status = entry.key,
        description = overrides and overrides.description or text_field(target, "description"),
        content = read_content(document, tree.get(target, "content")),
        headers = read_headers(document, tree.get(target, "headers")),
        pos = entry.key_pos,
      }
    else
      add_diagnostic(entry.value, "warn", "structure", "response " .. entry.key .. " is not a mapping", entry.key_pos)
    end
  end
  return responses
end

---@param node oas_glance.Node?
---@return table[]
local function read_security(node)
  local security = {}
  for _, item in ipairs(seq_items(node, "security")) do
    local requirement = {}
    for _, entry in ipairs(map_entries(item, "a security requirement")) do
      requirement[#requirement + 1] = { name = entry.key, scopes = text_list_of(entry.value, "scopes") }
    end
    security[#security + 1] = requirement
  end
  return security
end

--- The memoised Operation of a list row. Non-schema refs load here. Schema refs stay closed.
---@param document oas_glance.Document
---@param operation_ref table
---@return table
function M.operation(document, operation_ref)
  local known = document._operations[operation_ref]
  if known then
    return known
  end

  local operation = {}
  for key, value in pairs(operation_ref) do
    operation[key] = value
  end
  document._operations[operation_ref] = operation
  if operation_ref.broken then
    return operation
  end

  local node, item = operation_ref.node, operation_ref.path_item
  operation.operation_id = text_field(node, "operationId")
  operation.description = text_field(node, "description") or text_field(item, "description")
  operation.parameters = read_parameters(document, item, node)
  operation.request_body = read_request_body(document, tree.get(node, "requestBody"))
  operation.responses = read_responses(document, tree.get(node, "responses"))
  operation.security = read_security(tree.get(node, "security") or tree.get(document._root, "security"))

  local servers_owner = tree.get(node, "servers") and node or item
  operation.servers = read_servers(servers_owner)
  return operation
end

--- The memoised `components.securitySchemes[name]`, or nil when it is missing or broken.
---@param document oas_glance.Document
---@param name string
---@return { type: string?, ["in"]: string?, name: string?, scheme: string? }?
function M.security_scheme(document, name)
  local known = document._security_schemes[name]
  if known ~= nil then
    return known or nil
  end
  ---@type table|false
  local scheme = false
  local components = field(document._root, "components")
  local map = components and components.kind == "map" and field(components, "securitySchemes")
  local entry = map and map.kind == "map" and tree.get(map, name)
  local target = entry and deref(document, entry)
  if target and target.kind == "map" then
    scheme = {
      type = text_field(target, "type"),
      ["in"] = text_field(target, "in"),
      name = text_field(target, "name"),
      scheme = text_field(target, "scheme"),
    }
  end
  document._security_schemes[name] = scheme
  return scheme or nil
end

return M
