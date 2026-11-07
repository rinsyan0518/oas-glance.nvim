local filter = require("oas-glance.internal.filter")
local lines = require("oas-glance.internal.render.lines")

local M = {}

local SEP = "\31"
local METHOD_WIDTH = 7
local OVERLAY_PRIORITY = 210
local MATCH_PRIORITY = 200

local METHOD_GROUPS = {
  get = "OasGlanceMethodGet",
  post = "OasGlanceMethodPost",
  put = "OasGlanceMethodPut",
  patch = "OasGlanceMethodPatch",
  delete = "OasGlanceMethodDelete",
  head = "OasGlanceMethodHead",
  options = "OasGlanceMethodOptions",
  trace = "OasGlanceMethodTrace",
}

---@param path string
---@return table segments
local function path_segments(path)
  local segments = {}
  local index = 1
  while index <= #path do
    local first, last = path:find("{[^}]*}", index)
    if not first then
      segments[#segments + 1] = { path:sub(index), "OasGlancePath" }
      break
    end
    if first > index then
      segments[#segments + 1] = { path:sub(index, first - 1), "OasGlancePath" }
    end
    segments[#segments + 1] = { path:sub(first, last), "OasGlancePathParam" }
    index = last + 1
  end
  return segments
end

---@param b oas_glance.LineBuilder
---@param row integer?
---@param col integer
---@param text string
---@param ranges table[]
---@param field string
---@param tag string?
local function add_matches(b, row, col, text, ranges, field, tag)
  if not row or lines.clean(text) ~= text then
    return
  end
  for _, range in ipairs(ranges) do
    if range.field == field and range.tag == tag then
      b:overlay(row, col + range.col, col + range.end_col, "OasGlanceMatch", MATCH_PRIORITY)
    end
  end
end

---@param b oas_glance.LineBuilder
---@param icons table
---@param operation table
---@param ranges table[]
local function operation_row(b, icons, operation, ranges)
  local marker, marker_group = " ", nil
  if operation.problem then
    marker, marker_group = icons.problem, "OasGlanceProblem"
  elseif operation.deprecated then
    marker, marker_group = icons.deprecated, "OasGlanceDeprecated"
  end

  local head, head_group
  local action = { select = { kind = "operation", operation = operation }, pos = operation.pos }
  if operation.broken then
    head, head_group = icons.broken, "OasGlanceBroken"
    action.broken = { target = operation.broken.target, reason = operation.broken.reason, pos = operation.pos }
  else
    head, head_group = operation.method:upper(), METHOD_GROUPS[operation.method]
  end
  local padding = string.rep(" ", math.max(METHOD_WIDTH - lines.width(head), 0))

  local segments = { { " " }, { marker, marker_group }, { " " } }
  local method_col = 1 + #marker + 1
  segments[#segments + 1] = { head, head_group }
  segments[#segments + 1] = { padding .. " " }
  local path_col = method_col + #head + #padding + 1
  vim.list_extend(segments, path_segments(operation.path))
  if operation.broken then
    segments[#segments + 1] = { "  " }
    segments[#segments + 1] = { operation.broken.reason, "OasGlanceBroken" }
  end

  local row = b:add(segments, action)
  add_matches(b, row, path_col, operation.path, ranges, "path")
  if row and operation.deprecated then
    b:overlay(row, method_col, #b.lines[row + 1], "OasGlanceDeprecated", OVERLAY_PRIORITY)
  end
end

---@param b oas_glance.LineBuilder
---@param icons table
---@param schema_ref table
---@param ranges table[]
local function schema_row(b, icons, schema_ref, ranges)
  local marker, marker_group = " ", nil
  if schema_ref.problem then
    marker, marker_group = icons.problem, "OasGlanceProblem"
  end
  local row = b:add({ { " " }, { marker, marker_group }, { " " }, { schema_ref.name, "OasGlanceSchemaName" } }, {
    select = { kind = "schema", schema = schema_ref },
    pos = schema_ref.pos,
  })
  add_matches(b, row, 1 + #marker + 1, schema_ref.name, ranges, "name")
end

---@param items table[]
---@param terms oas_glance.FilterTerm[]?
---@return { item: table, ranges: table[] }[]
local function visible(items, terms)
  local result = {}
  for _, item in ipairs(items) do
    if terms then
      local matched, ranges = filter.match(terms, item)
      if matched then
        result[#result + 1] = { item = item, ranges = ranges }
      end
    else
      result[#result + 1] = { item = item, ranges = {} }
    end
  end
  return result
end

---@param b oas_glance.LineBuilder
---@param icons table
---@param open table
---@param filtering boolean
---@param section { key: string, title: string, rows: table[], tag: string? }
---@param draw fun(b: oas_glance.LineBuilder, icons: table, item: table, ranges: table[])
local function draw_section(b, icons, open, filtering, section, draw)
  -- Groups open while a filter is active, and their own state returns afterwards.
  local is_open = filtering or open[section.key] ~= false
  local fold = is_open and icons.expanded or icons.collapsed
  local row = b:add({
    { fold, "OasGlanceFold" },
    { " " },
    { section.title, "OasGlanceGroup" },
    { " " },
    { tostring(#section.rows), "OasGlanceMuted" },
  }, { toggle = section.key })

  if section.tag then
    local seen = {}
    for _, entry in ipairs(section.rows) do
      for _, range in ipairs(entry.ranges) do
        local id = string.format("%s:%d", tostring(range.tag), range.col)
        if range.field == "tag" and range.tag == section.tag and not seen[id] then
          seen[id] = true
          add_matches(b, row, #fold + 1, section.title, { range }, "tag", section.tag)
        end
      end
    end
  end

  if is_open then
    for _, entry in ipairs(section.rows) do
      draw(b, icons, entry.item, entry.ranges)
    end
  end
end

---@param b oas_glance.LineBuilder
---@param document table
---@param icons table
---@param problem_count integer
local function header(b, document, icons, problem_count)
  local overview = { select = { kind = "overview" } }
  local info = document.info or {}
  local title = table.concat({ info.title or "(untitled)", info.version }, " ")
  b:add({ { " " }, { title, "OasGlanceTitle" } }, overview)
  b:add({ { " " }, { "OpenAPI " .. (document.raw_version or ""), "OasGlanceMuted" } }, overview)
  if problem_count > 0 then
    local noun = problem_count == 1 and "problem" or "problems"
    local text = string.format("%s %d %s so far", icons.problem, problem_count, noun)
    b:add({ { " " }, { text, "OasGlanceProblem" } }, overview)
  else
    b:add({}, overview)
  end
  b:blank()
end

--- Renders the list pane.
---@param document table
---@param opts? { icons?: table, open?: table<string, boolean>, problem_count?: integer, filter?: string }
---@return oas_glance.RenderResult
function M.render(document, opts)
  opts = opts or {}
  local icons = lines.icons(opts.icons)
  local open = opts.open or {}
  local b = lines.builder({ icons = icons })

  local terms
  local filtering = opts.filter ~= nil and opts.filter ~= ""
  if filtering then
    terms = filter.parse(opts.filter)
    b:add({ { " " }, { "Filter: " .. opts.filter, "OasGlanceFilter" } }, { select = { kind = "overview" } })
    b:blank()
  else
    header(b, document, icons, opts.problem_count or 0)
  end

  local any_row = false
  for _, group in ipairs(document.groups or {}) do
    local rows = visible(group.operations, terms)
    if #rows > 0 then
      any_row = true
      draw_section(b, icons, open, filtering, {
        key = "group" .. SEP .. group.tag,
        title = group.tag,
        rows = rows,
        tag = group.tag,
      }, operation_row)
    end
  end

  local webhooks = visible(document.webhooks or {}, terms)
  if #webhooks > 0 then
    if any_row then
      b:blank()
    end
    any_row = true
    draw_section(b, icons, open, filtering, { key = "webhooks", title = "Webhooks", rows = webhooks }, operation_row)
  end

  local schemas = visible(document.schemas or {}, terms)
  if #schemas > 0 then
    if any_row then
      b:blank()
    end
    any_row = true
    draw_section(b, icons, open, filtering, { key = "schemas", title = "Schemas", rows = schemas }, schema_row)
  end

  if filtering and not any_row then
    b:add({ { " " }, { "No matches", "OasGlanceHint" } })
  end
  return b:result()
end

return M
