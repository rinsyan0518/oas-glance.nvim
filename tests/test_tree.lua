local helpers = dofile("tests/helpers.lua")
local tree = require("oas-glance.internal.tree")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local BOM = "\239\187\191"
local FIXTURES = { "pretty", "minified", "tabs", "crlf", "escapes", "bom" }

local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

local function fixture_path(name)
  return "tests/fixtures/json/" .. name .. ".json"
end

local function fixture(name)
  return read_bytes(fixture_path(name))
end

local function oracle(name)
  local bytes = fixture(name)
  if vim.startswith(bytes, BOM) then
    bytes = bytes:sub(#BOM + 1)
  end
  return vim.json.decode(bytes)
end

local function parse_fixture(name)
  local doc = assert(tree.parse(fixture(name), { file = fixture_path(name) }))
  return doc
end

---@param node oas_glance.Node
---@param key string
---@return oas_glance.Node
local function get(node, key)
  return assert(tree.get(node, key), "no key " .. key)
end

local function decode_node(node)
  if node.kind == "map" then
    local result = vim.empty_dict()
    for _, entry in ipairs(tree.entries(node)) do
      result[entry.key] = decode_node(entry.value)
    end
    return result
  end
  if node.kind == "seq" then
    local result = {}
    for index, item in ipairs(tree.items(node)) do
      result[index] = decode_node(item)
    end
    return result
  end
  if node.scalar_type == "null" then
    return vim.NIL
  end
  return node.value
end

local function is_empty_dict(value)
  return next(value) == nil and getmetatable(value) == getmetatable(vim.empty_dict())
end

-- vim.deep_equal cannot tell {} from [], so each table's kind is checked against the oracle's.
local function kind_mismatches(node, expected, path, found)
  if node.kind == "map" then
    if
      type(expected) ~= "table"
      or (next(expected) == nil and not is_empty_dict(expected))
      or vim.islist(expected) and next(expected) ~= nil
    then
      found[#found + 1] = path .. ": map, oracle has " .. vim.inspect(expected)
      return found
    end
    for _, entry in ipairs(tree.entries(node)) do
      kind_mismatches(entry.value, expected[entry.key], path .. "/" .. entry.key, found)
    end
  elseif node.kind == "seq" then
    if type(expected) ~= "table" or is_empty_dict(expected) or not vim.islist(expected) then
      found[#found + 1] = path .. ": seq, oracle has " .. vim.inspect(expected)
      return found
    end
    for index, item in ipairs(tree.items(node)) do
      kind_mismatches(item, expected[index], path .. "/" .. index, found)
    end
  elseif type(expected) == "table" then
    found[#found + 1] = path .. ": scalar, oracle has " .. vim.inspect(expected)
  end
  return found
end

local function line_starts(text)
  local starts = { 1 }
  local index = 1
  while true do
    local newline = text:find("\n", index, true)
    if not newline then
      return starts
    end
    starts[#starts + 1] = newline + 1
    index = newline + 1
  end
end

local function pos_source(text, pos)
  local starts = line_starts(text)
  return text:sub(starts[pos.row + 1] + pos.col, starts[pos.end_row + 1] + pos.end_col - 1)
end

-- A tokenizer independent of the parser, so positions and order are proven against the bytes.
local function json_keys(text)
  local starts = line_starts(text)
  local keys = {}
  local index = 1
  while true do
    local open = text:find('"', index, true)
    if not open then
      return keys
    end
    local close = open + 1
    while text:sub(close, close) ~= '"' do
      close = close + (text:sub(close, close) == "\\" and 2 or 1)
    end
    if text:match("^[ \t\r\n]*:", close + 1) then
      local row = 0
      while starts[row + 2] and starts[row + 2] <= open do
        row = row + 1
      end
      keys[#keys + 1] = { row = row, col = open - starts[row + 1], source = text:sub(open, close) }
    end
    index = close + 1
  end
end

local function tree_keys(text, node, keys)
  if node.kind == "map" then
    for _, entry in ipairs(tree.entries(node)) do
      keys[#keys + 1] = { row = entry.key_pos.row, col = entry.key_pos.col, source = pos_source(text, entry.key_pos) }
      tree_keys(text, entry.value, keys)
    end
  elseif node.kind == "seq" then
    for _, item in ipairs(tree.items(node)) do
      tree_keys(text, item, keys)
    end
  end
  return keys
end

T["fixture integrity"] = MiniTest.new_set()

T["fixture integrity"]["tabs.json has tabs in indentation, before closers and after a colon"] = function()
  local bytes = fixture("tabs")
  expect.equality(bytes:find('\n\t+"') ~= nil, true)
  expect.equality(bytes:find("\n\t+[%]}]") ~= nil, true)
  expect.equality(bytes:find(":\t") ~= nil, true)
end

T["fixture integrity"]["crlf.json has only CRLF line ends"] = function()
  local bytes = fixture("crlf")
  expect.equality(bytes:find("\r\n", 1, true) ~= nil, true)
  expect.equality(bytes:find("[^\r]\n") == nil, true)
end

T["fixture integrity"]["bom.json starts with a BOM"] = function()
  expect.equality(fixture("bom"):sub(1, 3), "\239\187\191")
end

T["fixture integrity"]["pretty and minified hold the same content"] = function()
  expect.equality(vim.deep_equal(oracle("minified")["x-content"], oracle("pretty")), true)
end

T["fixture integrity"]["minified.json is one line with a multibyte key first"] = function()
  local bytes = fixture("minified")
  expect.equality(bytes:find("\n", 1, true), nil)
  local first = json_keys(bytes)[1].source
  expect.equality(first:find("[\128-\255]") ~= nil, true)
end

T["fixture integrity"]["pretty and minified have a key over 1024 bytes"] = function()
  for _, name in ipairs({ "pretty", "minified" }) do
    local longest = 0
    for _, key in ipairs(json_keys(fixture(name))) do
      longest = math.max(longest, #key.source)
    end
    expect.equality(longest > 1024, true)
  end
end

T["fixture integrity"]["minified, crlf and bom are OpenAPI 3.1 documents"] = function()
  for _, name in ipairs({ "minified", "crlf", "bom" }) do
    local value = oracle(name)
    expect.equality(value.openapi:match("^3%.1") ~= nil, true)
    expect.equality(type(value.info.title), "string")
    expect.equality(type(value.info.version), "string")
    expect.equality(type(value.paths), "table")
  end
end

T["fixture integrity"]["bom.json has an operation on its first row and on a later row"] = function()
  local rows = {}
  for _, key in ipairs(json_keys(fixture("bom"))) do
    if key.source == '"get"' then
      rows[#rows + 1] = key.row
    end
  end
  expect.equality(rows[1], 0)
  expect.equality(rows[2] > 0, true)
end

T["fixture integrity"]["escapes.json has every escape"] = function()
  local bytes = fixture("escapes")
  local escapes = {
    [[\"]],
    [[\\]],
    [[\/]],
    [[\b]],
    [[\f]],
    [[\n]],
    [[\r]],
    [[\t]],
    "\\u0000",
    "\\u0041",
    "\\u00e9",
    "\\u00E9",
    "\\u3042",
    "\\uD83D\\uDE00",
    "\\uD800\\uDC00",
    "\\uDBFF\\uDFFF",
  }
  for _, escape in ipairs(escapes) do
    expect.equality({ escape = escape, found = bytes:find(escape, 1, true) ~= nil }, { escape = escape, found = true })
  end
end

T["differential"] = MiniTest.new_set()
T["position"] = MiniTest.new_set()

for _, name in ipairs(FIXTURES) do
  T["differential"][name] = function()
    local doc = parse_fixture(name)
    expect.equality(tree.has_error(doc), false)
    local expected = oracle(name)
    expect.equality(decode_node(doc.root), expected)
    expect.equality(kind_mismatches(doc.root, expected, "", {}), {})
  end

  T["position"][name] = function()
    local bytes = fixture(name)
    local observed = tree_keys(bytes, parse_fixture(name).root, {})
    local expected = json_keys(bytes)
    expect.equality(#expected > 0, true)
    expect.equality(observed, expected)
  end
end

T["differential"]["the kind check tells {} from []"] = function()
  local doc = assert(tree.parse('{"a": [], "b": {}}'))
  local swapped = vim.json.decode('{"a": {}, "b": []}')
  expect.equality(vim.deep_equal(decode_node(doc.root), swapped), true)
  expect.equality(#kind_mismatches(doc.root, swapped, "", {}), 2)
end

T["position"]["bom shifts only the first row"] = function()
  local bytes = fixture("bom")
  local doc = parse_fixture("bom")
  local openapi = tree.entries(doc.root)[1]
  expect.equality(openapi.key, "openapi")
  expect.equality(openapi.key_pos.row, 0)
  expect.equality(openapi.key_pos.col, bytes:find('"openapi"', 1, true) - 1)

  local paths = get(doc.root, "paths")
  local later = tree.entries(paths)[2]
  expect.equality(later.key_pos.row > 0, true)
  expect.equality(pos_source(bytes, later.key_pos), '"' .. later.key .. '"')
end

T["position"]["a node ending on the first row of a BOM file is shifted at both ends"] = function()
  local text = BOM .. '{"a": 1}'
  local doc = assert(tree.parse(text))
  local value = get(doc.root, "a")
  expect.equality(pos_source(text, value.pos), "1")
end

T["position"]["a real error in a BOM file strips the BOM and still shifts the first row"] = function()
  local text = BOM .. "a: 1\nb: 2\n...\n}\n"
  local doc = assert(tree.parse(text))
  expect.equality(tree.has_error(doc), true)
  expect.equality(doc.text, text)

  local entries = tree.entries(doc.root)
  expect.equality(entries[1].key, "a")
  expect.equality(entries[1].value.raw, "1")
  expect.equality({ entries[1].key_pos.row, entries[1].key_pos.col }, { 0, 3 })
  expect.equality({ entries[2].key_pos.row, entries[2].key_pos.col }, { 1, 0 })
  expect.equality(pos_source(text, entries[1].value.pos), "1")
end

T["identity"] = MiniTest.new_set()

T["identity"]["file and bufnr reach every pos"] = function()
  local doc = assert(tree.parse("a:\n  - b: 1\n", { file = "/x/a.yaml", bufnr = 7 }))
  local entry = tree.entries(doc.root)[1]
  local inner = tree.entries(tree.items(entry.value)[1])[1]
  for _, pos in ipairs({ doc.root.pos, entry.key_pos, entry.value.pos, inner.key_pos, inner.value.pos }) do
    expect.equality(pos.file, "/x/a.yaml")
    expect.equality(pos.bufnr, 7)
  end
  expect.equality(doc.file, "/x/a.yaml")
  expect.equality(doc.bufnr, 7)
end

T["identity"]["an unnamed buffer has no file"] = function()
  local doc = assert(tree.parse("a: 1\n", { bufnr = 3 }))
  expect.equality(doc.file, nil)
  expect.equality(tree.entries(doc.root)[1].key_pos.file, nil)
  expect.equality(tree.entries(doc.root)[1].key_pos.bufnr, 3)
end

T["identity"]["a file has no bufnr"] = function()
  local doc = assert(tree.parse("a: 1\n", { file = "/x/a.yaml" }))
  expect.equality(tree.entries(doc.root)[1].key_pos.bufnr, nil)
end

T["oracle only"] = function()
  local files = vim.fn.glob("lua/**/*.lua", false, true)
  expect.equality(#files > 0, true)
  for _, file in ipairs(files) do
    expect.equality({ file = file, found = read_bytes(file):find("vim.json.decode", 1, true) }, { file = file })
  end
end

T["yaml"] = MiniTest.new_set()

T["yaml"]["keeps order, positions and raw 200 keys"] = function()
  local text = "zebra: 1\n200:\n  description: ok\ndefault: 2\n2XX: 3\n"
  local doc = assert(tree.parse(text))
  expect.equality(doc.root.kind, "map")

  local keys, rows, sources = {}, {}, {}
  for _, entry in ipairs(tree.entries(doc.root)) do
    keys[#keys + 1] = entry.key
    rows[#rows + 1] = entry.key_pos.row
    sources[#sources + 1] = pos_source(text, entry.key_pos)
  end
  expect.equality(keys, { "zebra", "200", "default", "2XX" })
  expect.equality(rows, { 0, 1, 3, 4 })
  expect.equality(sources, keys)

  local response = get(doc.root, "200")
  expect.equality(response.kind, "map")
  local description = get(response, "description")
  expect.equality(description.value, "ok")
  expect.equality({ description.pos.row, description.pos.col }, { 2, 15 })
end

T["yaml"]["reads sequences and scalar fields"] = function()
  local doc = assert(tree.parse("- 1\n- 'two'\n- \"three\"\n- ~\n-\n- [x, y]\n"))
  expect.equality(doc.root.kind, "seq")
  local items = tree.items(doc.root)
  expect.equality(#items, 6)

  expect.equality({ items[1].value, items[1].raw, items[1].style, items[1].scalar_type }, { 1, "1", "plain", "int" })
  expect.equality(
    { items[2].value, items[2].raw, items[2].style, items[2].scalar_type },
    { "two", "'two'", "single", "string" }
  )
  expect.equality(
    { items[3].value, items[3].raw, items[3].style, items[3].scalar_type },
    { "three", '"three"', "double", "string" }
  )
  expect.equality({ items[4].value, items[4].scalar_type }, { nil, "null" })
  expect.equality({ items[5].value, items[5].raw, items[5].scalar_type }, { nil, "", "null" })
  expect.equality(items[6].kind, "seq")
end

T["yaml"]["a key with no value is null"] = function()
  local doc = assert(tree.parse("a:\nb: 1\n"))
  local value = get(doc.root, "a")
  expect.equality(value.kind, "scalar")
  expect.equality(value.scalar_type, "null")
end

T["yaml"]["flow forms without a value or a key"] = function()
  local doc = assert(tree.parse("a: {b, c: 1}\nd: [e: 1, f]\n"))
  local map = get(doc.root, "a")
  expect.equality(get(map, "b").scalar_type, "null")
  expect.equality(get(map, "c").value, 1)

  local items = tree.items(get(doc.root, "d"))
  expect.equality(items[1].kind, "map")
  expect.equality(get(items[1], "e").value, 1)
  expect.equality(items[2].value, "f")
end

T["yaml"]["anchors and tags do not hide content"] = function()
  local doc = assert(tree.parse("a: &one 1\nb: !!str 2\n"))
  expect.equality(get(doc.root, "a").value, 1)
  expect.equality(get(doc.root, "b").raw, "2")
end

T["yaml"]["key lookup on the wrong kind finds nothing"] = function()
  local doc = assert(tree.parse("a: 1\n"))
  local scalar_node = get(doc.root, "a")
  expect.equality(tree.get(doc.root, "missing"), nil)
  expect.equality(tree.get(scalar_node, "a"), nil)
  expect.equality(tree.entries(scalar_node), {})
  expect.equality(tree.items(scalar_node), {})
  expect.equality(tree.items(doc.root), {})
end

T["yaml"]["memoises children"] = function()
  local doc = assert(tree.parse("a:\n  - 1\n"))
  expect.equality(tree.entries(doc.root)[1] == tree.entries(doc.root)[1], true)
  local seq = get(doc.root, "a")
  expect.equality(tree.items(seq)[1] == tree.items(seq)[1], true)
end

T["yaml"]["an empty text has no root"] = function()
  local doc = assert(tree.parse(""))
  expect.equality(doc.root, nil)
  expect.equality(tree.has_error(doc), false)
end

local function parse_features()
  return assert(tree.parse(read_bytes("tests/fixtures/yaml-features.yaml")))
end

local function keys_of(node)
  local keys = {}
  for _, entry in ipairs(tree.entries(node)) do
    keys[#keys + 1] = entry.key
  end
  return keys
end

local function codes_of(doc)
  local codes = {}
  for _, diagnostic in ipairs(doc.diagnostics) do
    codes[#codes + 1] = diagnostic.code
  end
  return codes
end

T["alias"] = MiniTest.new_set()

T["alias"]["reaches the anchored node itself, not a copy"] = function()
  local doc = parse_features()
  local alias = get(doc.root, "same_items")
  expect.equality(alias.kind, "alias")
  expect.equality(alias.name, "items")
  expect.equality(tree.resolve(alias) == get(doc.root, "items"), true)
  expect.equality(tree.items(alias)[1] == tree.items(get(doc.root, "items"))[1], true)
end

T["alias"]["keeps its own position"] = function()
  local text = "a: &x 1\nb: *x\n"
  local doc = assert(tree.parse(text))
  expect.equality(pos_source(text, get(doc.root, "b").pos), "*x")
end

T["alias"]["uses the nearest preceding anchor"] = function()
  local doc = parse_features()
  expect.equality(tree.resolve(get(doc.root, "later")).value, "first")
  expect.equality(tree.resolve(get(doc.root, "latest")).value, "second")
end

T["alias"]["an anchor with no content is a null scalar"] = function()
  local doc = assert(tree.parse("a: &x\nb: *x\n"))
  expect.equality(tree.resolve(get(doc.root, "b")) == get(doc.root, "a"), true)
  expect.equality(get(doc.root, "a").scalar_type, "null")
end

T["alias"]["an unknown alias gives a diagnostic and resolves to nothing"] = function()
  local doc = assert(tree.parse("a: *nope\nb: *late\nc: &late 1\n"))
  expect.equality(tree.resolve(get(doc.root, "a")), nil)
  expect.equality(tree.resolve(get(doc.root, "b")), nil)
  expect.equality(tree.entries(get(doc.root, "a")), {})
  expect.equality(codes_of(doc), { "unknown-alias", "unknown-alias" })
end

T["merge"] = MiniTest.new_set()

T["merge"]["inserts at the << position and explicit keys win"] = function()
  local doc = parse_features()
  local single = get(doc.root, "single")
  expect.equality(keys_of(single), { "first", "zeta", "shared", "alpha", "last" })
  expect.equality(tree.resolve(get(single, "alpha")).value, "explicit alpha")
  expect.equality(tree.resolve(get(single, "zeta")).value, "base zeta")
end

T["merge"]["reuses the source's nodes and memoises"] = function()
  local doc = parse_features()
  local single = get(doc.root, "single")
  expect.equality(get(single, "zeta") == get(get(doc.root, "base"), "zeta"), true)
  expect.equality(tree.entries(single) == tree.entries(single), true)
end

T["merge"]["in a list, the earlier source wins"] = function()
  local doc = parse_features()
  local list = get(doc.root, "list")
  expect.equality(keys_of(list), { "zeta", "alpha", "shared", "extra" })
  expect.equality(get(list, "shared").value, "from base")
  expect.equality(get(list, "extra").value, "from other")
end

T["merge"]["accepts an inline mapping"] = function()
  local doc = parse_features()
  expect.equality(keys_of(get(doc.root, "inline")), { "inlined", "own" })
end

T["merge"]["a quoted << is an ordinary key"] = function()
  local doc = assert(tree.parse('{"<<": {"a": 1}}'))
  expect.equality(keys_of(doc.root), { "<<" })
end

T["merge"]["a value that is not a mapping gives a diagnostic"] = function()
  local doc = assert(tree.parse("a: &x 1\nb:\n  <<: *x\n  c: 2\n"))
  expect.equality(keys_of(get(doc.root, "b")), { "c" })
  expect.equality(codes_of(doc), { "bad-merge" })
end

T["cycles"] = MiniTest.new_set()

T["cycles"]["an alias inside its own anchor gives a diagnostic and ends"] = function()
  local doc = assert(tree.parse("a: &x\n  b: *x\n"))
  local inner = get(get(doc.root, "a"), "b")
  expect.equality(tree.resolve(inner), nil)
  expect.equality(tree.entries(inner), {})
  expect.equality(tree.get(inner, "b"), nil)
  expect.equality(codes_of(doc), { "alias-cycle" })
end

T["cycles"]["an alias in a flow sequence inside its own anchor ends"] = function()
  local doc = assert(tree.parse("a: &x [1, *x]\n"))
  local items = tree.items(get(doc.root, "a"))
  expect.equality(tree.resolve(items[2]), nil)
  expect.equality(codes_of(doc), { "alias-cycle" })
end

T["cycles"]["a merge of its own anchor gives a diagnostic and ends"] = function()
  local doc = assert(tree.parse("a: &x\n  <<: *x\n  k: 1\n"))
  expect.equality(keys_of(get(doc.root, "a")), { "k" })
  expect.equality(codes_of(doc), { "merge-cycle" })
end

T["cycles"]["a merge list reaching its own anchor ends"] = function()
  local doc = assert(tree.parse("o: &o { p: 1 }\na: &x\n  <<: [*o, *x]\n  k: 1\n"))
  expect.equality(keys_of(get(doc.root, "a")), { "p", "k" })
  expect.equality(codes_of(doc), { "merge-cycle" })
end

T["cycles"]["a merge nested under its own anchor ends"] = function()
  local doc = assert(tree.parse("a: &x\n  n:\n    <<: *x\n    k: 1\n"))
  expect.equality(keys_of(get(get(doc.root, "a"), "n")), { "k" })
  expect.equality(codes_of(doc), { "merge-cycle" })
end

T["scalars in the tree"] = MiniTest.new_set()

for key, expected in pairs({
  literal = "line one\n  indented\nline three\n",
  folded = "folded one folded two\nafter blank\n",
  keep = "kept\n\n",
  strip = "stripped",
  indicator = "  two extra\n",
  plain_multi = "first second\nthird",
  double_multi = "first second\n third",
  single_multi = "it's folded",
}) do
  T["scalars in the tree"][key] = function()
    local node = get(parse_features().root, key)
    expect.equality(node.value, expected)
    expect.equality(node.scalar_type, "string")
  end
end

T["scalars in the tree"]["an indicator in a sequence counts from the item"] = function()
  local items = tree.items(get(parse_features().root, "in_seq"))
  expect.equality(items[1].value, "  one extra\n")
end

T["scalars in the tree"]["block styles and raw text"] = function()
  local doc = parse_features()
  expect.equality(get(doc.root, "literal").style, "literal")
  expect.equality(get(doc.root, "folded").style, "folded")
  expect.equality(vim.startswith(get(doc.root, "strip").raw, ">-"), true)
end

T["scalars in the tree"]["keep chomping at the end of a file"] = function()
  local doc = assert(tree.parse("a: |+\n  x\n\n\n"))
  expect.equality(get(doc.root, "a").value, "x\n\n\n")
end

T["scalars in the tree"]["keep chomping before the next key"] = function()
  local doc = assert(tree.parse("a: |+\n  x\n\n\nb: 1\n"))
  expect.equality(get(doc.root, "a").value, "x\n\n\n")
  expect.equality(get(doc.root, "b").value, 1)
end

T["scalars in the tree"]["clip and strip ignore following blank lines"] = function()
  local doc = assert(tree.parse("a: |\n  x\n\n\nb: |-\n  y\n\nc: 1\n"))
  expect.equality(get(doc.root, "a").value, "x\n")
  expect.equality(get(doc.root, "b").value, "y")
end

T["scalars in the tree"]["a top-level block scalar's indicator counts from column 0"] = function()
  local doc = assert(tree.parse("--- |1\n  x\n"))
  expect.equality(doc.root.value, "  x\n")
end

T["syntax diagnostics"] = MiniTest.new_set()

local function error_captures(doc)
  local query = vim.treesitter.query.parse("yaml", "[(ERROR) (MISSING)] @problem")
  local count = 0
  for _ in query:iter_captures(doc.lang_tree:trees()[1]:root(), doc.text) do
    count = count + 1
  end
  return count
end

T["syntax diagnostics"]["one per node up to the cap"] = function()
  local doc = assert(tree.parse(string.rep("- 'x\n", 100)))
  expect.equality(error_captures(doc), 100)
  expect.equality(#doc.diagnostics, 100)
  expect.equality(doc.diagnostics[100].code, "syntax")
end

T["syntax diagnostics"]["101 errors give 100 plus a count"] = function()
  local doc = assert(tree.parse(string.rep("- 'x\n", 101)))
  expect.equality(error_captures(doc), 101)
  expect.equality(#doc.diagnostics, 101)
  expect.equality(doc.diagnostics[100].code, "syntax")
  expect.equality(doc.diagnostics[101].code, "syntax-rest")
  expect.equality(doc.diagnostics[101].count, 1)
end

T["syntax diagnostics"]["a clean text has none"] = function()
  local doc = assert(tree.parse("a: 1\n"))
  expect.equality(tree.has_error(doc), false)
  expect.equality(doc.diagnostics, {})
end

T["syntax diagnostics"]["the query does not run on a clean text"] = function()
  local original = vim.treesitter.query.parse
  local calls = 0
  vim.treesitter.query.parse = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, err = pcall(tree.parse, "a: 1\n")
  local broken_ok, broken_err = pcall(tree.parse, "a: }\n")
  vim.treesitter.query.parse = original
  expect.equality({ ok, err ~= nil }, { true, true })
  expect.equality({ broken_ok, broken_err ~= nil }, { true, true })
  expect.equality(calls, 1)
end

T["syntax diagnostics"]["an error the query cannot reach still gives a diagnostic"] = function()
  local doc = assert(tree.parse("ok:\n  x: 1\n...\n}\n"))
  expect.equality(tree.has_error(doc), true)
  expect.equality(error_captures(doc), 0)
  expect.equality(codes_of(doc), { "syntax" })
end

T["syntax diagnostics"]["a NUL byte is reported, because the parser stops there silently"] = function()
  local doc = assert(tree.parse("a: 1\n\0b: 2\n"))
  expect.equality(keys_of(doc.root), { "a" })
  expect.equality(tree.has_error(doc), true)
  expect.equality(codes_of(doc), { "nul-byte" })
  expect.equality({ doc.diagnostics[1].pos.row, doc.diagnostics[1].pos.col }, { 1, 0 })
end

T["syntax diagnostics"]["an escaped NUL is not a NUL byte"] = function()
  local doc = assert(tree.parse('{"a": "b' .. "\\" .. 'u0000c"}'))
  expect.equality(tree.has_error(doc), false)
  expect.equality(get(doc.root, "a").value, "b\0c")
end

T["syntax diagnostics"]["node_has_error marks only the element holding the error"] = function()
  local doc = assert(tree.parse("ok:\n  x: 1\nbad: [\nafter: 2\n"))
  expect.equality(tree.has_error(doc), true)
  expect.equality(tree.node_has_error(get(doc.root, "ok")), false)
  expect.equality(tree.node_has_error(doc.root), true)
end

T["neutral cases"] = MiniTest.new_set()

T["neutral cases"]["a second document"] = function()
  local doc = assert(tree.parse("---\na: 1\n---\nb: 2\n"))
  expect.equality(keys_of(doc.root), { "a" })
  expect.equality(codes_of(doc), { "second-document" })
  expect.equality(doc.diagnostics[1].level, "info")
  expect.equality(doc.diagnostics[1].pos.row, 2)
end

T["neutral cases"]["a duplicate key, last wins"] = function()
  local doc = assert(tree.parse("a: 1\nb: 2\na: 3\n"))
  expect.equality(keys_of(doc.root), { "b", "a" })
  expect.equality(get(doc.root, "a").value, 3)
  expect.equality(codes_of(doc), { "duplicate-key" })
  expect.equality(doc.diagnostics[1].level, "info")
  expect.equality(doc.diagnostics[1].pos.row, 2)
end

T["neutral cases"]["a custom tag keeps its value"] = function()
  local doc = assert(tree.parse("a: !thing 1\nb: !!str 2\nc: !!custom 3\n"))
  expect.equality(get(doc.root, "a").value, 1)
  expect.equality(get(doc.root, "b").raw, "2")
  expect.equality(get(doc.root, "c").value, 3)
  expect.equality(codes_of(doc), { "custom-tag", "custom-tag" })
  expect.equality(doc.diagnostics[1].level, "info")
end

T["neutral cases"]["complex keys keep their source text"] = function()
  local doc = assert(tree.parse("? [k]\n: 1\n{m: 1}: 2\nplain: 3\n"))
  expect.equality(keys_of(doc.root), { "[k]", "{m: 1}", "plain" })
  expect.equality(codes_of(doc), { "complex-key", "complex-key" })
  expect.equality(doc.diagnostics[1].level, "info")
end

T["laziness"] = MiniTest.new_set()

T["laziness"]["nodes materialise only on access"] = function()
  local doc = assert(tree.parse("a:\n  b:\n    c: 1\nd: 2\n"))
  local after_parse = doc.counters.materialised
  expect.equality(after_parse, 1)

  local entries = tree.entries(doc.root)
  local after_top = doc.counters.materialised
  expect.equality(after_top, after_parse + 4)

  tree.entries(doc.root)
  tree.get(doc.root, "d")
  expect.equality(doc.counters.materialised, after_top)

  tree.entries(entries[1].value)
  expect.equality(doc.counters.materialised, after_top + 2)
end

T["laziness"]["a scalar decodes only on access"] = function()
  local doc = assert(tree.parse("a: 1\n"))
  local node = get(doc.root, "a")
  expect.equality(rawget(node, "_decoded"), nil)
  expect.equality(node.value, 1)
  expect.equality(rawget(node, "_decoded"), true)
end

T["laziness"]["the anchor query does not run without an alias"] = function()
  local doc = assert(tree.parse("a: &x 1\nb: 2\nc:\n  <<: { d: 3 }\n"))
  tree.entries(doc.root)
  tree.entries(get(doc.root, "c"))
  expect.equality(doc.counters.anchor_queries, 0)
end

T["laziness"]["the anchor query runs once however many aliases"] = function()
  local doc = parse_features()
  expect.equality(doc.counters.anchor_queries, 0)
  tree.resolve(get(doc.root, "later"))
  tree.resolve(get(doc.root, "latest"))
  tree.resolve(get(doc.root, "same_items"))
  expect.equality(doc.counters.anchor_queries, 1)
end

T["parser status"] = MiniTest.new_set()

T["parser status"]["reports a working parser"] = function()
  expect.equality({ tree.parser_status() }, { true })
end

T["parser status"]["reports a missing parser without loading"] = function()
  local child = helpers.new_child()
  child.boot()
  local observed = child.lua([[
    vim.opt.runtimepath:remove("/opt/tree-sitter-yaml")
    local tree = require("oas-glance.internal.tree")
    local doc, err = tree.parse("a: 1")
    return { status = { tree.parser_status() }, doc = doc == nil, err = err }
  ]])
  child.stop()
  expect.equality(observed, { status = { false, "missing" }, doc = true, err = { kind = "missing" } })
end

T["parser status"]["reports a parser that cannot load"] = function()
  local child = helpers.new_child()
  child.boot()
  local observed = child.lua([[
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/parser", "p")
    vim.fn.writefile({ "not a shared object" }, dir .. "/parser/yaml.so")
    vim.opt.runtimepath:remove("/opt/tree-sitter-yaml")
    vim.opt.runtimepath:prepend(dir)
    local tree = require("oas-glance.internal.tree")
    local ok, kind, reason = tree.parser_status()
    return { ok = ok, kind = kind, reason = type(reason) == "string" and reason ~= "" }
  ]])
  child.stop()
  expect.equality(observed, { ok = false, kind = "load", reason = true })
end

T["line limit"] = MiniTest.new_set()

local LIMIT = tree.LINE_LIMIT
local OVER = helpers.block_yaml(LIMIT + 1)
local AT = helpers.block_yaml(LIMIT)

T["line limit"]["the limit is 32768"] = function()
  expect.equality(LIMIT, 32768)
end

T["line limit"]["counts lines as Neovim does"] = function()
  expect.equality(tree.line_count(""), 0)
  expect.equality(tree.line_count("a"), 1)
  expect.equality(tree.line_count("a\n"), 1)
  expect.equality(tree.line_count("a\r\nb\r\n"), 2)
end

T["line limit"]["the generators give exact line counts"] = function()
  local function count(text)
    return #vim.split(text, "\n", { plain = true }) - (text:sub(-1) == "\n" and 1 or 0)
  end
  expect.equality(count(helpers.block_yaml(12)), 12)
  expect.equality(count(helpers.block_yaml(12, { final_newline = false })), 12)
  expect.equality(helpers.block_yaml(12, { final_newline = false }):sub(-1) ~= "\n", true)
  expect.equality(count(helpers.block_yaml(14, { leading_comment = true })), 14)
  expect.equality(count(helpers.block_yaml(12, { syntax_error = true })), 12)
  expect.equality(count(helpers.pretty_json(16)), 16)
  expect.equality(count(helpers.pretty_json(16, { syntax_error = true })), 16)
  expect.equality(count(OVER), LIMIT + 1)
  expect.equality(count(AT), LIMIT)
  expect.equality(count(helpers.block_yaml(LIMIT, { final_newline = false })), LIMIT)
  expect.equality(count(helpers.block_yaml(LIMIT + 3, { leading_comment = true })), LIMIT + 3)
  expect.equality(count(helpers.block_yaml(LIMIT, { syntax_error = true })), LIMIT)
  expect.equality(count(helpers.pretty_json(40003)), 40003)
  expect.equality(count(helpers.pretty_json(40003, { syntax_error = true })), 40003)
end

T["line limit"]["the small generated documents parse as intended"] = function()
  -- A broken one keeps its root, so it opens partly broken rather than as not OpenAPI.
  local function has_error(text)
    local doc = assert(tree.parse(text))
    expect.equality(tree.get(assert(doc.root, "no root"), "openapi").value, "3.1.0")
    return tree.has_error(doc)
  end
  expect.equality(has_error(helpers.block_yaml(12)), false)
  expect.equality(has_error(helpers.block_yaml(14, { leading_comment = true })), false)
  expect.equality(has_error(helpers.block_yaml(12, { syntax_error = true })), true)
  expect.equality(has_error(helpers.pretty_json(16)), false)
  expect.equality(has_error(helpers.pretty_json(16, { syntax_error = true })), true)
end

T["line limit"]["fires over the limit with an error"] = function()
  expect.equality(tree.line_limit(OVER, true), LIMIT + 1)
end

T["line limit"]["does not fire at the limit"] = function()
  expect.equality(tree.line_limit(AT, true), nil)
  expect.equality(tree.line_limit(helpers.block_yaml(LIMIT, { final_newline = false }), true), nil)
end

T["line limit"]["does not fire without an error"] = function()
  expect.equality(tree.line_limit(OVER, false), nil)
end

T["line limit"]["does not fire on flow style"] = function()
  local body = OVER:gsub("^[^\n]*", "")
  for _, prefix in ipairs({ "{", "[", "  \t\n{", "# note\n[", "# a\n\n  # b\r\n{", BOM .. "{", BOM .. " # c\n[" }) do
    expect.equality(tree.line_limit(prefix .. body, true), nil)
  end
end

T["line limit"]["a leading comment before a block root still counts"] = function()
  local text = helpers.block_yaml(LIMIT + 3, { leading_comment = true })
  expect.equality(tree.line_limit(text, true), LIMIT + 3)
  expect.equality(tree.line_limit(BOM .. text, true), LIMIT + 3)
end

T["line limit"]["the pinned parser parses 32768 lines and fails on 32769"] = function()
  expect.equality(tree.has_error(assert(tree.parse(AT))), false)
  expect.equality(tree.has_error(assert(tree.parse(OVER))), true)
end

return T
