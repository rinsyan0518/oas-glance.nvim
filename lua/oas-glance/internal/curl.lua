local lines = require("oas-glance.internal.render.lines")
local model = require("oas-glance.internal.model")
local tree = require("oas-glance.internal.tree")

local M = {}

local DEFAULT_MAX_DEPTH = 64
local DEFAULT_MAX_VALUES = 10000
local DEFAULT_MAX_BYTES = 1024 * 1024
local REPLACEMENT = "\239\191\189"
-- U+0080-U+009F in UTF-8, as `lines.clean` matches it.
local C1_CONTROL = "\194[\128-\159]"

---@class oas_glance.CurlValue
---@field kind "object"|"array"|"string"|"number"|"bool"|"null"
---@field entries { key: string, value: oas_glance.CurlValue }[]?
---@field items oas_glance.CurlValue[]?
---@field value any
---@field text string?

---@class oas_glance.CurlBudget
---@field values integer Values still allowed.
---@field bytes integer Text bytes still allowed: strings, numbers, booleans and keys.
---@field spent boolean True once a value was dropped.

---@class oas_glance.CurlContext
---@field document table
---@field max_depth integer
---@field budget oas_glance.CurlBudget
---@field skip_read_only boolean
---@field path table<any, boolean>
---@field claims { by_source: table<string, string>, taken: table<string, boolean> }

--- An omitted value: a left-out property, an empty array, or `{}` at the top.
local OMIT = {}
---@type oas_glance.CurlValue
local NULL = { kind = "null" }

local STRING_FORMATS = {
  ["date-time"] = "1970-01-01T00:00:00Z",
  date = "1970-01-01",
  time = "00:00:00Z",
  uuid = "00000000-0000-0000-0000-000000000000",
  email = "user@example.com",
  uri = "https://example.com",
}

local JSON_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
}

local UNRESERVED = "[^A-Za-z0-9%-%._~]"
local UNRESERVED_OR_RESERVED = "[^A-Za-z0-9%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=]"

local ALWAYS_SKIPPED_HEADERS = { accept = true, ["content-type"] = true, authorization = true }

local RESERVED_NAMES = {}
for _, name in ipairs({
  "PATH",
  "HOME",
  "USER",
  "LOGNAME",
  "SHELL",
  "PWD",
  "OLDPWD",
  "LANG",
  "LC_ALL",
  "TERM",
  "IFS",
  "PS1",
  "PS2",
  "PS4",
  "TMPDIR",
  "HOSTNAME",
  "EDITOR",
  "DISPLAY",
  "MAIL",
  "UID",
  "EUID",
  "PPID",
  "RANDOM",
  "SECONDS",
  "LINENO",
  "OPTARG",
  "OPTIND",
  "HOST",
  "TZ",
  "COLUMNS",
  "LINES",
  "SHLVL",
  "OSTYPE",
  "HOSTTYPE",
  "CDPATH",
  "ENV",
  "HISTFILE",
  "PROMPT",
  "GROUPS",
  "PIPESTATUS",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "NO_PROXY",
}) do
  RESERVED_NAMES[name] = true
end

---@param char string
---@return string
local function percent(char)
  return string.format("%%%02X", char:byte())
end

--- C0 controls other than a newline, and DEL, become U+FFFD. A pasted control byte can act in a terminal.
---@param text string
---@return string
local function replace_controls(text)
  local replaced = text:gsub("%c", function(char)
    return char == "\n" and char or REPLACEMENT
  end)
  return (replaced:gsub(C1_CONTROL, REPLACEMENT))
end

--- C0, DEL and each byte of a C1 character, percent-encoded for a URL.
---@param text string
---@return string
local function encode_controls(text)
  local encoded = text:gsub("%c", percent):gsub(C1_CONTROL, function(char)
    return (char:gsub(".", percent))
  end)
  return encoded
end

---@param text string
---@return boolean
local function is_json_number(text)
  local rest = text:match("^%-?(.*)$")
  local after = rest:match("^0(.*)$") or rest:match("^[1-9]%d*(.*)$")
  if not after then
    return false
  end
  after = after:gsub("^%.%d+", "", 1)
  after = after:gsub("^[eE][+-]?%d+", "", 1)
  return after == ""
end

---@param target oas_glance.Node
---@return oas_glance.CurlValue
local function number_value(target)
  local value = target.value
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return NULL
  end
  local raw = target.raw
  if is_json_number(raw) then
    return { kind = "number", text = raw }
  end
  if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
    return { kind = "number", text = string.format("%d", value) }
  end
  return { kind = "number", text = string.format("%.17g", value) }
end

---@param max_values integer?
---@param max_bytes integer?
---@return oas_glance.CurlBudget
local function new_budget(max_values, max_bytes)
  return { values = max_values or DEFAULT_MAX_VALUES, bytes = max_bytes or DEFAULT_MAX_BYTES, spent = false }
end

--- Charges `values` values and `bytes` bytes. Once either runs out, every later charge fails too.
---@param budget oas_glance.CurlBudget
---@param values integer
---@param bytes integer
---@return boolean
local function charge(budget, values, bytes)
  if budget.spent or budget.values < values or budget.bytes < bytes then
    budget.spent = true
    return false
  end
  budget.values = budget.values - values
  budget.bytes = budget.bytes - bytes
  return true
end

--- One value whose text is `bytes` long.
---@param budget oas_glance.CurlBudget
---@param bytes integer
---@return boolean
local function take(budget, bytes)
  return charge(budget, 1, bytes)
end

