local curl = require("oas-glance.internal.curl")
local model = require("oas-glance.internal.model")
local tree = require("oas-glance.internal.tree")
local workspace = require("oas-glance.internal.workspace")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local FIXTURES = "tests/fixtures/"
local MULTI = vim.uv.fs_realpath(FIXTURES .. "multi")
local REPLACEMENT = "\239\191\189"

local function load_text(text)
  local ws = workspace.new()
  local doc = assert(ws:open_text(text, { bufnr = 1 }))
  return assert(model.load(ws, doc))
end

local function load_fixture(name)
  local ws = workspace.new({ root = vim.uv.fs_realpath(FIXTURES) })
  local doc = assert(ws:open_file(FIXTURES .. name))
  return assert(model.load(ws, doc))
end

local function all_operations(document)
  local operations = {}
  for _, group in ipairs(document.groups) do
    vim.list_extend(operations, group.operations)
  end
  return operations
end

local function operation_of(document, path, method)
  for _, operation in ipairs(all_operations(document)) do
    if operation.path == path and operation.method == method then
      return model.operation(document, operation)
    end
  end
  error("no operation " .. method .. " " .. path, 0)
end

local function build_in(document, path, method, opts)
  return curl.build(document, operation_of(document, path, method), opts)
end

--- A fresh document for each call, so one case never sees another's opened refs.
local function build(path, method, name)
  return build_in(load_fixture(name or "curl-31.yaml"), path, method)
end

local function build_text(text, path, method, opts)
  return build_in(load_text(text), path, method, opts)
end

local function schema_of(document, name)
  for _, schema_ref in ipairs(document.schemas) do
    if schema_ref.name == name then
      return model.schema(document, schema_ref)
    end
  end
  error("no schema " .. name, 0)
end

local function generated(name, opts, fixture)
  local document = load_fixture(fixture or "curl-31.yaml")
  local value = curl._generate(document, schema_of(document, name), opts)
  if value == curl._OMIT then
    return "OMIT"
  end
  return curl._json.pretty(value)
end

--- The value under `v` in a YAML or JSON text.
local function node_of(text)
  local ws = workspace.new()
  local doc = assert(ws:open_text(text, { bufnr = 1 }))
  local root = assert(doc.root, "no root")
  return tree.get(assert(tree.resolve(root), "unresolved root"), "v")
end

local function value_of(text, max_depth)
  return curl._json.from_node(node_of(text), 0, max_depth or 64)
end

local function compact(text)
  return curl._json.compact(value_of(text))
end

