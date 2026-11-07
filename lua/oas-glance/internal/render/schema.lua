local lines = require("oas-glance.internal.render.lines")

local M = {}

local SEP = "\31"
local NAME_CAP = 24
local MAX_ENUM = 5
local DEFAULT_MAX_DEPTH = 64
local INLINE_TARGET = "inline schema"

M.INCOMPLETE = "may be incomplete"

---@class oas_glance.RenderContext
---@field resolve fun(ref: table): table?, string?
---@field report fun(ref: table) Called for a drawn ref that is broken from its text.
---@field open table<string, boolean|string> An opened ref holds its raw `$ref` text.
---@field icons table
---@field max_depth integer
---@field ancestors table<string, integer>

--- A row to draw. `path` is its key in the view's `open` state, and `width` the name column.
---@class oas_glance.SchemaRow
---@field schema table?
---@field path string
---@field indent integer
---@field nesting integer
---@field label string?
---@field label_group string?
---@field required boolean?
---@field width integer?
---@field tight boolean? One space after the label and no padding, as for a composition member.
---@field columns { text: string, group: string, width: integer }[]?
---@field pos oas_glance.Pos?

---@param value table?
---@return table
local function list(value)
  return value or {}
end

---@param ctx oas_glance.RenderContext
---@param path string
---@param default boolean
---@return boolean
local function is_open(ctx, path, default)
  local state = ctx.open[path]
  -- A string is an opened ref's text, which says nothing about a row that is no longer a ref.
  if type(state) ~= "boolean" then
    return default
  end
  return state
end

---@param opts table
---@return oas_glance.RenderContext
function M.context(opts)
  return {
    resolve = opts.resolve or function()
      return nil, "not found"
    end,
    report = opts.report or function() end,
    open = opts.open or {},
    icons = lines.icons(opts.icons),
    max_depth = opts.max_depth or DEFAULT_MAX_DEPTH,
    ancestors = {},
  }
end

---@param schema table
---@return boolean
local function is_array(schema)
  return schema.items ~= nil or vim.tbl_contains(list(schema.types), "array")
end

---@param schema table
---@return boolean
local function is_map(schema)
  if #list(schema.properties) > 0 or (schema.additional ~= true and type(schema.additional) ~= "table") then
    return false
  end
  local types = list(schema.types)
  return #types == 0 or vim.tbl_contains(types, "object")
end

--- The schema an array or a map holds.
---@param schema table
---@return table?
local function element_of(schema)
  if type(schema.items) == "table" then
    return schema.items
  end
  if is_map(schema) and type(schema.additional) == "table" then
    return schema.additional
  end
  return nil
end

--- The schema at the bottom of nested arrays and maps. A `$ref` there makes the row a ref row.
---@param schema table
---@return table
local function innermost(schema)
  local current = schema
  for _ = 1, DEFAULT_MAX_DEPTH do
    local element = element_of(current)
    if not element then
      break
    end
    current = element
  end
  return current
end

---@param ref table
---@return string
local function ref_name(ref)
  local name = ref.name or ref.target
  return ref.file and string.format("%s (%s)", name, ref.file) or name
end

---@param value { type: string, text: string }
---@return string
local function literal_text(value)
  return value.type == "string" and string.format('"%s"', value.text) or value.text
end

local add_type