---@param value oas_glance.CurlValue
---@return integer
local function text_length(value)
  if value.kind == "string" then
    return #value.value
  end
  if value.kind == "number" then
    return #value.text
  end
  if value.kind == "bool" then
    return value.value and 4 or 5
  end
  return 0
end

---@param target oas_glance.Node
---@return oas_glance.CurlValue
local function scalar_value(target)
  local scalar_type = target.scalar_type
  if scalar_type == "string" then
    return { kind = "string", value = target.value }
  end
  if scalar_type == "bool" then
    return { kind = "bool", value = target.value }
  end
  if scalar_type == "int" or scalar_type == "float" then
    return number_value(target)
  end
  return NULL
end

--- OMIT once the budget has run out.
---@param node oas_glance.Node?
---@param depth integer
---@param max_depth integer
---@param budget oas_glance.CurlBudget
---@param key_bytes integer? Length of the key the value sits under.
---@return oas_glance.CurlValue|table
local function node_value(node, depth, max_depth, budget, key_bytes)
  if budget.spent then
    return OMIT
  end
  local target = node and tree.resolve(node)
  local value
  if not target or depth > max_depth then
    value = NULL
  elseif target.kind ~= "map" and target.kind ~= "seq" then
    value = scalar_value(target)
  end
  if not take(budget, (key_bytes or 0) + (value and text_length(value) or 0)) then
    return OMIT
  end
  if value then
    return value
  end
  ---@cast target oas_glance.Node
  if target.kind == "map" then
    local entries = {}
    for _, entry in ipairs(tree.entries(target)) do
      local entry_value = node_value(entry.value, depth + 1, max_depth, budget, #entry.key)
      if entry_value ~= OMIT then
        entries[#entries + 1] = { key = entry.key, value = entry_value }
      end
    end
    return { kind = "object", entries = entries }
  end
  local items = {}
  for _, item in ipairs(tree.items(target)) do
    local item_value = node_value(item, depth + 1, max_depth, budget)
    if item_value ~= OMIT then
      items[#items + 1] = item_value
    end
  end
  return { kind = "array", items = items }
end

--- NULL at the top once the budget has run out.
---@param node oas_glance.Node?
---@param depth integer
---@param max_depth integer
---@param budget oas_glance.CurlBudget?
---@return oas_glance.CurlValue
local function from_node(node, depth, max_depth, budget)
  local value = node_value(node, depth, max_depth, budget or new_budget())
  return value == OMIT and NULL or value
end

---@param text string
---@return string
local function json_string(text)
  local escaped = text:gsub('[%c"\\]', function(char)
    local escape = JSON_ESCAPES[char]
    if escape then
      return escape
    end
    if char:byte() < 0x20 then
      return string.format("\\u%04x", char:byte())
    end
    return char
  end)
  return '"' .. escaped .. '"'
end

---@param value oas_glance.CurlValue
---@return string
local function compact(value)
  if value.kind == "object" then
    local parts = {}
    for _, entry in ipairs(value.entries) do
      parts[#parts + 1] = json_string(entry.key) .. ":" .. compact(entry.value)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  if value.kind == "array" then
    local parts = {}
    for _, item in ipairs(value.items) do
      parts[#parts + 1] = compact(item)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  if value.kind == "string" then
    return json_string(value.value)
  end
  if value.kind == "number" then
    return value.text
  end
  if value.kind == "bool" then
    return value.value and "true" or "false"
  end
  return "null"
end

---@param value oas_glance.CurlValue
---@param indent string
---@param out string[]
---@param head string Text before the value on its first line.
---@param tail string Text after the value on its last line.
local function pretty_into(value, indent, out, head, tail)
  local inner = indent .. "  "
  if value.kind == "object" and #value.entries > 0 then
    out[#out + 1] = head .. "{"
    for index, entry in ipairs(value.entries) do
      local comma = index < #value.entries and "," or ""
      pretty_into(entry.value, inner, out, inner .. json_string(entry.key) .. ": ", comma)
    end
    out[#out + 1] = indent .. "}" .. tail
  elseif value.kind == "array" and #value.items > 0 then
    out[#out + 1] = head .. "["
    for index, item in ipairs(value.items) do
      pretty_into(item, inner, out, inner, index < #value.items and "," or "")
    end
    out[#out + 1] = indent .. "]" .. tail
  else
    out[#out + 1] = head .. compact(value) .. tail
  end
end

---@param value oas_glance.CurlValue
---@return string[]
local function pretty(value)
  local out = {}
  pretty_into(value, "", out, "", "")
  return out
end

---@param value oas_glance.CurlValue
---@return string
local function text_of_value(value)
  if value.kind == "string" then
    return value.value
  end
  return compact(value)
end

--- Step 4 of the generator: the first example, default, enum value or const.
---@param ctx oas_glance.CurlContext
---@param schema table
---@return oas_glance.CurlValue|table|nil OMIT once the budget has run out.
local function literal_value(ctx, schema)
  local literal = (schema.examples and schema.examples[1])
    or schema.default
    or (schema.enum and schema.enum[1])
    or schema.const
  return literal and node_value(literal.node, 0, ctx.max_depth, ctx.budget)
end

--- An ordered object whose later values replace earlier ones in place.
---@return { entries: table[], index: table<string, integer> }
local function new_merge()
  return { entries = {}, index = {} }
end

---@param merge { entries: table[], index: table<string, integer> }
---@param key string
---@param value oas_glance.CurlValue
local function merge_set(merge, key, value)
  local at = merge.index[key]
  if at then
    merge.entries[at].value = value
  else
    merge.entries[#merge.entries + 1] = { key = key, value = value }
    merge.index[key] = #merge.entries
  end
end

---@param merge { entries: table[], index: table<string, integer> }
---@param object oas_glance.CurlValue
local function merge_object(merge, object)
  for _, entry in ipairs(object.entries) do
    merge_set(merge, entry.key, entry.value)
  end
end

local generate

---@param ctx oas_glance.CurlContext
---@param schema table
---@param depth integer
---@param merge { entries: table[], index: table<string, integer> }
local function add_properties(ctx, schema, depth, merge)
  for _, property in ipairs(schema.properties or {}) do
    local property_schema = property.schema
    if not (ctx.skip_read_only and property_schema and property_schema.read_only) then
      if not charge(ctx.budget, 0, #property.name) then
        return
      end
      local value = generate(ctx, property_schema, depth + 1)
      if value ~= OMIT then
        merge_set(merge, property.name, value)
      end
    end
  end
end

--- The compositions' value: an object merged after the own properties, or the first non-object.
---@param ctx oas_glance.CurlContext
---@param schema table
---@param depth integer
---@param merge { entries: table[], index: table<string, integer> }
---@return oas_glance.CurlValue?
local function compose(ctx, schema, depth, merge)
  local merged_any, other = false, nil
  for _, composition in ipairs(schema.compositions or {}) do
    local members = composition.members
    if composition.kind ~= "allOf" then
      members = { members[1] }
    end
    for _, member in ipairs(members) do
      local value = generate(ctx, member, depth + 1)
      if value ~= OMIT then
        if value.kind == "object" then
          merge_object(merge, value)
          merged_any = true
        elseif other == nil then
          other = value
        end
      end
    end
  end
  if merged_any or (other == nil and #schema.compositions > 0) then
    return { kind = "object", entries = merge.entries }
  end
  return other
end

---@param ctx oas_glance.CurlContext
---@param schema table
---@param depth integer
---@return oas_glance.CurlValue|table
local function generate_type(ctx, schema, depth)
  local kind
  for _, name in ipairs(schema.types or {}) do
    if name ~= "null" then
      kind = name
      break
    end
  end
  local properties = schema.properties or {}
  local prefix_items = schema.prefix_items or {}
  if not kind and #(schema.types or {}) == 0 then
    if #properties > 0 then
      kind = "object"
    elseif schema.items or #prefix_items > 0 then
      kind = "array"
    end
  end

  local merge = new_merge()
  add_properties(ctx, schema, depth, merge)
  local composed = schema.compositions and #schema.compositions > 0 and compose(ctx, schema, depth, merge) or nil
  if composed and (kind == nil or (kind == "object" and composed.kind == "object")) then
    return composed
  end

  if kind == "object" then
    return { kind = "object", entries = merge.entries }
  end
  if kind == "array" then
    local items = {}
    if #prefix_items > 0 then
      for _, item in ipairs(prefix_items) do
        local value = generate(ctx, item, depth + 1)
        if value ~= OMIT then
          items[#items + 1] = value
        end
      end
    elseif schema.items then
      local value = generate(ctx, schema.items, depth + 1)
      if value ~= OMIT then
        items[1] = value
      end
    end
    return { kind = "array", items = items }
  end
  local placeholder = NULL
  if kind == "string" then
    placeholder = { kind = "string", value = STRING_FORMATS[schema.format] or "string" }
  elseif kind == "integer" or kind == "number" then
    placeholder = { kind = "number", text = "0" }
  elseif kind == "boolean" then
    placeholder = { kind = "bool", value = true }
  end
  return charge(ctx.budget, 0, text_length(placeholder)) and placeholder or OMIT
end

---@param ctx oas_glance.CurlContext
---@param schema table?
---@param depth integer
---@return oas_glance.CurlValue|table
function generate(ctx, schema, depth)
  if ctx.budget.spent then
    return OMIT
  end
  if not schema then
    return NULL
  end
  if schema.boolean == false then
    return OMIT
  end
  if schema.boolean == true then
    return NULL
  end
  if ctx.path[schema] then
    return OMIT
  end

  if schema.ref then
    local target = model.open_ref(ctx.document, schema.ref)
    if not target then
      return NULL
    end
    local key = schema.ref.key
    if (key and ctx.path[key]) or ctx.path[target] then
      return OMIT
    end
    if key then
      ctx.path[key] = true
    end
    ctx.path[schema] = true
    local value = generate(ctx, target, depth + 1)
    ctx.path[schema] = nil
    if key then
      ctx.path[key] = nil
    end
    return value
  end

  if schema.too_deep or depth > ctx.max_depth then
    return OMIT
  end
  local literal = literal_value(ctx, schema)
  if literal then
    return literal
  end
  if not take(ctx.budget, 0) then
    return OMIT
  end

  ctx.path[schema] = true
  local value = generate_type(ctx, schema, depth)
  ctx.path[schema] = nil
  return value
end

--- Upper snake case of a source name.
---@param source string?
---@return string
local function placeholder_name(source)
  local name = (source or ""):gsub("([a-z0-9])([A-Z])", "%1_%2")
  name = name:gsub("[^A-Za-z0-9]+", "_")
  name = name:gsub("^_+", ""):gsub("_+$", "")
  name = name:upper()
  if name == "" then
    return "VALUE"
  end
  if name:match("^%d") then
    return "_" .. name
  end
  return name
end

--- A shell or curl variable that a placeholder must not take. Only a base name is checked, because a
--- suffixed name keeps a reserved prefix and would never be free.
---@param name string
---@return boolean
local function is_reserved(name)
  return RESERVED_NAMES[name] == true
    or name:match("^LC_") ~= nil
    or name:match("^BASH") ~= nil
    or name:match("^ZSH") ~= nil
    or name:match("^CURL") ~= nil
end

---@return { by_source: table<string, string>, taken: table<string, boolean> }
local function new_claims()
  return { by_source = {}, taken = {} }
end

--- The placeholder name for a source. The same source keeps its name.
---@param claims { by_source: table<string, string>, taken: table<string, boolean> }
---@param base string
---@param source_key string
---@param location string? `PATH`, `QUERY`, `HEADER` or `COOKIE`.
---@return string
local function claim(claims, base, source_key, location)
  local known = claims.by_source[source_key]
  if known then
    return known
  end
  local name = base
  if (claims.taken[name] or is_reserved(name)) and location then
    name = base .. "_" .. location
  elseif is_reserved(name) then
    name = base .. "_2"
  end
  local number = 2
  while claims.taken[name] do
    name = base .. "_" .. number
    number = number + 1
  end
  claims.taken[name] = true
  claims.by_source[source_key] = name
  return name
end

---@param name string
---@return { var: string }
local function var(name)
  return { var = name }
end

---@param text string
---@return string
local function sq(text)
  return "'" .. replace_controls(text):gsub("'", "'\\''") .. "'"
end

--- One shell word: each run of literal text single-quoted, and only placeholders in double quotes.
---@param parts (string|{ var: string })[]
---@return string
local function word(parts)
  local out, literal = {}, {}
  local function flush()
    if #literal > 0 then
      out[#out + 1] = sq(table.concat(literal))
      literal = {}
    end
  end
  for _, part in ipairs(parts) do
    if type(part) == "table" then
      flush()
      out[#out + 1] = '"${' .. part.var .. '}"'
    elseif part ~= "" then
      literal[#literal + 1] = part
    end
  end
  flush()
  return #out > 0 and table.concat(out) or "''"
end

--- A token as RFC 7230 defines it, so a header name cannot be read as anything else.
---@param name string
---@return boolean
local function is_token(name)
  return name:match("^[A-Za-z0-9!#$%%&'*+%-.^_`|~]+$") ~= nil
end

---@param text string
---@param allow_reserved boolean?
---@return string
local function encode(text, allow_reserved)
  local encoded = text:gsub(allow_reserved and UNRESERVED_OR_RESERVED or UNRESERVED, percent)
  return encoded
end

---@param ctx oas_glance.CurlContext
---@param parameter table
---@return oas_glance.CurlValue?
local function parameter_value(ctx, parameter)
  if parameter.example then
    return from_node(parameter.example.node, 0, ctx.max_depth, ctx.budget)
  end
  for _, example in ipairs(parameter.examples or {}) do
    if example.value then
      return from_node(example.value.node, 0, ctx.max_depth, ctx.budget)
    end
  end
  if parameter.schema then
    local value = literal_value(ctx, parameter.schema)
    if value then
      return value == OMIT and NULL or value
    end
  end
  local media = parameter.content and parameter.content[1]
  for _, example in ipairs(media and media.examples or {}) do
    if example.value then
      return { kind = "string", value = compact(from_node(example.value.node, 0, ctx.max_depth, ctx.budget)) }
    end
  end
  return nil
end

---@param ctx oas_glance.CurlContext
---@param parameter table
---@param location string
---@return string
local function parameter_placeholder(ctx, parameter, location)
  local source = "param\0" .. location .. "\0" .. tostring(parameter.name)
  return claim(ctx.claims, placeholder_name(parameter.name), source, location)
end

---@alias oas_glance.CurlParts (string|{ var: string })[]

--- The one point that charges command text. `text` is the encoded text as it goes into the word,
--- and is put only when the budget allows. `keep` puts it anyway, for template text that appears
--- once in the document.
---@param ctx oas_glance.CurlContext
---@param parts oas_glance.CurlParts
---@param text string
---@param keep boolean?
---@return boolean
local function put(ctx, parts, text, keep)
  local ok = charge(ctx.budget, 0, #text)
  if ok or keep then
    parts[#parts + 1] = text
  end
  return ok
end

---@param text string
---@return string
local function identity(text)
  return text
end

--- Puts the texts of an array's items, or of an object's keys and values, each after `prefix` and
--- joined by `separator`. With `as_pairs`, an object's entries go as `key=value`. Stops at the
--- first text the budget does not allow.
---@param ctx oas_glance.CurlContext
---@param parts oas_glance.CurlParts
---@param value oas_glance.CurlValue
---@param map fun(text: string): string
---@param separator string
---@param as_pairs boolean?
---@param prefix string?
---@return boolean
local function put_flat(ctx, parts, value, map, separator, as_pairs, prefix)
  local first = true
  local function item(text)
    local lead = first and "" or separator
    first = false
    return put(ctx, parts, lead .. (prefix or "") .. text)
  end
  -- `spent` is checked before each text is built, so nothing is built once the budget has run out.
  if value.kind == "array" then
    for _, entry in ipairs(value.items) do
      if ctx.budget.spent or not item(map(text_of_value(entry))) then
        return false
      end
    end
    return true
  end
  for _, entry in ipairs(value.entries) do
    if ctx.budget.spent then
      return false
    end
    local key, text = map(entry.key), map(text_of_value(entry.value))
    local ok
    if as_pairs then
      ok = item(key .. "=" .. text)
    else
      ok = item(key) and item(text)
    end
    if not ok then
      return false
    end
  end
  return true
end

---@param ctx oas_glance.CurlContext
---@param parts oas_glance.CurlParts
---@param parameter table
---@param value oas_glance.CurlValue
---@return boolean
local function put_path_value(ctx, parts, parameter, value)
  local style, explode = parameter.style or "simple", parameter.explode == true
  local name = encode(parameter.name)
  if value.kind ~= "array" and value.kind ~= "object" then
    local text = encode(text_of_value(value))
    if style == "label" then
      return put(ctx, parts, "." .. text)
    end
    if style == "matrix" then
      return put(ctx, parts, ";" .. name .. "=" .. text)
    end
    return put(ctx, parts, text)
  end
  local as_pairs = explode and value.kind == "object"
  if style == "label" then
    return put(ctx, parts, ".") and put_flat(ctx, parts, value, encode, explode and "." or ",", as_pairs)
  end
  if style == "matrix" then
    if as_pairs then
      return put_flat(ctx, parts, value, encode, "", true, ";")
    end
    if explode then
      return put_flat(ctx, parts, value, encode, "", false, ";" .. name .. "=")
    end
    return put(ctx, parts, ";" .. name .. "=") and put_flat(ctx, parts, value, encode, ",")
  end
  return put_flat(ctx, parts, value, encode, ",", as_pairs)
end

---@param ctx oas_glance.CurlContext
---@param parts oas_glance.CurlParts
---@param parameter table
---@param placeholder string
---@param lead string? The `;name=` of a matrix parameter, encoded once by the caller.
local function put_path_placeholder(ctx, parts, parameter, placeholder, lead)
  local style = parameter.style or "simple"
  if style == "label" then
    put(ctx, parts, ".", true)
  elseif style == "matrix" then
    put(ctx, parts, lead or (";" .. encode(parameter.name) .. "="), true)
  end
  parts[#parts + 1] = var(placeholder)
end

--- Puts the query items of a parameter's value, each through `item`.
---@param ctx oas_glance.CurlContext
---@param url oas_glance.CurlParts
---@param item fun(text: string): boolean Puts one item after its `?` or `&`.
---@param parameter table
---@param value oas_glance.CurlValue
---@return boolean
local function put_query_value(ctx, url, item, parameter, value)
  if ctx.budget.spent then
    return false
  end
  local style = parameter.style or "form"
  local explode = parameter.explode
  if explode == nil then
    explode = style == "form"
  end
  local name = encode(parameter.name)
  local function encode_value(text)
    return encode(text, parameter.allow_reserved)
  end
  if value.kind ~= "array" and value.kind ~= "object" then
    return item(name .. "=" .. encode_value(text_of_value(value)))
  end

  -- `spent` is checked before each item's text is built.
  if value.kind == "object" and style == "deepObject" then
    for _, entry in ipairs(value.entries) do
      if
        ctx.budget.spent
        or not item(name .. "[" .. encode(entry.key) .. "]=" .. encode_value(text_of_value(entry.value)))
      then
        return false
      end
    end
    return true
  end
  if style == "form" and explode then
    if value.kind == "object" then
      for _, entry in ipairs(value.entries) do
        if ctx.budget.spent or not item(encode(entry.key) .. "=" .. encode_value(text_of_value(entry.value))) then
          return false
        end
      end
    else
      for _, entry in ipairs(value.items) do
        if ctx.budget.spent or not item(name .. "=" .. encode_value(text_of_value(entry))) then
          return false
        end
      end
    end
    return true
  end
  local separator = style == "spaceDelimited" and "%20" or style == "pipeDelimited" and "|" or ","
  return item(name .. "=") and put_flat(ctx, url, value, encode_value, separator)
end

---@param parts (string|{ var: string })[]
---@param more (string|{ var: string })[]
local function append(parts, more)
  for _, part in ipairs(more) do
    parts[#parts + 1] = part
  end
end

---@param parts (string|{ var: string })[]
local function trim_trailing_slashes(parts)
  while #parts > 0 and type(parts[#parts]) == "string" do
    local trimmed = (parts[#parts] --[[@as string]]):gsub("/+$", "")
    if trimmed ~= "" then
      parts[#parts] = trimmed
      return
    end
    parts[#parts] = nil
  end
end

---@param ctx oas_glance.CurlContext
---@param operation table
---@return (string|{ var: string })[]
local function server_parts(ctx, operation)
  local server = (operation.servers or {})[1] or ctx.document.servers[1]
  local url = server and server.url or "/"
  local defaults = server and server.variable_defaults or {}

  local probe = url:gsub("{([^{}]*)}", function(name)
    return defaults[name] or "x"
  end)
  local parts = {}
  if probe:match("^//") then
    put(ctx, parts, "https:", true)
  elseif not probe:match("^%a[%w+.-]*://") then
    parts[1] = var(claim(ctx.claims, "BASE_URL", "base_url"))
  end

  local encoded_defaults = {}
  local position = 1
  for start, name, after in url:gmatch("(){([^{}]*)}()") do
    put(ctx, parts, encode_controls(url:sub(position, start - 1)), true)
    local default = defaults[name]
    if default then
      encoded_defaults[name] = encoded_defaults[name] or encode_controls(default)
      default = encoded_defaults[name]
    end
    if not (default and put(ctx, parts, default)) then
      parts[#parts + 1] = var(claim(ctx.claims, placeholder_name(name), "server\0" .. name))
    end
    position = after
  end
  put(ctx, parts, encode_controls(url:sub(position)), true)
  trim_trailing_slashes(parts)
  return parts
end

---@param ctx oas_glance.CurlContext
---@param operation table
---@return { flags: string[][], header_names: table<string, boolean>, query: { text: string, var: string }[], cookies: oas_glance.CurlParts[], query_names: table<string, boolean>, cookie_names: table<string, boolean> }
local function auth(ctx, operation)
  local result = { flags = {}, header_names = {}, query = {}, cookies = {}, query_names = {}, cookie_names = {} }
  local requirement = (operation.security or {})[1] or {}
  local function header(flag, text, name)
    local parts = {}
    if put(ctx, parts, text) then
      parts[#parts + 1] = var(name)
      result.flags[#result.flags + 1] = { flag .. word(parts) }
    end
  end
  for _, item in ipairs(requirement) do
    local scheme = model.security_scheme(ctx.document, item.name) or {}
    local source = "auth\0" .. item.name
    local kind, key_name = scheme.type, scheme.name
    local http = (scheme.scheme or ""):lower()
    if kind == "apiKey" and key_name then
      local location = scheme["in"]
      if location == "header" then
        if is_token(key_name) then
          header("-H ", key_name .. ": ", claim(ctx.claims, "API_KEY", source))
          result.header_names[key_name:lower()] = true
        end
      elseif location == "query" then
        local name = claim(ctx.claims, "API_KEY", source)
        result.query[#result.query + 1] = { text = encode(key_name) .. "=", var = name }
        result.query_names[key_name] = true
      elseif location == "cookie" then
        local name = claim(ctx.claims, "API_KEY", source)
        local parts = {}
        if put(ctx, parts, key_name .. "=") then
          parts[#parts + 1] = var(name)
          result.cookies[#result.cookies + 1] = parts
        end
        result.cookie_names[key_name] = true
      end
    elseif kind == "oauth2" or kind == "openIdConnect" or (kind == "http" and http == "bearer") then
      header("-H ", "Authorization: Bearer ", claim(ctx.claims, "TOKEN", source))
    elseif kind == "http" and http == "basic" then
      local user = claim(ctx.claims, "USERNAME", source .. "\0user")
      local password = claim(ctx.claims, "PASSWORD", source .. "\0password")
      result.flags[#result.flags + 1] = { "-u " .. word({ var(user), ":", var(password) }) }
    elseif kind == "http" then
      header("-H ", "Authorization: " .. (scheme.scheme or "") .. " ", claim(ctx.claims, "TOKEN", source))
    end
  end
  return result
end

---@param operation table
---@param location string
---@return table[]
local function parameters_in(operation, location)
  local found = {}
  for _, parameter in ipairs(operation.parameters or {}) do
    if not parameter.broken and parameter["in"] == location and parameter.name then
      found[#found + 1] = parameter
    end
  end
  return found
end

---@param ctx oas_glance.CurlContext
---@param operation table
---@return (string|{ var: string })[]
local function path_parts(ctx, operation)
  ---@type table<string, { value: oas_glance.CurlValue?, parameter: table?, placeholder: string?, pieces: string[]?, cut: boolean?, lead: string? }>
  local by_name = {}
  for _, parameter in ipairs(parameters_in(operation, "path")) do
    local value = parameter_value(ctx, parameter)
    local entry = { parameter = parameter, value = value }
    if not value then
      entry.placeholder = parameter_placeholder(ctx, parameter, "PATH")
    end
    by_name[parameter.name] = entry
  end

  -- A control character cannot appear in a URL, and a newline would split the line.
  local path = encode_controls(operation.path or "")
  local parts = {}
  local position = 1
  for start, name, after in path:gmatch("(){([^{}]*)}()") do
    put(ctx, parts, path:sub(position, start - 1), true)
    local entry = by_name[name] or {}
    by_name[name] = entry
    -- Each occurrence is charged. The items that fit stay, and a value with none becomes the placeholder.
    local occurrence = {}
    if entry.value and not ctx.budget.spent then
      if not entry.pieces then
        -- Built once, and never longer than the bytes left, so a repeated `{name}` reuses it.
        entry.pieces = {}
        local recorder = vim.tbl_extend("force", ctx, { budget = new_budget(math.huge, ctx.budget.bytes) })
        put_path_value(recorder, entry.pieces, entry.parameter, entry.value)
        entry.cut = recorder.budget.spent
      end
      for _, piece in ipairs(entry.pieces) do
        if not put(ctx, occurrence, piece) then
          break
        end
      end
      -- The rest of the value did not fit in the bytes that were left.
      if entry.cut then
        ctx.budget.spent = true
      end
    end
    if #occurrence > 0 then
      append(parts, occurrence)
    elseif entry.parameter then
      entry.placeholder = entry.placeholder or parameter_placeholder(ctx, entry.parameter, "PATH")
      if (entry.parameter.style or "simple") == "matrix" then
        entry.lead = entry.lead or (";" .. encode(entry.parameter.name) .. "=")
      end
      put_path_placeholder(ctx, parts, entry.parameter, entry.placeholder, entry.lead)
    else
      entry.placeholder = entry.placeholder
        or claim(ctx.claims, placeholder_name(name), "param\0PATH\0" .. name, "PATH")
      parts[#parts + 1] = var(entry.placeholder)
    end
    position = after
  end
  put(ctx, parts, path:sub(position), true)
  return parts
end

---@param ctx oas_glance.CurlContext
---@param operation table
---@param skip table<string, boolean>
---@param url oas_glance.CurlParts
---@param auth_query { text: string, var: string }[]
local function put_query(ctx, operation, skip, url, auth_query)
  local count = 0
  local function item(text)
    count = count + 1
    return put(ctx, url, (count == 1 and "?" or "&") .. text)
  end
  for _, parameter in ipairs(parameters_in(operation, "query")) do
    if parameter.required and not skip[parameter.name] then
      local value = parameter_value(ctx, parameter)
      if value then
        put_query_value(ctx, url, item, parameter, value)
      else
        local name = parameter_placeholder(ctx, parameter, "QUERY")
        if item(encode(parameter.name) .. "=") then
          url[#url + 1] = var(name)
        end
      end
    end
  end
  for _, key in ipairs(auth_query) do
    if item(key.text) then
      url[#url + 1] = var(key.var)
    end
  end
end

--- Puts a header or cookie value in `simple` style, not encoded, or its placeholder.
---@param ctx oas_glance.CurlContext
---@param parts oas_glance.CurlParts
---@param parameter table
---@param location string
---@return boolean
local function put_simple(ctx, parts, parameter, location)
  local value = parameter_value(ctx, parameter)
  if not value then
    parts[#parts + 1] = var(parameter_placeholder(ctx, parameter, location))
    return true
  end
  if value.kind ~= "array" and value.kind ~= "object" then
    return put(ctx, parts, text_of_value(value))
  end
  return put_flat(ctx, parts, value, identity, ",")
end

---@param name string
---@return "json"|"form"|"multipart"|"text"|"other"
local function media_kind(name)
  local base = vim.trim((name:lower():match("^[^;]*")))
  if base:match("^[^/]+/json$") or base:match("^[^/]+/[^/]*%+json$") then
    return "json"
  end
  if base == "application/x-www-form-urlencoded" then
    return "form"
  end
  if base == "multipart/form-data" then
    return "multipart"
  end
  if base:match("^text/") or base == "application/xml" or base:match("^[^/]+/[^/]*%+xml$") then
    return "text"
  end
  return "other"
end

---@param content table[]
---@return table?
local function choose_media(content)
  for _, media in ipairs(content) do
    if vim.trim((media.name:lower():match("^[^;]*"))) == "application/json" then
      return media
    end
  end
  for _, media in ipairs(content) do
    if media_kind(media.name) == "json" then
      return media
    end
  end
  return content[1]
end

---@param ctx oas_glance.CurlContext
---@param schema table?
---@param name string
---@param depth integer
---@return table?
local function property_schema(ctx, schema, name, depth)
  if not schema or depth > ctx.max_depth or not take(ctx.budget, 0) then
    return nil
  end
  if schema.ref then
    return property_schema(ctx, model.open_ref(ctx.document, schema.ref), name, depth + 1)
  end
  for _, property in ipairs(schema.properties or {}) do
    if property.name == name then
      return property.schema
    end
  end
  for _, composition in ipairs(schema.compositions or {}) do
    for _, member in ipairs(composition.members) do
      local found = property_schema(ctx, member, name, depth + 1)
      if found then
        return found
      end
    end
  end
  return nil
end

---@param ctx oas_glance.CurlContext
---@param schema table?
---@return boolean
local function is_file(ctx, schema)
  if schema and schema.ref then
    schema = model.open_ref(ctx.document, schema.ref)
  end
  if not schema then
    return false
  end
  if schema.format == "binary" then
    return true
  end
  for _, entry in ipairs(schema.extra or {}) do
    if entry.key == "contentMediaType" then
      return true
    end
  end
  return false
end

---@param ctx oas_glance.CurlContext
---@return string[]
local function body_file_flag(ctx)
  return { "--data-binary " .. word({ "@", var(claim(ctx.claims, "BODY_FILE", "body_file")) }) }
end

---@param ctx oas_glance.CurlContext
---@param media table
---@return oas_glance.CurlValue?
local function body_value(ctx, media)
  for _, example in ipairs(media.examples or {}) do
    if example.value then
      return from_node(example.value.node, 0, ctx.max_depth, ctx.budget)
    end
  end
  if media.schema then
    ctx.skip_read_only = true
    local value = generate(ctx, media.schema, 0)
    ctx.skip_read_only = false
    if value == OMIT then
      return { kind = "object", entries = {} }
    end
    return value
  end
  return nil
end

--- The Content-Type flag, if any, and the body flags.
---@param ctx oas_glance.CurlContext
---@param media table
---@return string[]? content_type
---@return string[][] flags
local function body_flags(ctx, media)
  local kind = media_kind(media.name)
  local content_type
  local type_parts = {}
  if not (media.name:find("*", 1, true) or kind == "form") and put(ctx, type_parts, "Content-Type: " .. media.name) then
    content_type = { "-H " .. word(type_parts) }
  end
  -- The value is charged as it is built. Its JSON or text form is not charged again.
  local value = body_value(ctx, media)

  if not value then
    return content_type, { body_file_flag(ctx) }
  end
  if kind == "json" then
    local quoted = vim.split(sq(table.concat(pretty(value), "\n")), "\n", { plain = true })
    local flag = { "--data-raw " .. quoted[1] }
    for index = 2, #quoted do
      flag[#flag + 1] = "  " .. quoted[index]
    end
    return content_type, { flag }
  end
  if kind == "form" or kind == "multipart" then
    if value.kind ~= "object" then
      return content_type, { body_file_flag(ctx) }
    end
    local files = {}
    if kind == "multipart" then
      for _, entry in ipairs(value.entries) do
        files[entry.key] = is_file(ctx, property_schema(ctx, media.schema, entry.key, 0))
        -- curl would read these in a file field's name, as in `a=@.env;filename`.
        if files[entry.key] and (entry.key:find('[=;@<,"%c]') or entry.key:find(C1_CONTROL)) then
          return content_type, { body_file_flag(ctx) }
        end
      end
    end
    local flags = {}
    for _, entry in ipairs(value.entries) do
      if ctx.budget.spent then
        break
      end
      local parts = {}
      local flag
      if kind == "form" then
        flag = "--data-urlencode "
        put(ctx, parts, entry.key .. "=" .. text_of_value(entry.value))
      elseif files[entry.key] then
        flag = "-F "
        local name = claim(ctx.claims, placeholder_name(entry.key) .. "_FILE", "file\0" .. entry.key)
        if put(ctx, parts, entry.key .. "=@") then
          parts[#parts + 1] = var(name)
        end
      else
        -- `-F` would read a leading `@` or `<`, or `;type=`, in the value as instructions.
        flag = "--form-string "
        put(ctx, parts, entry.key .. "=" .. text_of_value(entry.value))
      end
      if #parts == 0 then
        break
      end
      flags[#flags + 1] = { flag .. word(parts) }
    end
    return nil, flags
  end
  if kind == "text" and value.kind == "string" then
    return content_type, { vim.split("--data-raw " .. sq(value.value), "\n", { plain = true }) }
  end
  return content_type, { body_file_flag(ctx) }
end

---@param parts (string|{ var: string })[]
---@return boolean
local function needs_globoff(parts)
  for _, part in ipairs(parts) do
    if type(part) == "string" and part:find("[%[%]{}]") then
      return true
    end
  end
  return false
end

---@param operation table
---@return string
local function comment_line(operation)
  local text = (operation.method or ""):upper() .. " " .. (operation.path or "")
  if operation.operation_id then
    text = operation.operation_id .. ": " .. text
  end
  return ": " .. sq((lines.clean(text):gsub("\n", REPLACEMENT)))
end

--- The cURL command for an Operation, one string per line.
---@param document table
---@param operation table An Operation from `model.operation`.
---@param opts? { max_depth?: integer, max_values?: integer, max_bytes?: integer }
---@return string[]
function M.build(document, operation, opts)
  opts = opts or {}
  ---@type oas_glance.CurlContext
  local ctx = {
    document = document,
    max_depth = opts.max_depth or DEFAULT_MAX_DEPTH,
    budget = new_budget(opts.max_values, opts.max_bytes),
    skip_read_only = false,
    path = {},
    claims = new_claims(),
  }

  local url = server_parts(ctx, operation)
  local auth_result = auth(ctx, operation)
  append(url, path_parts(ctx, operation))

  put_query(ctx, operation, auth_result.query_names, url, auth_result.query)

  -- A header or cookie the budget cuts short is left out whole.
  local skipped_headers = vim.tbl_extend("force", {}, ALWAYS_SKIPPED_HEADERS, auth_result.header_names)
  local header_flags = {}
  for _, parameter in ipairs(parameters_in(operation, "header")) do
    if parameter.required and is_token(parameter.name) and not skipped_headers[parameter.name:lower()] then
      local parts = {}
      if put(ctx, parts, parameter.name .. ": ") and put_simple(ctx, parts, parameter, "HEADER") then
        header_flags[#header_flags + 1] = { "-H " .. word(parts) }
      end
    end
  end

  local cookies = {}
  for _, parameter in ipairs(parameters_in(operation, "cookie")) do
    if parameter.required and not auth_result.cookie_names[parameter.name] then
      local parts = {}
      if put(ctx, parts, parameter.name .. "=") and put_simple(ctx, parts, parameter, "COOKIE") then
        cookies[#cookies + 1] = parts
      end
    end
  end
  vim.list_extend(cookies, auth_result.cookies)

  local content_type, data_flags
  local body = operation.request_body
  local media = body and not body.broken and choose_media(body.content or {})
  if media then
    content_type, data_flags = body_flags(ctx, media)
  end

  local method = (operation.method or "get"):lower()
  local method_flag = ""
  if method == "head" then
    method_flag = " -I"
  elseif method ~= "get" or data_flags then
    method_flag = " -X " .. method:upper()
  end

  local flags = { { "curl" .. (needs_globoff(url) and " -g" or "") .. method_flag .. " --url " .. word(url) } }
  vim.list_extend(flags, auth_result.flags)
  vim.list_extend(flags, header_flags)
  if #cookies > 0 then
    local parts = {}
    for index, cookie in ipairs(cookies) do
      if index > 1 then
        put(ctx, parts, "; ", true)
      end
      append(parts, cookie)
    end
    flags[#flags + 1] = { "-b " .. word(parts) }
  end
  if content_type then
    flags[#flags + 1] = content_type
  end
  vim.list_extend(flags, data_flags or {})

  local out = { comment_line(operation) }
  if ctx.budget.spent then
    out[2] = ": " .. sq("oas-glance: example cut at size budget")
  end
  for index, flag in ipairs(flags) do
    -- A newline from an example continues the quoted word on the next line.
    flag = vim.split(table.concat(flag, "\n"), "\n", { plain = true })
    for line_index, line in ipairs(flag) do
      local text = (index > 1 and line_index == 1) and "  " .. line or line
      if line_index == #flag and index < #flags then
        text = text .. " \\"
      end
      out[#out + 1] = text
    end
  end
  return out
end

M._json = { from_node = from_node, compact = compact, pretty = pretty }
M._generate = function(document, schema, opts)
  opts = opts or {}
  ---@type oas_glance.CurlContext
  local ctx = {
    document = document,
    max_depth = opts.max_depth or DEFAULT_MAX_DEPTH,
    budget = new_budget(opts.max_values, opts.max_bytes),
    skip_read_only = opts.skip_read_only == true,
    path = {},
    claims = new_claims(),
  }
  return generate(ctx, schema, 0)
end
M._OMIT = OMIT
M._names = { placeholder_name = placeholder_name, new_claims = new_claims, claim = claim }
M._quote = { word = word, sq = sq }

return M
