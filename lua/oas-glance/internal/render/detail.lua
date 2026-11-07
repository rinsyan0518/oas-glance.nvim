local lines = require("oas-glance.internal.render.lines")
local schema_render = require("oas-glance.internal.render.schema")

local M = {}

local SEP = "\31"
local DEFAULT_MAX_ROWS = 10000
local HINT = "References are checked when opened."

local KEY_HELP = {
  {
    pane = "list",
    title = "List pane",
    keys = {
      { "select", "<CR>", "Toggle a group, or focus the detail pane" },
      { "toggle", "za", "Toggle the group" },
      { "filter", "f", "Filter" },
      { "clear_filter", "F", "Clear the filter" },
      { "source", "gs", "Jump to source" },
      { "curl", "gc", "Open a cURL command for the operation" },
      { "reload", "R", "Reload" },
      { "help", "?", "Show this help" },
      { "close", "q", "Close the tabpage" },
    },
  },
  {
    pane = "detail",
    title = "Detail pane",
    keys = {
      { "toggle", { "<CR>", "za" }, "Expand or collapse the row" },
      { "definition", "gd", "Jump to the definition" },
      { "back", "<BS>", "Back to the previous view" },
      { "source", "gs", "Jump to source" },
      { "curl", "gc", "Open a cURL command for the operation" },
      { "reload", "R", "Reload" },
      { "help", "?", "Show this help" },
      { "close", "q", "Close the tabpage" },
    },
  },
}

---@param opts table?
---@return oas_glance.LineBuilder b
---@return oas_glance.RenderContext ctx
local function start(opts)
  opts = opts or {}
  local ctx = schema_render.context(opts)
  return lines.builder({ limit = opts.max_detail_rows or DEFAULT_MAX_ROWS, icons = ctx.icons }), ctx
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param element table
local function incomplete_note(b, ctx, element)
  if element.problem then
    local text = string.format("%s This element %s.", ctx.icons.problem, schema_render.INCOMPLETE)
    b:add({ { text, "OasGlanceProblem" } }, { pos = element.pos })
  end
end

---@param status string
---@return string
local function status_group(status)
  local first = status:sub(1, 1)
  if first == "2" then
    return "OasGlanceStatus2xx"
  end
  if first == "4" then
    return "OasGlanceStatus4xx"
  end
  if first == "5" then
    return "OasGlanceStatus5xx"
  end
  return "OasGlanceStatusOther"
end

---@param b oas_glance.LineBuilder
---@param media table
---@param indent integer
local function example_rows(b, media, indent)
  local prefix = string.rep(" ", indent + 2)
  for _, example in ipairs(media.examples or {}) do
    local name = example.name and ("example " .. example.name) or "example"
    if example.broken then
      local text = string.format("%s  %s", example.broken.target, example.broken.reason)
      b:add({ { prefix }, { name .. "  ", "OasGlanceMuted" }, { text, "OasGlanceBroken" } }, {
        broken = { target = example.broken.target, reason = example.broken.reason, pos = example.broken.pos },
        pos = example.broken.pos,
      })
    else
      local value = example.value and example.value.text or example.summary or ""
      b:add({ { prefix }, { name .. "  " .. value, "OasGlanceMuted" } }, { pos = example.pos }, prefix)
    end
  end
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param content table[]?
---@param path string
---@param indent integer
local function content_rows(b, ctx, content, path, indent)
  for _, media in ipairs(content or {}) do
    if b.stopped then
      return
    end
    b:add({ { string.rep(" ", indent + 2) }, { media.name, "OasGlanceMuted" } }, { pos = media.pos })
    if media.schema then
      schema_render.row(b, ctx, {
        schema = media.schema,
        path = path .. SEP .. "m" .. SEP .. media.name,
        indent = indent + 2,
        nesting = 1,
      })
    end
    example_rows(b, media, indent + 2)
  end
end

