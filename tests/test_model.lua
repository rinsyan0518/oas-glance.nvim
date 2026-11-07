local model = require("oas-glance.internal.model")
local refs = require("oas-glance.internal.refs")
local tree = require("oas-glance.internal.tree")
local workspace = require("oas-glance.internal.workspace")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local FIXTURES = "tests/fixtures/"
local MULTI = vim.uv.fs_realpath(FIXTURES .. "multi")

local function load_text(text, opts)
  local ws = workspace.new(opts)
  local doc = assert(ws:open_text(text, { bufnr = 1 }))
  local document = assert(model.load(ws, doc))
  return document, doc, ws
end

local function load_fixture(name)
  local ws = workspace.new({ root = vim.uv.fs_realpath(FIXTURES) })
  local doc = assert(ws:open_file(FIXTURES .. name))
  local document = assert(model.load(ws, doc))
  return document, doc, ws
end

local function load_multi()
  local ws = workspace.new({ root = MULTI })
  local doc = assert(ws:open_file(MULTI .. "/root.yaml"))
  local document = assert(model.load(ws, doc))
  return document, doc, ws
end

local function find(list, field, value)
  for _, item in ipairs(list) do
    if item[field] == value then
      return item
    end
  end
  error("no item with " .. field .. " = " .. tostring(value), 0)
end

local function all_operations(document)
  local operations = {}
  for _, group in ipairs(document.groups) do
    vim.list_extend(operations, group.operations)
  end
  return operations
end

local function operation_ref(document, path, method)
  for _, operation in ipairs(all_operations(document)) do
    if operation.path == path and operation.method == method then
      return operation
    end
  end
  error("no operation " .. method .. " " .. path, 0)
end

