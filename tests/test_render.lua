local detail = require("oas-glance.internal.render.detail")
local filter = require("oas-glance.internal.filter")
local list = require("oas-glance.internal.render.list")
local model = require("oas-glance.internal.model")
local workspace = require("oas-glance.internal.workspace")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local REPLACEMENT = "\239\191\189"
local POS = { file = "/x/a.yaml", row = 7, col = 2, end_row = 7, end_col = 9 }

local function load_text(text, opts)
  local ws = workspace.new(opts)
  local document = assert(model.load(ws, assert(ws:open_text(text, { bufnr = 1 }))))
  return document, ws
end

local function load_file(path)
  local ws = workspace.new({ root = assert(vim.uv.fs_realpath("tests/fixtures")) })
  return assert(model.load(ws, assert(ws:open_file(path))))
end

local function find(items, field, value)
  for _, item in ipairs(items) do
    if item[field] == value then
      return item
    end
  end
  error("no item with " .. field .. " = " .. tostring(value), 0)
end

local function resolver(document)
  return function(ref)
    return model.open_ref(document, ref)
  end
end

local function render_listed(document, name, opts)
  local schema_ref = find(document.schemas, "name", name)
  local options = vim.tbl_extend("keep", opts or {}, { resolve = resolver(document) })
  return detail.schema(schema_ref, model.schema(document, schema_ref), options)
end

local function view(schema, opts)
  return detail.schema({ name = "S", key = opts and opts.key }, schema, opts)
end

local function find_row(result, text)
  for index, line in ipairs(result.lines) do
    if line:find(text, 1, true) then
      return index - 1
    end
  end
  error("no line with " .. text .. " in:\n" .. table.concat(result.lines, "\n"), 0)
end

