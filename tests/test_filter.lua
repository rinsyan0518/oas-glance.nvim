local filter = require("oas-glance.internal.filter")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local OPERATION = { method = "get", path = "/pets/{petId}", tags = { "Pets", "store" } }
local SCHEMA = { name = "PetStatus" }
local WEBHOOK = { method = "post", path = "newPet", tags = {} }
local BROKEN_PATH_ITEM = { path = "/lost", tags = {}, broken = { target = "./x.yaml", reason = "not found" } }

local function matches(text, row)
  return (filter.match(filter.parse(text), row))
end

T["parse"] = MiniTest.new_set()

T["parse"]["splits on any whitespace and folds case"] = function()
  expect.equality(filter.parse("  path:/PETS \t tag:Store\nschema:Pet  Bare "), {
    { kind = "path", text = "/pets" },
    { kind = "tag", text = "store" },
    { kind = "schema", text = "pet" },
    { kind = "any", text = "bare" },
  })
end

T["parse"]["an empty text has no terms and matches every row"] = function()
  expect.equality(filter.parse(""), {})
  expect.equality(filter.parse("   "), {})
  expect.equality(matches("", OPERATION), true)
  expect.equality(matches("", SCHEMA), true)
end

T["parse"]["another colon is part of a bare term"] = function()
  expect.equality(filter.parse("foo:bar"), { { kind = "any", text = "foo:bar" } })
  expect.equality(filter.parse("PATH:x"), { { kind = "any", text = "path:x" } })
  expect.equality(filter.parse("path:a:b"), { { kind = "path", text = "a:b" } })
end

T["match"] = MiniTest.new_set()

for _, row in ipairs({
  { "path: matches a path", "path:/pets", OPERATION, true },
  { "path: misses a tag", "path:store", OPERATION, false },
  { "tag: matches any tag", "tag:store", OPERATION, true },
  { "tag: misses a path", "tag:petId", OPERATION, false },
  { "schema: misses an operation", "schema:pet", OPERATION, false },
  { "schema: matches a name", "schema:status", SCHEMA, true },
  { "bare matches a path", "petid", OPERATION, true },
  { "bare matches a tag", "stor", OPERATION, true },
  { "bare matches a name", "status", SCHEMA, true },
  { "bare misses everything", "zebra", OPERATION, false },
  { "case-insensitive in the term", "PATH:/PETS", OPERATION, false },
  { "case-insensitive in the text", "path:/PETS", OPERATION, true },
  { "case-insensitive in a tag", "tag:pets", OPERATION, true },
  { "all terms must match", "path:/pets tag:store", OPERATION, true },
  { "one failing term hides the row", "path:/pets tag:zebra", OPERATION, false },
  { "two bare terms", "pets store", OPERATION, true },
}) do
  T["match"][row[1]] = function()
    expect.equality(matches(row[2], row[3]), row[4])
  end
end

T["match"]["case folding reaches non-ASCII text"] = function()
  expect.equality(matches("path:ÉCOLE", { path = "/école" }), true)
  expect.equality(matches("path:école", { path = "/ÉCOLE" }), true)
end

T["literals"] = MiniTest.new_set()

for _, row in ipairs({
  { "{", "/a{b", "/ab" },
  { "%", "/a%d", "/a1" },
  { ".", "/a.c", "/abc" },
  { "*", "/a*", "/aaa" },
  { "[", "/[a", "/a" },
  { "^", "/^a", "/a" },
  { "$", "/a$", "/a" },
  { "-", "/a-z", "/az" },
}) do
  T["literals"][row[1] .. " is a plain character"] = function()
    expect.equality(matches("path:" .. row[2], { path = row[2] }), true)
    expect.equality(matches("path:" .. row[2], { path = row[3] }), false)
  end
end

T["literals"]["a brace in a real path"] = function()
  expect.equality(matches("path:{petId}", OPERATION), true)
end

T["row kinds"] = MiniTest.new_set()

T["row kinds"]["a schema row is hidden by path: and tag:"] = function()
  expect.equality(matches("path:pet", SCHEMA), false)
  expect.equality(matches("tag:pet", SCHEMA), false)
  expect.equality(matches("schema:pet", SCHEMA), true)
end

T["row kinds"]["a webhook row matches on its name as the path"] = function()
  expect.equality(matches("path:newPet", WEBHOOK), true)
  expect.equality(matches("newpet", WEBHOOK), true)
  expect.equality(matches("tag:newpet", WEBHOOK), false)
end

T["row kinds"]["a broken path item has a path and no tags"] = function()
  expect.equality(matches("path:/lost", BROKEN_PATH_ITEM), true)
  expect.equality(matches("lost", BROKEN_PATH_ITEM), true)
  expect.equality(matches("tag:lost", BROKEN_PATH_ITEM), false)
  expect.equality(matches("schema:lost", BROKEN_PATH_ITEM), false)
end

T["ranges"] = MiniTest.new_set()

local function ranges_of(text, row)
  local _, ranges = filter.match(filter.parse(text), row)
  return ranges
end

T["ranges"]["give byte columns in the matched path"] = function()
  expect.equality(ranges_of("path:pets", { path = "/pets/{petId}" }), {
    { field = "path", col = 1, end_col = 5 },
  })
end

T["ranges"]["give every occurrence"] = function()
  expect.equality(ranges_of("path:pet", { path = "/pets/{petId}" }), {
    { field = "path", col = 1, end_col = 4 },
    { field = "path", col = 7, end_col = 10 },
  })
end

T["ranges"]["name the tag and the schema"] = function()
  expect.equality(ranges_of("tag:pet", OPERATION), { { field = "tag", tag = "Pets", col = 0, end_col = 3 } })
  expect.equality(ranges_of("schema:status", SCHEMA), { { field = "name", col = 3, end_col = 9 } })
end

T["ranges"]["cover each term, and a bare term in each field"] = function()
  expect.equality(ranges_of("pets /p", OPERATION), {
    { field = "path", col = 1, end_col = 5 },
    { field = "tag", tag = "Pets", col = 0, end_col = 4 },
    { field = "path", col = 0, end_col = 2 },
  })
end

T["ranges"]["are bytes of the source with multibyte text"] = function()
  local path = "/日本語/ÉCOLE"
  local ranges = ranges_of("path:école", { path = path })
  expect.equality(#ranges, 1)
  expect.equality(path:sub(ranges[1].col + 1, ranges[1].end_col), "ÉCOLE")
  local kanji = ranges_of("path:本", { path = path })
  expect.equality(path:sub(kanji[1].col + 1, kanji[1].end_col), "本")
end

T["ranges"]["are empty when the row does not match"] = function()
  expect.equality(ranges_of("path:pets zebra", OPERATION), {})
end

T["ranges"]["an empty prefixed term matches with no range"] = function()
  expect.equality(matches("path:", OPERATION), true)
  expect.equality(matches("path:", SCHEMA), false)
  expect.equality(ranges_of("path:", OPERATION), {})
end

return T