---@param schema table?
---@param ctx oas_glance.RenderContext
---@param out table
local function add_element(schema, ctx, out)
  if schema then
    add_type(schema, ctx, out)
  else
    out[#out + 1] = { "any", "OasGlanceType" }
  end
end

---@param schema table
---@return string[]
local function effective_types(schema)
  local types = list(schema.types)
  if #types > 0 then
    return types
  end
  if is_array(schema) then
    return { "array" }
  end
  if is_map(schema) or #list(schema.properties) > 0 then
    return { "object" }
  end
  return { "any" }
end

---@param schema table
---@param ctx oas_glance.RenderContext
---@param out table
function add_type(schema, ctx, out)
  if schema.ref then
    out[#out + 1] = { ctx.icons.ref .. " " .. ref_name(schema.ref), "OasGlanceRef" }
    return
  end
  if schema.boolean ~= nil then
    out[#out + 1] = { schema.boolean and "any" or "never", "OasGlanceType" }
    return
  end
  if schema.const then
    out[#out + 1] = { "const " .. literal_text(schema.const), "OasGlanceEnum" }
    return
  end
  local enum = list(schema.enum)
  if #enum > 0 then
    local shown = {}
    for index = 1, math.min(#enum, MAX_ENUM) do
      shown[index] = literal_text(enum[index])
    end
    local text = table.concat(shown, " | ")
    if #enum > MAX_ENUM then
      text = string.format("%s … +%d", text, #enum - MAX_ENUM)
    end
    out[#out + 1] = { text, "OasGlanceEnum" }
    return
  end

  local format_shown = false
  for index, name in ipairs(effective_types(schema)) do
    if name == "null" then
      out[#out + 1] = { index > 1 and " " or nil }
      out[#out + 1] = { index > 1 and "| null" or "null", "OasGlanceNull" }
    else
      if index > 1 then
        out[#out + 1] = { " | ", "OasGlanceType" }
      end
      if name == "array" and is_array(schema) then
        add_element(type(schema.items) == "table" and schema.items or nil, ctx, out)
        out[#out + 1] = { "[]", "OasGlanceType" }
      elseif name == "object" and is_map(schema) then
        out[#out + 1] = { "map<string, ", "OasGlanceType" }
        add_element(type(schema.additional) == "table" and schema.additional or nil, ctx, out)
        out[#out + 1] = { ">", "OasGlanceType" }
      else
        out[#out + 1] = { name, "OasGlanceType" }
        if schema.format and not format_shown then
          format_shown = true
          out[#out + 1] = { "<" .. schema.format .. ">", "OasGlanceFormat" }
        end
      end
    end
  end
end

---@param range { min: string?, max: string? }
---@return string
local function range_text(range)
  return (range.min or "") .. ".." .. (range.max or "")
end

---@param schema table
---@param out table
local function add_constraints(schema, out)
  if schema.default then
    out[#out + 1] = { " " }
    out[#out + 1] = { "= " .. literal_text(schema.default), "OasGlanceDefault" }
  end

  local parts = {}
  local bounds = {}
  if schema.min then
    bounds[#bounds + 1] = (schema.min.exclusive and "> " or ">= ") .. schema.min.value
  end
  if schema.max then
    bounds[#bounds + 1] = (schema.max.exclusive and "< " or "<= ") .. schema.max.value
  end
  if #bounds > 0 then
    parts[#parts + 1] = table.concat(bounds, ", ")
  end
  if schema.length then
    parts[#parts + 1] = "len " .. range_text(schema.length)
  end
  if schema.item_count then
    parts[#parts + 1] = "items " .. range_text(schema.item_count)
  end
  if schema.unique then
    parts[#parts + 1] = "unique"
  end
  if schema.pattern then
    parts[#parts + 1] = "/" .. schema.pattern .. "/"
  end
  if schema.multiple_of then
    parts[#parts + 1] = "multiple of " .. schema.multiple_of
  end
  if schema.additional == false then
    parts[#parts + 1] = "closed"
  end
  if schema.read_only then
    parts[#parts + 1] = "ro"
  end
  if schema.write_only then
    parts[#parts + 1] = "wo"
  end
  for _, part in ipairs(parts) do
    out[#out + 1] = { "  " }
    out[#out + 1] = { part, "OasGlanceConstraint" }
  end

  if schema.deprecated then
    out[#out + 1] = { "  " }
    out[#out + 1] = { "deprecated", "OasGlanceDeprecated" }
  end
end

---@param schema table
---@return boolean
local function is_empty_problem(schema)
  return schema.problem == true and schema.types == nil and schema.boolean == nil
end

--- The problem note for a schema overlapping an error or left empty by one.
---@param schema table
---@param ctx oas_glance.RenderContext
---@param out table
local function add_problem(schema, ctx, out)
  if schema.problem then
    if #out > 0 then
      out[#out + 1] = { "  " }
    end
    out[#out + 1] = { ctx.icons.problem .. " " .. M.INCOMPLETE, "OasGlanceProblem" }
  end
end

--- The type, its constraints and any problem note, as segments.
---@param schema table
---@param ctx oas_glance.RenderContext
---@return table
function M.summary(schema, ctx)
  local out = {}
  if not is_empty_problem(schema) then
    add_type(schema, ctx, out)
    add_constraints(schema, out)
  end
  add_problem(schema, ctx, out)
  return out
end

---@param schema table
---@param path string
---@param as_target boolean?
---@return table[]
local function collect(schema, path, as_target)
  local entries = {}
  local element = element_of(schema)
  if element then
    if not innermost(element).ref then
      entries = collect(element, path .. SEP .. "i")
    elseif as_target then
      entries[1] = { schema = element, path = path .. SEP .. "i" }
    end
  elseif as_target and schema.ref then
    entries[1] = { schema = { ref = schema.ref, pos = schema.pos }, path = path .. SEP .. "r" }
  end

  for _, property in ipairs(list(schema.properties)) do
    entries[#entries + 1] = {
      label = property.name,
      required = property.required,
      schema = property.schema,
      path = path .. SEP .. "p" .. SEP .. property.name,
      pos = property.pos,
    }
  end
  for _, property in ipairs(list(schema.pattern_properties)) do
    entries[#entries + 1] = {
      label = property.pattern,
      schema = property.schema,
      path = path .. SEP .. "x" .. SEP .. property.pattern,
      pos = property.pos,
    }
  end
  if type(schema.additional) == "table" and not is_map(schema) then
    entries[#entries + 1] = { label = "additional", schema = schema.additional, path = path .. SEP .. "a" }
  end
  for index, item in ipairs(list(schema.prefix_items)) do
    entries[#entries + 1] = {
      label = string.format("[%d]", index - 1),
      schema = item,
      path = path .. SEP .. "t" .. SEP .. index,
    }
  end
  for index, composition in ipairs(list(schema.compositions)) do
    entries[#entries + 1] = {
      label = composition.kind,
      composition = composition,
      discriminator = schema.discriminator,
      path = path .. SEP .. "c" .. SEP .. index,
      pos = schema.pos,
    }
  end
  if schema.not_schema then
    entries[#entries + 1] = {
      label = "not",
      label_group = "OasGlanceComposition",
      schema = schema.not_schema,
      path = path .. SEP .. "n",
    }
  end
  for _, extra in ipairs(list(schema.extra)) do
    entries[#entries + 1] = { label = extra.key, extra = extra, pos = extra.node and extra.node.pos }
  end
  return entries
end

--- Children of a schema, for a caller that lays them out.
---@param schema table
---@param path string
---@param as_target boolean? Also gives a row for the schema's own `$ref`.
---@return table[]
function M.entries(schema, path, as_target)
  return collect(schema, path, as_target)
end

---@param ctx oas_glance.RenderContext
---@param row oas_glance.SchemaRow
---@param marker string?
---@param body table
---@return table segments
---@return string continuation
local function row_segments(ctx, row, marker, body)
  local prefix = string.rep(" ", row.indent)
  local segments = { { prefix } }
  if marker then
    segments[#segments + 1] = { marker, "OasGlanceFold" }
    segments[#segments + 1] = { " " }
  else
    segments[#segments + 1] = { "  " }
  end

  local has_label = row.label ~= nil
  if has_label then
    segments[#segments + 1] = { row.label, row.label_group or "OasGlanceProperty" }
    local used = lines.width(row.label)
    if row.required then
      segments[#segments + 1] = { ctx.icons.required, "OasGlanceRequired" }
      used = used + lines.width(ctx.icons.required)
    end
    if not row.tight then
      segments[#segments + 1] = { string.rep(" ", math.max((row.width or 0) - used, 0)) }
    end
  end
  for _, column in ipairs(row.columns or {}) do
    segments[#segments + 1] = { "  " }
    segments[#segments + 1] = { column.text, column.group }
    segments[#segments + 1] = { string.rep(" ", math.max(column.width - lines.width(column.text), 0)) }
  end
  if #body > 0 and (has_label or row.columns) then
    segments[#segments + 1] = { row.tight and " " or "  " }
  end
  vim.list_extend(segments, body)
  return segments, prefix .. "  "
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param row oas_glance.SchemaRow
---@param marker string?
---@param body table
---@param action oas_glance.RowAction
local function emit(b, ctx, row, marker, body, action)
  local segments, continuation = row_segments(ctx, row, marker, body)
  return b:add(segments, action, continuation)
end

--- A broken row, shared with the operation view.
---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param row oas_glance.SchemaRow
---@param target string
---@param reason string
---@param pos oas_glance.Pos?
---@param ref table?
---@return integer? row Nil when the row limit stopped it.
function M.broken_row(b, ctx, row, target, reason, pos, ref)
  local body = { { string.format("%s %s  %s", ctx.icons.broken, target, reason), "OasGlanceBroken" } }
  return emit(
    b,
    ctx,
    row,
    nil,
    body,
    { broken = { target = target, reason = reason, pos = pos }, pos = pos, ref = ref }
  )
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param row oas_glance.SchemaRow
---@param ref table
local function cycle_row(b, ctx, row, ref)
  local body = { { string.format("%s %s  cycle", ctx.icons.cycle, ref_name(ref)), "OasGlanceCycle" } }
  emit(b, ctx, row, nil, body, { ref = ref, cycle = true, pos = ref.pos })
end

---@param ctx oas_glance.RenderContext
---@param keys string[]
---@return boolean
local function any_above(ctx, keys)
  for _, key in ipairs(keys) do
    if ctx.ancestors[key] then
      return true
    end
  end
  return false
end

--- Marks keys as above the rows that `render` draws.
---@param ctx oas_glance.RenderContext
---@param keys string[]
---@param render fun()
function M.with_ancestors(ctx, keys, render)
  for _, key in ipairs(keys) do
    ctx.ancestors[key] = (ctx.ancestors[key] or 0) + 1
  end
  render()
  for _, key in ipairs(keys) do
    local count = ctx.ancestors[key] - 1
    ctx.ancestors[key] = count > 0 and count or nil
  end
end

local render_entries

--- The type of an opened ref's target. A plain object shows only through its rows, as in spec 6.
---@param target table
---@param ctx oas_glance.RenderContext
---@return table
local function opened_summary(target, ctx)
  local types = list(target.types)
  local plain_object = #list(target.properties) > 0 and (#types == 0 or (#types == 1 and types[1] == "object"))
  if plain_object or target.ref then
    return {}
  end
  return M.summary(target, ctx)
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param row oas_glance.SchemaRow
---@param holder table The schema holding the `$ref`.
local function ref_row(b, ctx, row, holder)
  local ref = holder.ref
  if ref.status == "broken" then
    -- A ref broken from its text joins Problems when drawn, and not when the limit or a closed row hides it.
    if M.broken_row(b, ctx, row, ref.target, ref.reason, ref.pos, ref) then
      ctx.report(ref)
    end
    return
  end
  -- An external ref has no key while closed, even when an earlier opening has filled it in.
  if not ref.file and ref.key and ctx.ancestors[ref.key] then
    cycle_row(b, ctx, row, ref)
    return
  end

  local summary = M.summary(row.schema, ctx)
  -- An opened ref stores its raw text, so a ref whose text changed on reload starts closed.
  if ctx.open[row.path] ~= ref.target then
    emit(b, ctx, row, ctx.icons.collapsed, summary, { toggle = row.path, expanded = false, ref = ref, pos = ref.pos })
    return
  end

  local target, reason = ctx.resolve(ref)
  if not target then
    M.broken_row(b, ctx, row, ref.target, reason or ref.reason or "not found", ref.pos, ref)
    return
  end
  local keys = ref.keys or { ref.key }
  if any_above(ctx, keys) then
    cycle_row(b, ctx, row, ref)
    return
  end

  local target_summary = opened_summary(target, ctx)
  if #target_summary > 0 then
    summary[#summary + 1] = { "  " }
    vim.list_extend(summary, target_summary)
  end
  emit(b, ctx, row, ctx.icons.expanded, summary, { toggle = row.path, expanded = true, ref = ref, pos = ref.pos })
  local entries = collect(target, row.path .. SEP .. "o", true)
  vim.list_extend(entries, collect(row.schema, row.path .. SEP .. "s"))
  M.with_ancestors(ctx, keys, function()
    render_entries(b, ctx, entries, row.indent + 2, 1)
  end)
end

--- Draws one schema row, and its children when open.
---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param row oas_glance.SchemaRow
function M.row(b, ctx, row)
  local schema = row.schema
  if not schema then
    emit(b, ctx, row, nil, {}, { pos = row.pos })
    return
  end
  local inner = innermost(schema)
  if inner.ref then
    ref_row(b, ctx, row, inner)
    return
  end
  if schema.too_deep or inner.too_deep or row.nesting >= ctx.max_depth then
    M.broken_row(b, ctx, row, INLINE_TARGET, "too deep", row.pos or schema.pos)
    return
  end

  local entries = collect(schema, row.path)
  local openable = #entries > 0
  local open = openable and is_open(ctx, row.path, true)
  local marker = openable and (open and ctx.icons.expanded or ctx.icons.collapsed) or nil
  local action = { pos = row.pos or schema.pos, toggle = openable and row.path or nil, expanded = openable and open }
  emit(b, ctx, row, marker, M.summary(schema, ctx), action)
  if open then
    render_entries(b, ctx, entries, row.indent + 2, row.nesting + 1)
  end
end

---@param composition table
---@param discriminator table?
---@return table[]
local function member_entries(composition, discriminator, path)
  local labels = {}
  for _, mapping in ipairs(discriminator and list(discriminator.mapping) or {}) do
    if mapping.target then
      labels[mapping.target] = mapping.value
    end
  end
  local entries = {}
  for index, member in ipairs(list(composition.members)) do
    entries[index] = {
      label = member.ref and labels[member.ref.target] or nil,
      tight = true,
      schema = member,
      path = path .. SEP .. index,
    }
  end
  return entries
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param entry table
---@param width integer
---@param indent integer
---@param nesting integer
local function composition_row(b, ctx, entry, width, indent, nesting)
  local row = {
    label = entry.label,
    label_group = "OasGlanceComposition",
    width = width,
    path = entry.path,
    indent = indent,
    nesting = nesting,
  }
  if nesting >= ctx.max_depth then
    M.broken_row(b, ctx, row, INLINE_TARGET, "too deep", entry.pos)
    return
  end

  local members = member_entries(entry.composition, entry.discriminator, entry.path)
  local openable = #members > 0
  local open = openable and is_open(ctx, entry.path, true)
  local body = {}
  local discriminator = entry.discriminator
  if discriminator and discriminator.property and entry.label ~= "allOf" then
    body[1] = { "by " .. discriminator.property, "OasGlanceMuted" }
  end
  local marker = openable and (open and ctx.icons.expanded or ctx.icons.collapsed) or nil
  emit(
    b,
    ctx,
    row,
    marker,
    body,
    { pos = entry.pos, toggle = openable and entry.path or nil, expanded = openable and open }
  )
  if open then
    render_entries(b, ctx, members, indent + 2, nesting + 1)
  end
end

---@param ctx oas_glance.RenderContext
---@param entries table[]
---@return integer
function M.label_width(ctx, entries)
  local width = 0
  for _, entry in ipairs(entries) do
    if entry.label then
      local used = lines.width(entry.label)
      if entry.required then
        used = used + lines.width(ctx.icons.required)
      end
      width = math.max(width, used)
    end
  end
  return math.min(width, NAME_CAP)
end

--- Draws sibling rows with their names aligned. Stops as soon as the row limit is reached.
---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param entries table[]
---@param indent integer
---@param nesting integer
function render_entries(b, ctx, entries, indent, nesting)
  local width = M.label_width(ctx, entries)
  for _, entry in ipairs(entries) do
    if b.stopped then
      return
    end
    if entry.composition then
      composition_row(b, ctx, entry, width, indent, nesting)
    elseif entry.extra then
      local row = { label = entry.label, label_group = "OasGlanceMuted", width = width, indent = indent, path = "" }
      emit(b, ctx, row, nil, { { entry.extra.text or "", "OasGlanceMuted" } }, { pos = entry.pos })
    else
      M.row(b, ctx, {
        schema = entry.schema,
        path = entry.path,
        indent = indent,
        nesting = nesting,
        label = entry.label,
        label_group = entry.label_group,
        required = entry.required,
        width = width,
        tight = entry.tight,
        pos = entry.pos,
      })
    end
  end
end

M.render_entries = function(b, ctx, entries, indent, nesting)
  render_entries(b, ctx, entries, indent, nesting)
end

return M