---@param items table[]
---@param key string
---@return integer
local function column_width(items, key)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, lines.width(item[key] or ""))
  end
  return width
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param parameters table[]
local function parameter_rows(b, ctx, parameters)
  if #parameters == 0 then
    return
  end
  b:blank()
  b:add({ { "Parameters", "OasGlanceSection" } })

  local labelled = {}
  for index, parameter in ipairs(parameters) do
    labelled[index] = { label = parameter.name or "", required = parameter.required }
  end
  local width = schema_render.label_width(ctx, labelled)
  local location_width = column_width(parameters, "in")

  for _, parameter in ipairs(parameters) do
    if b.stopped then
      return
    end
    local path = table.concat({ "param", parameter.name or "", parameter["in"] or "" }, SEP)
    local row = {
      schema = parameter.schema,
      path = path,
      indent = 0,
      nesting = 1,
      label = parameter.name or "",
      required = parameter.required,
      width = width,
      pos = parameter.pos,
    }
    if parameter.broken then
      schema_render.broken_row(b, ctx, row, parameter.broken.target, parameter.broken.reason, parameter.broken.pos)
    else
      row.columns = { { text = parameter["in"] or "", group = "OasGlanceLocation", width = location_width } }
      schema_render.row(b, ctx, row)
      if parameter.description then
        b:add({ { "    " }, { parameter.description, "OasGlanceDescription" } }, { pos = parameter.pos }, "    ")
      end
      content_rows(b, ctx, parameter.content, path, 2)
    end
  end
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param body table?
local function request_body_rows(b, ctx, body)
  if not body then
    return
  end
  b:blank()
  local heading = { { "Request body", "OasGlanceSection" } }
  if body.required then
    heading[2] = { "  required", "OasGlanceMuted" }
  end
  b:add(heading, { pos = body.pos })
  if body.broken then
    local row = { indent = 0, nesting = 1, path = "" }
    schema_render.broken_row(b, ctx, row, body.broken.target, body.broken.reason, body.broken.pos)
    return
  end
  if body.description then
    b:add({ { "  " }, { body.description, "OasGlanceDescription" } }, { pos = body.pos }, "  ")
  end
  content_rows(b, ctx, body.content, "body", 0)
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param response table
---@param path string
local function header_rows(b, ctx, response, path)
  local headers = response.headers or {}
  local width = column_width(headers, "name")
  for _, header in ipairs(headers) do
    if b.stopped then
      return
    end
    local row = {
      schema = header.schema,
      path = path .. SEP .. "h" .. SEP .. header.name,
      indent = 0,
      nesting = 1,
      label = header.name,
      width = width,
      pos = header.pos,
    }
    if header.broken then
      schema_render.broken_row(b, ctx, row, header.broken.target, header.broken.reason, header.broken.pos)
    else
      schema_render.row(b, ctx, row)
    end
  end
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param responses table[]
local function response_rows(b, ctx, responses)
  if #responses == 0 then
    return
  end
  b:blank()
  b:add({ { "Responses", "OasGlanceSection" } })

  for index, response in ipairs(responses) do
    if b.stopped then
      return
    end
    local status = { response.status, status_group(response.status) }
    if response.broken then
      local broken = response.broken
      local text = string.format("%s %s  %s", ctx.icons.broken, broken.target, broken.reason)
      b:add({ { "  " }, status, { "  " }, { text, "OasGlanceBroken" } }, {
        broken = { target = broken.target, reason = broken.reason, pos = broken.pos },
        pos = broken.pos,
      })
    else
      local path = "response" .. SEP .. response.status
      local openable = #(response.content or {}) + #(response.headers or {}) > 0
      local state = ctx.open[path]
      local open = openable and (state == nil and index == 1 or state == true)
      local segments = {}
      if openable then
        segments[1] = { open and ctx.icons.expanded or ctx.icons.collapsed, "OasGlanceFold" }
        segments[2] = { " " }
      else
        segments[1] = { "  " }
      end
      segments[#segments + 1] = status
      if response.description then
        segments[#segments + 1] = { " " }
        segments[#segments + 1] = { response.description, "OasGlanceDescription" }
      end
      b:add(segments, { toggle = openable and path or nil, expanded = openable and open, pos = response.pos }, "  ")
      if open then
        content_rows(b, ctx, response.content, path, 0)
        header_rows(b, ctx, response, path)
      end
    end
  end
end

---@param b oas_glance.LineBuilder
---@param security table[]
local function security_rows(b, security)
  if #security == 0 then
    return
  end
  b:blank()
  b:add({ { "Security", "OasGlanceSection" } })
  for _, requirement in ipairs(security) do
    for _, scheme in ipairs(requirement) do
      local scopes = table.concat(scheme.scopes or {}, ", ")
      b:add({ { "  " }, { scheme.name, "OasGlanceProperty" }, { "  " .. scopes, "OasGlanceMuted" } })
    end
  end
end

---@param b oas_glance.LineBuilder
---@param servers table[]
local function server_rows(b, servers)
  if #servers == 0 then
    return
  end
  b:blank()
  b:add({ { "Servers", "OasGlanceSection" } })
  for _, server in ipairs(servers) do
    b:add({ { "  " }, { server.url or "", "OasGlanceMuted" } })
  end
end

--- Renders an operation, or the broken row of a path item that did not load.
---@param operation table
---@param opts table?
---@return oas_glance.RenderResult
function M.operation(operation, opts)
  local b, ctx = start(opts)
  if operation.broken then
    local broken = operation.broken
    b:add({ { operation.path, "OasGlanceTitle" } }, { pos = operation.pos })
    local text = string.format("%s %s  %s", ctx.icons.broken, broken.target, broken.reason)
    b:add({ { text, "OasGlanceBroken" } }, {
      broken = { target = broken.target, reason = broken.reason, pos = operation.pos },
      pos = operation.pos,
    })
    return b:result()
  end

  local title = { { operation.method:upper() .. " " .. operation.path, "OasGlanceTitle" } }
  if operation.deprecated then
    title[2] = { "  " }
    title[3] = { "deprecated", "OasGlanceDeprecated" }
  end
  b:add(title, { pos = operation.pos })
  if operation.summary then
    b:add({ { operation.summary, "OasGlanceDescription" } }, { pos = operation.pos })
  end

  local tag_line = table.concat(operation.tags or {}, ", ")
  if operation.operation_id then
    tag_line = tag_line == "" and operation.operation_id or (tag_line .. " · " .. operation.operation_id)
  end
  if tag_line ~= "" then
    b:add({ { tag_line, "OasGlanceMuted" } }, { pos = operation.pos })
  end
  if operation.description then
    b:add({ { operation.description, "OasGlanceDescription" } }, { pos = operation.pos })
  end
  incomplete_note(b, ctx, operation)

  parameter_rows(b, ctx, operation.parameters or {})
  request_body_rows(b, ctx, operation.request_body)
  response_rows(b, ctx, operation.responses or {})
  security_rows(b, operation.security or {})
  server_rows(b, operation.servers or {})
  return b:result()
end

--- Renders a listed schema. The schema itself counts as above its rows, for the cycle rule.
---@param schema_ref { name: string, key: string?, pos: oas_glance.Pos? }
---@param schema table
---@param opts table?
---@return oas_glance.RenderResult
function M.schema(schema_ref, schema, opts)
  local b, ctx = start(opts)

  local title = { { schema_ref.name, "OasGlanceTitle" } }
  if not schema.ref then
    local summary = schema_render.summary(schema, ctx)
    if #summary > 0 then
      title[2] = { "  " }
      vim.list_extend(title, summary)
    end
  end
  b:add(title, { pos = schema_ref.pos })
  if schema.description then
    b:add({ { schema.description, "OasGlanceDescription" } }, { pos = schema.pos })
  end
  if schema.required and #schema.required > 0 then
    b:add({ { "required: " .. table.concat(schema.required, ", "), "OasGlanceMuted" } }, { pos = schema.pos })
  end
  for _, example in ipairs(schema.examples or {}) do
    b:add({ { "example: " .. example.text, "OasGlanceMuted" } }, { pos = schema.pos })
  end

  local entries = schema_render.entries(schema, "root", true)
  if #entries > 0 then
    b:blank()
    local keys = schema_ref.key and { schema_ref.key } or {}
    schema_render.with_ancestors(ctx, keys, function()
      schema_render.render_entries(b, ctx, entries, 0, 1)
    end)
  end
  return b:result()
end

--- The number the list header and the overview heading show. An info diagnostic is neutral.
---@param diagnostics table[]
---@return integer
function M.problem_count(diagnostics)
  local count = 0
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.level ~= "info" then
      count = count + 1
    end
  end
  return count
end

---@param b oas_glance.LineBuilder
---@param ctx oas_glance.RenderContext
---@param diagnostic table
---@param file string?
local function diagnostic_row(b, ctx, diagnostic, file)
  local pos = diagnostic.pos or {}
  local text = string.format("line %d  %s", (pos.row or 0) + 1, diagnostic.message)
  if pos.file and pos.file ~= file then
    text = string.format("%s  (%s)", text, vim.fs.basename(pos.file))
  end
  local action = { pos = diagnostic.pos }
  if diagnostic.level == "info" then
    b:add({ { "  " }, { text, "OasGlanceMuted" } }, action, "  ")
  elseif diagnostic.code == "broken-ref" then
    b:add({ { ctx.icons.broken .. " " .. text, "OasGlanceBroken" } }, action, "  ")
  else
    b:add({ { ctx.icons.problem .. " " .. text, "OasGlanceProblem" } }, action, "  ")
  end
end

--- Renders the overview. Problems come first, then a `Notes` section for neutral diagnostics.
---@param document table
---@param opts table? `diagnostics` replaces the document's own, `file_name` is shown, `file` is the root file.
---@return oas_glance.RenderResult
function M.overview(document, opts)
  opts = opts or {}
  local b, ctx = start(opts)
  local info = document.info or {}

  b:add({ { table.concat({ info.title or "(untitled)", info.version }, " "), "OasGlanceTitle" } })
  local version = { { "OpenAPI " .. (document.raw_version or ""), "OasGlanceMuted" } }
  if opts.file_name then
    version[2] = { "  " .. opts.file_name, "OasGlanceMuted" }
  end
  b:add(version)
  for _, server in ipairs(document.servers or {}) do
    b:add({ { server.url or "", "OasGlanceMuted" } })
  end

  b:blank()
  local diagnostics = opts.diagnostics or document.diagnostics or {}
  local count = M.problem_count(diagnostics)
  if count > 0 then
    b:add({ { string.format("Problems so far %d", count), "OasGlanceSection" } })
  else
    b:add({ { "No problems so far.", "OasGlanceHint" } })
  end
  b:add({ { HINT, "OasGlanceHint" } })

  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.level ~= "info" then
      diagnostic_row(b, ctx, diagnostic, opts.file)
    end
  end

  local notes = #diagnostics - count
  if notes > 0 then
    b:blank()
    b:add({ { string.format("Notes %d", notes), "OasGlanceSection" } })
    for _, diagnostic in ipairs(diagnostics) do
      if diagnostic.level == "info" then
        diagnostic_row(b, ctx, diagnostic, opts.file)
      end
    end
  end
  return b:result()
end

---@param value string|string[]|false
---@return string?
local function key_text(value)
  if value == false then
    return nil
  end
  if type(value) == "table" then
    return table.concat(value, ", ")
  end
  return value
end

--- Renders key help. `keymaps` holds the user's values by pane and action, and a false value hides the action.
---@param opts table?
---@return oas_glance.RenderResult
function M.help(opts)
  opts = opts or {}
  local b = start(opts)
  local keymaps = opts.keymaps or {}
  for index, pane in ipairs(KEY_HELP) do
    if index > 1 then
      b:blank()
    end
    b:add({ { pane.title, "OasGlanceSection" } })
    local configured = keymaps[pane.pane] or {}
    for _, key in ipairs(pane.keys) do
      local value = configured[key[1]]
      if value == nil then
        value = key[2]
      end
      local text = key_text(value)
      if text then
        b:add({ { "  " .. text .. "  " .. key[3], "OasGlanceHint" } })
      end
    end
  end
  return b:result()
end

return M