--- Every double-quoted segment of a shell text, quotes included, and the count of `!` outside single quotes.
local function double_quoted(text)
  local segments, bare_bangs = {}, 0
  local index = 1
  while index <= #text do
    local char = text:sub(index, index)
    if char == "\\" then
      index = index + 2
    elseif char == "'" then
      local close = assert(text:find("'", index + 1, true), "unclosed single quote")
      index = close + 1
    elseif char == '"' then
      local stop = index + 1
      while text:sub(stop, stop) ~= '"' do
        assert(stop <= #text, "unclosed double quote")
        if text:sub(stop, stop) == "!" then
          bare_bangs = bare_bangs + 1
        end
        stop = stop + (text:sub(stop, stop) == "\\" and 2 or 1)
      end
      segments[#segments + 1] = text:sub(index, stop)
      index = stop + 1
    else
      if char == "!" then
        bare_bangs = bare_bangs + 1
      end
      index = index + 1
    end
  end
  return segments, bare_bangs
end

-- serialiser

T["serialiser"] = MiniTest.new_set()

T["serialiser"]["escapes quote, backslash and control characters"] = function()
  expect.equality(compact([[v: "\"\\\n\t\x01/é"]]), [["\"\\\n\t\u0001/é"]])
end

T["serialiser"]["a big integer keeps every digit"] = function()
  expect.equality(compact("v: 12345678901234567890123"), "12345678901234567890123")
end

T["serialiser"]["0x1F becomes 31"] = function()
  expect.equality(compact("v: 0x1F"), "31")
end

T["serialiser"]["+1 becomes 1"] = function()
  expect.equality(compact("v: +1"), "1")
end

T["serialiser"][".5 becomes 0.5"] = function()
  expect.equality(compact("v: .5"), "0.5")
end

T["serialiser"]["1e400 and .inf and .nan become null"] = function()
  expect.equality(compact("v: [1e400, .inf, -.inf, .nan]"), "[null,null,null,null]")
end

T["serialiser"]["nested map and seq keep source order"] = function()
  expect.equality(
    compact('v: { z: 1, a: [true, null, "s"], m: { k: v, b: false } }'),
    '{"z":1,"a":[true,null,"s"],"m":{"k":"v","b":false}}'
  )
end

T["serialiser"]["empty map and seq print as {} and []"] = function()
  local value = value_of("v: { a: {}, b: [] }")
  expect.equality(curl._json.compact(value), '{"a":{},"b":[]}')
  expect.equality(curl._json.pretty(value), { "{", '  "a": {},', '  "b": []', "}" })
end

T["serialiser"]["pretty indents by two spaces"] = function()
  expect.equality(curl._json.pretty(value_of("v: { a: 1, b: [1, { c: x }] }")), {
    "{",
    '  "a": 1,',
    '  "b": [',
    "    1,",
    "    {",
    '      "c": "x"',
    "    }",
    "  ]",
    "}",
  })
end

T["serialiser"]["nesting past max_depth gives null"] = function()
  expect.equality(curl._json.compact(value_of("v: { a: { b: 1 } }", 1)), '{"a":{"b":null}}')
end

T["serialiser"]["YAML and JSON sources give the same text"] = function()
  local yaml = table.concat({
    "v:",
    "  name: Rex",
    "  tags: [a, b]",
    "  size: 1.50",
    "  meta:",
    "    ok: true",
    "    none: null",
    "",
  }, "\n")
  local json = '{"v": {"name": "Rex", "tags": ["a", "b"], "size": 1.50, "meta": {"ok": true, "none": null}}}\n'
  local expected = {
    "{",
    '  "name": "Rex",',
    '  "tags": [',
    '    "a",',
    '    "b"',
    "  ],",
    '  "size": 1.50,',
    '  "meta": {',
    '    "ok": true,',
    '    "none": null',
    "  }",
    "}",
  }
  expect.equality(curl._json.pretty(value_of(yaml)), expected)
  expect.equality(curl._json.pretty(value_of(json)), expected)
end

-- generator

T["generator"] = MiniTest.new_set()

T["generator"]["example wins over default, enum and const"] = function()
  expect.equality(generated("Precedence"), { '"ex"' })
end

T["generator"]["default wins over enum and const"] = function()
  expect.equality(generated("DefaultFirst"), { '"def"' })
end

T["generator"]["first enum wins over const"] = function()
  expect.equality(generated("EnumFirst"), { '"en"' })
end

T["generator"]["const alone"] = function()
  expect.equality(generated("ConstAlone"), { '"co"' })
end

T["generator"]["each string format"] = function()
  expect.equality(generated("Formats"), {
    "{",
    '  "dt": "1970-01-01T00:00:00Z",',
    '  "d": "1970-01-01",',
    '  "t": "00:00:00Z",',
    '  "u": "00000000-0000-0000-0000-000000000000",',
    '  "e": "user@example.com",',
    '  "uri": "https://example.com",',
    '  "other": "string"',
    "}",
  })
end

T["generator"]["integer, number, boolean and null"] = function()
  expect.equality(generated("Scalars"), { "{", '  "i": 0,', '  "n": 0,', '  "b": true,', '  "z": null', "}" })
end

T["generator"]["readOnly properties are skipped in a body"] = function()
  expect.equality(generated("ReadOnly", { skip_read_only = true }), { "{", '  "name": "string"', "}" })
  expect.equality(generated("ReadOnly"), { "{", '  "id": 0,', '  "name": "string"', "}" })
end

T["generator"]["allOf merges own properties first, then members, and a later value replaces in place"] = function()
  expect.equality(generated("AllOf"), {
    "{",
    '  "own": "string",',
    '  "shared": "member",',
    '  "first": 0,',
    '  "second": true',
    "}",
  })
end

T["generator"]["a non-object allOf takes the first member"] = function()
  expect.equality(generated("AllOfScalar"), { '"1970-01-01"' })
end

T["generator"]["oneOf and anyOf take the first member, merged after own properties"] = function()
  expect.equality(generated("OneOf"), { "{", '  "own": "string",', '  "a": 0', "}" })
  expect.equality(generated("AnyOf"), { "0" })
end

T["generator"]["no type: properties make an object, items an array, else null"] = function()
  expect.equality(generated("NoType"), {
    "{",
    '  "props": {',
    '    "a": 0',
    "  },",
    '  "list": [',
    '    "string"',
    "  ],",
    '  "none": null',
    "}",
  })
end

T["generator"]["prefixItems each, items once, neither gives []"] = function()
  expect.equality(generated("Arrays"), {
    "{",
    '  "prefix": [',
    "    0,",
    '    "string"',
    "  ],",
    '  "items": [',
    "    true",
    "  ],",
    '  "neither": []',
    "}",
  })
end

T["generator"]['3.0 nullable string gives "string"'] = function()
  expect.equality(generated("Nullable", nil, "curl-30.yaml"), { '"string"' })
end

T["generator"]["a cycle is omitted as a property, as an array item and at the top"] = function()
  expect.equality(generated("Node"), { "{", '  "name": "string"', "}" })
  expect.equality(generated("Tree"), { "[]" })
  expect.equality(generated("SelfRef"), "OMIT")
end

T["generator"]["max_depth cuts off"] = function()
  expect.equality(generated("Deep", { max_depth = 2 }), { "{", '  "a": {', '    "b": {}', "  }", "}" })
  expect.equality(generated("Deep"), { "{", '  "a": {', '    "b": {', '      "c": "string"', "    }", "  }", "}" })
end

T["generator"]["a broken ref gives null and joins the diagnostics"] = function()
  local document = load_fixture("curl-31.yaml")
  local before = #model.diagnostics(document)
  local value = curl._generate(document, schema_of(document, "Broken"))
  expect.equality(curl._json.pretty(value), { "{", '  "gone": null', "}" })
  local diagnostics = model.diagnostics(document)
  expect.equality(#diagnostics, before + 1)
  expect.equality(diagnostics[#diagnostics].code, "broken-ref")
end

T["generator"]["boolean schemas: true is null, false is omitted"] = function()
  expect.equality(generated("Booleans"), { "{", '  "allowed": null', "}" })
end

-- placeholders and quoting

T["placeholders"] = MiniTest.new_set()

T["placeholders"]["petId, X-Request-Id, already_snake, HTTPServer, 9lives, empty and non-ASCII"] = function()
  local name = curl._names.placeholder_name
  expect.equality(
    { name("petId"), name("X-Request-Id"), name("already_snake"), name("HTTPServer"), name("9lives"), name("") },
    { "PET_ID", "X_REQUEST_ID", "ALREADY_SNAKE", "HTTPSERVER", "_9LIVES", "VALUE" }
  )
  expect.equality({ name("éé"), name("--"), name("café_id") }, { "VALUE", "VALUE", "CAF_ID" })
end

T["placeholders"]["a collision takes the location suffix, then a number"] = function()
  local names = curl._names
  local claims = names.new_claims()
  expect.equality({
    names.claim(claims, "ID", "path id", "PATH"),
    names.claim(claims, "ID", "query id", "QUERY"),
    names.claim(claims, "ID", "header id", "HEADER"),
    names.claim(claims, "ID", "cookie id", "COOKIE"),
    names.claim(claims, "ID", "query ID", "QUERY"),
  }, { "ID", "ID_QUERY", "ID_HEADER", "ID_COOKIE", "ID_2" })
end

T["placeholders"]["the same source keeps one name"] = function()
  local names = curl._names
  local claims = names.new_claims()
  expect.equality({
    names.claim(claims, "ID", "a", "PATH"),
    names.claim(claims, "ID", "b", "QUERY"),
    names.claim(claims, "ID", "a", "PATH"),
    names.claim(claims, "ID", "b", "QUERY"),
  }, { "ID", "ID_QUERY", "ID", "ID_QUERY" })
end

T["placeholders"]["a second bearer scheme gets TOKEN_2"] = function()
  local names = curl._names
  local claims = names.new_claims()
  expect.equality(
    { names.claim(claims, "TOKEN", "auth a"), names.claim(claims, "TOKEN", "auth b") },
    { "TOKEN", "TOKEN_2" }
  )
end

T["quoting"] = MiniTest.new_set()

T["quoting"]["a word single-quotes a literal with '"] = function()
  expect.equality(curl._quote.word({ [[it's "$x" `y` \z !]] }), [['it'\''s "$x" `y` \z !']])
end

T["quoting"]["a word of a placeholder only"] = function()
  expect.equality(curl._quote.word({ { var = "NAME" } }), [["${NAME}"]])
end

T["quoting"]["a word joins adjacent literals and puts only placeholders in double quotes"] = function()
  expect.equality(curl._quote.word({ "a", "b ", { var = "X" }, { var = "Y" }, "!", "" }), [['ab '"${X}""${Y}"'!']])
end

T["quoting"]["an empty word is ''"] = function()
  expect.equality(curl._quote.word({}), "''")
  expect.equality(curl._quote.word({ "" }), "''")
end

T["quoting"]["single quotes become '\\''"] = function()
  expect.equality(curl._quote.sq([[it's "$x"]]), [['it'\''s "$x"']])
end

local BANG_DOC = [[
openapi: 3.1.0
servers:
  - url: "https://h!x.example.com/{v}/{w}!$"
    variables:
      v: { default: "d!!" }
paths:
  "/p!#/{id}":
    post:
      operationId: "op!$"
      security:
        - { key: [], cookieKey: [], queryKey: [], odd: [] }
      parameters:
        - { name: id, in: path, required: true, example: "e!$" }
        - { name: "q!x", in: query, required: true, example: "v!#" }
        - { name: "X-H!", in: header, required: true, example: "h!!" }
        - { name: "c!k", in: cookie, required: true, example: "c!$" }
      requestBody:
        content:
          "text/x!y":
            schema: { type: integer }
  /form:
    post:
      requestBody:
        content:
          application/x-www-form-urlencoded:
            example: { "k!": "v!$" }
  /multi:
    post:
      requestBody:
        content:
          multipart/form-data:
            example: { "m!": "w!#" }
  /basic:
    get:
      security:
        - { basic: [] }
components:
  securitySchemes:
    key: { type: apiKey, in: header, name: "K!" }
    cookieKey: { type: apiKey, in: cookie, name: "ck!" }
    queryKey: { type: apiKey, in: query, name: "qk!" }
    odd: { type: http, scheme: "Dig!est" }
    basic: { type: http, scheme: basic }
]]

T["quoting"]["no literal text inside double quotes"] = MiniTest.new_set()

for _, row in ipairs({ { "/p!#/{id}", "post" }, { "/form", "post" }, { "/multi", "post" }, { "/basic", "get" } }) do
  T["quoting"]["no literal text inside double quotes"][row[2] .. " " .. row[1]] = function()
    local text = table.concat(build_text(BANG_DOC, row[1], row[2]), "\n")
    expect.equality(text:find("!", 1, true) ~= nil, true)
    local segments, bare_bangs = double_quoted(text)
    for _, segment in ipairs(segments) do
      if not segment:match('^"%${[A-Z_][A-Z0-9_]*}"$') then
        error("literal text in double quotes: " .. segment, 0)
      end
    end
    expect.equality(bare_bangs, 0)
  end
end

T["quoting"]["the main operation covers every literal kind"] = function()
  expect.equality(build_text(BANG_DOC, "/p!#/{id}", "post"), {
    [[: 'op!$: POST /p!#/{id}']],
    [[curl -X POST --url 'https://h!x.example.com/d!!/'"${W}"'!$/p!#/e%21%24?q%21x=v%21%23&qk%21='"${API_KEY_3}" \]],
    [[  -H 'K!: '"${API_KEY}" \]],
    [[  -H 'Authorization: Dig!est '"${TOKEN}" \]],
    [[  -H 'X-H!: h!!' \]],
    [[  -b 'c!k=c!$; ck!='"${API_KEY_2}" \]],
    [[  -H 'Content-Type: text/x!y' \]],
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

-- layout

T["layout"] = MiniTest.new_set()

T["layout"]["comment line with operationId"] = function()
  expect.equality(build("/layout/get", "get"), {
    ": 'layoutGet: GET /layout/get'",
    "curl --url 'https://eu.example.com/v1/layout/get'",
  })
end

T["layout"]["comment line without operationId"] = function()
  expect.equality(build("/layout/no-id", "get"), {
    ": 'GET /layout/no-id'",
    "curl --url 'https://eu.example.com/v1/layout/no-id'",
  })
end

T["layout"]["a newline in the path is replaced"] = function()
  local text = 'openapi: 3.1.0\npaths:\n  "/a\\nb":\n    get: {}\n'
  expect.equality(build_text(text, "/a\nb", "get"), {
    ": 'GET /a" .. REPLACEMENT .. "b'",
    [[curl --url "${BASE_URL}"'/a%0Ab']],
  })
end

T["layout"]["shell syntax in the operationId and path stays inside single quotes"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    '  "/p;$(id)|&!x":',
    "    get:",
    '      operationId: "a;b$(id)`!x|y&z"',
    "",
  }, "\n")
  local first = build_text(text, "/p;$(id)|&!x", "get")[1]
  expect.equality(first, [[: 'a;b$(id)`!x|y&z: GET /p;$(id)|&!x']])
  expect.equality(first:match("^: '[^']*'$") ~= nil, true)
end

T["layout"]["a single quote in the operationId becomes '\\''"] = function()
  local text = 'openapi: 3.1.0\npaths:\n  /q:\n    get:\n      operationId: "it\'s"\n'
  expect.equality(build_text(text, "/q", "get")[1], [[: 'it'\''s: GET /q']])
end

T["layout"]["GET has no -X"] = function()
  expect.equality(build("/layout/get", "get")[2], "curl --url 'https://eu.example.com/v1/layout/get'")
end

T["layout"]["POST has -X POST"] = function()
  expect.equality(build("/layout/post", "post"), {
    ": 'layoutPost: POST /layout/post'",
    "curl -X POST --url 'https://eu.example.com/v1/layout/post'",
  })
end

T["layout"]["HEAD has -I"] = function()
  expect.equality(build("/layout/head", "head"), {
    ": 'layoutHead: HEAD /layout/head'",
    "curl -I --url 'https://eu.example.com/v1/layout/head'",
  })
end

T["layout"]["every line but the last ends with a backslash"] = function()
  expect.equality(build("/layout/lines", "get"), {
    ": 'layoutLines: GET /layout/lines'",
    "curl --url 'https://eu.example.com/v1/layout/lines' \\",
    "  -H 'X-A: a' \\",
    "  -H 'X-B: b'",
  })
end

-- url

T["url"] = MiniTest.new_set()

local function url_of(path, method)
  return build(path, method or "get")[2]
end

T["url"]["the operation's server wins"] = function()
  expect.equality(url_of("/servers/operation"), "curl --url 'https://op.example.com/servers/operation'")
end

T["url"]["the path item's server is next"] = function()
  expect.equality(url_of("/servers/path-item"), "curl --url 'https://path.example.com/servers/path-item'")
end

T["url"]["the root server is next"] = function()
  expect.equality(url_of("/layout/get"), "curl --url 'https://eu.example.com/v1/layout/get'")
end

T["url"]["no server gives ${BASE_URL}/"] = function()
  expect.equality(build_text("openapi: 3.1.0\npaths:\n  /pets:\n    get: {}\n", "/pets", "get"), {
    ": 'GET /pets'",
    [[curl --url "${BASE_URL}"'/pets']],
  })
end

T["url"]["a server URL starting with - stays the --url value"] = function()
  local text = 'openapi: 3.1.0\nservers: [{ url: "-K./evil" }]\npaths:\n  /pets:\n    get: {}\n'
  local line = build_text(text, "/pets", "get")[2]
  expect.equality(line, [[curl --url "${BASE_URL}"'-K./evil/pets']])
  expect.equality(line:find("%s%-K") == nil and line:find("%s'%-K") == nil, true)
end

T["url"]["variable defaults are substituted"] = function()
  expect.equality(url_of("/servers/defaults"), "curl --url 'https://api.example.com:8443/base/servers/defaults'")
end

T["url"]["a variable with no default becomes a placeholder"] = function()
  expect.equality(url_of("/servers/no-default"), [[curl --url 'https://'"${TENANT}"'.example.com/servers/no-default']])
end

T["url"]["an undeclared variable becomes a placeholder"] = function()
  expect.equality(url_of("/servers/undeclared"), [[curl --url 'https://'"${ZONE}"'.example.com/servers/undeclared']])
end

T["url"]["a relative server starts with ${BASE_URL}"] = function()
  expect.equality(url_of("/servers/relative"), [[curl --url "${BASE_URL}"'/api/v2/servers/relative']])
end

T["url"]["//host gets https:"] = function()
  expect.equality(url_of("/servers/scheme-relative"), "curl --url 'https://host.example.com/servers/scheme-relative'")
end

T["url"]["trailing slashes are removed before the path"] = function()
  expect.equality(url_of("/servers/trailing"), "curl --url 'https://slash.example.com/servers/trailing'")
end

-- path parameters

T["path parameters"] = MiniTest.new_set()

T["path parameters"]["a parameter with no example becomes a placeholder"] = function()
  expect.equality(url_of("/pets/{petId}"), [[curl --url 'https://eu.example.com/v1/pets/'"${PET_ID}"]])
end

T["path parameters"]["an example is used and percent-encoded"] = function()
  expect.equality(url_of("/files/{name}"), "curl --url 'https://eu.example.com/v1/files/a%20b%2Fc'")
end

T["path parameters"]["label style"] = function()
  expect.equality(url_of("/label/{id}"), "curl --url 'https://eu.example.com/v1/label/.5'")
end

T["path parameters"]["matrix style"] = function()
  expect.equality(url_of("/matrix/{id}"), "curl --url 'https://eu.example.com/v1/matrix/;id=5'")
end

T["path parameters"]["a template name with no parameter becomes a placeholder"] = function()
  expect.equality(url_of("/missing/{thing}"), [[curl --url 'https://eu.example.com/v1/missing/'"${THING}"]])
end

-- query

T["query"] = MiniTest.new_set()

T["query"]["only required parameters are included"] = function()
  expect.equality(url_of("/query/required"), "curl --url 'https://eu.example.com/v1/query/required?q=x'")
end

T["query"]["form explode array repeats the name"] = function()
  expect.equality(
    url_of("/query/form-explode"),
    "curl --url 'https://eu.example.com/v1/query/form-explode?ids=1&ids=2'"
  )
end

T["query"]["form non-explode array joins with commas"] = function()
  expect.equality(url_of("/query/form-flat"), "curl --url 'https://eu.example.com/v1/query/form-flat?ids=1,2'")
end

T["query"]["spaceDelimited and pipeDelimited"] = function()
  expect.equality(url_of("/query/delimited"), "curl --url 'https://eu.example.com/v1/query/delimited?a=1%202&b=1|2'")
end

T["query"]["form explode and non-explode objects"] = function()
  expect.equality(url_of("/query/objects"), "curl --url 'https://eu.example.com/v1/query/objects?x=1&y=2&o2=x,1,y,2'")
end

T["query"]["deepObject adds -g"] = function()
  expect.equality(build("/query/deep", "get"), {
    ": 'queryDeep: GET /query/deep'",
    "curl -g --url 'https://eu.example.com/v1/query/deep?filter[color]=red&filter[size]=2'",
  })
end

T["query"]["allowReserved keeps reserved characters"] = function()
  expect.equality(url_of("/query/reserved"), "curl --url 'https://eu.example.com/v1/query/reserved?r=a/b?c&s=a%2Fb'")
end

T["query"]["a placeholder alone adds no -g"] = function()
  expect.equality(url_of("/query/placeholder"), [[curl --url 'https://eu.example.com/v1/query/placeholder?q='"${Q}"]])
end

T["query"]["a content parameter uses its example as compact JSON"] = function()
  expect.equality(
    url_of("/query/content"),
    "curl --url 'https://eu.example.com/v1/query/content?filter=%7B%22a%22%3A1%7D'"
  )
end

-- headers, cookies and auth

T["headers and cookies"] = MiniTest.new_set()

T["headers and cookies"]["required headers in parameter order, optional left out"] = function()
  expect.equality(build("/headers", "get"), {
    ": 'headers: GET /headers'",
    "curl --url 'https://eu.example.com/v1/headers' \\",
    [[  -H 'X-Request-Id: '"${X_REQUEST_ID}" \]],
    "  -H 'X-Trace: t1'",
  })
end

T["headers and cookies"]["cookies join in one -b"] = function()
  expect.equality(build("/cookies", "get"), {
    ": 'cookies: GET /cookies'",
    "curl --url 'https://eu.example.com/v1/cookies' \\",
    [[  -b 'session=abc; lang='"${LANG_COOKIE}"]],
  })
end

T["headers and cookies"]["Accept, Content-Type and Authorization parameters are skipped"] = function()
  expect.equality(build("/headers/skipped", "get"), {
    ": 'headersSkipped: GET /headers/skipped'",
    "curl --url 'https://eu.example.com/v1/headers/skipped' \\",
    "  -H 'X-Keep: k'",
  })
end

T["headers and cookies"]["a parameter that duplicates an apiKey header is skipped"] = function()
  expect.equality(build("/headers/duplicate", "get"), {
    ": 'headersDuplicate: GET /headers/duplicate'",
    "curl --url 'https://eu.example.com/v1/headers/duplicate' \\",
    [[  -H 'X-API-Key: '"${API_KEY}"]],
  })
end

T["headers and cookies"]['header example with $, ", ` and \\ stays literal'] = function()
  expect.equality(build("/headers/quoting", "get"), {
    ": 'headersQuoting: GET /headers/quoting'",
    "curl --url 'https://eu.example.com/v1/headers/quoting' \\",
    [[  -H 'X-Q: a$b"c`d\e']],
  })
end

local TOKEN_DOC = [[
openapi: 3.1.0
paths:
  /tokens:
    get:
      parameters:
        - { name: "@./h", in: header, required: true, example: a }
        - { name: "X:Y", in: header, required: true, example: b }
        - { name: "X Y", in: header, required: true, example: c }
        - { name: "", in: header, required: true, example: d }
        - { name: X-Ok, in: header, required: true, example: e }
  /key:
    get:
      security:
        - { bad: [], good: [] }
components:
  securitySchemes:
    bad: { type: apiKey, in: header, name: "@./h" }
    good: { type: apiKey, in: query, name: k }
]]

T["headers and cookies"]["a header parameter name that is not a token is skipped"] = function()
  local out = build_text(TOKEN_DOC, "/tokens", "get")
  expect.equality(out, {
    ": 'GET /tokens'",
    [[curl --url "${BASE_URL}"'/tokens' \]],
    "  -H 'X-Ok: e'",
  })
  for _, line in ipairs(out) do
    expect.equality(line:find("-H '@", 1, true), nil)
  end
end

T["headers and cookies"]["an apiKey header name that is not a token adds no flag and claims no name"] = function()
  local out = build_text(TOKEN_DOC, "/key", "get")
  expect.equality(out, {
    ": 'GET /key'",
    [[curl --url "${BASE_URL}"'/key?k='"${API_KEY}"]],
  })
end

T["auth"] = MiniTest.new_set()

T["auth"]["apiKey in header, query and cookie"] = function()
  expect.equality(build("/auth/apikey", "get"), {
    ": 'authApiKey: GET /auth/apikey'",
    [[curl --url 'https://eu.example.com/v1/auth/apikey?q=1&api_key='"${API_KEY_2}" \]],
    [[  -H 'X-API-Key: '"${API_KEY}" \]],
    [[  -b 'key='"${API_KEY_3}"]],
  })
end

T["auth"]["http bearer, case-insensitive"] = function()
  expect.equality(build("/auth/bearer", "get"), {
    ": 'authBearer: GET /auth/bearer'",
    "curl --url 'https://eu.example.com/v1/auth/bearer' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}"]],
  })
end

T["auth"]["oauth2 and openIdConnect as bearer"] = function()
  expect.equality(build("/auth/oauth", "get"), {
    ": 'authOauth: GET /auth/oauth'",
    "curl --url 'https://eu.example.com/v1/auth/oauth' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}" \]],
    [[  -H 'Authorization: Bearer '"${TOKEN_2}"]],
  })
end

T["auth"]["http basic gives -u"] = function()
  expect.equality(build("/auth/basic", "get"), {
    ": 'authBasic: GET /auth/basic'",
    "curl --url 'https://eu.example.com/v1/auth/basic' \\",
    [[  -u "${USERNAME}"':'"${PASSWORD}"]],
  })
end

T["auth"]["another http scheme keeps its name"] = function()
  expect.equality(build("/auth/digest", "get"), {
    ": 'authDigest: GET /auth/digest'",
    "curl --url 'https://eu.example.com/v1/auth/digest' \\",
    [[  -H 'Authorization: Digest '"${TOKEN}"]],
  })
end

T["auth"]["mutualTLS is skipped"] = function()
  expect.equality(build("/auth/mtls", "get"), {
    ": 'authMtls: GET /auth/mtls'",
    "curl --url 'https://eu.example.com/v1/auth/mtls'",
  })
end

T["auth"]["empty security gives no auth"] = function()
  expect.equality(build("/public", "get", "curl-30.yaml"), {
    ": 'public: GET /public'",
    "curl --url 'https://api.example.com/public'",
  })
end

T["auth"]["a first requirement {} gives no auth"] = function()
  expect.equality(build("/empty-first", "get", "curl-30.yaml"), {
    ": 'emptyFirst: GET /empty-first'",
    "curl --url 'https://api.example.com/empty-first'",
  })
end

T["auth"]["only the first requirement is used"] = function()
  expect.equality(build("/auth/first-only", "get"), {
    ": 'authFirstOnly: GET /auth/first-only'",
    "curl --url 'https://eu.example.com/v1/auth/first-only' \\",
    [[  -u "${USERNAME}"':'"${PASSWORD}"]],
  })
end

T["auth"]["two schemes in one requirement keep their order"] = function()
  expect.equality(build("/auth/two", "get"), {
    ": 'authTwo: GET /auth/two'",
    "curl --url 'https://eu.example.com/v1/auth/two' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}" \]],
    [[  -H 'X-API-Key: '"${API_KEY}"]],
  })
end

T["auth"]["a missing scheme name is skipped"] = function()
  expect.equality(build("/auth/missing", "get"), {
    ": 'authMissing: GET /auth/missing'",
    "curl --url 'https://eu.example.com/v1/auth/missing' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}"]],
  })
end

T["auth"]["root security is inherited"] = function()
  expect.equality(build("/inherited", "get", "curl-30.yaml"), {
    ": 'inherited: GET /inherited'",
    "curl --url 'https://api.example.com/inherited' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}"]],
  })
end

T["auth"]["a $ref scheme is followed"] = function()
  expect.equality(build("/auth/ref", "get"), {
    ": 'authRef: GET /auth/ref'",
    "curl --url 'https://eu.example.com/v1/auth/ref' \\",
    [[  -u "${USERNAME}"':'"${PASSWORD}"]],
  })
end

T["auth"]["two bearer schemes give TOKEN and TOKEN_2"] = function()
  expect.equality(build("/auth/two-bearer", "get"), {
    ": 'authTwoBearer: GET /auth/two-bearer'",
    "curl --url 'https://eu.example.com/v1/auth/two-bearer' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}" \]],
    [[  -H 'Authorization: Bearer '"${TOKEN_2}"]],
  })
end

-- request body

T["media type"] = MiniTest.new_set()

T["media type"]["application/json is chosen among others"] = function()
  expect.equality(build("/media/json-among", "post"), {
    ": 'mediaJsonAmong: POST /media/json-among'",
    "curl -X POST --url 'https://eu.example.com/v1/media/json-among' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": 1',
    "  }'",
  })
end

T["media type"]["application/json; charset=utf-8 matches"] = function()
  expect.equality(build("/media/charset", "post"), {
    ": 'mediaCharset: POST /media/charset'",
    "curl -X POST --url 'https://eu.example.com/v1/media/charset' \\",
    "  -H 'Content-Type: application/json; charset=utf-8' \\",
    "  --data-raw '{",
    '    "a": 1',
    "  }'",
  })
end

T["media type"]["application/vnd.x+json without application/json"] = function()
  expect.equality(build("/media/vnd", "post"), {
    ": 'mediaVnd: POST /media/vnd'",
    "curl -X POST --url 'https://eu.example.com/v1/media/vnd' \\",
    "  -H 'Content-Type: application/vnd.x+json' \\",
    "  --data-raw '[",
    "    1",
    "  ]'",
  })
end

T["media type"]["the first type otherwise"] = function()
  expect.equality(build("/media/first", "post"), {
    ": 'mediaFirst: POST /media/first'",
    "curl -X POST --url 'https://eu.example.com/v1/media/first' \\",
    "  -H 'Content-Type: application/xml' \\",
    "  --data-raw '<a/>'",
  })
end

T["media type"]["*/* gets no Content-Type"] = function()
  expect.equality(build("/media/any", "post"), {
    ": 'mediaAny: POST /media/any'",
    "curl -X POST --url 'https://eu.example.com/v1/media/any' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"] = MiniTest.new_set()

T["body"]["body from example"] = function()
  expect.equality(build("/body/example", "post"), {
    ": 'bodyExample: POST /body/example'",
    "curl -X POST --url 'https://eu.example.com/v1/body/example' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "name": "Rex",',
    '    "tags": [',
    '      "a"',
    "    ]",
    "  }'",
  })
end

T["body"]["body from examples skips a broken entry and an externalValue entry"] = function()
  expect.equality(build("/body/examples", "post"), {
    ": 'bodyExamples: POST /body/examples'",
    "curl -X POST --url 'https://eu.example.com/v1/body/examples' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "n": 1',
    "  }'",
  })
end

T["body"]["body from the schema"] = function()
  expect.equality(build("/body/schema", "post"), {
    ": 'bodySchema: POST /body/schema'",
    "curl -X POST --url 'https://eu.example.com/v1/body/schema' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "name": "string",',
    '    "born": "1970-01-01"',
    "  }'",
  })
end

T["body"]["a top-level cycle gives {}"] = function()
  expect.equality(build("/body/cycle", "post"), {
    ": 'bodyCycle: POST /body/cycle'",
    "curl -X POST --url 'https://eu.example.com/v1/body/cycle' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{}'",
  })
end

T["body"]["a scalar body prints inline"] = function()
  expect.equality(build("/body/scalar", "post"), {
    ": 'bodyScalar: POST /body/scalar'",
    "curl -X POST --url 'https://eu.example.com/v1/body/scalar' \\",
    "  -H 'Content-Type: application/json' \\",
    [[  --data-raw '"string"']],
  })
end

T["body"]["a single quote in a string becomes '\\''"] = function()
  expect.equality(build("/body/quote", "post"), {
    ": 'bodyQuote: POST /body/quote'",
    "curl -X POST --url 'https://eu.example.com/v1/body/quote' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    [[    "name": "O'\''Brien"]],
    "  }'",
  })
end

T["body"]["GET with a body has -X GET"] = function()
  expect.equality(build("/body/get", "get"), {
    ": 'bodyGet: GET /body/get'",
    "curl -X GET --url 'https://eu.example.com/v1/body/get' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": 1',
    "  }'",
  })
end

T["body"]["a broken body has no body flags and no Content-Type"] = function()
  expect.equality(build("/body/broken", "post"), {
    ": 'bodyBroken: POST /body/broken'",
    "curl -X POST --url 'https://eu.example.com/v1/body/broken'",
  })
end

T["body"]["no example and no schema gives @${BODY_FILE}"] = function()
  expect.equality(build("/body/none", "post"), {
    ": 'bodyNone: POST /body/none'",
    "curl -X POST --url 'https://eu.example.com/v1/body/none' \\",
    "  -H 'Content-Type: application/json' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"]["form urlencoded gives one --data-urlencode per property"] = function()
  expect.equality(build("/body/form", "post"), {
    ": 'bodyForm: POST /body/form'",
    "curl -X POST --url 'https://eu.example.com/v1/body/form' \\",
    "  --data-urlencode 'name=string' \\",
    [[  --data-urlencode 'tags=["string"]' \]],
    [[  --data-urlencode 'meta={"a":0}']],
  })
end

T["body"]["form urlencoded with a non-object value falls back to @${BODY_FILE}"] = function()
  expect.equality(build("/body/form-scalar", "post"), {
    ": 'bodyFormScalar: POST /body/form-scalar'",
    "curl -X POST --url 'https://eu.example.com/v1/body/form-scalar' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"]["multipart gives -F and @${NAME_FILE} for binary and contentMediaType"] = function()
  expect.equality(build("/body/multipart", "post"), {
    ": 'bodyMultipart: POST /body/multipart'",
    "curl -X POST --url 'https://eu.example.com/v1/body/multipart' \\",
    "  --form-string 'name=string' \\",
    [[  -F 'file=@'"${FILE_FILE}" \]],
    [[  -F 'avatar=@'"${AVATAR_FILE}"]],
  })
end

T["body"]["a format: binary file field with a key curl would read falls back to @${BODY_FILE}"] = function()
  expect.equality(build("/body/multipart-binary-key", "post"), {
    ": 'bodyMultipartBinaryKey: POST /body/multipart-binary-key'",
    "curl -X POST --url 'https://eu.example.com/v1/body/multipart-binary-key' \\",
    "  -H 'Content-Type: multipart/form-data' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"]["a contentMediaType file field with a key curl would read falls back to @${BODY_FILE}"] = function()
  expect.equality(build("/body/multipart-media-key", "post"), {
    ": 'bodyMultipartMediaKey: POST /body/multipart-media-key'",
    "curl -X POST --url 'https://eu.example.com/v1/body/multipart-media-key' \\",
    "  -H 'Content-Type: multipart/form-data' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"]["multipart text fields use --form-string, so @, < and ;type stay literal"] = function()
  expect.equality(build("/body/multipart-literal", "post"), {
    ": 'bodyMultipartLiteral: POST /body/multipart-literal'",
    "curl -X POST --url 'https://eu.example.com/v1/body/multipart-literal' \\",
    "  --form-string 'at=@/etc/passwd' \\",
    "  --form-string 'lt=<notes.txt' \\",
    "  --form-string 'k=@v=x' \\",
    "  --form-string 'k;type=text/html=y'",
  })
end

T["body"]["text with a string example"] = function()
  expect.equality(build("/body/text", "post"), {
    ": 'bodyText: POST /body/text'",
    "curl -X POST --url 'https://eu.example.com/v1/body/text' \\",
    "  -H 'Content-Type: text/plain' \\",
    "  --data-raw 'hello world'",
  })
end

T["body"]["text without a string example gives @${BODY_FILE}"] = function()
  expect.equality(build("/body/text-none", "post"), {
    ": 'bodyTextNone: POST /body/text-none'",
    "curl -X POST --url 'https://eu.example.com/v1/body/text-none' \\",
    "  -H 'Content-Type: text/plain' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"]["application/octet-stream gives @${BODY_FILE}"] = function()
  expect.equality(build("/body/octet", "post"), {
    ": 'bodyOctet: POST /body/octet'",
    "curl -X POST --url 'https://eu.example.com/v1/body/octet' \\",
    "  -H 'Content-Type: application/octet-stream' \\",
    [[  --data-binary '@'"${BODY_FILE}"]],
  })
end

T["body"]["placeholders follow the assignment order"] = function()
  expect.equality(build("/order/{id}", "post"), {
    ": 'order: POST /order/{id}'",
    [[curl -X POST --url "${BASE_URL}""${BASE}"'/v1/order/'"${ID}"'?id='"${ID_QUERY}" \]],
    [[  -H 'Authorization: Bearer '"${TOKEN}" \]],
    [[  -H 'id: '"${ID_HEADER}" \]],
    [[  -H 'token: '"${TOKEN_HEADER}" \]],
    [[  -b 'id='"${ID_COOKIE}" \]],
    [[  -F 'id=@'"${ID_FILE}"]],
  })
end

T["body"]["an external schema ref loads its file"] = function()
  local ws = workspace.new({ root = MULTI })
  local document = assert(model.load(ws, assert(ws:open_file(MULTI .. "/curl.yaml"))))
  expect.equality(build_in(document, "/pets", "post"), {
    ": 'addPet: POST /pets'",
    "curl -X POST --url 'https://api.example.com/pets' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "owner": {',
    '      "name": "string"',
    "    },",
    '    "back": {',
    '      "id": 0,',
    '      "owner": {',
    '        "name": "string"',
    "      },",
    '      "gone": null',
    "    }",
    "  }'",
  })
  expect.equality(vim.tbl_contains(ws:loaded_files(), MULTI .. "/schemas/pet.yaml"), true)
end

-- control characters

T["control characters"] = MiniTest.new_set()

local CONTROL_DOC = [[
openapi: 3.1.0
servers:
  - url: "https://h\x01\u0085.example.com/{v}\x7f"
    variables:
      v: { default: "a\x1bb" }
paths:
  /server:
    get: {}
  /headers:
    get:
      parameters:
        - { name: X-A, in: header, required: true, example: "v\x1bw\tz" }
        - { name: "X-\x01B", in: header, required: true, example: b }
        - { name: "c\x01", in: cookie, required: true, example: "v\x07" }
  /apikey:
    get:
      security:
        - { key: [], odd: [] }
  /form:
    post:
      requestBody:
        content:
          application/x-www-form-urlencoded:
            example: { a: "x\x01y" }
  /multipart:
    post:
      requestBody:
        content:
          multipart/form-data:
            example: { a: "x\x02" }
  /text:
    post:
      requestBody:
        content:
          text/plain:
            example: "a\tb\x01c\nd"
  /newline:
    get:
      parameters:
        - { name: X-N, in: header, required: true, example: "a\nb" }
        - { name: X-Last, in: header, required: true, example: z }
  /c1:
    post:
      parameters:
        - { name: X-C, in: header, required: true, example: "a\u009fb" }
        - { name: "X-\u0080", in: header, required: true, example: c }
      requestBody:
        content:
          text/plain:
            example: "x\u0085y"
components:
  securitySchemes:
    key: { type: apiKey, in: header, name: "K\x01" }
    odd: { type: http, scheme: "Dig\x01est" }
]]

local CONTROL_SERVER = "https://h%01%C2%85.example.com/a%1Bb%7F"

local function control(path, method)
  return build_text(CONTROL_DOC, path, method or "get")
end

T["control characters"]["C1 characters become U+FFFD in a header value and in a text body"] = function()
  local R = REPLACEMENT
  expect.equality(control("/c1", "post"), {
    ": 'POST /c1'",
    "curl -X POST --url '" .. CONTROL_SERVER .. "/c1' \\",
    "  -H 'X-C: a" .. R .. "b' \\",
    "  -H 'Content-Type: text/plain' \\",
    "  --data-raw 'x" .. R .. "y'",
  })
end

T["control characters"]["are percent-encoded in the server URL, defaults included"] = function()
  expect.equality(control("/server"), { ": 'GET /server'", "curl --url '" .. CONTROL_SERVER .. "/server'" })
end

T["control characters"]["become U+FFFD in header values and cookie names and values"] = function()
  local R = REPLACEMENT
  expect.equality(control("/headers"), {
    ": 'GET /headers'",
    "curl --url '" .. CONTROL_SERVER .. "/headers' \\",
    "  -H 'X-A: v" .. R .. "w" .. R .. "z' \\",
    "  -b 'c" .. R .. "=v" .. R .. "'",
  })
end

T["control characters"]["skip an apiKey name, and become U+FFFD in scheme text"] = function()
  local R = REPLACEMENT
  expect.equality(control("/apikey"), {
    ": 'GET /apikey'",
    "curl --url '" .. CONTROL_SERVER .. "/apikey' \\",
    "  -H 'Authorization: Dig" .. R .. [[est '"${TOKEN}"]],
  })
end

T["control characters"]["become U+FFFD in form and multipart text"] = function()
  local R = REPLACEMENT
  expect.equality(control("/form", "post")[3], "  --data-urlencode 'a=x" .. R .. "y'")
  expect.equality(control("/multipart", "post")[3], "  --form-string 'a=x" .. R .. "'")
end

T["control characters"]["become U+FFFD in a text body, and its newline stays"] = function()
  local R = REPLACEMENT
  expect.equality(control("/text", "post"), {
    ": 'POST /text'",
    "curl -X POST --url '" .. CONTROL_SERVER .. "/text' \\",
    "  -H 'Content-Type: text/plain' \\",
    "  --data-raw 'a" .. R .. "b" .. R .. "c",
    "d'",
  })
end

T["control characters"]["a newline in a flag's text continues the quoted word on the next line"] = function()
  expect.equality(control("/newline"), {
    ": 'GET /newline'",
    "curl --url '" .. CONTROL_SERVER .. "/newline' \\",
    "  -H 'X-N: a",
    "b' \\",
    "  -H 'X-Last: z'",
  })
end

-- reserved placeholder names

T["reserved names"] = MiniTest.new_set()

T["reserved names"]["count as claimed, so the suffix rule applies"] = function()
  local names = curl._names
  local claims = names.new_claims()
  expect.equality({
    names.claim(claims, "HOME", "a"),
    names.claim(claims, "PATH", "b", "QUERY"),
    names.claim(claims, "CURL_HOME", "c", "HEADER"),
    names.claim(claims, "ZSH_X", "d"),
    names.claim(claims, "TOKEN", "e"),
  }, { "HOME_2", "PATH_QUERY", "CURL_HOME_HEADER", "ZSH_X_2", "TOKEN" })
end

T["reserved names"]["path, user and prefixed names in a command"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "servers:",
    '  - url: "https://{user}.example.com"',
    "    variables:",
    "      user: { enum: [a] }",
    "paths:",
    "  /reserved:",
    "    get:",
    "      parameters:",
    "        - { name: path, in: query, required: true }",
    "        - { name: Bash-Env, in: header, required: true }",
    "        - { name: lc_time, in: cookie, required: true }",
    "        - { name: https_proxy, in: query, required: true }",
    "",
  }, "\n")
  expect.equality(build_text(text, "/reserved", "get"), {
    ": 'GET /reserved'",
    [[curl --url 'https://'"${USER_2}"'.example.com/reserved?path='"${PATH_QUERY}"'&https_proxy='"${HTTPS_PROXY_QUERY}" \]],
    [[  -H 'Bash-Env: '"${BASH_ENV_HEADER}" \]],
    [[  -b 'lc_time='"${LC_TIME_COOKIE}"]],
  })
end

-- size budget

T["budget"] = MiniTest.new_set()

local function anchor_bomb()
  local out = { "openapi: 3.1.0", "x-a:", "  l0: &l0 [x, x, x, x, x, x, x, x, x, x]" }
  for level = 1, 8 do
    local items = {}
    for index = 1, 10 do
      items[index] = "*l" .. (level - 1)
    end
    out[#out + 1] = string.format("  l%d: &l%d [%s]", level, level, table.concat(items, ", "))
  end
  vim.list_extend(out, {
    "paths:",
    "  /bomb:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            example: *l8",
    "",
  })
  return table.concat(out, "\n")
end

local function ref_fan_out()
  local out = {
    "openapi: 3.1.0",
    "paths:",
    "  /fan:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    '            schema: { $ref: "#/components/schemas/S0" }',
    "components:",
    "  schemas:",
  }
  for level = 0, 7 do
    local properties = {}
    for index = 0, 9 do
      properties[#properties + 1] = string.format('p%d: { $ref: "#/components/schemas/S%d" }', index, level + 1)
    end
    out[#out + 1] = string.format("    S%d: { properties: { %s } }", level, table.concat(properties, ", "))
  end
  out[#out + 1] = "    S8: { type: string }"
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

local NOTE = ": 'oas-glance: example cut at size budget'"
local MAX_BYTES = 1024 * 1024
-- Quotes, indentation and the curl flags around the cut values.
local OVERHEAD = 4096

local function expect_cut(text, path, extra)
  local start = vim.uv.hrtime()
  local out = build_text(text, path, "post")
  local elapsed = (vim.uv.hrtime() - start) / 1e9
  expect.equality(elapsed < 2, true)
  expect.equality(out[2], NOTE)
  expect.equality(out[3]:match("^curl ") ~= nil, true)
  expect.equality(#out < 20100, true)
  local size = 0
  for _, line in ipairs(out) do
    size = size + #line + 1
  end
  expect.equality(size < MAX_BYTES + OVERHEAD + (extra or 0), true)
  return out
end

local function repeated(count)
  local items = {}
  for index = 1, count do
    items[index] = "{v}"
  end
  return table.concat(items, "/")
end

--- A POST whose server URL or path repeats one template variable `count` times.
local function repeated_template(where, count)
  local big = string.rep("v", 64 * 1024)
  local template = repeated(count)
  if where == "server" then
    return table.concat({
      "openapi: 3.1.0",
      "servers:",
      '  - url: "https://h.example.com/' .. template .. '"',
      "    variables:",
      "      v: { default: " .. big .. " }",
      "paths:",
      "  /p:",
      "    post: {}",
      "",
    }, "\n")
  end
  return table.concat({
    "openapi: 3.1.0",
    "servers: [{ url: https://h.example.com }]",
    "paths:",
    '  "/' .. template .. '":',
    "    post:",
    "      parameters:",
    "        - { name: v, in: path, required: true, example: " .. big .. " }",
    "",
  }, "\n")
end

-- Each occurrence past the budget stays, as `'/'"${V}"` for the template's `/{v}`: 9 bytes, not amplified.
local PLACEHOLDER_BYTES = 9

T["budget"]["a long server variable default repeated 1000 times is cut by size"] = function()
  local out = expect_cut(repeated_template("server", 1000), "/p", 1000 * PLACEHOLDER_BYTES)
  expect.equality(out[3]:find('"${V}"', 1, true) ~= nil, true)
end

T["budget"]["a long path example repeated 1000 times is cut by size"] = function()
  local path = "/" .. repeated(1000)
  local out = expect_cut(repeated_template("path", 1000), path, 1000 * PLACEHOLDER_BYTES)
  expect.equality(out[3]:find('"${V}"', 1, true) ~= nil, true)
end

T["budget"]["max_bytes counts each server variable default and the template pieces"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "servers:",
    '  - url: "https://{v}.{v}.x"',
    "    variables:",
    "      v: { default: abcd }",
    "paths:",
    "  /p:",
    "    get: {}",
    "",
  }, "\n")
  expect.equality(build_text(text, "/p", "get", { max_bytes = 12 }), {
    ": 'GET /p'",
    NOTE,
    [[curl --url 'https://abcd.'"${V}"'.x/p']],
  })
end

T["budget"]["max_bytes counts each occurrence of a path parameter"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /a/{id}/{id}:",
    "    get:",
    "      parameters:",
    "        - { name: id, in: path, required: true, example: xyz }",
    "",
  }, "\n")
  expect.equality(build_text(text, "/a/{id}/{id}", "get", { max_bytes = 10 }), {
    ": 'GET /a/{id}/{id}'",
    NOTE,
    [[curl --url "${BASE_URL}"'/a/xyz/'"${ID}"]],
  })
end

--- A body example of `count` aliases of `anchored`, defined under `x-a`.
local function aliased(anchored, count)
  local items = {}
  for index = 1, count do
    items[index] = "*big"
  end
  return table.concat({
    "openapi: 3.1.0",
    "x-a:",
    "  big: &big " .. anchored,
    "paths:",
    "  /big:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            example: [" .. table.concat(items, ", ") .. "]",
    "",
  }, "\n")
end

T["budget"]["nested YAML anchors are cut"] = function()
  expect_cut(anchor_bomb(), "/bomb")
end

T["budget"]["$ref fan-out is cut"] = function()
  expect_cut(ref_fan_out(), "/fan")
end

T["budget"]["a long anchored string aliased 1000 times is cut by size"] = function()
  local out = expect_cut(aliased(string.rep("x", 64 * 1024), 1000), "/big")
  -- The URL text `/` and `/big` takes 5 bytes, so 15 strings fit.
  expect.equality(#out, 4 + 15 + 2)
end

T["budget"]["a long map key aliased 1000 times is cut by size"] = function()
  local out = expect_cut(aliased("{ " .. string.rep("k", 64 * 1024) .. ": 1 }", 1000), "/big")
  -- 15 maps fit whole. The 16th fits, but its key does not, so it stays empty.
  expect.equality(#out, 4 + 15 * 3 + 1 + 2)
  expect.equality(out[#out - 1], "    {}")
end

T["budget"]["a long schema example reached through many $refs is cut by size"] = function()
  local out = {
    "openapi: 3.1.0",
    "paths:",
    "  /fan:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    '            schema: { $ref: "#/components/schemas/S0" }',
    "components:",
    "  schemas:",
  }
  for level = 0, 2 do
    local properties = {}
    for index = 0, 9 do
      properties[#properties + 1] = string.format('p%d: { $ref: "#/components/schemas/S%d" }', index, level + 1)
    end
    out[#out + 1] = string.format("    S%d: { properties: { %s } }", level, table.concat(properties, ", "))
  end
  out[#out + 1] = "    S3: { type: string, examples: [" .. string.rep("e", 64 * 1024) .. "] }"
  out[#out + 1] = ""
  expect_cut(table.concat(out, "\n"), "/fan")
end

T["budget"]["max_bytes counts strings, numbers and keys of an example"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /small:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            example: { a: abc, bb: de, c: 1 }",
    "",
  }, "\n")
  -- 7 bytes for the URL text `/` and `/small`, 30 for `Content-Type: application/json`, then 8 for the body.
  expect.equality(build_text(text, "/small", "post", { max_bytes = 7 + 30 + 8 }), {
    ": 'POST /small'",
    NOTE,
    [[curl -X POST --url "${BASE_URL}"'/small' \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": "abc",',
    '    "bb": "de"',
    "  }'",
  })
end

T["budget"]["max_bytes counts placeholders and property names of a generated schema"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /small:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            schema:",
    "              properties:",
    "                a: { type: string }",
    "                b: { type: integer }",
    "                c: { type: boolean }",
    "",
  }, "\n")
  expect.equality(build_text(text, "/small", "post", { max_bytes = 7 + 30 + 11 }), {
    ": 'POST /small'",
    NOTE,
    [[curl -X POST --url "${BASE_URL}"'/small' \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": "string",',
    '    "b": 0',
    "  }'",
  })
end

T["budget"]["max_values drops the values past the budget from an example"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /small:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            example: { a: 1, b: [2, 3], c: 4 }",
    "",
  }, "\n")
  expect.equality(build_text(text, "/small", "post", { max_values = 5 }), {
    ": 'POST /small'",
    NOTE,
    [[curl -X POST --url "${BASE_URL}"'/small' \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": 1,',
    '    "b": [',
    "      2,",
    "      3",
    "    ]",
    "  }'",
  })
end

T["budget"]["max_values drops the values past the budget from a generated schema"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /small:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            schema:",
    "              properties:",
    "                a: { type: string }",
    "                b: { type: integer }",
    "                c: { type: boolean }",
    "                d: { enum: [x] }",
    "                e: { type: string }",
    "                f: { type: string }",
    "",
  }, "\n")
  expect.equality(build_text(text, "/small", "post", { max_values = 5 }), {
    ": 'POST /small'",
    NOTE,
    [[curl -X POST --url "${BASE_URL}"'/small' \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": "string",',
    '    "b": 0,',
    '    "c": true,',
    '    "d": "x"',
    "  }'",
  })
end

--- A POST with one parameter of a 64 KiB name whose example has 1000 items.
local function exploded(location, style, example)
  local name = string.rep("n", 64 * 1024)
  local path = location == "path" and "/x/{" .. name .. "}" or "/x"
  return table.concat({
    "openapi: 3.1.0",
    "servers: [{ url: https://h.example.com }]",
    "paths:",
    '  "' .. path .. '":',
    "    post:",
    "      parameters:",
    string.format(
      "        - { name: %s, in: %s, required: true, style: %s, explode: true, example: %s }",
      name,
      location,
      style,
      example
    ),
    "",
  }, "\n"),
    path
end

local function thousand(item)
  local items = {}
  for index = 1, 1000 do
    items[index] = item(index)
  end
  return table.concat(items, ", ")
end

local THOUSAND_ITEMS = "[" .. thousand(function()
  return "1"
end) .. "]"
local THOUSAND_KEYS = "{ " .. thousand(function(index)
  return "k" .. index .. ": 1"
end) .. " }"

T["budget"]["a long query name with an exploded 1000-item array is cut by size"] = function()
  expect_cut(exploded("query", "form", THOUSAND_ITEMS))
end

T["budget"]["a long query name with a 1000-key deepObject is cut by size"] = function()
  expect_cut(exploded("query", "deepObject", THOUSAND_KEYS))
end

T["budget"]["a long path name with a matrix-exploded 1000-item array is cut by size"] = function()
  local out = expect_cut(exploded("path", "matrix", THOUSAND_ITEMS))
  -- The items that fit stay, and no placeholder replaces them.
  expect.equality(out[3]:find(";" .. string.rep("n", 64 * 1024) .. "=1", 1, true) ~= nil, true)
  expect.equality(out[3]:find("${", 1, true), nil)
end

--- A POST whose path repeats `{id}` `count` times, with `example` for `id`.
local function repeated_path(count, example)
  local items = {}
  for index = 1, count do
    items[index] = "{id}"
  end
  local path = "/" .. table.concat(items, "/")
  return table.concat({
    "openapi: 3.1.0",
    "servers: [{ url: https://h.example.com }]",
    "paths:",
    '  "' .. path .. '":',
    "    post:",
    "      parameters:",
    "        - { name: id, in: path, required: true, example: " .. example .. " }",
    "",
  }, "\n"),
    path
end

-- Each occurrence past the budget stays as `'/'"${ID}"`.
local ID_PLACEHOLDER_BYTES = 10

T["budget"]["a long path example repeated 5000 times is encoded once"] = function()
  local text, path = repeated_path(5000, string.rep("e", 512 * 1024))
  local out = expect_cut(text, path, 5000 * ID_PLACEHOLDER_BYTES)
  expect.equality(out[3]:find('"${ID}"', 1, true) ~= nil, true)
end

T["budget"]["an array path example with a long first item repeated 5000 times is encoded once"] = function()
  local text, path = repeated_path(5000, "[" .. string.rep("e", 512 * 1024) .. ", b]")
  local out = expect_cut(text, path, 5000 * ID_PLACEHOLDER_BYTES)
  -- Reading the example took 512 KiB, so its first item no longer fits and every occurrence is a placeholder.
  expect.equality(vim.startswith(out[3], [[curl -X POST --url 'https://h.example.com/'"${ID}"'/'"${ID}"]]), true)
  expect.equality(out[3]:find("eeee", 1, true), nil)
end

T["budget"]["max_bytes counts the name of each exploded query item"] = function()
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /q:",
    "    get:",
    "      parameters:",
    "        - { name: nm, in: query, required: true, example: [a, b, c] }",
    "",
  }, "\n")
  -- `/` and `/q` take 3 bytes and the example's values 3, then `?nm=a` and `&nm=b` take 5 each.
  expect.equality(build_text(text, "/q", "get", { max_bytes = 16 }), {
    ": 'GET /q'",
    NOTE,
    [[curl --url "${BASE_URL}"'/q?nm=a&nm=b']],
  })
end

T["budget"]["a normal operation has no note line"] = function()
  local out = build("/pets/{petId}/toys", "post")
  expect.equality(out[2]:match("^curl ") ~= nil, true)
  for _, line in ipairs(out) do
    expect.equality(line:find("example cut", 1, true), nil)
  end
end

-- whole command

T["whole command"] = MiniTest.new_set()

T["whole command"]["the spec 1 example"] = function()
  expect.equality(build("/pets/{petId}/toys", "post"), {
    ": 'createPet: POST /pets/{petId}/toys'",
    [[curl -X POST --url 'https://api.example.com/v1/pets/'"${PET_ID}"'/toys?limit=20' \]],
    [[  -H 'Authorization: Bearer '"${TOKEN}" \]],
    [[  -H 'X-Request-Id: '"${X_REQUEST_ID}" \]],
    [[  -b 'session='"${SESSION}" \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "name": "string",',
    '    "tags": [',
    '      "string"',
    "    ]",
    "  }'",
  })
end

T["whole command"]["flag order: auth, headers, cookies, Content-Type, body"] = function()
  expect.equality(build("/flag-order", "post"), {
    ": 'flagOrder: POST /flag-order'",
    "curl -X POST --url 'https://eu.example.com/v1/flag-order' \\",
    [[  -u "${USERNAME}"':'"${PASSWORD}" \]],
    "  -H 'X-A: a' \\",
    "  -b 'c=v' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": 1',
    "  }'",
  })
end

T["whole command"]["3.0 document"] = function()
  expect.equality(build("/pets", "post", "curl-30.yaml"), {
    ": 'createPet30: POST /pets'",
    "curl -X POST --url 'https://api.example.com/pets' \\",
    [[  -H 'Authorization: Bearer '"${TOKEN}" \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "name": "string",',
    '    "size": 3',
    "  }'",
  })
end

T["whole command"]["YAML and JSON give the same lines"] = function()
  local yaml = table.concat({
    "openapi: 3.1.0",
    "servers: [{ url: https://api.example.com }]",
    "paths:",
    "  /pets/{id}:",
    "    put:",
    "      operationId: put",
    "      parameters:",
    "        - { name: id, in: path, required: true }",
    "        - { name: v, in: query, required: true, example: 1.0 }",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            example: { a: [1, 2.50], b: { c: null } }",
    "",
  }, "\n")
  local json = [[
{
  "openapi": "3.1.0",
  "servers": [{ "url": "https://api.example.com" }],
  "paths": {
    "/pets/{id}": {
      "put": {
        "operationId": "put",
        "parameters": [
          { "name": "id", "in": "path", "required": true },
          { "name": "v", "in": "query", "required": true, "example": 1.0 }
        ],
        "requestBody": {
          "content": {
            "application/json": { "example": { "a": [1, 2.50], "b": { "c": null } } }
          }
        }
      }
    }
  }
}
]]
  local expected = {
    ": 'put: PUT /pets/{id}'",
    [[curl -X PUT --url 'https://api.example.com/pets/'"${ID}"'?v=1.0' \]],
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "a": [',
    "      1,",
    "      2.50",
    "    ],",
    '    "b": {',
    '      "c": null',
    "    }",
    "  }'",
  }
  expect.equality(build_text(yaml, "/pets/{id}", "put"), expected)
  expect.equality(build_text(json, "/pets/{id}", "put"), expected)
end

T["determinism"] = MiniTest.new_set()

T["determinism"]["building twice gives equal lines"] = function()
  local document = load_fixture("curl-31.yaml")
  local first = build_in(document, "/pets/{petId}/toys", "post")
  expect.equality(build_in(document, "/pets/{petId}/toys", "post"), first)
  expect.equality(build("/pets/{petId}/toys", "post"), first)
end

T["determinism"]["many keys in a non-sorted order keep source order"] = function()
  local properties, expected = {}, {}
  for index = 40, 1, -1 do
    local name = string.format("k%02d", (index * 7) % 41)
    properties[#properties + 1] = string.format("                %s: { type: integer }", name)
    expected[#expected + 1] = string.format('    "%s": 0', name) .. (index > 1 and "," or "")
  end
  local text = table.concat({
    "openapi: 3.1.0",
    "paths:",
    "  /many:",
    "    post:",
    "      requestBody:",
    "        content:",
    "          application/json:",
    "            schema:",
    "              properties:",
    table.concat(properties, "\n"),
    "",
  }, "\n")
  local lines = build_text(text, "/many", "post")
  expect.equality(vim.list_slice(lines, 5, 44), expected)
  expect.equality(#lines, 45)
end

return T