local function schema_doc(version, schema_lines)
  local lines = {
    "openapi: " .. version,
    "info: { title: t, version: '1' }",
    "paths: {}",
    "components:",
    "  schemas:",
    "    S:",
  }
  for _, line in ipairs(schema_lines) do
    lines[#lines + 1] = "      " .. line
  end
  return table.concat(lines, "\n") .. "\n"
end

local function build(version, schema_lines)
  local document = load_text(schema_doc(version, schema_lines))
  return model.schema(document, document.schemas[1]), document
end

local function codes_of(diagnostics)
  local codes = {}
  for _, diagnostic in ipairs(diagnostics) do
    codes[#codes + 1] = diagnostic.code
  end
  return codes
end

local STRIPPED = {
  version = true,
  raw_version = true,
  pos = true,
  key_pos = true,
  node = true,
  path_item = true,
  key = true,
  webhooks = true,
  diagnostics = true,
}

-- Positions, node handles, and keys holding a file's path differ by construction.
local function strip(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    local hidden = type(key) == "string" and (STRIPPED[key] or key:sub(1, 1) == "_")
    if not hidden then
      result[key] = strip(item)
    end
  end
  return result
end

local function comparable(document)
  local operations = {}
  for _, operation in ipairs(all_operations(document)) do
    operations[#operations + 1] = strip(model.operation(document, operation))
  end
  local schemas = {}
  for _, schema_ref in ipairs(document.schemas) do
    schemas[#schemas + 1] = strip(model.schema(document, schema_ref))
  end
  return { document = strip(document), operations = operations, schemas = schemas }
end

T["normalisation"] = MiniTest.new_set()

T["normalisation"]["3.0 nullable appends null"] = function()
  local schema = build("3.0.3", { "type: string", "nullable: true" })
  expect.equality(schema.types, { "string", "null" })
end

T["normalisation"]["3.0 nullable false appends nothing"] = function()
  local schema = build("3.0.3", { "type: string", "nullable: false" })
  expect.equality(schema.types, { "string" })
end

T["normalisation"]["3.1 type list keeps source order"] = function()
  local schema = build("3.1.0", { 'type: ["null", string]' })
  expect.equality(schema.types, { "null", "string" })
end

T["normalisation"]["3.1 nullable is an unknown keyword"] = function()
  local schema = build("3.1.0", { "type: string", "nullable: true" })
  expect.equality(schema.types, { "string" })
  expect.equality(schema.extra[1].key, "nullable")
end

T["normalisation"]["3.0 boolean exclusiveMinimum with minimum"] = function()
  local schema = build("3.0.3", { "minimum: 5", "exclusiveMinimum: true" })
  expect.equality(schema.min, { value = "5", exclusive = true })
end

T["normalisation"]["3.0 boolean exclusiveMaximum false with maximum"] = function()
  local schema = build("3.0.3", { "maximum: 5", "exclusiveMaximum: false" })
  expect.equality(schema.max, { value = "5", exclusive = false })
end

T["normalisation"]["3.1 numeric exclusiveMinimum alone"] = function()
  local schema = build("3.1.0", { "exclusiveMinimum: 5" })
  expect.equality(schema.min, { value = "5", exclusive = true })
end

T["normalisation"]["example and examples both reach examples"] = function()
  local schema = build("3.1.0", { "examples: [a, 1]", "example: b" })
  local texts = {}
  for _, example in ipairs(schema.examples) do
    texts[#texts + 1] = example.text
  end
  expect.equality(texts, { "a", "1", "b" })
end

T["normalisation"]["3.1 webhooks reach webhooks"] = function()
  local document = load_fixture("petstore-31.yaml")
  expect.equality(#document.webhooks, 1)
  expect.equality({ document.webhooks[1].path, document.webhooks[1].method }, { "newPet", "post" })
end

T["normalisation"]["3.0 has no webhooks"] = function()
  local document = load_text("openapi: 3.0.3\ninfo: {}\npaths: {}\nwebhooks:\n  a:\n    post: {}\n")
  expect.equality(document.webhooks, {})
end

T["normalisation"]["3.1 components/pathItems are reached through refs"] = function()
  local document = load_text([[
openapi: 3.1.0
paths:
  /a:
    $ref: "#/components/pathItems/A"
components:
  pathItems:
    A:
      get:
        summary: Through a ref
]])
  expect.equality(all_operations(document)[1].summary, "Through a ref")
end

T["normalisation"]["no paths in 3.0 is an empty list with a diagnostic"] = function()
  local document = load_text("openapi: 3.0.3\ninfo: {}\n")
  expect.equality(document.groups, {})
  expect.equality(codes_of(document.diagnostics), { "structure" })
end

T["normalisation"]["no paths in 3.1 is an empty list with none"] = function()
  local document = load_text("openapi: 3.1.0\ninfo: {}\n")
  expect.equality(document.groups, {})
  expect.equality(document.diagnostics, {})
end

T["normalisation"]["$ref siblings in a 3.0 schema are ignored, with an info diagnostic"] = function()
  local schema, document = build("3.0.3", { "$ref: '#/x'", "title: Ignored" })
  expect.equality(schema.ref.target, "#/x")
  expect.equality(schema.title, nil)
  expect.equality(codes_of(document.diagnostics), { "ref-siblings" })
  expect.equality(document.diagnostics[1].level, "info")
end

T["normalisation"]["$ref siblings in a 3.1 schema are kept"] = function()
  local schema, document = build("3.1.0", { "$ref: '#/x'", "title: Kept" })
  expect.equality(schema.ref.target, "#/x")
  expect.equality(schema.title, "Kept")
  expect.equality(document.diagnostics, {})
end

local REFERENCE_DOC = [[
openapi: %s
paths:
  /a:
    get:
      parameters:
        - $ref: "#/components/parameters/p"
          summary: Own summary
          description: Own description
          in: path
components:
  parameters:
    p:
      name: p
      in: query
      description: Target description
]]

T["normalisation"]["a 3.1 Reference Object overrides only summary and description"] = function()
  local document = load_text(REFERENCE_DOC:format("3.1.0"))
  local operation = model.operation(document, operation_ref(document, "/a", "get"))
  expect.equality(operation.parameters[1].description, "Own description")
  expect.equality(operation.parameters[1]["in"], "query")
  expect.equality(document.diagnostics, {})
end

T["normalisation"]["a 3.0 Reference Object ignores its siblings, with an info diagnostic"] = function()
  local document = load_text(REFERENCE_DOC:format("3.0.3"))
  local operation = model.operation(document, operation_ref(document, "/a", "get"))
  expect.equality(operation.parameters[1].description, "Target description")
  expect.equality(codes_of(document.diagnostics), { "ref-siblings" })
end

T["normalisation"]["compositions are not merged and keep source order"] = function()
  local schema = build("3.1.0", {
    "oneOf:",
    "  - type: string",
    "allOf:",
    "  - type: integer",
    "  - type: number",
    "anyOf: []",
  })
  expect.equality(
    vim.tbl_map(function(composition)
      return { composition.kind, #composition.members }
    end, schema.compositions),
    { { "oneOf", 1 }, { "allOf", 2 }, { "anyOf", 0 } }
  )
  expect.equality(schema.types, {})
end

T["normalisation"]["unknown keywords reach extra in source order"] = function()
  local schema = build("3.1.0", { "if: {}", "type: string", "then: {}", "$dynamicRef: x", "x-own: 1" })
  expect.equality(
    vim.tbl_map(function(extra)
      return extra.key
    end, schema.extra),
    { "if", "then", "$dynamicRef", "x-own" }
  )
end

T["bounds"] = MiniTest.new_set()

for _, row in ipairs({
  { "a tie goes to the exclusive", "0", "0", { value = "0", exclusive = true } },
  { "the inclusive is tighter", "5", "0", { value = "5", exclusive = false } },
  { "the exclusive is tighter", "0", "5", { value = "5", exclusive = true } },
  { "a tie by number keeps the exclusive's raw text", "1.0", "1", { value = "1", exclusive = true } },
}) do
  T["bounds"]["minimum: " .. row[1]] = function()
    local schema = build("3.1.0", { "minimum: " .. row[2], "exclusiveMinimum: " .. row[3] })
    expect.equality(schema.min, row[4])
  end
end

for _, row in ipairs({
  { "a tie goes to the exclusive", "0", "0", { value = "0", exclusive = true } },
  { "the inclusive is tighter", "0", "5", { value = "0", exclusive = false } },
  { "the exclusive is tighter", "5", "0", { value = "0", exclusive = true } },
  { "a tie by number keeps the exclusive's raw text", "1.0", "1", { value = "1", exclusive = true } },
}) do
  T["bounds"]["maximum: " .. row[1]] = function()
    local schema = build("3.1.0", { "maximum: " .. row[2], "exclusiveMaximum: " .. row[3] })
    expect.equality(schema.max, row[4])
  end
end

T["schema fields"] = MiniTest.new_set()

T["schema fields"]["read every keyword"] = function()
  local schema = build("3.1.0", {
    "title: Title",
    "description: Described",
    "type: string",
    "format: email",
    "const: x",
    "default: 1.50",
    "deprecated: true",
    "readOnly: true",
    "writeOnly: false",
    "minLength: 1",
    "maxLength: 64",
    "minItems: 2",
    "uniqueItems: true",
    "pattern: ^a$",
    "multipleOf: 2.50",
  })
  expect.equality(schema.title, "Title")
  expect.equality(schema.description, "Described")
  expect.equality(schema.format, "email")
  expect.equality({ schema.const.type, schema.const.text }, { "string", "x" })
  expect.equality({ schema.default.type, schema.default.text }, { "float", "1.50" })
  expect.equality({ schema.deprecated, schema.read_only, schema.write_only }, { true, true, false })
  expect.equality(schema.length, { min = "1", max = "64" })
  expect.equality(schema.item_count, { min = "2" })
  expect.equality(schema.unique, true)
  expect.equality(schema.pattern, "^a$")
  expect.equality(schema.multiple_of, "2.50")
end

T["schema fields"]["properties keep order and mark required"] = function()
  local schema = build("3.1.0", {
    "required: [a, z]",
    "properties:",
    "  z: { type: string }",
    "  m: { type: integer }",
    "  a: { type: number }",
  })
  expect.equality(schema.required, { "a", "z" })
  expect.equality(
    vim.tbl_map(function(property)
      return { property.name, property.required, property.schema.types[1] }
    end, schema.properties),
    { { "z", true, "string" }, { "m", false, "integer" }, { "a", true, "number" } }
  )
end

T["schema fields"]["nested forms"] = function()
  local schema = build("3.1.0", {
    "additionalProperties: { type: string }",
    "patternProperties:",
    "  ^x: { type: integer }",
    "items: { type: boolean }",
    "prefixItems:",
    "  - { type: number }",
    "not: { type: 'null' }",
    "discriminator:",
    "  propertyName: kind",
    "  mapping:",
    "    a: '#/A'",
  })
  expect.equality(schema.additional.types, { "string" })
  expect.equality(schema.pattern_properties[1].pattern, "^x")
  expect.equality(schema.pattern_properties[1].schema.types, { "integer" })
  expect.equality(schema.items.types, { "boolean" })
  expect.equality(schema.prefix_items[1].types, { "number" })
  expect.equality(schema.not_schema.types, { "null" })
  expect.equality(schema.discriminator, { property = "kind", mapping = { { value = "a", target = "#/A" } } })
end

T["schema fields"]["additionalProperties false stays a boolean"] = function()
  expect.equality(build("3.1.0", { "additionalProperties: false" }).additional, false)
end

T["schema fields"]["boolean schemas"] = function()
  local schema = build("3.1.0", { "properties:", "  yes_schema: true", "  no_schema: false" })
  expect.equality(schema.properties[1].schema.boolean, true)
  expect.equality(schema.properties[2].schema.boolean, false)
end

T["schema fields"]["a large number and 1.0 stay exact"] = function()
  local schema = build("3.1.0", { "maximum: 123456789012345678901234567890", "default: 1.0" })
  expect.equality(schema.max.value, "123456789012345678901234567890")
  expect.equality(schema.default.text, "1.0")
end

T["schema fields"]["an alias reaches one Schema, not a copy"] = function()
  local schema = build("3.1.0", {
    "properties:",
    "  a: &shared { type: string }",
    "  b: *shared",
  })
  expect.equality(schema.properties[1].schema == schema.properties[2].schema, true)
end

T["schema fields"]["an alias cycle ends"] = function()
  local schema, document = build("3.1.0", { "properties: &p", "  a: *p" })
  expect.equality(schema.properties[1].schema.problem, true)
  expect.equality(codes_of(document.diagnostics), { "alias-cycle" })
end

T["schema fields"]["inline nesting past max_depth stops"] = function()
  local lines = {}
  for depth = 0, 4 do
    lines[#lines + 1] = string.rep("  ", depth * 2) .. "properties:"
    lines[#lines + 1] = string.rep("  ", depth * 2 + 1) .. "a:"
  end
  lines[#lines + 1] = string.rep("  ", 10) .. "type: string"
  local document = load_text(schema_doc("3.1.0", lines), { max_depth = 2 })
  local schema = model.schema(document, document.schemas[1])
  local level = schema.properties[1].schema.properties[1].schema.properties[1].schema
  expect.equality(level.too_deep, true)
  expect.equality(level.properties, nil)
end

T["same API"] = MiniTest.new_set()

T["same API"]["3.0 and 3.1 give an equal model"] = function()
  local v30 = comparable(load_fixture("petstore-30.yaml"))
  local v31 = comparable(load_fixture("petstore-31.yaml"))
  expect.equality(#v31.operations, 6)
  expect.equality(v30, v31)
end

T["same API"]["the JSON form gives the same model as 3.1"] = function()
  local json_document = load_fixture("petstore.json")
  local yaml_document = load_fixture("petstore-31.yaml")
  expect.equality(comparable(json_document), comparable(yaml_document))
  expect.equality(#yaml_document.webhooks, 1)
  expect.equality(strip(json_document.webhooks), strip(yaml_document.webhooks))
end

T["same API"]["the fixtures are clean"] = function()
  for _, name in ipairs({ "petstore-30.yaml", "petstore-31.yaml", "petstore.json" }) do
    local document, doc = load_fixture(name)
    comparable(document)
    expect.equality({ name = name, error = tree.has_error(doc), diagnostics = document.diagnostics }, {
      name = name,
      error = false,
      diagnostics = {},
    })
  end
end

T["same API"]["the versions differ as the source does"] = function()
  local v30 = load_fixture("petstore-30.yaml")
  local v31 = load_fixture("petstore-31.yaml")
  expect.equality({ v30.version, v30.raw_version }, { "3.0", "3.0.3" })
  expect.equality({ v31.version, v31.raw_version }, { "3.1", "3.1.0" })
end

T["petstore"] = MiniTest.new_set()

T["petstore"]["follows the diagrams"] = function()
  local document = load_fixture("petstore-31.yaml")
  expect.equality(document.info.title, "Petstore")
  expect.equality(document.servers[1].url, "https://api.example.com/v1")

  local shape = {}
  for _, group in ipairs(document.groups) do
    shape[#shape + 1] = { group.tag, #group.operations }
  end
  expect.equality(shape, { { "pets", 4 }, { "store", 1 }, { "(untagged)", 1 } })

  local names = vim.tbl_map(function(schema_ref)
    return schema_ref.name
  end, document.schemas)
  expect.equality(names, { "Error", "NewPet", "Pet" })
end

T["petstore"]["builds the operation in the diagram"] = function()
  local document = load_fixture("petstore-31.yaml")
  local operation = model.operation(document, operation_ref(document, "/pets/{petId}", "get"))
  expect.equality(operation.summary, "Info for a specific pet")
  expect.equality(operation.operation_id, "showPetById")
  expect.equality(operation.parameters[1].name, "petId")
  expect.equality(operation.parameters[1].required, true)
  expect.equality(operation.parameters[2].schema.default.text, "false")
  expect.equality(operation.responses[1].status, "200")
  expect.equality(operation.responses[2].status, "default")
  expect.equality(operation.responses[1].content[1].schema.ref.name, "Pet")
end

T["petstore"]["builds the schema in the diagram, with Pet.parent referring to Pet"] = function()
  local document, doc = load_fixture("petstore-31.yaml")
  local schema = model.schema(document, find(document.schemas, "name", "Pet"))
  local function property(name)
    return find(schema.properties, "name", name).schema
  end
  expect.equality(property("parent").ref.key, doc.identity .. "#/components/schemas/Pet")
  expect.equality(property("owner").ref.name, "Owner")
  expect.equality(property("owner").ref.file, "common.yaml")
  expect.equality(property("gone").ref.name, "gone")
  expect.equality(schema.compositions[1].kind, "oneOf")
  expect.equality(schema.discriminator.property, "petType")
end

T["petstore"]["a deprecated operation is marked"] = function()
  local document = load_fixture("petstore-31.yaml")
  expect.equality(operation_ref(document, "/pets/{petId}", "delete").deprecated, true)
  expect.equality(operation_ref(document, "/pets", "get").deprecated, false)
end

T["groups"] = MiniTest.new_set()

T["groups"]["top-level tags, then first seen, then untagged"] = function()
  local document = load_text([[
openapi: 3.1.0
tags:
  - name: declared-b
  - name: unused
  - name: declared-a
paths:
  /1:
    get: { tags: [seen-z] }
  /2:
    get: {}
  /3:
    get: { tags: [declared-a] }
  /4:
    get: { tags: [seen-y] }
  /5:
    get: { tags: [declared-b] }
]])
  local tags = vim.tbl_map(function(group)
    return group.tag
  end, document.groups)
  expect.equality(tags, { "declared-b", "declared-a", "seen-z", "seen-y", "(untagged)" })
end

T["groups"]["an operation with several tags appears under each"] = function()
  local document = load_text("openapi: 3.1.0\npaths:\n  /a:\n    get: { tags: [x, y] }\n")
  expect.equality(document.groups[1].operations[1] == document.groups[2].operations[1], true)
  expect.equality({ document.groups[1].tag, document.groups[2].tag }, { "x", "y" })
end

T["groups"]["a tag's description reaches its group"] = function()
  local document =
    load_text("openapi: 3.1.0\ntags:\n  - { name: x, description: D }\npaths:\n  /a:\n    get: { tags: [x] }\n")
  expect.equality(document.groups[1].description, "D")
end

T["order"] = MiniTest.new_set()

T["order"]["many keys in a non-sorted order keep spec order"] = function()
  local paths, properties, schemas, expected_paths, expected_properties, expected_schemas = {}, {}, {}, {}, {}, {}
  for index = 40, 1, -1 do
    local name = string.format("k%02d", (index * 7) % 41)
    paths[#paths + 1] = string.format("  /%s:\n    get: {}", name)
    properties[#properties + 1] = string.format("          %s: {}", name)
    schemas[#schemas + 1] = string.format("    %s: {}", name)
    expected_paths[#expected_paths + 1] = "/" .. name
    expected_properties[#expected_properties + 1] = name
    expected_schemas[#expected_schemas + 1] = name
  end
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    table.concat(paths, "\n"),
    "components:",
    "  schemas:",
    table.concat(schemas, "\n"),
    "    Z:",
    "      properties:",
    table.concat(
      vim.tbl_map(function(line)
        return line:sub(3)
      end, properties),
      "\n"
    ),
    "",
  }, "\n")
  local document = load_text(text)

  expect.equality(
    vim.tbl_map(function(operation)
      return operation.path
    end, all_operations(document)),
    expected_paths
  )

  local schema_names = vim.tbl_map(function(schema_ref)
    return schema_ref.name
  end, document.schemas)
  table.insert(expected_schemas, "Z")
  expect.equality(schema_names, expected_schemas)

  local schema = model.schema(document, find(document.schemas, "name", "Z"))
  expect.equality(
    vim.tbl_map(function(property)
      return property.name
    end, schema.properties),
    expected_properties
  )
end

T["path-level parameters"] = MiniTest.new_set()

local PARAMS_DOC = [[
openapi: 3.1.0
paths:
  /a:
    summary: Path summary
    description: Path description
    parameters:
      - { name: id, in: path, description: From the path }
      - { name: shared, in: query, description: From the path }
      - { name: shared, in: header, description: From the path }
    get:
      parameters:
        - { name: own, in: query }
        - { name: shared, in: query, description: From the operation }
    post:
      summary: Own summary
      description: Own description
]]

T["path-level parameters"]["merge, and the operation wins on name plus in"] = function()
  local document = load_text(PARAMS_DOC)
  local operation = model.operation(document, operation_ref(document, "/a", "get"))
  expect.equality(
    vim.tbl_map(function(parameter)
      return { parameter.name, parameter["in"], parameter.description }
    end, operation.parameters),
    {
      { "id", "path", "From the path" },
      { "shared", "query", "From the operation" },
      { "shared", "header", "From the path" },
      { "own", "query" },
    }
  )
end

T["path-level parameters"]["path summary and description are fallbacks"] = function()
  local document = load_text(PARAMS_DOC)
  local get = model.operation(document, operation_ref(document, "/a", "get"))
  local post = model.operation(document, operation_ref(document, "/a", "post"))
  expect.equality({ get.summary, get.description }, { "Path summary", "Path description" })
  expect.equality({ post.summary, post.description }, { "Own summary", "Own description" })
end

T["version classification"] = MiniTest.new_set()

local function classify(text)
  local doc = assert(tree.parse(text))
  return model.classify(doc)
end

for _, row in ipairs({
  { "openapi: 3.0\n", "ok", "3.0" },
  { "openapi: 3.0.3\n", "ok", "3.0" },
  { "openapi: 3.1\n", "ok", "3.1" },
  { "openapi: 3.1.1\n", "ok", "3.1" },
  { 'openapi: "3.1.0"\n', "ok", "3.1" },
  { "openapi: 3.10\n", "unsupported", "3.10" },
  { "openapi: 3.01\n", "unsupported", "3.01" },
  { "openapi: 3.2\n", "unsupported", "3.2" },
  { "openapi: 3.2.0\n", "unsupported", "3.2.0" },
  { "openapi: 2.0\n", "unsupported", "2.0" },
  { 'swagger: "2.0"\n', "swagger", "2.0" },
  { "swagger: 2.0\n", "swagger", "2.0" },
  { 'swagger: "1.2"\n', "unsupported", "1.2" },
  { "a: 1\n", "not_openapi" },
  { "- a\n", "not_openapi" },
  { "plain\n", "not_openapi" },
  { "", "not_openapi" },
  { 'openapi: 3.1.0\nswagger: "2.0"\n', "ok", "3.1" },
  { 'openapi: 3.2.0\nswagger: "2.0"\n', "unsupported", "3.2.0" },
  { "openapi: {}\n", "not_openapi" },
  { 'openapi: {}\nswagger: "2.0"\n', "swagger", "2.0" },
  { "openapi: [3.1]\n", "not_openapi" },
}) do
  T["version classification"][vim.inspect(row[1])] = function()
    local result = classify(row[1])
    expect.equality({ result.kind, result.version }, { row[2], row[3] })
  end
end

T["version classification"]["keeps the raw version"] = function()
  expect.equality(classify("openapi: 3.0\n").raw_version, "3.0")
  expect.equality(classify("openapi: 3.1.1\n").raw_version, "3.1.1")
end

T["version classification"]["through the fixtures"] = function()
  for _, row in ipairs({
    { "swagger-20.yaml", "swagger" },
    { "version-32.yaml", "unsupported" },
    { "not-openapi.yaml", "not_openapi" },
  }) do
    local ws = workspace.new()
    local doc = assert(ws:open_file(FIXTURES .. row[1]))
    local document, classification = model.load(ws, doc)
    expect.equality(document, nil)
    expect.equality(classification.kind, row[2])
  end
end

T["broken structure"] = MiniTest.new_set()

local function structure_messages(document)
  local messages = {}
  for _, diagnostic in ipairs(document.diagnostics) do
    if diagnostic.code == "structure" then
      messages[#messages + 1] = diagnostic.message
    end
  end
  return messages
end

T["broken structure"]["each document-level case gives a diagnostic, and the rest stays"] = function()
  local document = load_fixture("broken-structure.yaml")
  local messages = structure_messages(document)
  for _, expected in ipairs({
    "tags is not a list",
    "servers is not a list",
    "path item /scalar-item is not a mapping",
    "operation get is not a mapping",
    "webhooks is not a mapping",
    "components/schemas is not a mapping",
  }) do
    expect.equality({ expected = expected, found = vim.tbl_contains(messages, expected) }, {
      expected = expected,
      found = true,
    })
  end

  expect.equality(document.info.title, "Broken")
  expect.equality(operation_ref(document, "/good", "get").summary, "Still fine")
  expect.equality(operation_ref(document, "/scalar-operation", "post").summary, "Still fine too")
  expect.equality(operation_ref(document, "/scalar-operation", "post").tags, {})
end

T["broken structure"]["each operation-level case gives a diagnostic, and the rest stays"] = function()
  local document = load_fixture("broken-structure.yaml")
  local parts = model.operation(document, operation_ref(document, "/bad-parts", "get"))
  local messages = structure_messages(document)
  for _, expected in ipairs({
    "a parameter is not a mapping",
    "schema is not a mapping or a boolean",
    "requestBody is not a mapping",
    "response 200 is not a mapping",
    "media type text/plain is not a mapping",
    "header X-Bad is not a mapping",
  }) do
    expect.equality({ expected = expected, found = vim.tbl_contains(messages, expected) }, {
      expected = expected,
      found = true,
    })
  end
  expect.equality(#parts.parameters, 1)
  expect.equality(parts.parameters[1].name, "fine")
  expect.equality(parts.parameters[1].schema.problem, true)
  expect.equality(parts.request_body, nil)
  expect.equality(#parts.responses, 1)
  expect.equality(parts.responses[1].status, "201")
  expect.equality(parts.responses[1].description, "Made")

  local lists = model.operation(document, operation_ref(document, "/bad-lists", "get"))
  expect.equality({ lists.parameters, lists.responses, lists.security }, { {}, {}, {} })
  messages = structure_messages(document)
  for _, expected in ipairs({ "parameters is not a list", "security is not a list", "responses is not a mapping" }) do
    expect.equality(vim.tbl_contains(messages, expected), true)
  end
end

T["broken structure"]["paths as a list and info as a scalar"] = function()
  local document = load_text("openapi: 3.1.0\ninfo: text\npaths: [a]\n")
  expect.equality(document.groups, {})
  expect.equality(document.info, {})
  expect.equality(structure_messages(document), { "info is not a mapping", "paths is not a mapping" })
end

T["broken structure"]["an operation overlapping a syntax error has the problem marker"] = function()
  local document, doc = load_text([[
openapi: 3.1.0
paths:
  /good:
    get:
      summary: Good
  /bad:
    get:
      summary: [broken
      description: After
]])
  expect.equality(tree.has_error(doc), true)
  expect.equality(operation_ref(document, "/good", "get").problem, false)
  expect.equality(operation_ref(document, "/bad", "get").problem, true)
end

T["broken path items"] = MiniTest.new_set()

local BROKEN_PATHS = [[
openapi: 3.1.0
tags:
  - name: t
paths:
  /first:
    get: { tags: [t] }
  /a-untagged:
    get: {}
  /gone:
    $ref: ./gone.yaml
  /z-untagged:
    get: {}
webhooks:
  good:
    post: {}
  lost:
    $ref: https://x/y.yaml
]]

T["broken path items"]["sit in (untagged) in spec order, with no method"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.uv.fs_realpath(dir) .. "/root.yaml"
  vim.fn.writefile(vim.split(BROKEN_PATHS, "\n"), path)
  local ws = workspace.new({ root = vim.uv.fs_realpath(dir) })
  local document = assert(model.load(ws, assert(ws:open_file(path))))

  local untagged = find(document.groups, "tag", "(untagged)")
  expect.equality(
    vim.tbl_map(function(row)
      return row.path
    end, untagged.operations),
    { "/a-untagged", "/gone", "/z-untagged" }
  )

  local row = untagged.operations[2]
  expect.equality(row.method, nil)
  expect.equality(row.problem, true)
  expect.equality(row.tags, {})
  expect.equality(row.broken, { target = "./gone.yaml", reason = "not found" })
  expect.equality(row.pos.row, 9)
  expect.equality(model.operation(document, row).broken, row.broken)
end

T["broken path items"]["under webhooks sit in webhooks"] = function()
  local document = load_text(BROKEN_PATHS)
  expect.equality(
    vim.tbl_map(function(row)
      return { row.path, row.method, row.broken and row.broken.reason }
    end, document.webhooks),
    { { "good", "post" }, { "lost", nil, "remote not loaded" } }
  )
end

T["broken path items"]["join the diagnostics once"] = function()
  local document = load_text(BROKEN_PATHS)
  local messages = {}
  for _, diagnostic in ipairs(document.diagnostics) do
    if diagnostic.code == "broken-ref" then
      messages[#messages + 1] = diagnostic.message
    end
  end
  expect.equality(messages, { "./gone.yaml  no base path", "https://x/y.yaml  remote not loaded" })
end

T["memoisation"] = MiniTest.new_set()

T["memoisation"]["Operation is not built before request, and the same table returns"] = function()
  local document = load_fixture("petstore-31.yaml")
  expect.equality(document._operations, {})
  local ref = operation_ref(document, "/pets", "get")
  expect.equality(ref.parameters, nil)
  local first = model.operation(document, ref)
  expect.equality(model.operation(document, ref) == first, true)
  expect.equality(ref.parameters, nil)
end

T["memoisation"]["Schema is not built before request, and the same table returns"] = function()
  local document = load_fixture("petstore-31.yaml")
  expect.equality(document._schemas, {})
  local first = model.schema(document, document.schemas[1])
  expect.equality(model.schema(document, document.schemas[1]) == first, true)
end

T["what loads"] = MiniTest.new_set()

T["what loads"]["loading loads a path item's file and no other"] = function()
  local _, _, ws = load_multi()
  expect.equality(ws:loaded_files(), { MULTI .. "/paths/pets.yaml" })
end

T["what loads"]["the path item's content fills the list"] = function()
  local document = load_multi()
  expect.equality(
    vim.tbl_map(function(operation)
      return operation.method
    end, document.groups[1].operations),
    { "get", "post", "delete" }
  )
  expect.equality(document.groups[1].operations[1].pos.file, MULTI .. "/paths/pets.yaml")
end

T["what loads"]["building a Schema loads nothing"] = function()
  local document, _, ws = load_multi()
  local before = ws:loaded_files()
  for _, schema_ref in ipairs(document.schemas) do
    model.schema(document, schema_ref)
  end
  expect.equality(ws:loaded_files(), before)
end

T["what loads"]["a closed external ref has no key"] = function()
  local document = load_multi()
  local schema = model.schema(document, find(document.schemas, "name", "Pet"))
  local owner = find(schema.properties, "name", "owner").schema.ref
  expect.equality({ owner.status, owner.key, owner.reason }, { "closed", nil, nil })
  local gone = find(schema.properties, "name", "gone").schema.ref
  expect.equality({ gone.status, gone.key, gone.reason, gone.name, gone.file }, {
    "closed",
    nil,
    nil,
    "gone",
    "gone.yaml",
  })
end

T["what loads"]["a closed local ref has its key and no walked target"] = function()
  local document, doc = load_multi()
  local walked = 0
  local original = refs.walk
  ---@diagnostic disable-next-line: duplicate-set-field
  refs.walk = function(...)
    walked = walked + 1
    return original(...)
  end
  local ok, schema = pcall(model.schema, document, find(document.schemas, "name", "Local"))
  refs.walk = original
  expect.equality(ok, true)
  expect.equality(walked, 0)

  local missing = find(schema.properties, "name", "missing").schema.ref
  expect.equality(missing.status, "closed")
  expect.equality(missing.key, doc.identity .. "#/components/schemas/NoSuch")
end

T["what loads"]["a listed schema that is an external $ref is one closed ref"] = function()
  local document, _, ws = load_multi()
  local before = ws:loaded_files()
  local schema = model.schema(document, find(document.schemas, "name", "Listed"))
  expect.equality(schema.ref.status, "closed")
  expect.equality({ schema.ref.name, schema.ref.file }, { "pet", "pet.yaml" })
  expect.equality(ws:loaded_files(), before)
end

T["what loads"]["an Operation loads its non-schema refs, and schema refs inside stay closed"] = function()
  local document, _, ws = load_multi()
  local operation = model.operation(document, operation_ref(document, "/pets", "get"))
  expect.equality(ws:loaded_files(), { MULTI .. "/paths/pets.yaml", MULTI .. "/shared.yaml" })

  expect.equality(operation.parameters[1].name, "limit")
  expect.equality(operation.parameters[1].schema.types, { "integer" })
  local response = operation.responses[1]
  expect.equality(response.description, "Expected response")
  local ref = response.content[1].schema.ref
  expect.equality({ ref.status, ref.key, ref.file }, { "closed", nil, "pet.yaml" })
end

T["what loads"]["a request body's ref loads too"] = function()
  local document, _, ws = load_multi()
  local operation = model.operation(document, operation_ref(document, "/pets", "post"))
  expect.equality(operation.request_body.description, "The pet")
  expect.equality(ws:loaded_files(), { MULTI .. "/paths/pets.yaml", MULTI .. "/shared.yaml" })
end

T["what loads"]["a broken non-schema ref builds as broken, with a diagnostic, at that point"] = function()
  local document = load_multi()
  expect.equality(document.diagnostics, {})

  local ref = operation_ref(document, "/pets", "delete")
  local operation = model.operation(document, ref)
  local parameter = operation.parameters[1]
  expect.equality(parameter.broken.reason, "not found")
  expect.equality(parameter.broken.target, "../gone.yaml#/parameters/id")
  expect.equality(codes_of(document.diagnostics), { "broken-ref" })
  expect.equality(document.diagnostics[1].pos.file, MULTI .. "/paths/pets.yaml")
end

T["what loads"]["the same broken ref reached twice is one problem"] = function()
  local document = load_text([[
openapi: 3.1.0
paths:
  /a:
    parameters:
      - $ref: "#/no/such"
    get: {}
    post: {}
]])
  model.operation(document, operation_ref(document, "/a", "get"))
  model.operation(document, operation_ref(document, "/a", "post"))
  expect.equality(codes_of(document.diagnostics), { "broken-ref" })
end

T["opening a ref"] = MiniTest.new_set()

T["opening a ref"]["loads exactly its file and gives the Schema"] = function()
  local document, _, ws = load_multi()
  local schema = model.schema(document, find(document.schemas, "name", "Pet"))
  local ref = find(schema.properties, "name", "owner").schema.ref
  local target = assert(model.open_ref(document, ref))
  expect.equality(target.types, { "object" })
  expect.equality(ref.status, "open")
  expect.equality(ref.key, MULTI .. "/schemas/owner.yaml#/Owner")
  expect.equality(vim.tbl_contains(ws:loaded_files(), MULTI .. "/schemas/owner.yaml"), true)
  expect.equality(model.open_ref(document, ref) == target, true)
end

local function cycle_with_siblings(version)
  return string.format(
    [[
openapi: %s
paths: {}
a:
  $ref: "#/b"
  description: x
b:
  $ref: "#/a"
  description: y
components:
  schemas:
    S:
      properties:
        p:
          $ref: "#/a"
]],
    version
  )
end

T["opening a ref"]["a 3.0 cycle with siblings is a ref cycle and joins the diagnostics"] = function()
  local document = load_text(cycle_with_siblings("3.0.3"))
  local ref = model.schema(document, document.schemas[1]).properties[1].schema.ref
  local target, reason = model.open_ref(document, ref)
  expect.equality({ target, reason, ref.status, ref.reason }, { nil, "ref cycle", "broken", "ref cycle" })
  expect.equality(codes_of(document.diagnostics), { "ref-siblings", "ref-siblings", "broken-ref" })
end

T["opening a ref"]["the same document in 3.1 opens with no reason"] = function()
  local document = load_text(cycle_with_siblings("3.1.0"))
  local ref = model.schema(document, document.schemas[1]).properties[1].schema.ref
  local target, reason = model.open_ref(document, ref)
  expect.equality(reason, nil)
  expect.equality(assert(target).description, "x")
  expect.equality(ref.status, "open")
  expect.equality(document.diagnostics, {})
end

T["opening a ref"]["a 3.0 hop gives one ref-siblings per position, also when built as a listed schema"] = function()
  local document = load_text([[
openapi: 3.0.3
paths: {}
components:
  schemas:
    A:
      $ref: "#/components/schemas/B"
      description: ignored
    B:
      type: string
    S:
      properties:
        p:
          $ref: "#/components/schemas/A"
]])
  model.schema(document, find(document.schemas, "name", "A"))
  local schema = model.schema(document, find(document.schemas, "name", "S"))
  local target = assert(model.open_ref(document, schema.properties[1].schema.ref))
  expect.equality(target.types, { "string" })
  expect.equality(codes_of(document.diagnostics), { "ref-siblings" })
end

T["opening a ref"]["ignored hops in an external file reach the merged diagnostics"] = function()
  local dir = assert(vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")))
  dir = dir .. "/siblings-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "x:", "  $ref: ./gone.yaml", "  title: ignored" }, dir .. "/ext.yaml")
  vim.fn.writefile({
    "openapi: 3.0.3",
    "paths: {}",
    "components:",
    "  schemas:",
    "    S:",
    "      properties:",
    "        p:",
    "          $ref: ./ext.yaml#/x",
  }, dir .. "/root.yaml")
  local ws = workspace.new({ root = dir })
  local document = assert(model.load(ws, assert(ws:open_file(dir .. "/root.yaml"))))
  local ref = model.schema(document, document.schemas[1]).properties[1].schema.ref
  local _, reason = model.open_ref(document, ref)
  expect.equality(reason, "not found")
  expect.equality(codes_of(model.diagnostics(document)), { "broken-ref", "ref-siblings" })
end

T["opening a ref"]["a failure makes that row broken and joins the diagnostics"] = function()
  local document = load_multi()
  local schema = model.schema(document, find(document.schemas, "name", "Pet"))
  local ref = find(schema.properties, "name", "gone").schema.ref
  local target, reason = model.open_ref(document, ref)
  expect.equality({ target, reason, ref.status, ref.reason }, { nil, "not found", "broken", "not found" })
  expect.equality(codes_of(document.diagnostics), { "broken-ref" })
end

T["opening a ref"]["a ref broken from its text joins nothing until rendered"] = function()
  local document = load_text(schema_doc("3.1.0", { "properties:", "  a: { $ref: 'https://x/y' }" }))
  local ref = model.schema(document, document.schemas[1]).properties[1].schema.ref
  expect.equality({ ref.status, ref.reason, ref.target }, { "broken", "remote not loaded", "https://x/y" })
  expect.equality(document.diagnostics, {})
end

T["opening a ref"]["a damaged external file's diagnostics join the document's"] = function()
  local document = load_multi()
  expect.equality(model.diagnostics(document), {})

  local schema = model.schema(document, find(document.schemas, "name", "Pet"))
  local ref = find(schema.properties, "name", "owner").schema.ref
  ref._parsed = refs.check_text("./damaged.yaml#/ok", ref._doc.identity)
  model.open_ref(document, ref)
  expect.equality(codes_of(model.diagnostics(document)), { "syntax" })
  expect.equality(document.diagnostics, {})
end

-- Laziness on a large generated document (spec 8)

local DESCRIPTION = string.rep("A long description that the list never needs. ", 12)

local OPERATION = table.concat({
  "  /items/{id}/n%d: { get: { tags: [t%d], summary: Get item %d, operationId: get%d,",
  ' description: "%s",',
  " parameters: [ { name: id, in: path, required: true, description: The id of the item,",
  " schema: { type: string, format: uuid } } ],",
  ' responses: { "200": { description: Expected response, content: { application/json:',
  ' { schema: { $ref: "#/components/schemas/S%d" } } } }, "404": { description: Missing } } } }',
})

--- About 1 KB per operation, so 5,000 operations give about 5 MB. Each operation and each schema is one
--- flow-style line, because the pinned YAML parser fails on block YAML longer than 32,768 lines.
--- With `external`, every tenth path item is a `$ref` to its own file and every schema is a `$ref` into one
--- shared file, all written there.
local function large_document(count, external)
  local out = { "openapi: 3.1.0", "info:", "  title: Large", "  version: '1'", "paths:" }
  local function add(line)
    out[#out + 1] = line
  end
  for i = 1, count do
    if external and i % 10 == 0 then
      add(string.format("  /items/{id}/n%d: { $ref: ./p%d.yaml }", i, i))
      vim.fn.writefile(
        { "get:", "  summary: External " .. i, "  responses: {}" },
        string.format("%s/p%d.yaml", external, i)
      )
    else
      add(string.format(OPERATION, i, i % 10, i, i, DESCRIPTION, i))
    end
  end
  add("components:")
  add("  schemas:")
  local shared = {}
  for i = 1, count do
    if external then
      add(string.format('    S%d: { $ref: "./schemas.yaml#/S%d" }', i, i))
      shared[#shared + 1] = string.format("S%d: { type: string }", i)
    else
      add(string.format("    S%d: { type: object, properties: { a: { type: string, description: First },", i))
      out[#out] = out[#out] .. " b: { type: integer, minimum: 0 } } }"
    end
  end
  if external then
    vim.fn.writefile(shared, external .. "/schemas.yaml")
  end
  return table.concat(out, "\n") .. "\n"
end

local function load_large(count, external)
  local ws = workspace.new({ root = external })
  local text = large_document(count, external)
  local doc
  if external then
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), external .. "/root.yaml")
    doc = assert(ws:open_file(external .. "/root.yaml"))
  else
    doc = assert(ws:open_text(text, { bufnr = 1 }))
  end
  local document, classification = model.load(ws, doc)
  if not document then
    error(vim.inspect({ classification, doc.diagnostics[1], text:sub(1, 300) }), 0)
  end
  return document, doc, ws, #text
end

local function decoded_scalars(doc)
  local count = 0
  -- Only counted, so the order of `pairs()` does not matter.
  for _, node in pairs(doc._nodes) do
    if node.kind == "scalar" and rawget(node, "_decoded") then
      count = count + 1
    end
  end
  return count
end

T["large document"] = MiniTest.new_set()

T["large document"]["5,000 operations make about 5 MB"] = function()
  local bytes = #large_document(5000)
  expect.equality(bytes > 4.5 * 1024 * 1024 and bytes < 6 * 1024 * 1024, true)
end

T["large document"]["materialised nodes grow by a fixed amount per operation, with no Operation or Schema built"] = function()
  local counts, decoded = {}, {}
  for _, count in ipairs({ 100, 200, 5000 }) do
    local document, doc = load_large(count)
    counts[count] = doc.counters.materialised
    decoded[count] = decoded_scalars(doc)
    expect.equality({ count, next(document._schemas), next(document._operations) }, { count, nil, nil })
  end
  local per_operation = (counts[200] - counts[100]) / 100
  expect.equality(counts[5000] - counts[100], 49 * (counts[200] - counts[100]))
  -- Measured as 19: the path key and item, the method key and operation, the operation's six keys and
  -- their values (read shallowly for the list fields), the one tag, and the schema's key and value.
  expect.equality(per_operation <= 19, true)
  expect.equality(decoded[5000] - decoded[100], 49 * (decoded[200] - decoded[100]))
  -- Measured as 2: the tag and the summary.
  expect.equality((decoded[200] - decoded[100]) / 100 <= 2, true)
end

T["large document"]["scalars outside the list stay undecoded"] = function()
  local document = load_large(100)
  local operation = operation_ref(document, "/items/{id}/n7", "get").node
  for _, key in ipairs({ "description", "operationId" }) do
    local node = assert(tree.get(operation, key))
    expect.equality({ key, rawget(node, "_decoded") }, { key, nil })
  end
end

T["large document"]["only path-item targets load at open, however many schema refs there are"] = function()
  for _, count in ipairs({ 100, 5000 }) do
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local real = assert(vim.uv.fs_realpath(dir))
    local _, _, ws = load_large(count, real)
    local expected = {}
    for i = 10, count, 10 do
      expected[#expected + 1] = string.format("%s/p%d.yaml", real, i)
    end
    expect.equality(ws:loaded_files(), expected)
  end
end

T["large document"]["a Schema with 1,000 closed refs loads no file and walks no pointer"] = function()
  local dir = assert(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/") or "/tmp"))
  local properties = {}
  for i = 1, 1000 do
    properties[#properties + 1] = string.format("  p%d:", i)
    if i % 2 == 0 then
      properties[#properties + 1] = '    $ref: "#/components/schemas/T"'
    else
      properties[#properties + 1] = string.format("    $ref: ./ext%d.yaml#/X", i)
    end
  end
  local lines = { "openapi: 3.1.0", "paths: {}", "components:", "  schemas:", "    S:", "      properties:" }
  for _, line in ipairs(properties) do
    lines[#lines + 1] = "      " .. line
  end
  vim.list_extend(lines, { "    T:", "      type: string" })
  local path = dir .. "/many-refs-" .. vim.uv.hrtime() .. ".yaml"
  vim.fn.writefile(lines, path)
  local ws = workspace.new({ root = dir })
  local document = assert(model.load(ws, assert(ws:open_file(path))))

  local walked = 0
  local original = refs.walk
  ---@diagnostic disable-next-line: duplicate-set-field
  refs.walk = function(...)
    walked = walked + 1
    return original(...)
  end
  local ok, schema = pcall(model.schema, document, find(document.schemas, "name", "S"))
  refs.walk = original
  expect.equality(ok, true)
  expect.equality({ #schema.properties, walked, ws:loaded_files() }, { 1000, 0, {} })
  expect.equality(schema.properties[1].schema.ref.status, "closed")
  expect.equality(schema.properties[2].schema.ref.status, "closed")
end

T["curl fields"] = MiniTest.new_set()

local CURL_DOC = [[
openapi: 3.1.0
servers:
  - url: "{scheme}://{region}.example.com"
    variables:
      scheme: { default: https }
      region: { description: no default }
paths:
  /a:
    get:
      servers:
        - url: https://op.example.com/{v}
          variables:
            v: { default: v2 }
      parameters:
        - name: id
          in: query
          style: form
          explode: false
          allowReserved: true
          example: 7
          examples:
            good: { value: 8 }
            gone: { $ref: "#/components/examples/missing" }
            far: { externalValue: https://example.com/x }
        - { name: plain, in: query }
components:
  securitySchemes:
    key: { type: apiKey, in: header, name: X-Key }
    bearer: { type: http, scheme: bearer }
    linked: { $ref: "#/components/securitySchemes/bearer" }
]]

T["curl fields"]["server variables keep source order and defaults"] = function()
  local document = load_text(CURL_DOC)
  expect.equality(document.servers[1].variables, { { name = "scheme", default = "https" }, { name = "region" } })
  expect.equality(document.servers[1].variable_defaults, { scheme = "https" })
end

T["curl fields"]["operation servers read variables too"] = function()
  local document = load_text(CURL_DOC)
  local operation = model.operation(document, operation_ref(document, "/a", "get"))
  expect.equality(operation.servers[1].variables, { { name = "v", default = "v2" } })
end

T["curl fields"]["parameter example, examples, style, explode and allowReserved"] = function()
  local document = load_text(CURL_DOC)
  local parameter = model.operation(document, operation_ref(document, "/a", "get")).parameters[1]
  expect.equality(
    { parameter.style, parameter.explode, parameter.allow_reserved, parameter.example.text },
    { "form", false, true, "7" }
  )
  expect.equality(
    vim.tbl_map(function(example)
      return { example.name, example.value and example.value.text or false, example.broken ~= nil }
    end, parameter.examples),
    { { "good", "8", false }, { "gone", false, true }, { "far", false, false } }
  )
end

T["curl fields"]["a parameter without them has nil fields"] = function()
  local document = load_text(CURL_DOC)
  local parameter = model.operation(document, operation_ref(document, "/a", "get")).parameters[2]
  expect.equality(
    { parameter.style, parameter.explode, parameter.allow_reserved, parameter.example, parameter.examples },
    { nil, nil, nil, nil, {} }
  )
end

T["curl fields"]["security_scheme reads type, in, name and scheme"] = function()
  local document = load_text(CURL_DOC)
  expect.equality(model.security_scheme(document, "key"), { type = "apiKey", ["in"] = "header", name = "X-Key" })
  expect.equality(model.security_scheme(document, "bearer"), { type = "http", scheme = "bearer" })
end

T["curl fields"]["security_scheme follows a $ref"] = function()
  local document = load_text(CURL_DOC)
  expect.equality(model.security_scheme(document, "linked"), { type = "http", scheme = "bearer" })
end

T["curl fields"]["security_scheme returns nil for a missing name and for no components"] = function()
  local document = load_text(CURL_DOC)
  expect.equality(model.security_scheme(document, "missing"), nil)
  local bare = load_text("openapi: 3.1.0\npaths: {}\n")
  expect.equality(model.security_scheme(bare, "key"), nil)
end

T["curl fields"]["security_scheme is memoised"] = function()
  local document = load_text(CURL_DOC)
  expect.equality(rawequal(model.security_scheme(document, "key"), model.security_scheme(document, "key")), true)
end

return T