local function spans_on(result, row)
  local found = {}
  for _, span in ipairs(result.spans) do
    if span.row == row then
      found[#found + 1] = { result.lines[row + 1]:sub(span.col + 1, span.end_col), span.group }
    end
  end
  return found
end

local function has_span(result, row, text, group)
  for _, span in ipairs(spans_on(result, row)) do
    if span[1] == text and span[2] == group then
      return true
    end
  end
  return false
end

local function expect_span(result, row, text, group)
  expect.equality(
    { row = result.lines[row + 1], text = text, group = group, found = has_span(result, row, text, group) },
    {
      row = result.lines[row + 1],
      text = text,
      group = group,
      found = true,
    }
  )
end

local function closed_ref(target, fields)
  return vim.tbl_extend("force", { target = target, status = "closed", name = target, pos = POS }, fields or {})
end

local function ref_schema(target, fields)
  return { ref = closed_ref(target, fields), pos = POS }
end

local function object(properties, fields)
  local rows = {}
  for index, property in ipairs(properties) do
    rows[index] = { name = property[1], schema = property[2], required = property[3], pos = POS }
  end
  return vim.tbl_extend("force", { types = { "object" }, properties = rows, pos = POS }, fields or {})
end

local function recording_resolver(answers)
  local calls = {}
  return function(ref)
    calls[#calls + 1] = ref.target
    local answer = answers and answers[ref.target]
    if answer and answer.key then
      ref.key = answer.key
    end
    if answer and answer.schema then
      return answer.schema
    end
    return nil, answer and answer.reason or "not found"
  end,
    calls
end

--- Stores the open state as the UI does: a ref row holds its raw `$ref` text.
local function open_action(open, action)
  open[assert(action.toggle, "no toggle")] = action.ref and action.ref.target or true
end

--- Opens the first row holding `text` and renders again.
local function open_row(result, text, open)
  local action = assert(result.rows[find_row(result, text)], "no action on " .. text)
  assert(action.toggle, "no toggle on " .. text)
  open_action(open, action)
end

-- Type display

T["type display"] = MiniTest.new_set()

T["type display"]["TypesA, every scalar form"] = function()
  local document = load_file("tests/fixtures/types.yaml")
  expect.equality(render_listed(document, "TypesA").lines, {
    "TypesA  object",
    "required: id",
    "",
    "  id*     integer<int64>  ro",
    "  name    string  len 1..64",
    "  note    string | null",
    '  color   "red" | "green" | "blue" | "cyan" | "pink" … +2',
    '  kind    const "x"',
    "  ge      integer  >= 0",
    "  gt      number  > 0, <= 100",
    "  lt      number  < 100",
    "  code    string  /^a+$/",
    "  flag    boolean = false",
    "  token   string  wo",
    "  legacy  string  deprecated",
  })
end

T["type display"]["TypesB, every structured form"] = function()
  local document = load_file("tests/fixtures/types.yaml")
  expect.equality(render_listed(document, "TypesB").lines, {
    "TypesB  object",
    "",
    "  tags      string[]  items 1..5  unique",
    "▸ pets      → TypesA[]",
    "▾ rows      object[]",
    "    x  string",
    "  labels    map<string, string>",
    "  strict    object  closed",
    "  allowed   any",
    "  denied    never",
    "  anything  any",
    "▾ either    any",
    "  ▾ oneOf",
    "      string",
    "    ▸ → TypesA",
    "▾ inline    object",
    "    y  integer",
  })
end

T["type display"]["spans name each part"] = function()
  local document = load_file("tests/fixtures/types.yaml")
  local a = render_listed(document, "TypesA")
  local id = find_row(a, "id*")
  expect_span(a, id, "id", "OasGlanceProperty")
  expect_span(a, id, "*", "OasGlanceRequired")
  expect_span(a, id, "integer", "OasGlanceType")
  expect_span(a, id, "<int64>", "OasGlanceFormat")
  expect_span(a, id, "ro", "OasGlanceConstraint")
  expect_span(a, find_row(a, "note"), "| null", "OasGlanceNull")
  expect_span(a, find_row(a, "kind"), 'const "x"', "OasGlanceEnum")
  expect_span(a, find_row(a, "flag"), "= false", "OasGlanceDefault")
  expect_span(a, find_row(a, "legacy"), "deprecated", "OasGlanceDeprecated")
  expect_span(a, 0, "TypesA", "OasGlanceTitle")

  local b = render_listed(document, "TypesB")
  expect_span(b, find_row(b, "pets"), "→ TypesA", "OasGlanceRef")
  expect_span(b, find_row(b, "strict"), "closed", "OasGlanceConstraint")
  expect_span(b, find_row(b, "oneOf"), "oneOf", "OasGlanceComposition")
  expect_span(b, find_row(b, "oneOf"), "▾", "OasGlanceFold")
end

T["type display"]["forms the fixture leaves out"] = function()
  for _, row in ipairs({
    { { types = { "string", "integer" } }, "string | integer" },
    { { types = { "null", "string" } }, "null | string" },
    { { types = { "string", "null" }, format = "uuid" }, "string<uuid> | null" },
    { { format = "uuid" }, "any<uuid>" },
    { { items = { types = { "array" }, items = { types = { "string" } } } }, "string[][]" },
    { { types = { "array" } }, "any[]" },
    { { additional = true }, "map<string, any>" },
    { { additional = ref_schema("#/x", { name = "Pet" }) }, "map<string, → Pet>" },
    { { items = ref_schema("#/x", { name = "Pet", file = "a.yaml" }) }, "→ Pet (a.yaml)[]" },
    { { boolean = true }, "any" },
    { { boolean = false }, "never" },
    { {}, "any" },
    { { types = { "integer" }, min = { value = "0", exclusive = false } }, "integer  >= 0" },
    { { types = { "integer" }, max = { value = "1.50", exclusive = true } }, "integer  < 1.50" },
    { { types = { "string" }, length = { min = "2" } }, "string  len 2.." },
    { { types = { "string" }, length = { max = "9" } }, "string  len ..9" },
    { { types = { "array" }, item_count = { min = "1", max = "5" } }, "any[]  items 1..5" },
    { { types = { "number" }, multiple_of = "2.50" }, "number  multiple of 2.50" },
    { { types = { "string" }, default = { type = "string", text = "x" } }, 'string = "x"' },
    { { enum = { { type = "integer", text = "1" }, { type = "null", text = "null" } } }, "1 | null" },
    { { const = { type = "integer", text = "1.0" } }, "const 1.0" },
  }) do
    local result = view(object({ { "p", row[1] } }), {})
    expect.equality(result.lines[#result.lines]:gsub("^[▸ ]+p  ", ""), row[2])
  end
end

T["type display"]["enum shows five, and a count only past five"] = function()
  local function enum(count)
    local values = {}
    for index = 1, count do
      values[index] = { type = "integer", text = tostring(index) }
    end
    return view(object({ { "p", { enum = values } } }), {}).lines[3]
  end
  expect.equality(enum(5), "  p  1 | 2 | 3 | 4 | 5")
  expect.equality(enum(6), "  p  1 | 2 | 3 | 4 | 5 … +1")
end

T["type display"]["a 3.0 nullable renders like a 3.1 type list"] = function()
  local text = "openapi: %s\npaths: {}\ncomponents:\n  schemas:\n    S:\n      properties:\n        p:\n          %s\n"
  local v30 = load_text(text:format("3.0.3", "{ type: string, nullable: true }"))
  local v31 = load_text(text:format("3.1.0", '{ type: [string, "null"] }'))
  expect.equality(render_listed(v30, "S").lines, render_listed(v31, "S").lines)
  expect.equality(render_listed(v31, "S").lines[3], "  p  string | null")
end

T["type display"]["numbers render from raw text"] = function()
  local document = load_text(
    "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      properties:\n"
      .. "        p: { maximum: 123456789012345678901234567890, default: 1.0 }\n"
  )
  expect.equality(render_listed(document, "S").lines[3], "  p  any = 1.0  <= 123456789012345678901234567890")
end

T["type display"]["a schema's title line shows its type and an unknown keyword as a raw row"] = function()
  local document = load_text(
    "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      type: string\n      format: uuid\n      x-own: { a: 1 }\n"
  )
  expect.equality(render_listed(document, "S").lines, { "S  string<uuid>", "", "  x-own  { a: 1 }" })
end

-- List

local function petstore()
  return load_file("tests/fixtures/petstore-31.yaml")
end

T["list"] = MiniTest.new_set()

T["list"]["follows the diagram"] = function()
  expect.equality(list.render(petstore()).lines, {
    " Petstore 1.0.0",
    " OpenAPI 3.1.0",
    "",
    "",
    "▾ pets 4",
    "   GET     /pets",
    "   POST    /pets",
    "   GET     /pets/{petId}",
    " ~ DELETE  /pets/{petId}",
    "▾ store 1",
    "   GET     /store/inventory",
    "▾ (untagged) 1",
    "   GET     /health",
    "",
    "▾ Webhooks 1",
    "   POST    newPet",
    "",
    "▾ Schemas 3",
    "   Error",
    "   NewPet",
    "   Pet",
  })
end

local function list_document(fields)
  return vim.tbl_extend("force", { info = { title = "T", version = "1" }, raw_version = "3.1.0", groups = {} }, fields)
end

local function one_operation(fields)
  return list_document({
    groups = {
      {
        tag = "t",
        operations = { vim.tbl_extend("force", { method = "get", path = "/a", tags = { "t" }, pos = POS }, fields) },
      },
    },
  })
end

T["list"]["marker priority is problem, then deprecated"] = function()
  local row = 5
  expect.equality(list.render(one_operation({})).lines[row + 1], "   GET     /a")
  expect.equality(list.render(one_operation({ deprecated = true })).lines[row + 1], " ~ GET     /a")
  expect.equality(list.render(one_operation({ problem = true })).lines[row + 1], " ! GET     /a")
  local both = list.render(one_operation({ problem = true, deprecated = true }))
  expect.equality(both.lines[row + 1], " ! GET     /a")
  expect_span(both, row, "!", "OasGlanceProblem")
end

T["list"]["a schema with a problem has the marker"] = function()
  local result = list.render(list_document({ schemas = { { name = "Pet", problem = true, pos = POS } } }))
  local row = find_row(result, "Pet")
  expect.equality(result.lines[row + 1], " ! Pet")
  expect_span(result, row, "Pet", "OasGlanceSchemaName")
  expect_span(result, row, "!", "OasGlanceProblem")
end

T["list"]["the deprecated overlay is a second span over method and path"] = function()
  local result = list.render(one_operation({ method = "delete", path = "/a/{b}", deprecated = true }))
  local row = find_row(result, "DELETE")
  expect_span(result, row, "~", "OasGlanceDeprecated")
  expect_span(result, row, "DELETE", "OasGlanceMethodDelete")
  expect_span(result, row, "/a/", "OasGlancePath")
  expect_span(result, row, "{b}", "OasGlancePathParam")
  expect_span(result, row, "DELETE  /a/{b}", "OasGlanceDeprecated")

  local method_priority, overlay_priority = 0, 0
  for _, span in ipairs(result.spans) do
    if span.row == row and span.group == "OasGlanceDeprecated" and span.priority then
      overlay_priority = span.priority
    elseif span.row == row and span.group == "OasGlanceMethodDelete" then
      method_priority = span.priority or 0
    end
  end
  expect.equality(overlay_priority > method_priority, true)
end

T["list"]["each method has its group"] = function()
  for method, group in pairs({
    get = "OasGlanceMethodGet",
    post = "OasGlanceMethodPost",
    put = "OasGlanceMethodPut",
    patch = "OasGlanceMethodPatch",
    delete = "OasGlanceMethodDelete",
    head = "OasGlanceMethodHead",
    options = "OasGlanceMethodOptions",
    trace = "OasGlanceMethodTrace",
  }) do
    local result = list.render(one_operation({ method = method }))
    expect_span(result, 5, method:upper(), group)
  end
end

T["list"]["group rows have a marker, a name and a count, and toggle"] = function()
  local result = list.render(one_operation({}))
  expect.equality(result.lines[5], "▾ t 1")
  expect_span(result, 4, "▾", "OasGlanceFold")
  expect_span(result, 4, "t", "OasGlanceGroup")
  expect_span(result, 4, "1", "OasGlanceMuted")
  expect.equality(type(result.rows[4].toggle), "string")
end

T["list"]["a closed group hides its rows and keeps its count"] = function()
  local open = {}
  local first = list.render(one_operation({}), { open = open })
  open[first.rows[4].toggle] = false
  local closed = list.render(one_operation({}), { open = open })
  expect.equality(closed.lines[5], "▸ t 1")
  expect.equality(#closed.lines, 5)
end

T["list"]["rows select their target"] = function()
  local document = petstore()
  local result = list.render(document)
  local get = result.rows[5]
  expect.equality(get.select.kind, "operation")
  expect.equality(get.select.operation == document.groups[1].operations[1], true)
  expect.equality(get.pos == document.groups[1].operations[1].pos, true)
  local schema_row = result.rows[find_row(result, "NewPet")]
  expect.equality(schema_row.select.kind, "schema")
  expect.equality(schema_row.select.schema.name, "NewPet")
  for row = 0, 2 do
    expect.equality(result.rows[row].select.kind, "overview")
  end
end

T["list"]["a multibyte path keeps byte columns and aligned columns"] = function()
  local result = list.render(one_operation({ path = "/日本語/{id}" }))
  expect.equality(result.lines[6], "   GET     /日本語/{id}")
  expect_span(result, 5, "/日本語/", "OasGlancePath")
  expect_span(result, 5, "{id}", "OasGlancePathParam")
end

-- Statuses

local function operation_view(fields, opts)
  local operation = vim.tbl_extend("force", { method = "get", path = "/a", tags = {}, pos = POS }, fields)
  return detail.operation(operation, opts)
end

T["statuses"] = MiniTest.new_set()

for _, row in ipairs({
  { "100", "OasGlanceStatusOther" },
  { "200", "OasGlanceStatus2xx" },
  { "204", "OasGlanceStatus2xx" },
  { "2XX", "OasGlanceStatus2xx" },
  { "2xx", "OasGlanceStatus2xx" },
  { "301", "OasGlanceStatusOther" },
  { "3XX", "OasGlanceStatusOther" },
  { "404", "OasGlanceStatus4xx" },
  { "4XX", "OasGlanceStatus4xx" },
  { "500", "OasGlanceStatus5xx" },
  { "5XX", "OasGlanceStatus5xx" },
  { "default", "OasGlanceStatusOther" },
}) do
  T["statuses"][row[1]] = function()
    local result = operation_view({ responses = { { status = row[1], pos = POS } } })
    expect_span(result, find_row(result, row[1]), row[1], row[2])
  end
end

-- Bytes and display width

T["width and bytes"] = MiniTest.new_set()

T["width and bytes"]["spans are byte columns with multibyte text"] = function()
  local result = view(object({ { "名前", { types = { "string" } } }, { "x", { types = { "integer" } } } }), {})
  local row = find_row(result, "名前")
  expect.equality(result.lines[row + 1], "  名前  string")
  expect_span(result, row, "名前", "OasGlanceProperty")
  expect_span(result, row, "string", "OasGlanceType")
  for _, span in ipairs(result.spans) do
    if span.row == row and span.group == "OasGlanceType" then
      expect.equality(span.col, #"  名前  ")
      expect.equality(span.end_col, #"  名前  string")
    end
  end
end

T["width and bytes"]["alignment uses display width, not bytes"] = function()
  local result = view(object({ { "名前", { types = { "string" } } }, { "x", { types = { "integer" } } } }), {})
  expect.equality(result.lines[4], "  x     integer")
  expect.equality(vim.api.nvim_strwidth(result.lines[3]:sub(1, #"  名前  ")), vim.api.nvim_strwidth("  x     "))
end

T["width and bytes"]["names pad to the longest sibling"] = function()
  local result = view(object({ { "short", { types = { "string" } } }, { "longest", { types = { "string" } } } }), {})
  expect.equality(result.lines[3], "  short    string")
  expect.equality(result.lines[4], "  longest  string")
end

T["width and bytes"]["required counts towards the name's width"] = function()
  local result = view(object({ { "abc", { types = { "string" } }, true }, { "abcd", { types = { "string" } } } }), {})
  expect.equality(result.lines[3], "  abc*  string")
  expect.equality(result.lines[4], "  abcd  string")
end

T["width and bytes"]["the pad is capped at 24 cells"] = function()
  local long = string.rep("n", 30)
  local exact = string.rep("m", 24)
  local result = view(
    object({
      { long, { types = { "string" } } },
      { exact, { types = { "string" } } },
      { "s", { types = { "string" } } },
    }),
    {}
  )
  expect.equality(result.lines[3], "  " .. long .. "  string")
  expect.equality(result.lines[4], "  " .. exact .. "  string")
  expect.equality(result.lines[5], "  s" .. string.rep(" ", 23) .. "  string")
end

T["text"] = MiniTest.new_set()

T["text"]["an embedded newline splits lines, so no line holds one"] = function()
  local result = operation_view({ summary = "one\ntwo", description = "three\r\nfour" })
  expect.equality(result.lines, { "GET /a", "one", "two", "three", "four" })
  for _, line in ipairs(result.lines) do
    expect.equality(line:find("\n", 1, true), nil)
  end
end

T["text"]["other control characters become U+FFFD"] = function()
  local result = operation_view({ summary = "a\0b\tc\27d\127e\r" })
  local replaced = "a" .. REPLACEMENT .. "b" .. REPLACEMENT .. "c" .. REPLACEMENT .. "d" .. REPLACEMENT .. "e"
  expect.equality(result.lines[2], replaced .. REPLACEMENT)
end

T["text"]["a C1 control character becomes U+FFFD and other multibyte text stays"] = function()
  local result = operation_view({ summary = "a\194\133b é" })
  expect.equality(result.lines[2], "a" .. REPLACEMENT .. "b é")
end

T["text"]["a newline in a property name or a value splits rows too"] = function()
  local result = view(object({ { "a\nq1", { const = { type = "string", text = "c\nq2" } } } }), {})
  for _, line in ipairs(result.lines) do
    expect.equality(line:find("\n", 1, true), nil)
  end
  expect.equality(find_row(result, "q1") > find_row(result, "  a"), true)
  expect.equality(find_row(result, "q2") > find_row(result, "q1"), true)
end

T["text"]["a further row of a split keeps pos and no toggle"] = function()
  local result = operation_view({
    responses = { { status = "200", description = "one\ntwo", content = { { name = "a/b" } }, pos = POS } },
  })
  local first = find_row(result, "one")
  local second = find_row(result, "two")
  expect.equality(type(result.rows[first].toggle), "string")
  expect.equality(result.rows[second].toggle, nil)
  expect.equality(result.rows[second].pos, POS)
  expect.equality(result.lines[first + 1]:sub(1, #"▾"), "▾")
end

T["text"]["list text is cleaned too"] = function()
  local result = list.render(one_operation({ path = "/a\0b" }))
  expect.equality(result.lines[6], "   GET     /a" .. REPLACEMENT .. "b")
end

-- Cycle rule

local LOCAL_KEY = "/x/a.yaml#/components/schemas/Pet"

T["cycle rule"] = MiniTest.new_set()

T["cycle rule"]["a key above the row gives the cycle row, keeping pos and target"] = function()
  local ref = closed_ref("#/components/schemas/Pet", { name = "Pet", key = LOCAL_KEY })
  local result = view(object({ { "parent", { ref = ref, pos = POS } } }), { key = LOCAL_KEY })
  local row = find_row(result, "parent")
  expect.equality(result.lines[row + 1], "  parent  ↻ Pet  cycle")
  expect_span(result, row, "↻ Pet  cycle", "OasGlanceCycle")
  local action = result.rows[row]
  expect.equality(action.toggle, nil)
  expect.equality(action.cycle, true)
  expect.equality(action.pos, POS)
  expect.equality(action.ref == ref, true)
end

T["cycle rule"]["with no property name"] = function()
  local schema = {
    types = { "array" },
    items = ref_schema("#/components/schemas/Pet", { name = "Pet", key = LOCAL_KEY }),
    pos = POS,
  }
  local result = view(object({ { "p", { compositions = { { kind = "oneOf", members = { schema.items } } } } } }), {
    key = LOCAL_KEY,
  })
  expect.equality(result.lines[find_row(result, "↻") + 1], "      ↻ Pet  cycle")
end

T["cycle rule"]["Pet.parent is a cycle row in the Pet view, with no expansion first"] = function()
  local result = render_listed(petstore(), "Pet")
  expect.equality(result.lines[find_row(result, "parent") + 1]:match("parent%s+(.*)$"), "↻ Pet  cycle")
end

T["cycle rule"]["a listed schema's key escapes the name as its own pointer does"] = function()
  local document = load_text([[
openapi: 3.1.0
components:
  schemas:
    a/b~c:
      properties:
        self:
          $ref: "#/components/schemas/a~1b~0c"
]])
  expect.equality(render_listed(document, "a/b~c").lines[3], "  self  ↻ a/b~c  cycle")
end

T["cycle rule"]["a closed local ref above the row calls no resolve"] = function()
  local resolve, calls = recording_resolver()
  view(
    object({ { "parent", ref_schema("#/P", { name = "P", key = LOCAL_KEY }) } }),
    { key = LOCAL_KEY, resolve = resolve }
  )
  expect.equality(calls, {})
end

T["cycle rule"]["a closed external ref to the same target stays closed"] = function()
  local result = view(
    object({ { "parent", ref_schema("./a.yaml#/components/schemas/Pet", { name = "Pet", file = "a.yaml" }) } }),
    { key = LOCAL_KEY }
  )
  expect.equality(result.lines[3], "▸ parent  → Pet (a.yaml)")
end

T["cycle rule"]["a closed external ref stays closed even when an earlier opening gave it a key"] = function()
  local result = view(
    object({ { "parent", ref_schema("./a.yaml#/P", { name = "P", file = "a.yaml", key = LOCAL_KEY }) } }),
    { key = LOCAL_KEY }
  )
  expect.equality(result.lines[3], "▸ parent  → P (a.yaml)")
end

T["cycle rule"]["that external ref becomes the cycle row when opened"] = function()
  local schema = object({ { "parent", ref_schema("./a.yaml#/P", { name = "P", file = "a.yaml" }) } })
  local open = {}
  open_action(open, view(schema, { key = LOCAL_KEY }).rows[2])
  local resolve = recording_resolver({ ["./a.yaml#/P"] = { schema = object({}), key = LOCAL_KEY } })
  local result = view(schema, { key = LOCAL_KEY, open = open, resolve = resolve })
  expect.equality(result.lines[3], "  parent  ↻ P (a.yaml)  cycle")
  expect.equality(result.rows[2].toggle, nil)
  expect.equality(result.rows[2].cycle, true)
end

T["cycle rule"]["every key on an opened chain counts as above"] = function()
  local inner = ref_schema("#/hop", { name = "hop", key = "k#/hop" })
  local target = object({ { "back", inner } })
  local schema = object({ { "start", ref_schema("#/a", { name = "a", key = "k#/a" }) } })
  local open = {}
  open_action(open, view(schema).rows[2])
  local resolve = function(ref)
    ref.keys = { "k#/a", "k#/hop" }
    return target
  end
  local result = view(schema, { open = open, resolve = resolve })
  expect.equality(result.lines[find_row(result, "back") + 1], "    back  ↻ hop  cycle")
end

T["cycle rule"]["the same schema in sibling branches expands"] = function()
  local target = object({ { "x", { types = { "string" } } } })
  local schema = object({
    { "one", ref_schema("#/T", { name = "T", key = "k#/T" }) },
    { "two", ref_schema("#/T", { name = "T", key = "k#/T" }) },
  })
  local first = view(schema)
  local open = {}
  open_action(open, first.rows[2])
  open_action(open, first.rows[3])
  local resolve = recording_resolver({ ["#/T"] = { schema = target } })
  local result = view(schema, { open = open, resolve = resolve })
  expect.equality(result.lines, {
    "S  object",
    "",
    "▾ one  → T",
    "    x  string",
    "▾ two  → T",
    "    x  string",
  })
end

T["cycle rule"]["a mutual cycle ends at the marker when opened step by step"] = function()
  local a = object({})
  local b = object({ { "to_a", ref_schema("#/a", { name = "a", key = "k#/a" }) } })
  a.properties[1] = { name = "to_b", schema = ref_schema("#/b", { name = "b", key = "k#/b" }), pos = POS }
  local schema = object({ { "start", ref_schema("#/a", { name = "a", key = "k#/a" }) } })
  local open = {}
  local resolve = recording_resolver({ ["#/a"] = { schema = a }, ["#/b"] = { schema = b } })
  local function render()
    return view(schema, { open = open, resolve = resolve })
  end
  open_row(render(), "start", open)
  open_row(render(), "to_b", open)
  expect.equality(render().lines, {
    "S  object",
    "",
    "▾ start  → a",
    "  ▾ to_b  → b",
    "      to_a  ↻ a  cycle",
  })
end

local REF_ONLY_CYCLE = [[
openapi: 3.1.0
paths: {}
components:
  schemas:
    A:
      $ref: "#/components/schemas/B"
    B:
      $ref: "#/components/schemas/A"
    S:
      properties:
        p:
          $ref: "#/components/schemas/A"
]]

T["cycle rule"]["a ref-only chain stays closed, and is broken with ref cycle when opened"] = function()
  local document = load_text(REF_ONLY_CYCLE)
  local open = {}
  local closed = render_listed(document, "S", { open = open })
  expect.equality(closed.lines[3], "▸ p  → A")

  open_action(open, closed.rows[2])
  local opened = render_listed(document, "S", { open = open })
  expect.equality(opened.lines[3], "  p  ✗ #/components/schemas/A  ref cycle")
  expect.equality(opened.rows[2].toggle, nil)
  expect.equality(opened.rows[2].broken.reason, "ref cycle")
  expect.equality(document.diagnostics[#document.diagnostics].code, "broken-ref")
end

-- Closed and broken rows

T["closed rows"] = MiniTest.new_set()

T["closed rows"]["rendering closed refs never calls resolve"] = function()
  local resolve, calls = recording_resolver()
  local result = view(
    object({
      { "local_here", ref_schema("#/there", { name = "there", key = "k#/there" }) },
      { "local_gone", ref_schema("#/no/such", { name = "such", key = "k#/no/such" }) },
      { "external_here", ref_schema("./a.yaml", { name = "a", file = "a.yaml" }) },
      { "external_gone", ref_schema("./gone.yaml", { name = "gone", file = "gone.yaml" }) },
    }),
    { resolve = resolve }
  )
  expect.equality(calls, {})
  expect.equality(#result.lines, 6)
end

T["closed rows"]["a real document's closed refs load and walk nothing"] = function()
  local document, ws = load_text(
    "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      properties:\n        p:\n          $ref: '#/no/such'\n"
  )
  local result = render_listed(document, "S", {
    resolve = function()
      error("resolve must not run")
    end,
  })
  expect.equality(result.lines[3], "▸ p  → such")
  expect.equality(ws:loaded_files(), {})
  expect.equality(document.diagnostics, {})
end

T["closed rows"]["a name comes from the ref's text"] = function()
  local function closed_line(ref)
    local text = string.format(
      "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      properties:\n        p:\n          $ref: '%s'\n",
      ref
    )
    return render_listed(load_text(text), "S").lines[3]
  end
  expect.equality(closed_line("./gone.yaml"), "▸ p  → gone (gone.yaml)")
  expect.equality(closed_line("../x/common.yaml#/Owner"), "▸ p  → Owner (common.yaml)")
  expect.equality(closed_line("#/components/schemas/Pet"), "▸ p  → Pet")
end

T["closed rows"]["a closed row has a fold marker, a toggle, the ref and its pos"] = function()
  local schema = ref_schema("#/T", { name = "T" })
  local result = view(object({ { "p", schema } }))
  expect_span(result, 2, "▸", "OasGlanceFold")
  expect_span(result, 2, "→ T", "OasGlanceRef")
  expect.equality(type(result.rows[2].toggle), "string")
  expect.equality(result.rows[2].ref == schema.ref, true)
  expect.equality(result.rows[2].pos, POS)
end

T["broken rows"] = MiniTest.new_set()

for _, row in ipairs({
  { "https://x/a.yaml", "remote not loaded" },
  { "file:///x", "not allowed" },
  { "#name", "unsupported ref" },
}) do
  T["broken rows"][row[2] .. " is broken from the start"] = function()
    local resolve, calls = recording_resolver()
    local text = string.format(
      "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      properties:\n        p:\n          $ref: '%s'\n",
      row[1]
    )
    local document = load_text(text)
    local result = render_listed(document, "S", { resolve = resolve })
    local rendered = result.lines[3]
    expect.equality(rendered, string.format("  p  ✗ %s  %s", row[1], row[2]))
    expect_span(result, 2, string.format("✗ %s  %s", row[1], row[2]), "OasGlanceBroken")
    local action = result.rows[2]
    expect.equality(action.toggle, nil)
    expect.equality({ action.broken.target, action.broken.reason }, { row[1], row[2] })
    expect.equality(action.broken.pos.row, 6)
    expect.equality(calls, {})
  end
end

T["broken rows"]["an opened ref is open only while its stored text matches its raw text"] = function()
  local schema = object({ { "gone", ref_schema("./gone.yaml", { name = "gone", file = "gone.yaml" }) } })
  local path = view(schema).rows[2].toggle
  local resolve = recording_resolver({ ["./gone.yaml"] = { reason = "not found" } })
  local opened = view(schema, { open = { [path] = "./gone.yaml" }, resolve = resolve })
  expect.equality(opened.lines[3], "  gone  ✗ ./gone.yaml  not found")

  for _, state in ipairs({ "./other.yaml", true }) do
    local result = view(schema, { open = { [path] = state }, resolve = resolve })
    expect.equality(result.lines[3], "▸ gone  → gone (gone.yaml)")
    expect.equality(result.rows[2].toggle, path)
    expect.equality(result.rows[2].expanded, false)
  end
end

T["broken rows"]["a closed ref that resolve fails on is broken in place, with no marker"] = function()
  local schema = object({ { "gone", ref_schema("./gone.yaml", { name = "gone", file = "gone.yaml" }) } })
  local open = {}
  open_action(open, view(schema).rows[2])
  local resolve = recording_resolver({ ["./gone.yaml"] = { reason = "not found" } })
  local result = view(schema, { open = open, resolve = resolve })
  expect.equality(result.lines[3], "  gone  ✗ ./gone.yaml  not found")
  expect.equality(result.rows[2].toggle, nil)
  expect.equality(result.rows[2].broken.reason, "not found")
  expect.equality(result.rows[2].pos, POS)
end

T["broken rows"]["a second closed ref to that missing target stays closed"] = function()
  local schema = object({
    { "one", ref_schema("./gone.yaml", { name = "gone", file = "gone.yaml" }) },
    { "two", ref_schema("./gone.yaml", { name = "gone", file = "gone.yaml" }) },
  })
  local open = {}
  open_action(open, view(schema).rows[2])
  local resolve, calls = recording_resolver({ ["./gone.yaml"] = { reason = "not found" } })
  local result = view(schema, { open = open, resolve = resolve })
  expect.equality(result.lines[3], "  one  ✗ ./gone.yaml  not found")
  expect.equality(result.lines[4], "▸ two  → gone (gone.yaml)")
  expect.equality(#calls, 1)
end

T["broken rows"]["through the real model, the row stays broken with no second check"] = function()
  local document = load_text(
    "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      properties:\n        p:\n          $ref: '#/no/such'\n"
  )
  local open = {}
  open_action(open, render_listed(document, "S").rows[2])
  expect.equality(render_listed(document, "S", { open = open }).lines[3], "  p  ✗ #/no/such  no such pointer")
  local again = render_listed(document, "S", {
    open = {},
    resolve = function()
      error("a broken ref is not checked again")
    end,
  })
  expect.equality(again.lines[3], "  p  ✗ #/no/such  no such pointer")
end

T["broken rows"]["a broken parameter, request body and response"] = function()
  local broken = { target = "#/gone", reason = "no such pointer", pos = POS }
  local result = operation_view({
    parameters = { { name = "id", broken = broken, pos = POS } },
    request_body = { broken = broken, pos = POS },
    responses = { { status = "404", broken = broken, pos = POS } },
  })
  expect.equality(result.lines, {
    "GET /a",
    "",
    "Parameters",
    "  id  ✗ #/gone  no such pointer",
    "",
    "Request body",
    "  ✗ #/gone  no such pointer",
    "",
    "Responses",
    "  404  ✗ #/gone  no such pointer",
  })
  for _, row in ipairs({ 3, 6, 9 }) do
    expect.equality(result.rows[row].broken.reason, "no such pointer")
    expect.equality(result.rows[row].toggle, nil)
  end
end

-- Default fold state

T["fold state"] = MiniTest.new_set()

local function response(status, schema)
  return {
    status = status,
    description = "D" .. status,
    content = { { name = "application/json", schema = schema } },
    pos = POS,
  }
end

T["fold state"]["list groups start open"] = function()
  local result = list.render(petstore())
  for _, row in ipairs({ 4, 9, 11, 14, 17 }) do
    expect.equality(result.lines[row + 1]:sub(1, #"▾"), "▾")
  end
end

T["fold state"]["the first response in spec order starts open, even a 404 before a 200"] = function()
  local result = operation_view({
    responses = { response("404", { types = { "string" } }), response("200", { types = { "string" } }) },
  })
  expect.equality(result.lines, {
    "GET /a",
    "",
    "Responses",
    "▾ 404 D404",
    "  application/json",
    "    string",
    "▸ 200 D200",
  })
end

T["fold state"]["a response with nothing to show has no marker"] = function()
  local result = operation_view({ responses = { { status = "204", description = "Gone", pos = POS } } })
  expect.equality(result.lines[4], "  204 Gone")
  expect.equality(result.rows[3].toggle, nil)
end

T["fold state"]["toggling a response follows the state"] = function()
  local fields =
    { responses = { response("200", { types = { "string" } }), response("404", { types = { "string" } }) } }
  local first = operation_view(fields)
  local open = {
    [first.rows[find_row(first, "D200")].toggle] = false,
    [first.rows[find_row(first, "D404")].toggle] = true,
  }
  local result = operation_view(fields, { open = open })
  expect.equality(result.lines[4], "▸ 200 D200")
  expect.equality(result.lines[5], "▾ 404 D404")
end

T["fold state"]["every $ref starts closed"] = function()
  local resolve, calls = recording_resolver()
  local result = operation_view({
    responses = {
      response("200", ref_schema("#/InResponse", { name = "InResponse" })),
    },
    parameters = {
      {
        name = "p",
        ["in"] = "query",
        schema = { items = ref_schema("#/InItems", { name = "InItems" }), pos = POS },
        pos = POS,
      },
      {
        name = "q",
        ["in"] = "query",
        schema = {
          compositions = { { kind = "oneOf", members = { ref_schema("#/Member", { name = "Member" }) } } },
          pos = POS,
        },
        pos = POS,
      },
    },
  }, { resolve = resolve })
  expect.equality(calls, {})
  expect.equality(result.lines[find_row(result, "InResponse") + 1], "  ▸ → InResponse")
  expect.equality(result.lines[find_row(result, "InItems") + 1], "▸ p  query  → InItems[]")
  expect.equality(result.lines[find_row(result, "Member") + 1], "    ▸ → Member")
end

T["fold state"]["compositions and inline objects start open"] = function()
  local inline = object({ { "x", { types = { "string" } } } })
  local result = view(object({
    { "direct", inline },
    { "under_items", { types = { "array" }, items = inline, pos = POS } },
    { "all", { compositions = { { kind = "allOf", members = { { types = { "string" } } } } }, pos = POS } },
    { "one", { compositions = { { kind = "oneOf", members = { { types = { "string" } } } } }, pos = POS } },
    { "some", { compositions = { { kind = "anyOf", members = { { types = { "string" } } } } }, pos = POS } },
  }))
  expect.equality(result.lines, {
    "S  object",
    "",
    "▾ direct       object",
    "    x  string",
    "▾ under_items  object[]",
    "    x  string",
    "▾ all          any",
    "  ▾ allOf",
    "      string",
    "▾ one          any",
    "  ▾ oneOf",
    "      string",
    "▾ some         any",
    "  ▾ anyOf",
    "      string",
  })
end

T["fold state"]["closing an inline row hides its children"] = function()
  local schema = object({ { "direct", object({ { "x", { types = { "string" } } } }) } })
  local open = {}
  open[view(schema).rows[2].toggle] = false
  expect.equality(view(schema, { open = open }).lines, { "S  object", "", "▸ direct  object" })
end

local function expect_markers_match_toggles(result)
  for index, line in ipairs(result.lines) do
    local action = result.rows[index - 1]
    local has_toggle = action ~= nil and action.toggle ~= nil
    local has_marker = line:find("▾", 1, true) ~= nil or line:find("▸", 1, true) ~= nil
    expect.equality({ line = line, marker = has_marker }, { line = line, marker = has_toggle })
    if has_toggle and action.expanded ~= nil then
      local drawn_open = line:find("▾", 1, true) ~= nil
      expect.equality({ line = line, expanded = action.expanded }, { line = line, expanded = drawn_open })
    end
  end
end

T["fold state"]["every row with a toggle has a fold marker, and no other row has one"] = function()
  local document = load_file("tests/fixtures/types.yaml")
  expect_markers_match_toggles(render_listed(document, "TypesA"))
  expect_markers_match_toggles(render_listed(document, "TypesB"))
  expect_markers_match_toggles(render_listed(petstore(), "Pet"))
  local store = petstore()
  expect_markers_match_toggles(list.render(store))
  for _, group in ipairs(store.groups) do
    for _, operation in ipairs(group.operations) do
      expect_markers_match_toggles(detail.operation(model.operation(store, operation), {}))
    end
  end
end

T["fold state"]["a composition labels a member from the discriminator mapping"] = function()
  local result = view(object({}, {
    compositions = { { kind = "oneOf", members = { ref_schema("#/Cat", { name = "Cat" }) } } },
    discriminator = { property = "petType", mapping = { { value = "cat", target = "#/Cat" } } },
  }))
  expect.equality(result.lines, { "S  object", "", "▾ oneOf  by petType", "  ▸ cat → Cat" })
end

-- Depth

local function chain(levels, leaf)
  local schema = leaf
  for index = levels, 1, -1 do
    schema = object({ { "n" .. index, schema } })
  end
  return schema
end

T["depth"] = MiniTest.new_set()

T["depth"]["inline nesting past max_depth is a broken row and ends"] = function()
  local result = view(chain(10, { types = { "string" } }), { max_depth = 3 })
  expect.equality(result.lines, {
    "S  object",
    "",
    "▾ n1  object",
    "  ▾ n2  object",
    "      n3  ✗ inline schema  too deep",
  })
  expect.equality(result.rows[4].broken.reason, "too deep")
  expect.equality(result.rows[4].toggle, nil)
end

T["depth"]["a schema the model marked too_deep renders as that broken row"] = function()
  local result = view(object({ { "p", { too_deep = true, pos = POS } } }), {})
  expect.equality(result.lines[3], "  p  ✗ inline schema  too deep")
  expect.equality(result.rows[2].broken.pos, POS)
end

T["depth"]["a too_deep element under items renders as that broken row"] = function()
  local result = view(object({ { "p", { items = { too_deep = true, pos = POS }, pos = POS } } }), {})
  expect.equality(result.lines[3], "  p  ✗ inline schema  too deep")
end

T["depth"]["compositions count as nesting"] = function()
  local result = view(
    object({ { "a", { compositions = { { kind = "oneOf", members = { { types = { "string" } } } } }, pos = POS } } }),
    { max_depth = 2 }
  )
  expect.equality(result.lines[4], "    oneOf  ✗ inline schema  too deep")
end

local TWO_CHAINS = [[
openapi: 3.1.0
components:
  schemas:
    First: &first
      properties:
        a1:
          properties:
            a2:
              properties:
                a3:
                  properties:
                    a4:
                      type: string
    Second:
      properties:
        b1:
          properties:
            b2:
              properties:
                b3:
                  properties:
                    b4:
                      properties:
                        b5: *first
]]

local function any_too_deep(schema, seen)
  seen = seen or {}
  if seen[schema] then
    return false
  end
  seen[schema] = true
  if schema.too_deep then
    return true
  end
  for _, property in ipairs(schema.properties or {}) do
    if any_too_deep(property.schema, seen) then
      return true
    end
  end
  return false
end

T["depth"]["the renderer counts through a shared alias the model did not mark"] = function()
  local document = load_text(TWO_CHAINS, { max_depth = 8 })
  local first = model.schema(document, find(document.schemas, "name", "First"))
  local second = model.schema(document, find(document.schemas, "name", "Second"))
  expect.equality(any_too_deep(first), false)
  expect.equality(any_too_deep(second), false)

  local result = render_listed(document, "Second", { max_depth = 8 })
  local last = result.lines[#result.lines]
  expect.equality(last, string.rep(" ", 16) .. "a3  ✗ inline schema  too deep")
  expect.equality(find_row(result, "a3"), #result.lines - 1)
  expect.equality(result.rows[#result.lines - 1].broken.reason, "too deep")

  local shallow = render_listed(document, "First", { max_depth = 8 })
  expect.equality(shallow.lines[#shallow.lines]:find("too deep", 1, true), nil)
end

T["depth"]["opening a ref starts a new count"] = function()
  local target = chain(2, { types = { "string" } })
  local schema = chain(2, ref_schema("#/T", { name = "T", key = "k#/T" }))
  local open = {}
  local function render()
    return view(schema, {
      max_depth = 3,
      open = open,
      resolve = recording_resolver({ ["#/T"] = { schema = target } }),
    })
  end
  local closed = render()
  open_action(open, closed.rows[find_row(closed, "→ T")])
  expect.equality(render().lines, {
    "S  object",
    "",
    "▾ n1  object",
    "  ▾ n2  → T",
    "    ▾ n1  object",
    "        n2  string",
  })
end

-- Row limit

local function alias_doubling(levels)
  local out = { "openapi: 3.1.0", "paths: {}", "x-levels:", "  l0: &l0", "    type: string" }
  for level = 1, levels do
    out[#out + 1] = string.format("  l%d: &l%d", level, level)
    out[#out + 1] = "    properties:"
    out[#out + 1] = string.format("      a: *l%d", level - 1)
    out[#out + 1] = string.format("      b: *l%d", level - 1)
  end
  out[#out + 1] = "components:"
  out[#out + 1] = "  schemas:"
  out[#out + 1] = string.format("    Top: *l%d", levels)
  return table.concat(out, "\n") .. "\n"
end

local function merge_doubling(levels)
  local out = { "openapi: 3.1.0", "paths: {}", "x-levels:", "  l0: &l0", "    type: string" }
  for level = 1, levels do
    out[#out + 1] = string.format("  l%d: &l%d", level, level)
    out[#out + 1] = "    properties:"
    out[#out + 1] = "      a:"
    out[#out + 1] = string.format("        <<: *l%d", level - 1)
    out[#out + 1] = "      b:"
    out[#out + 1] = string.format("        <<: *l%d", level - 1)
  end
  out[#out + 1] = "components:"
  out[#out + 1] = "  schemas:"
  out[#out + 1] = string.format("    Top: *l%d", levels)
  return table.concat(out, "\n") .. "\n"
end

T["row limit"] = MiniTest.new_set()

for name, generate in pairs({ aliases = alias_doubling, merges = merge_doubling }) do
  T["row limit"]["30 levels of doubling through " .. name .. " give limit + 1 lines"] = function()
    local document = load_text(generate(30))
    for _, limit in ipairs({ 50, 57, 200 }) do
      local result = render_listed(document, "Top", { max_detail_rows = limit })
      expect.equality(#result.lines, limit + 1)
      local last = string.format("! stopped at %d rows (max_detail_rows)", limit)
      expect.equality(result.lines[limit + 1], last)
      expect.equality(spans_on(result, limit), { { last, "OasGlanceProblem" } })
    end
  end

  T["row limit"]["doubling through " .. name .. " really doubles, and the build stays linear"] = function()
    local document = load_text(generate(30))
    render_listed(document, "Top", { max_detail_rows = 50 })
    expect.equality(vim.tbl_count(document._schemas) <= 3 * 30 + 1, true)

    local small = load_text(generate(4))
    local count = #render_listed(small, "Top").lines
    local five = #render_listed(load_text(generate(5)), "Top").lines
    expect.equality(five - 2, (count - 2) * 2 + 2)
  end
end

local function five_rows()
  return object({
    { "a", { types = { "string" } } },
    { "b", { types = { "string" } } },
    { "c", { types = { "string" } } },
  })
end

T["row limit"]["a view of exactly the limit has no limit row"] = function()
  local result = view(five_rows(), { max_detail_rows = 5 })
  expect.equality(result.lines, { "S  object", "", "  a  string", "  b  string", "  c  string" })
end

T["row limit"]["the same view with one less has limit lines, the last being the limit row"] = function()
  local result = view(five_rows(), { max_detail_rows = 4 })
  expect.equality(result.lines, {
    "S  object",
    "",
    "  a  string",
    "  b  string",
    "! stopped at 4 rows (max_detail_rows)",
  })
end

T["row limit"]["the limit row has no toggle, ref, pos or broken mark, and no marker"] = function()
  local result = view(five_rows(), { max_detail_rows = 4 })
  local action = result.rows[4]
  expect.equality({ action.toggle, action.ref, action.pos, action.broken }, { nil, nil, nil, nil })
  expect.equality(result.lines[5]:find("▸", 1, true), nil)
  expect.equality(result.lines[5]:find("▾", 1, true), nil)
end

T["row limit"]["rows past the limit are not rendered, so a broken ref there is not marked"] = function()
  local schema = object({
    { "a", { types = { "string" } } },
    { "b", ref_schema("https://x/y", { status = "broken", reason = "remote not loaded" }) },
  })
  local function broken_rows(limit)
    local count = 0
    local result = view(schema, { max_detail_rows = limit })
    for row = 0, #result.lines - 1 do
      if result.rows[row] and result.rows[row].broken then
        count = count + 1
      end
    end
    return count
  end
  expect.equality(broken_rows(3), 0)
  expect.equality(broken_rows(4), 1)
end

T["row limit"]["report is called for a drawn ref broken from its text, and not past the limit"] = function()
  local broken = ref_schema("https://x/y", { status = "broken", reason = "remote not loaded" })
  local schema = object({ { "a", { types = { "string" } } }, { "b", broken } })
  local function reported(limit)
    local refs = {}
    view(schema, {
      max_detail_rows = limit,
      report = function(ref)
        refs[#refs + 1] = ref
      end,
    })
    return refs
  end
  expect.equality(#reported(3), 0)
  local refs = reported(4)
  expect.equality({ #refs, refs[1] == broken.ref }, { 1, true })
end

T["row limit"]["report is not called for a closed or an opened ref"] = function()
  local schema = object({ { "c", ref_schema("#/T", { name = "T" }) } })
  local calls = 0
  view(schema, {
    report = function()
      calls = calls + 1
    end,
  })
  expect.equality(calls, 0)
end

T["row limit"]["icons.problem changes the first character, and the span covers the line"] = function()
  for _, icon in ipairs({ "E", "⚠" }) do
    local result = view(five_rows(), { max_detail_rows = 4, icons = { problem = icon } })
    local last = icon .. " stopped at 4 rows (max_detail_rows)"
    expect.equality(result.lines[5], last)
    expect.equality(spans_on(result, 4), { { last, "OasGlanceProblem" } })
  end
end

T["row limit"]["applies to the operation view"] = function()
  local result = operation_view({
    parameters = {
      { name = "a", ["in"] = "query", pos = POS },
      { name = "b", ["in"] = "query", pos = POS },
      { name = "c", ["in"] = "query", pos = POS },
    },
  }, { max_detail_rows = 4 })
  expect.equality(result.lines[5], "! stopped at 4 rows (max_detail_rows)")
  expect.equality(#result.lines, 5)
end

T["row limit"]["applies to the overview"] = function()
  local diagnostics = {}
  for index = 1, 5 do
    diagnostics[index] = { level = "error", code = "syntax", message = "m", pos = POS }
  end
  local result = detail.overview({ info = { title = "T" }, raw_version = "3.1.0" }, {
    diagnostics = diagnostics,
    max_detail_rows = 6,
  })
  expect.equality(#result.lines, 7)
  expect.equality(result.lines[7], "! stopped at 6 rows (max_detail_rows)")
end

T["row limit"]["applies to help"] = function()
  local result = detail.help({ max_detail_rows = 3 })
  expect.equality(#result.lines, 4)
  expect.equality(result.lines[4], "! stopped at 3 rows (max_detail_rows)")
end

T["row limit"]["a split description counts each row"] = function()
  local result = operation_view({ summary = "one\ntwo\nthree\nfour" }, { max_detail_rows = 3 })
  expect.equality(result.lines, { "GET /a", "one", "two", "! stopped at 3 rows (max_detail_rows)" })
end

T["row limit"]["expanded rows count too"] = function()
  local schema = object({ { "p", ref_schema("#/T", { name = "T", key = "k#/T" }) } })
  local open = {}
  open_action(open, view(schema).rows[2])
  local resolve = recording_resolver({ ["#/T"] = { schema = five_rows() } })
  local result = view(schema, { open = open, resolve = resolve, max_detail_rows = 4 })
  expect.equality(result.lines[5], "! stopped at 4 rows (max_detail_rows)")
end

T["row limit"]["the list pane has no limit"] = function()
  local operations = {}
  for index = 1, 50 do
    operations[index] = { method = "get", path = "/p" .. index, tags = {}, pos = POS }
  end
  local result = list.render(list_document({ groups = { { tag = "t", operations = operations } } }), {
    max_detail_rows = 5,
  })
  expect.equality(#result.lines, 55)
end

T["an alias containing itself"] = function()
  local document = load_text([[
openapi: 3.1.0
components:
  schemas:
    S:
      properties: &p
        a: *p
]])
  local limit = 20
  local result = render_listed(document, "S", { max_detail_rows = limit })
  expect.equality(#result.lines <= limit + 1, true)
  expect.equality(result.lines, { "S  object", "", "  a  ! may be incomplete" })
  expect_span(result, 2, "! may be incomplete", "OasGlanceProblem")
  expect.equality(result.rows[2].broken, nil)

  local codes = vim.tbl_map(function(diagnostic)
    return diagnostic.code
  end, document.diagnostics)
  expect.equality(vim.tbl_contains(codes, "alias-cycle"), true)
end

-- Broken path items

T["broken path item"] = MiniTest.new_set()

local BROKEN_ITEM = {
  path = "/pets",
  tags = {},
  problem = true,
  pos = POS,
  broken = { target = "./paths/pets.yaml", reason = "not found" },
}

T["broken path item"]["the list row is exact, with the icon and reason in OasGlanceBroken"] = function()
  local result = list.render(list_document({ groups = { { tag = "(untagged)", operations = { BROKEN_ITEM } } } }))
  local row = find_row(result, "/pets")
  expect.equality(result.lines[row + 1], " ! ✗       /pets  not found")
  expect_span(result, row, "!", "OasGlanceProblem")
  expect_span(result, row, "✗", "OasGlanceBroken")
  expect_span(result, row, "not found", "OasGlanceBroken")
  expect_span(result, row, "/pets", "OasGlancePath")
  expect.equality(result.rows[row].broken.reason, "not found")
  expect.equality(result.rows[row].select.operation == BROKEN_ITEM, true)
end

local function broken_item_document()
  local dir = assert(vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")))
  dir = dir .. "/broken-item-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "openapi: 3.1.0",
    "paths:",
    "  /a-first:",
    "    get: {}",
    "  /pets:",
    "    $ref: ./paths/pets.yaml",
    "  /z-last:",
    "    get: {}",
    "webhooks:",
    "  lost:",
    "    $ref: ./paths/lost.yaml",
  }, dir .. "/root.yaml")
  local ws = workspace.new({ root = dir })
  return assert(model.load(ws, assert(ws:open_file(dir .. "/root.yaml"))))
end

T["broken path item"]["sits in (untagged) in spec order, and under webhooks in Webhooks"] = function()
  local document = broken_item_document()
  expect.equality(list.render(document).lines, {
    " (untitled)",
    " OpenAPI 3.1.0",
    "",
    "",
    "▾ (untagged) 3",
    "   GET     /a-first",
    " ! ✗       /pets  not found",
    "   GET     /z-last",
    "",
    "▾ Webhooks 1",
    " ! ✗       lost  not found",
  })
end

T["broken path item"]["its detail view has the path, then the broken row with the $ref's pos"] = function()
  local result = detail.operation(BROKEN_ITEM, {})
  expect.equality(result.lines, { "/pets", "✗ ./paths/pets.yaml  not found" })
  expect_span(result, 0, "/pets", "OasGlanceTitle")
  expect_span(result, 1, "✗ ./paths/pets.yaml  not found", "OasGlanceBroken")
  expect.equality(result.rows[1].pos, POS)
  expect.equality(result.rows[1].broken.reason, "not found")
  expect.equality(result.rows[1].toggle, nil)
end

T["broken path item"]["its model row reaches the same view with the real $ref position"] = function()
  local document = broken_item_document()
  local row = document.groups[1].operations[2]
  local result = detail.operation(model.operation(document, row), {})
  expect.equality(result.lines, { "/pets", "✗ ./paths/pets.yaml  not found" })
  expect.equality(result.rows[1].pos.row, 5)
end

-- Problem header

T["problem header"] = MiniTest.new_set()

T["problem header"]["counts in the plural and the singular"] = function()
  local document = one_operation({})
  local two = list.render(document, { problem_count = 2 })
  expect.equality(two.lines[3], " ! 2 problems so far")
  expect_span(two, 2, "! 2 problems so far", "OasGlanceProblem")
  expect.equality(list.render(document, { problem_count = 1 }).lines[3], " ! 1 problem so far")
end

T["problem header"]["with none the row is blank and later rows keep their indices"] = function()
  local document = one_operation({})
  local none = list.render(document)
  local some = list.render(document, { problem_count = 3 })
  expect.equality(none.lines[3], "")
  expect.equality(#none.lines, #some.lines)
  for index = 4, #none.lines do
    expect.equality(none.lines[index], some.lines[index])
  end
end

T["problem header"]["a custom icon reaches the row"] = function()
  local result = list.render(one_operation({}), { problem_count = 1, icons = { problem = "E" } })
  expect.equality(result.lines[3], " E 1 problem so far")
end

-- Overview

local function overview_document()
  return {
    info = { title = "Petstore", version = "1.0.0" },
    raw_version = "3.1.0",
    servers = { { url = "https://api.example.com/v1" } },
  }
end

T["overview"] = MiniTest.new_set()

T["overview"]["with problems follows the diagram"] = function()
  local result = detail.overview(overview_document(), {
    file_name = "petstore.yaml",
    file = "/x/petstore.yaml",
    diagnostics = {
      { level = "error", code = "syntax", message = "unexpected token", pos = { file = "/x/petstore.yaml", row = 41 } },
      {
        level = "error",
        code = "broken-ref",
        message = "./gone.yaml  not found",
        pos = { file = "/x/petstore.yaml", row = 76 },
      },
    },
  })
  expect.equality(result.lines, {
    "Petstore 1.0.0",
    "OpenAPI 3.1.0  petstore.yaml",
    "https://api.example.com/v1",
    "",
    "Problems so far 2",
    "References are checked when opened.",
    "! line 42  unexpected token",
    "✗ line 77  ./gone.yaml  not found",
  })
  expect_span(result, 0, "Petstore 1.0.0", "OasGlanceTitle")
  expect_span(result, 4, "Problems so far 2", "OasGlanceSection")
  expect_span(result, 5, "References are checked when opened.", "OasGlanceHint")
  expect_span(result, 6, "! line 42  unexpected token", "OasGlanceProblem")
  expect_span(result, 7, "✗ line 77  ./gone.yaml  not found", "OasGlanceBroken")
  expect.equality(result.rows[6].pos.row, 41)
  expect.equality(result.rows[7].pos.row, 76)
end

T["overview"]["with none"] = function()
  local result = detail.overview(overview_document(), { diagnostics = {} })
  expect.equality(result.lines, {
    "Petstore 1.0.0",
    "OpenAPI 3.1.0",
    "https://api.example.com/v1",
    "",
    "No problems so far.",
    "References are checked when opened.",
  })
  expect_span(result, 4, "No problems so far.", "OasGlanceHint")
end

T["overview"]["uses the document's diagnostics by default"] = function()
  local document = overview_document()
  document.diagnostics = { { level = "warn", code = "structure", message = "m", pos = { row = 0 } } }
  expect.equality(detail.overview(document).lines[5], "Problems so far 1")
end

T["overview"]["an info diagnostic goes under Notes and is not counted"] = function()
  local info = { level = "info", code = "ref-siblings", message = "neutral", pos = { row = 1 } }
  local warn = { level = "warn", code = "structure", message = "bad", pos = { row = 2 } }
  local only_info = detail.overview(overview_document(), { diagnostics = { info } })
  expect.equality(vim.list_slice(only_info.lines, 5), {
    "No problems so far.",
    "References are checked when opened.",
    "",
    "Notes 1",
    "  line 2  neutral",
  })
  expect_span(only_info, 7, "Notes 1", "OasGlanceSection")
  expect_span(only_info, 8, "line 2  neutral", "OasGlanceMuted")

  local both = detail.overview(overview_document(), { diagnostics = { info, warn } })
  expect.equality(vim.list_slice(both.lines, 5), {
    "Problems so far 1",
    "References are checked when opened.",
    "! line 3  bad",
    "",
    "Notes 1",
    "  line 2  neutral",
  })
  expect.equality(detail.problem_count({ info, warn }), 1)
end

T["overview"]["a diagnostic in another file names it"] = function()
  local result = detail.overview(overview_document(), {
    file = "/x/root.yaml",
    diagnostics = {
      { level = "error", code = "syntax", message = "m", pos = { file = "/x/sub/damaged.yaml", row = 2 } },
    },
  })
  expect.equality(result.lines[7], "! line 3  m  (damaged.yaml)")
end

-- Operation

T["operation"] = MiniTest.new_set()

T["operation"]["follows the diagram"] = function()
  local document = petstore()
  local row
  for _, operation in ipairs(document.groups[1].operations) do
    if operation.path == "/pets/{petId}" and operation.method == "get" then
      row = operation
    end
  end
  local result = detail.operation(model.operation(document, row), { resolve = resolver(document) })
  expect.equality(result.lines, {
    "GET /pets/{petId}",
    "Info for a specific pet",
    "pets · showPetById",
    "",
    "Parameters",
    "  petId*   path   string",
    "    The id of the pet",
    "  verbose  query  boolean = false",
    "",
    "Responses",
    "▾ 200 Expected response",
    "  application/json",
    "  ▸ → Pet",
    "▸ default Unexpected error",
  })
  expect_span(result, 0, "GET /pets/{petId}", "OasGlanceTitle")
  expect_span(result, 2, "pets · showPetById", "OasGlanceMuted")
  expect_span(result, 4, "Parameters", "OasGlanceSection")
  expect_span(result, 5, "path", "OasGlanceLocation")
  expect_span(result, 10, "200", "OasGlanceStatus2xx")
  expect_span(result, 10, "Expected response", "OasGlanceDescription")
  expect_span(result, 13, "default", "OasGlanceStatusOther")
end

T["operation"]["expanding the ref in place shows the target, and Pet.parent as the cycle row"] = function()
  local document = petstore()
  local row
  for _, operation in ipairs(document.groups[1].operations) do
    if operation.path == "/pets/{petId}" and operation.method == "get" then
      row = operation
    end
  end
  local operation = model.operation(document, row)
  local open = {}
  local options = { resolve = resolver(document), open = open }
  local closed = detail.operation(operation, options)
  open_action(open, closed.rows[find_row(closed, "→ Pet")])

  local result = detail.operation(operation, options)
  local expanded = find_row(result, "→ Pet")
  expect.equality(result.lines[expanded + 1], "  ▾ → Pet")
  expect.equality(result.lines[expanded + 2], "      id*       integer<int64>  ro")
  expect.equality(result.lines[find_row(result, "parent") + 1], "      parent    ↻ Pet  cycle")
  expect.equality(result.lines[find_row(result, "owner") + 1], "    ▸ owner     → Owner (common.yaml)")
  expect.equality(result.lines[#result.lines], "▸ default Unexpected error")
end

T["operation"]["a deprecated operation says so in words"] = function()
  local result = operation_view({ deprecated = true })
  expect.equality(result.lines[1], "GET /a  deprecated")
  expect_span(result, 0, "deprecated", "OasGlanceDeprecated")
end

T["operation"]["a problem element says it may be incomplete"] = function()
  local result = operation_view({ problem = true })
  expect.equality(result.lines[2], "! This element may be incomplete.")
  expect_span(result, 1, "! This element may be incomplete.", "OasGlanceProblem")
end

T["operation"]["request body, headers, security and servers"] = function()
  local result = operation_view({
    request_body = {
      required = true,
      description = "The pet",
      content = { { name = "application/json", schema = { types = { "string" } } } },
      pos = POS,
    },
    responses = {
      {
        status = "200",
        headers = { { name = "X-Rate", schema = { types = { "integer" } }, pos = POS } },
        pos = POS,
      },
    },
    security = { { { name = "key", scopes = { "read", "write" } } } },
    servers = { { url = "https://x" } },
  })
  expect.equality(result.lines, {
    "GET /a",
    "",
    "Request body  required",
    "  The pet",
    "  application/json",
    "    string",
    "",
    "Responses",
    "▾ 200",
    "  X-Rate  integer",
    "",
    "Security",
    "  key  read, write",
    "",
    "Servers",
    "  https://x",
  })
end

T["operation"]["a media type's examples and a schema's example show"] = function()
  local result = operation_view({
    responses = {
      {
        status = "200",
        content = { { name = "a/b", examples = { { value = { type = "string", text = "hi" }, pos = POS } } } },
        pos = POS,
      },
    },
  })
  expect.equality(result.lines[#result.lines], "    example  hi")
  local schema = view({ types = { "string" }, examples = { { type = "string", text = "x" } }, pos = POS }, {})
  expect.equality(schema.lines, { "S  string", "example: x" })
end

T["schema view"] = MiniTest.new_set()

T["schema view"]["follows the diagram"] = function()
  local result = render_listed(petstore(), "Pet")
  expect.equality(result.lines, {
    "Pet  object",
    "A pet in the store",
    "required: id, name",
    "",
    "  id*       integer<int64>  ro",
    "  name*     string  len 1..64",
    '  status    "available" | "sold"',
    "  weight    number  > 0, <= 100",
    "  nickname  string | null",
    "  tags      string[]  unique",
    "  labels    map<string, string>",
    "▸ owner     → Owner (common.yaml)",
    "  parent    ↻ Pet  cycle",
    "  legacy    string  deprecated",
    "▸ gone      → gone (gone.yaml)",
    "▾ oneOf     by petType",
    "  ▸ → Cat",
    "  ▸ → Dog",
  })
end

T["schema view"]["opening gone replaces the row with the broken form"] = function()
  local document = petstore()
  local open = {}
  local first = render_listed(document, "Pet", { open = open })
  open_action(open, first.rows[find_row(first, "gone")])
  local result = render_listed(document, "Pet", { open = open })
  expect.equality(result.lines[find_row(result, "gone") + 1], "  gone      ✗ ./gone.yaml  not found")
end

T["schema view"]["a listed schema that is a $ref shows one closed row"] = function()
  local result = view(ref_schema("./pet.yaml", { name = "pet", file = "pet.yaml" }), {})
  expect.equality(result.lines, { "S", "", "▸ → pet (pet.yaml)" })
end

T["schema view"]["a problem schema says so on its title"] = function()
  local result = view({ types = { "object" }, problem = true, pos = POS }, {})
  expect.equality(result.lines[1], "S  object  ! may be incomplete")
end

T["schema view"]["an array of refs offers the ref when opened as a target"] = function()
  local target = { types = { "array" }, items = ref_schema("#/Item", { name = "Item", key = "k#/Item" }), pos = POS }
  local schema = object({ { "p", ref_schema("#/List", { name = "List", key = "k#/List" }) } })
  local open = {}
  open_action(open, view(schema).rows[2])
  local resolve = recording_resolver({ ["#/List"] = { schema = target } })
  expect.equality(view(schema, { open = open, resolve = resolve }).lines, {
    "S  object",
    "",
    "▾ p  → List  → Item[]",
    "  ▸ → Item",
  })
end

T["schema view"]["a 3.1 $ref's own keywords show beside the target's rows"] = function()
  local holder = ref_schema("#/T", { name = "T", key = "k#/T" })
  holder.properties = { { name = "own", schema = { types = { "string" } }, pos = POS } }
  local schema = object({ { "p", holder } })
  local open = {}
  open_action(open, view(schema).rows[2])
  local resolve = recording_resolver({ ["#/T"] = { schema = object({ { "x", { types = { "integer" } } } }) } })
  expect.equality(view(schema, { open = open, resolve = resolve }).lines, {
    "S  object",
    "",
    "▾ p  → T",
    "    x    integer",
    "    own  string",
  })
end

-- Help

T["help"] = MiniTest.new_set()

T["help"]["lists both panes' keys in OasGlanceHint"] = function()
  local result = detail.help()
  expect.equality(result.lines[1], "List pane")
  expect_span(result, 0, "List pane", "OasGlanceSection")
  expect.equality(result.lines[find_row(result, "Detail pane") + 2], "  <CR>, za  Expand or collapse the row")
  expect.equality(result.lines[2], "  <CR>  Toggle a group, or focus the detail pane")
  expect_span(result, 1, "  <CR>  Toggle a group, or focus the detail pane", "OasGlanceHint")
end

T["help"]["shows the user's keys and hides a disabled action"] = function()
  local result = detail.help({ keymaps = { list = { filter = "<leader>f", help = false }, detail = { toggle = "x" } } })
  local text = table.concat(result.lines, "\n")
  expect.equality(text:find("  <leader>f  Filter", 1, true) ~= nil, true)
  expect.equality(text:find("  x  Expand or collapse the row", 1, true) ~= nil, true)
  local list_part = table.concat(vim.list_slice(result.lines, 1, find_row(result, "Detail pane")), "\n")
  expect.equality(list_part:find("Show this help", 1, true), nil)
end

T["help"]["lists curl after source in both panes"] = function()
  local result = detail.help()
  local after = {}
  for index, line in ipairs(result.lines) do
    if line == "  gs  Jump to source" then
      after[#after + 1] = result.lines[index + 1]
    end
  end
  expect.equality(
    after,
    { "  gc  Open a cURL command for the operation", "  gc  Open a cURL command for the operation" }
  )
  expect.equality(find_row(result, "  gc  ") < find_row(result, "Detail pane"), true)
end

-- Icons

T["icons"] = MiniTest.new_set()

local ASCII = {
  expanded = "v",
  collapsed = ">",
  ref = "->",
  cycle = "@",
  broken = "x",
  required = "+",
  deprecated = "-",
  problem = "E",
}

T["icons"]["ASCII overrides reach every row kind"] = function()
  local open = {}
  local function render()
    return view(
      object({
        { "req", { types = { "string" } }, true },
        { "ref", ref_schema("#/T", { name = "T" }) },
        { "cyc", ref_schema("#/C", { name = "C", key = "k#/S" }) },
        { "bad", ref_schema("http://x", { status = "broken", reason = "remote not loaded" }) },
        { "inl", object({ { "x", { types = { "string" } } } }) },
      }),
      { icons = ASCII, key = "k#/S", open = open }
    )
  end
  expect.equality(render().lines, {
    "S  object",
    "",
    "  req+  string",
    "> ref   -> T",
    "  cyc   @ C  cycle",
    "  bad   x http://x  remote not loaded",
    "v inl   object",
    "    x  string",
  })
end

T["icons"]["ASCII overrides reach the list"] = function()
  local result = list.render(one_operation({ deprecated = true }), { icons = ASCII, problem_count = 1 })
  expect.equality(result.lines[3], " E 1 problem so far")
  expect.equality(result.lines[5], "v t 1")
  expect.equality(result.lines[6], " - GET     /a")
end

T["icons"]["a part left out keeps its default"] = function()
  local result = list.render(one_operation({}), { icons = { problem = "E" } })
  expect.equality(result.lines[5], "▾ t 1")
end

-- Order

T["order"] = MiniTest.new_set()

T["order"]["rendering twice is identical, and non-sorted keys stay in order"] = function()
  local properties = {}
  for index = 40, 1, -1 do
    properties[#properties + 1] = string.format("        k%02d: { type: string }", (index * 7) % 41)
  end
  local text = "openapi: 3.1.0\ncomponents:\n  schemas:\n    S:\n      properties:\n"
    .. table.concat(properties, "\n")
    .. "\n"
  local document = load_text(text)
  local first = render_listed(document, "S")
  local second = render_listed(document, "S")
  expect.equality(first, second)
  for index = 40, 1, -1 do
    expect.equality(first.lines[3 + 40 - index]:sub(3, 5), string.format("k%02d", (index * 7) % 41))
  end
end

T["order"]["renderers read no windows"] = function()
  local calls = {}
  local originals = {}
  for _, name in ipairs({ "nvim_get_current_win", "nvim_win_get_width", "nvim_list_wins", "nvim_win_get_cursor" }) do
    originals[name] = vim.api[name]
    vim.api[name] = function(...)
      calls[#calls + 1] = name
      return originals[name](...)
    end
  end
  local ok, err = pcall(function()
    local document = petstore()
    list.render(document)
    render_listed(document, "Pet")
    detail.overview(document)
    detail.help()
  end)
  for name, original in pairs(originals) do
    vim.api[name] = original
  end
  expect.equality({ ok, err }, { true, nil })
  expect.equality(calls, {})
end

-- Filter in the list

T["list filter"] = MiniTest.new_set()

T["list filter"]["the filter line replaces the three header rows"] = function()
  local result = list.render(petstore(), { filter = "tag:pets path:/pets", problem_count = 2 })
  expect.equality(vim.list_slice(result.lines, 1, 3), { " Filter: tag:pets path:/pets", "", "▾ pets 4" })
  expect_span(result, 0, "Filter: tag:pets path:/pets", "OasGlanceFilter")
  expect.equality(result.rows[0].select.kind, "overview")
end

T["list filter"]["counts show matches, and groups with none are gone"] = function()
  local result = list.render(petstore(), { filter = "/store" })
  expect.equality(result.lines, { " Filter: /store", "", "▾ store 1", "   GET     /store/inventory" })
end

T["list filter"]["a closed group opens during a filter, and its state returns after"] = function()
  local document = petstore()
  local first = list.render(document)
  local open = { [first.rows[4].toggle] = false }
  expect.equality(list.render(document, { open = open, filter = "/store" }).lines[3], "▾ store 1")
  expect.equality(list.render(document, { open = open, filter = "tag:pets" }).lines[3], "▾ pets 4")
  expect.equality(list.render(document, { open = open }).lines[5], "▸ pets 4")
end

T["list filter"]["no match says so under the filter line"] = function()
  local result = list.render(petstore(), { filter = "zebra" })
  expect.equality(result.lines, { " Filter: zebra", "", " No matches" })
  expect_span(result, 2, "No matches", "OasGlanceHint")
end

T["list filter"]["schema rows are hidden by path:, and webhook rows match on their name"] = function()
  expect.equality(
    list.render(petstore(), { filter = "path:Pet" }).lines[#list.render(petstore(), {
      filter = "path:Pet",
    }).lines],
    "   POST    newPet"
  )
  local schemas = list.render(petstore(), { filter = "schema:Pet" })
  expect.equality(schemas.lines, { " Filter: schema:Pet", "", "▾ Schemas 2", "   NewPet", "   Pet" })
end

T["list filter"]["matched text gets OasGlanceMatch on bytes of the row"] = function()
  local result = list.render(one_operation({ path = "/日本語/pets" }), { filter = "path:PETS" })
  local row = find_row(result, "GET")
  expect_span(result, row, "pets", "OasGlanceMatch")
  local schemas = list.render(list_document({ schemas = { { name = "PetStatus", pos = POS } } }), { filter = "status" })
  expect_span(schemas, find_row(schemas, "PetStatus"), "Status", "OasGlanceMatch")
  local tags = list.render(one_operation({}), { filter = "tag:t" })
  expect_span(tags, find_row(tags, "t 1"), "t", "OasGlanceMatch")
end

T["list filter"]["a match span has a priority, so it overlays the path's span"] = function()
  local result = list.render(one_operation({ path = "/pets" }), { filter = "pets" })
  local found = 0
  for _, span in ipairs(result.spans) do
    if span.group == "OasGlanceMatch" then
      found = found + 1
      expect.equality(type(span.priority), "number")
    elseif span.group == "OasGlancePath" then
      expect.equality(span.priority, nil)
    end
  end
  expect.equality(found, 1)
end

T["list filter"]["uses the same matcher as the filter module"] = function()
  local row = { method = "get", path = "/a", tags = { "t" }, pos = POS }
  expect.equality((filter.match(filter.parse("tag:t"), row)), true)
  expect.equality(#list.render(one_operation(row), { filter = "tag:t" }).lines, 4)
end

return T
