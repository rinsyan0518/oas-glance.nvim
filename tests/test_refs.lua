local helpers = dofile("tests/helpers.lua")
local refs = require("oas-glance.internal.refs")
local tree = require("oas-glance.internal.tree")
local workspace = require("oas-glance.internal.workspace")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local FIXTURES = vim.uv.fs_realpath("tests/fixtures")
local MULTI = FIXTURES .. "/multi"

local function new_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function open_root(dir, text, opts)
  local path = dir .. "/root.yaml"
  write(path, text or "a: 1\n")
  local ws = workspace.new(vim.tbl_extend("keep", opts or {}, { root = dir }))
  local doc = assert(ws:open_file(path))
  return ws, doc
end

local function open_ref(ws, doc, ref)
  return refs.open(ws, doc, refs.check_text(ref, doc.identity))
end

local function reason_of(ws, doc, ref)
  return open_ref(ws, doc, ref).reason
end

local function with_spy(names, target, run)
  local calls = {}
  local originals = {}
  for _, name in ipairs(names) do
    originals[name] = target[name]
    target[name] = function(...)
      calls[#calls + 1] = name
      return originals[name](...)
    end
  end
  local ok, err = pcall(run)
  for _, name in ipairs(names) do
    target[name] = originals[name]
  end
  if not ok then
    error(err, 0)
  end
  return calls
end

local FS_CALLS = { "fs_stat", "fs_lstat", "fs_realpath" }

local function outside_setup()
  local base = new_dir()
  local inside = base .. "/inside"
  vim.fn.mkdir(inside, "p")
  write(base .. "/secret.yaml", "x: 1\n")
  local ws, doc = open_root(inside)
  return base, inside, ws, doc
end
local V31 = { version = "3.1" }

T["pointers"] = MiniTest.new_set()

local function walk_value(text, pointer)
  local doc = assert(tree.parse(text))
  local node, reason = refs.walk(doc, pointer)
  return node and node.value, reason
end

T["pointers"]["unescape ~0 and ~1"] = function()
  expect.equality(walk_value('"a/b": 1\n', "/a~1b"), 1)
  expect.equality(walk_value('"a~b": 2\n', "/a~0b"), 2)
  expect.equality(walk_value('"a~1b": 3\n', "/a~01b"), 3)
end

T["pointers"]["percent-decode through the fragment"] = function()
  local doc = assert(tree.parse('"a b":\n  c: 1\n'))
  local parsed = refs.check_text("#/a%20b/c", "id")
  expect.equality(parsed.pointer, "/a b/c")
  expect.equality(refs.walk(doc, parsed.pointer).value, 1)
end

T["pointers"]["index into a sequence"] = function()
  expect.equality(walk_value("a: [x, y]\n", "/a/1"), "y")
  expect.equality({ walk_value("a: [x, y]\n", "/a/2") }, { nil, "no such pointer" })
  expect.equality({ walk_value("a: [x, y]\n", "/a/b") }, { nil, "no such pointer" })
end

T["pointers"]["an index with a leading zero is no such pointer"] = function()
  expect.equality(walk_value("a: [x, y]\n", "/a/0"), "x")
  expect.equality({ walk_value("a: [x, y]\n", "/a/01") }, { nil, "no such pointer" })
  expect.equality({ walk_value("a: [x, y]\n", "/a/00") }, { nil, "no such pointer" })
  expect.equality({ walk_value("a: [x, y]\n", "/a/-1") }, { nil, "no such pointer" })
end

T["pointers"]["walk through aliases"] = function()
  expect.equality(walk_value("a: &x\n  b: 1\nc: *x\n", "/c/b"), 1)
end

T["pointers"]["do not walk through a $ref"] = function()
  local text = "a:\n  $ref: '#/b'\nb:\n  c: 1\n"
  expect.equality({ walk_value(text, "/a/c") }, { nil, "no such pointer" })
end

T["pointers"]["an empty pointer is the whole file"] = function()
  local doc = assert(tree.parse("a: 1\n"))
  expect.equality(refs.walk(doc, "") == doc.root, true)
end

T["reasons"] = MiniTest.new_set()

T["reasons"]["not found"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "./gone.yaml"), "not found")
end

T["reasons"]["no such pointer"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir)
  expect.equality(reason_of(ws, doc, "./a.yaml#/y"), "no such pointer")
end

T["reasons"]["outside root"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "../a.yaml"), "outside root")
end

T["reasons"]["not allowed"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "file:///x"), "not allowed")
end

T["reasons"]["remote not loaded"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "https://x/a.yaml"), "remote not loaded")
end

T["reasons"]["no base path"] = function()
  local ws = workspace.new()
  local doc = assert(ws:open_text("a: 1\n", { bufnr = 5 }))
  expect.equality(reason_of(ws, doc, "./a.yaml"), "no base path")
end

T["reasons"]["bad file type"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "./a.txt"), "bad file type")
end

T["reasons"]["too large"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir, nil, { max_file_bytes = 2 })
  expect.equality(reason_of(ws, doc, "./a.yaml"), "too large")
end

T["reasons"]["too many files"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  write(dir .. "/b.yaml", "x: 1\n")
  local ws, doc = open_root(dir, nil, { max_files = 1 })
  expect.equality(reason_of(ws, doc, "./a.yaml"), nil)
  expect.equality(reason_of(ws, doc, "./b.yaml"), "too many files")
end

T["reasons"]["too deep"] = function()
  local ws, doc = open_root(new_dir(), "a:\n  $ref: '#/b'\nb:\n  $ref: '#/c'\nc:\n  $ref: '#/d'\nd:\n  e: 1\n", {
    max_depth = 2,
  })
  local result = refs.follow(ws, doc, refs.check_text("#/a", doc.identity), V31)
  expect.equality(result.reason, "too deep")
end

T["reasons"]["ref cycle"] = function()
  local ws, doc = open_root(new_dir(), "a:\n  $ref: '#/b'\nb:\n  $ref: '#/a'\n")
  local result = refs.follow(ws, doc, refs.check_text("#/a", doc.identity), V31)
  expect.equality(result.reason, "ref cycle")
end

T["reasons"]["parse failed"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "}}}}\n")
  local ws, doc = open_root(dir)
  expect.equality(reason_of(ws, doc, "./a.yaml"), "parse failed")
end

T["reasons"]["unsupported ref"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "#name"), "unsupported ref")
end

T["follow"] = MiniTest.new_set()

T["follow"]["reaches content through a chain, recording every key"] = function()
  local ws, doc = open_root(new_dir(), "a:\n  $ref: '#/b'\nb:\n  $ref: '#/c'\nc:\n  d: 1\n")
  local result = refs.follow(ws, doc, refs.check_text("#/a", doc.identity), V31)
  expect.equality(tree.get(result.node, "d").value, 1)
  expect.equality(result.key, doc.identity .. "#/a")
  expect.equality(result.keys, { doc.identity .. "#/a", doc.identity .. "#/b", doc.identity .. "#/c" })
end

T["follow"]["stops at a $ref with content beside it"] = function()
  local ws, doc = open_root(new_dir(), "a:\n  $ref: '#/b'\n  title: Here\nb:\n  c: 1\n")
  local result = refs.follow(ws, doc, refs.check_text("#/a", doc.identity), V31)
  expect.equality(tree.get(result.node, "title").value, "Here")
end

T["follow"]["a Reference Object's siblings do not stop it"] = function()
  local ws, doc = open_root(new_dir(), "a:\n  $ref: '#/b'\n  summary: Here\nb:\n  c: 1\n")
  local result =
    refs.follow(ws, doc, refs.check_text("#/a", doc.identity), { reference_object = true, version = "3.1" })
  expect.equality(tree.get(result.node, "c").value, 1)
end

T["follow"]["a broken hop gives that hop's reason"] = function()
  local ws, doc = open_root(new_dir(), "a:\n  $ref: https://x/y\nb:\n  $ref: 1\n")
  expect.equality(refs.follow(ws, doc, refs.check_text("#/a", doc.identity), V31).reason, "remote not loaded")
  expect.equality(refs.follow(ws, doc, refs.check_text("#/b", doc.identity), V31).reason, "unsupported ref")
end

T["follow"]["a hop resolves against the file holding it"] = function()
  local dir = new_dir()
  write(dir .. "/sub/a.yaml", "$ref: ./b.yaml\n")
  write(dir .. "/sub/b.yaml", "c: 1\n")
  local ws, doc = open_root(dir)
  local result = refs.follow(ws, doc, refs.check_text("./sub/a.yaml", doc.identity), V31)
  expect.equality(tree.get(result.node, "c").value, 1)
end

local CYCLE_WITH_SIBLINGS = "a:\n  $ref: '#/b'\n  description: x\nb:\n  $ref: '#/a'\n  description: y\n"
local CHAIN_WITH_SIBLINGS = "a:\n  $ref: '#/b'\n  title: Here\nb:\n  c: 1\n"

local function follow_a(text, opts)
  local ws, doc = open_root(new_dir(), text)
  return refs.follow(ws, doc, refs.check_text("#/a", doc.identity), opts), doc
end

T["follow by version"] = MiniTest.new_set()

T["follow by version"]["needs a version"] = function()
  local ws, doc = open_root(new_dir(), CHAIN_WITH_SIBLINGS)
  expect.error(function()
    refs.follow(ws, doc, refs.check_text("#/a", doc.identity), {})
  end, "version")
end

T["follow by version"]["a 3.0 cycle with siblings is a ref cycle"] = function()
  local result = follow_a(CYCLE_WITH_SIBLINGS, { version = "3.0" })
  expect.equality(result.reason, "ref cycle")
  expect.equality(#result.ignored, 2)
end

T["follow by version"]["the same document in 3.1 stops at node a"] = function()
  local result, doc = follow_a(CYCLE_WITH_SIBLINGS, { version = "3.1" })
  expect.equality(result.reason, nil)
  expect.equality(result.node == tree.get(doc.root, "a"), true)
  expect.equality(result.ignored, {})
end

T["follow by version"]["a 3.0 chain with siblings reaches the content"] = function()
  local result, doc = follow_a(CHAIN_WITH_SIBLINGS, { version = "3.0" })
  expect.equality(result.node == tree.get(doc.root, "b"), true)
  expect.equality(#result.ignored, 1)
end

T["follow by version"]["a 3.1 chain with siblings stops at the siblings"] = function()
  local result = follow_a(CHAIN_WITH_SIBLINGS, { version = "3.1" })
  expect.equality(tree.get(result.node, "title").value, "Here")
end

for _, version in ipairs({ "3.0", "3.1" }) do
  T["follow by version"]["a Reference Object continues past siblings in " .. version] = function()
    local opts = { reference_object = true, version = version }
    local chain, doc = follow_a(CHAIN_WITH_SIBLINGS, opts)
    expect.equality(chain.node == tree.get(doc.root, "b"), true)
    expect.equality(follow_a(CYCLE_WITH_SIBLINGS, opts).reason, "ref cycle")
    expect.equality(#chain.ignored, version == "3.0" and 1 or 0)
  end
end

T["follow by version"]["a hop in an external file follows the version passed in"] = function()
  local dir = new_dir()
  write(dir .. "/ext.yaml", "openapi: 3.1.0\nx:\n  $ref: '#/y'\n  title: Here\ny:\n  c: 1\n")
  local ws, doc = open_root(dir, "a:\n  $ref: ./ext.yaml#/x\n")
  local parsed = refs.check_text("#/a", doc.identity)
  local v30 = refs.follow(ws, doc, parsed, { version = "3.0" })
  expect.equality(tree.get(v30.node, "c").value, 1)
  expect.equality(tree.doc_of(v30.ignored[1]).file, dir .. "/ext.yaml")
  local v31 = refs.follow(ws, doc, parsed, { version = "3.1" })
  expect.equality(tree.get(v31.node, "title").value, "Here")
end

T["follow by version"]["ignored hops are returned when the chain fails"] = function()
  local result = follow_a("a:\n  $ref: ./gone.yaml\n  title: Here\n", { version = "3.0" })
  expect.equality(result.reason, "not found")
  expect.equality(#result.ignored, 1)
end

T["text checks"] = MiniTest.new_set()

local TEXT_REASONS = {
  { "a non-string", 12, "unsupported ref" },
  { "nil", nil, "unsupported ref" },
  { "an empty ref", "", "unsupported ref" },
  { "an anchor", "#name", "unsupported ref" },
  { "a file anchor", "x.yaml#name", "unsupported ref" },
  { "http", "http://x/a.yaml", "remote not loaded" },
  { "https with a pointer", "https://x/a.yaml#/P", "remote not loaded" },
  { "https with an odd fragment", "https://x#name", "remote not loaded" },
  { "upper-case http", "HTTP://x", "remote not loaded" },
  { "mixed-case https", "Https://x", "remote not loaded" },
  { "file", "file:///x", "not allowed" },
  { "upper-case file", "FILE:///x", "not allowed" },
  { "ftp", "ftp://x/a.yaml", "not allowed" },
  { "mailto", "mailto:a@b", "not allowed" },
  { "a missing file", "./gone.yaml", false },
  { "an absolute path", "/etc/x.yaml", false },
  { "a bad extension", "x.txt", false },
  { "a missing pointer", "#/no/such", false },
  { "an empty fragment", "x.yaml#", false },
  { "a lone hash", "#", false },
  { "a colon in a relative path", "./a:b.yaml", false },
}

for _, row in ipairs(TEXT_REASONS) do
  T["text checks"][row[1]] = function()
    local parsed = refs.check_text(row[2], "id")
    expect.equality(parsed.reason, row[3] or nil)
  end
end

T["text checks"]["show a non-string's text"] = function()
  expect.equality(refs.check_text(nil, "id", "[1, 2]").target, "[1, 2]")
end

T["text checks"]["touch no file and no tree"] = function()
  local fs_calls = with_spy(
    {
      "fs_stat",
      "fs_lstat",
      "fs_realpath",
      "fs_open",
      "fs_read",
      "fs_opendir",
    },
    vim.uv,
    function()
      local tree_calls = with_spy({ "get", "entries", "items", "resolve", "parse" }, tree, function()
        for _, row in ipairs(TEXT_REASONS) do
          refs.check_text(row[2], "id")
        end
      end)
      expect.equality(tree_calls, {})
    end
  )
  expect.equality(fs_calls, {})
end

local CONTROLS = { "\n", "\0", "\1", "\t", "\127" }

T["text checks"]["a control character is not allowed anywhere, with no filesystem call"] = function()
  local _, _, ws, doc = outside_setup()
  local calls = with_spy(FS_CALLS, vim.uv, function()
    for _, char in ipairs(CONTROLS) do
      for _, ref in ipairs({ "./a" .. char .. ".yaml", "#/a" .. char, "https://x/" .. char, "./a.yaml#/b" .. char }) do
        expect.equality({ ref = ref, reason = reason_of(ws, doc, ref) }, { ref = ref, reason = "not allowed" })
      end
    end
  end)
  expect.equality(calls, {})
end

T["text checks"]["percent-decoding"] = MiniTest.new_set()

T["text checks"]["percent-decoding"]["names a file with a space"] = function()
  local dir = new_dir()
  write(dir .. "/my file.yaml", "x: 1\n")
  local ws, doc = open_root(dir)
  expect.equality(open_ref(ws, doc, "./my%20file.yaml#/x").node.value, 1)
end

T["text checks"]["percent-decoding"]["a decoded control character is not allowed"] = function()
  for _, ref in ipairs({ "./a%0A.yaml", "./a%00.yaml", "#/a%0A", "#/a%00", "./a.yaml#/b%0a" }) do
    expect.equality({ ref = ref, reason = refs.check_text(ref, "id").reason }, { ref = ref, reason = "not allowed" })
  end
end

T["text checks"]["percent-decoding"]["a malformed escape is unsupported"] = function()
  for _, ref in ipairs({ "./a%zz.yaml", "./a.yaml%4", "#/a%zz", "#/a%4", "#/a%" }) do
    expect.equality(
      { ref = ref, reason = refs.check_text(ref, "id").reason },
      { ref = ref, reason = "unsupported ref" }
    )
  end
end

T["text checks"]["percent-decoding"]["a remote ref is never decoded"] = function()
  expect.equality(refs.check_text("https://x/%zz", "id").reason, "remote not loaded")
  expect.equality(refs.check_text("https://x/a%0A", "id").reason, "remote not loaded")
end

T["text checks"]["percent-decoding"]["encoded dot segments are outside root, with no filesystem call"] = function()
  local _, _, ws, doc = outside_setup()
  local calls = with_spy(FS_CALLS, vim.uv, function()
    expect.equality(reason_of(ws, doc, "%2E%2E/secret.yaml"), "outside root")
    expect.equality(reason_of(ws, doc, ".%2E/secret.yaml"), "outside root")
    expect.equality(reason_of(ws, doc, "..%2Fsecret.yaml"), "outside root")
  end)
  expect.equality(calls, {})
end

T["text checks"]["percent-decoding"]["%2F in a fragment separates segments, and ~1 does not"] = function()
  local dir = new_dir()
  local ws, doc = open_root(dir, 'a:\n  b: 1\n"a/b": 2\n')
  expect.equality(open_ref(ws, doc, "#/a%2Fb").node.value, 1)
  expect.equality(open_ref(ws, doc, "#/a~1b").node.value, 2)
end

T["text checks"]["percent-decoding"]["an encoded fragment start is a pointer"] = function()
  expect.equality(refs.check_text("#%2Fa", "id").pointer, "/a")
  expect.equality(refs.check_text("#%41", "id").reason, "unsupported ref")
end

T["text checks"]["dot segments collapse before symlinks resolve"] = function()
  local base, inside, ws, doc = outside_setup()
  write(inside .. "/x.yaml", "x: 1\n")
  write(base .. "/x.yaml", "x: 2\n")
  assert(vim.uv.fs_symlink(base, inside .. "/link"))
  local result = open_ref(ws, doc, "./link/../x.yaml#/x")
  expect.equality(result.node.value, 1)
  expect.equality(result.key, inside .. "/x.yaml#/x")
end

T["canonical keys"] = MiniTest.new_set()

T["canonical keys"]["come from the text for a local ref"] = function()
  expect.equality(refs.check_text("#/a/b", "/x/y.yaml").key, "/x/y.yaml#/a/b")
end

T["canonical keys"]["ignore percent-encoding"] = function()
  expect.equality(refs.check_text("#/a%20b", "id").key, refs.check_text("#/a b", "id").key)
end

T["canonical keys"]["an external ref has none until opened, even if already loaded"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir)
  expect.equality(reason_of(ws, doc, "./a.yaml"), nil)

  local parsed = refs.check_text("./a.yaml#/x", doc.identity)
  expect.equality(parsed.key, nil)
  expect.equality(refs.open(ws, doc, parsed).key, dir .. "/a.yaml#/x")
end

T["display names"] = MiniTest.new_set()

for _, row in ipairs({
  { "#/components/schemas/Pet", "Pet", nil },
  { "./gone.yaml", "gone", "gone.yaml" },
  { "../x/common.yaml#/Owner", "Owner", "common.yaml" },
  { "./a.yaml#/x~1y", "x/y", "a.yaml" },
  { "./a.yaml#", "a", "a.yaml" },
  { "#", "#", nil },
}) do
  T["display names"][row[1]] = function()
    local parsed = refs.check_text(row[1], "id")
    expect.equality({ parsed.name, parsed.file }, { row[2], row[3] })
  end
end

T["parse failed"] = MiniTest.new_set()

local function open_multi()
  local ws = workspace.new({ root = MULTI })
  local doc = assert(ws:open_file(MULTI .. "/root.yaml"))
  return ws, doc
end

T["parse failed"]["garbage.yaml really has errors and no usable root"] = function()
  local file = assert(io.open(MULTI .. "/garbage.yaml", "rb"))
  local doc = assert(tree.parse(file:read("*a")))
  file:close()
  expect.equality(doc.lang_tree:trees()[1]:root():has_error(), true)
  expect.equality(doc.root, nil)
end

T["parse failed"]["garbage.yaml fails with a pointer and with the whole file"] = function()
  local ws, doc = open_multi()
  expect.equality(reason_of(ws, doc, "./garbage.yaml#/x"), "parse failed")
  expect.equality(reason_of(ws, doc, "./garbage.yaml#"), "parse failed")
end

T["parse failed"]["damaged.yaml really has errors, a usable root and an unreachable key"] = function()
  local file = assert(io.open(MULTI .. "/damaged.yaml", "rb"))
  local doc = assert(tree.parse(file:read("*a")))
  file:close()
  expect.equality(tree.has_error(doc), true)
  expect.equality(doc.root.kind, "map")
  expect.equality(tree.get(doc.root, "ok").kind, "map")
  local bad = assert(tree.get(doc.root, "bad"), "the damaged key exists")
  expect.equality(tree.get(bad, "y"), nil)
end

T["parse failed"]["damaged.yaml fails past the error and resolves elsewhere"] = function()
  local ws, doc = open_multi()
  expect.equality(reason_of(ws, doc, "./damaged.yaml#/bad/y"), "parse failed")

  local good = open_ref(ws, doc, "./damaged.yaml#/ok/x")
  expect.equality(good.reason, nil)
  expect.equality(good.node.value, 1)

  local whole = open_ref(ws, doc, "./damaged.yaml#")
  expect.equality(whole.reason, nil)
  expect.equality(whole.node.kind, "map")
  expect.equality(#whole.diagnostics > 0, true)
  expect.equality(whole.diagnostics[1].code, "syntax")
end

T["too many lines"] = MiniTest.new_set()

local large_dir
local function large_files()
  if not large_dir then
    large_dir = new_dir()
    write(large_dir .. "/over.yaml", helpers.block_yaml(32769))
    write(large_dir .. "/at.yaml", helpers.block_yaml(32768))
    write(large_dir .. "/big.json", helpers.pretty_json(40003))
  end
  return large_dir
end

T["too many lines"]["an external file over the limit gives the reason twice with one read"] = function()
  local ws, doc = open_root(large_files())
  local calls = with_spy({ "open" }, io, function()
    expect.equality(reason_of(ws, doc, "./over.yaml"), "too many lines")
    expect.equality(reason_of(ws, doc, "./over.yaml"), "too many lines")
    expect.equality(reason_of(ws, doc, "./over.yaml#/components/schemas/Pad"), "too many lines")
  end)
  expect.equality(calls, { "open" })
end

T["too many lines"]["a pointer into the file gives it, not parse failed"] = function()
  local ws, doc = open_root(large_files())
  expect.equality(reason_of(ws, doc, "./over.yaml#/components/schemas/Pad"), "too many lines")
end

T["too many lines"]["a YAML file at the limit resolves"] = function()
  local ws, doc = open_root(large_files())
  local opened = open_ref(ws, doc, "./at.yaml#/components/schemas/Pad/type")
  expect.equality(opened.reason, nil)
  expect.equality(opened.node.value, "object")
end

T["too many lines"]["a JSON file over the limit resolves"] = function()
  local ws, doc = open_root(large_files())
  local opened = open_ref(ws, doc, "./big.json#/components/schemas/Pad/type")
  expect.equality(opened.reason, nil)
  expect.equality(opened.node.value, "object")
end

T["parse failed"]["its failure also returns the file's diagnostics"] = function()
  local ws, doc = open_multi()
  local result = open_ref(ws, doc, "./damaged.yaml#/bad/y")
  expect.equality(result.diagnostics[1].code, "syntax")
end

T["parse failed"]["the same missing pointer in a clean file is no such pointer"] = function()
  local ws, doc = open_multi()
  expect.equality(reason_of(ws, doc, "./schemas/owner.yaml#/bad/y"), "no such pointer")
end

T["parse failed"]["a local pointer in a root document with errors"] = function()
  local dir = new_dir()
  local ws, doc = open_root(dir, "ok:\n  x: 1\nbad: {y\nafter: 2\n")
  expect.equality(reason_of(ws, doc, "#/bad/y"), "parse failed")
  expect.equality(open_ref(ws, doc, "#/ok/x").node.value, 1)
end

T["parse failed"]["a NUL byte hides the rest, so a miss is not a false claim"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n\0y: 2\n")
  local ws, doc = open_root(dir)
  expect.equality(reason_of(ws, doc, "./a.yaml#/y"), "parse failed")
  expect.equality(open_ref(ws, doc, "./a.yaml#/x").node.value, 1)
end

local function with_tree_parse(stub, run)
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir)
  local original = tree.parse
  tree.parse = stub
  local ok, err = pcall(run, ws, doc)
  tree.parse = original
  if not ok then
    error(err, 0)
  end
end

T["parse failed"]["a parser that raises"] = function()
  with_tree_parse(function()
    error("boom")
  end, function(ws, doc)
    expect.equality(reason_of(ws, doc, "./a.yaml#/x"), "parse failed")
    expect.equality(reason_of(ws, doc, "./a.yaml#/x"), "parse failed")
    expect.equality(#ws:loaded_files(), 1)
  end)
end

T["parse failed"]["a parser that returns no tree"] = function()
  with_tree_parse(function()
    return nil
  end, function(ws, doc)
    expect.equality(reason_of(ws, doc, "./a.yaml#/x"), "parse failed")
  end)
end

T["open checks"] = MiniTest.new_set()

T["open checks"]["a local ref goes straight to the pointer walk, even in an unnamed buffer"] = function()
  local ws = workspace.new()
  local doc = assert(ws:open_text("x: 1\n", { bufnr = 9 }))
  expect.equality(open_ref(ws, doc, "#/x").node.value, 1)
  expect.equality(reason_of(ws, doc, "#/no/such"), "no such pointer")
  expect.equality(open_ref(ws, doc, "#").node == doc.root, true)
end

T["open checks"]["an external ref from an unnamed buffer has no base, even with a root set"] = function()
  local ws = workspace.new({ root = new_dir() })
  local doc = assert(ws:open_text("x: 1\n", { bufnr = 9 }))
  expect.equality(reason_of(ws, doc, "./a.yaml"), "no base path")
  expect.equality(reason_of(ws, doc, "/etc/a.txt"), "no base path")
end

T["open checks"]["an outside path with a bad extension is outside root"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "../a.txt"), "outside root")
  expect.equality(reason_of(ws, doc, "/etc/passwd"), "outside root")
end

T["open checks"]["an inside missing .txt is bad file type"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "./missing.txt"), "bad file type")
end

T["open checks"]["an inside missing .yaml is not found"] = function()
  local ws, doc = open_root(new_dir())
  expect.equality(reason_of(ws, doc, "./missing.yaml"), "not found")
end

T["open checks"]["a FIFO named x.yaml is bad file type and returns at once"] = function()
  local dir = new_dir()
  vim.fn.system({ "mkfifo", dir .. "/x.yaml" })
  expect.equality(vim.v.shell_error, 0)
  local ws, doc = open_root(dir)
  expect.equality(reason_of(ws, doc, "./x.yaml"), "bad file type")
end

T["open checks"]["a directory named x.yaml is bad file type"] = function()
  local dir = new_dir()
  vim.fn.mkdir(dir .. "/x.yaml")
  local ws, doc = open_root(dir)
  expect.equality(reason_of(ws, doc, "./x.yaml"), "bad file type")
end

T["open checks"]["size comes before file count"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir, nil, { max_file_bytes = 2, max_files = 0 })
  expect.equality(reason_of(ws, doc, "./a.yaml"), "too large")
end

T["outside root"] = MiniTest.new_set()

T["outside root"]["an absolute path"] = function()
  local base, _, ws, doc = outside_setup()
  expect.equality(reason_of(ws, doc, base .. "/secret.yaml"), "outside root")
end

T["outside root"]["relative paths to an existing and a missing file"] = function()
  local _, _, ws, doc = outside_setup()
  expect.equality(reason_of(ws, doc, "../secret.yaml"), "outside root")
  expect.equality(reason_of(ws, doc, "../missing.yaml"), "outside root")
end

T["outside root"]["the committed outside fixture"] = function()
  local ws, doc = open_multi()
  expect.equality(reason_of(ws, doc, "../outside.yaml"), "outside root")
  expect.equality(reason_of(ws, doc, "../no-such-outside.yaml"), "outside root")
end

T["outside root"]["a link to an outside file"] = function()
  local base, inside, ws, doc = outside_setup()
  assert(vim.uv.fs_symlink(base .. "/secret.yaml", inside .. "/link.yaml"))
  expect.equality(reason_of(ws, doc, "./link.yaml"), "outside root")
end

T["outside root"]["a missing file under a symlinked directory that leaves the root"] = function()
  local base, inside, ws, doc = outside_setup()
  assert(vim.uv.fs_symlink(base, inside .. "/out"))
  expect.equality(reason_of(ws, doc, "./out/missing.yaml"), "outside root")
  expect.equality(reason_of(ws, doc, "./out/secret.yaml"), "outside root")
end

T["outside root"]["a dangling symlink target, pointing inside or outside"] = function()
  local base, inside, ws, doc = outside_setup()
  assert(vim.uv.fs_symlink(inside .. "/gone.yaml", inside .. "/in.yaml"))
  assert(vim.uv.fs_symlink(base .. "/gone.yaml", inside .. "/out.yaml"))
  expect.equality(reason_of(ws, doc, "./in.yaml"), "outside root")
  expect.equality(reason_of(ws, doc, "./out.yaml"), "outside root")
end

T["outside root"]["a dangling symlink or a loop in the middle of the path"] = function()
  local _, inside, ws, doc = outside_setup()
  assert(vim.uv.fs_symlink(inside .. "/gone", inside .. "/dangling"))
  assert(vim.uv.fs_symlink(inside .. "/loop", inside .. "/loop"))
  expect.equality(reason_of(ws, doc, "./dangling/a.yaml"), "outside root")
  expect.equality(reason_of(ws, doc, "./loop/a.yaml"), "outside root")
end

T["outside root"]["a link staying inside the root is followed"] = function()
  local _, inside, ws, doc = outside_setup()
  write(inside .. "/real.yaml", "x: 1\n")
  assert(vim.uv.fs_symlink(inside .. "/real.yaml", inside .. "/link.yaml"))
  local result = open_ref(ws, doc, "./link.yaml#/x")
  expect.equality(result.node.value, 1)
  expect.equality(result.key, inside .. "/real.yaml#/x")
end

T["outside root"]["checks 1 to 3 make no filesystem call"] = function()
  local base, _, ws, doc = outside_setup()
  local unnamed_ws = workspace.new()
  local unnamed = assert(unnamed_ws:open_text("x: 1\n", { bufnr = 2 }))
  local calls = with_spy(FS_CALLS, vim.uv, function()
    expect.equality(reason_of(unnamed_ws, unnamed, "./a.yaml"), "no base path")
    expect.equality(reason_of(ws, doc, base .. "/secret.yaml"), "outside root")
    expect.equality(reason_of(ws, doc, "../secret.yaml"), "outside root")
    expect.equality(reason_of(ws, doc, "../missing.txt"), "outside root")
    expect.equality(reason_of(ws, doc, "./inside.txt"), "bad file type")
  end)
  expect.equality(calls, {})
end

T["boundary"] = MiniTest.new_set()

T["boundary"]["refs.root wins"] = function()
  local dir = new_dir()
  write(dir .. "/.git/HEAD", "")
  write(dir .. "/sub/root.yaml", "a: 1\n")
  local ws = workspace.new({ root = dir .. "/sub" })
  assert(ws:open_file(dir .. "/sub/root.yaml"))
  expect.equality(ws.root, dir .. "/sub")
end

T["boundary"]["then the nearest .git"] = function()
  local dir = new_dir()
  write(dir .. "/.git/HEAD", "")
  write(dir .. "/a/b/root.yaml", "a: 1\n")
  local ws = workspace.new()
  assert(ws:open_file(dir .. "/a/b/root.yaml"))
  expect.equality(ws.root, dir)
end

T["boundary"]["a .git file counts"] = function()
  local dir = new_dir()
  write(dir .. "/.git", "gitdir: elsewhere\n")
  write(dir .. "/a/root.yaml", "a: 1\n")
  local ws = workspace.new()
  assert(ws:open_file(dir .. "/a/root.yaml"))
  expect.equality(ws.root, dir)
end

T["boundary"]["then the document's directory"] = function()
  local dir = new_dir()
  write(dir .. "/a/root.yaml", "a: 1\n")
  local ws = workspace.new()
  assert(ws:open_file(dir .. "/a/root.yaml"))
  expect.equality(ws.root, dir .. "/a")
end

local function with_home(home, run)
  local saved = vim.env.HOME
  vim.env.HOME = home
  local ok, err = pcall(run)
  vim.env.HOME = saved
  if not ok then
    error(err, 0)
  end
end

T["boundary"]["a .git in the home directory gives the document's directory"] = function()
  local home = new_dir()
  write(home .. "/.git/HEAD", "")
  write(home .. "/.config/x.yml", "x: 1\n")
  write(home .. "/a/b/root.yaml", "a: 1\n")
  with_home(home, function()
    local ws = workspace.new()
    local doc = assert(ws:open_file(home .. "/a/b/root.yaml"))
    expect.equality(ws.root, home .. "/a/b")
    expect.equality(reason_of(ws, doc, "../../.config/x.yml"), "outside root")
  end)
end

T["boundary"]["a .git above the home directory gives the document's directory"] = function()
  local parent = new_dir()
  write(parent .. "/.git/HEAD", "")
  write(parent .. "/home/a/root.yaml", "a: 1\n")
  with_home(parent .. "/home", function()
    local ws = workspace.new()
    assert(ws:open_file(parent .. "/home/a/root.yaml"))
    expect.equality(ws.root, parent .. "/home/a")
  end)
end

T["boundary"]["a .git below the home directory still counts"] = function()
  local home = new_dir()
  write(home .. "/.git/HEAD", "")
  write(home .. "/proj/.git/HEAD", "")
  write(home .. "/proj/x/root.yaml", "a: 1\n")
  with_home(home, function()
    local ws = workspace.new()
    assert(ws:open_file(home .. "/proj/x/root.yaml"))
    expect.equality(ws.root, home .. "/proj")
  end)
end

T["boundary"]["a symlinked home directory is compared by its real path"] = function()
  local real = new_dir()
  write(real .. "/.git/HEAD", "")
  write(real .. "/a/root.yaml", "a: 1\n")
  local link = new_dir() .. "/home"
  assert(vim.uv.fs_symlink(real, link))
  with_home(link, function()
    local ws = workspace.new()
    assert(ws:open_file(real .. "/a/root.yaml"))
    expect.equality(ws.root, real .. "/a")
  end)
end

T["boundary"]["a trailing slash in HOME still matches"] = function()
  local home = new_dir()
  write(home .. "/.git/HEAD", "")
  write(home .. "/a/root.yaml", "a: 1\n")
  with_home(home .. "/", function()
    local ws = workspace.new()
    assert(ws:open_file(home .. "/a/root.yaml"))
    expect.equality(ws.root, home .. "/a")
  end)
end

T["boundary"]["a .git at / is never the automatic root, even with no home directory"] = function()
  local dir = new_dir()
  write(dir .. "/a/root.yaml", "a: 1\n")
  local fs_stat, os_homedir = vim.uv.fs_stat, vim.uv.os_homedir
  vim.uv.fs_stat = function(path, ...)
    if path == "/.git" then
      return { type = "directory" }
    end
    return fs_stat(path, ...)
  end
  vim.uv.os_homedir = function()
    return ""
  end
  local ok, err = pcall(function()
    local ws = workspace.new()
    assert(ws:open_file(dir .. "/a/root.yaml"))
    expect.equality(ws.root, dir .. "/a")
  end)
  vim.uv.fs_stat, vim.uv.os_homedir = fs_stat, os_homedir
  if not ok then
    error(err, 0)
  end
end

T["boundary"]["an explicit refs.root may be the home directory"] = function()
  local home = new_dir()
  write(home .. "/a/root.yaml", "a: 1\n")
  with_home(home, function()
    local ws = workspace.new({ root = home })
    assert(ws:open_file(home .. "/a/root.yaml"))
    expect.equality(ws.root, home)
  end)
end

T["boundary"]["a sibling with the root as a name prefix is outside"] = function()
  local dir = new_dir()
  write(dir .. "/a-b/x.yaml", "x: 1\n")
  write(dir .. "/a/root.yaml", "a: 1\n")
  local ws = workspace.new({ root = dir .. "/a" })
  local doc = assert(ws:open_file(dir .. "/a/root.yaml"))
  expect.equality(reason_of(ws, doc, "../a-b/x.yaml"), "outside root")
end

T["boundary"]["a symlinked root is compared by its real path"] = function()
  local dir = new_dir()
  write(dir .. "/real/root.yaml", "a: 1\n")
  write(dir .. "/real/b.yaml", "x: 1\n")
  assert(vim.uv.fs_symlink(dir .. "/real", dir .. "/link"))
  local ws = workspace.new({ root = dir .. "/link" })
  local doc = assert(ws:open_file(dir .. "/link/root.yaml"))
  expect.equality(ws.root, dir .. "/real")
  expect.equality(open_ref(ws, doc, "./b.yaml#/x").node.value, 1)
end

T["file types"] = MiniTest.new_set()

for _, row in ipairs({
  { "a.yaml", nil },
  { "a.yml", nil },
  { "a.json", nil },
  { "a.txt", "bad file type" },
  { "a.lua", "bad file type" },
  { "yaml", "bad file type" },
}) do
  T["file types"][row[1]] = function()
    local dir = new_dir()
    write(dir .. "/" .. row[1], "{}\n")
    local ws, doc = open_root(dir)
    expect.equality(reason_of(ws, doc, "./" .. row[1]), row[2])
  end
end

T["limits"] = MiniTest.new_set()

T["limits"]["do not apply to the opened document"] = function()
  local dir = new_dir()
  write(dir .. "/root.yaml", "a: 1\nb: 2\n")
  local ws = workspace.new({ root = dir, max_file_bytes = 1, max_files = 0 })
  local doc = assert(ws:open_file(dir .. "/root.yaml"))
  expect.equality(tree.get(doc.root, "b").value, 2)
  expect.equality(ws:loaded_files(), {})
end

T["limits"]["a file at exactly the size limit loads"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir, nil, { max_file_bytes = 5 })
  expect.equality(reason_of(ws, doc, "./a.yaml"), nil)
end

T["limits"]["an already loaded file does not count again"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws, doc = open_root(dir, nil, { max_files = 1 })
  expect.equality(reason_of(ws, doc, "./a.yaml#/x"), nil)
  expect.equality(reason_of(ws, doc, "./a.yaml#"), nil)
end

T["unnamed and named buffers"] = MiniTest.new_set()

T["unnamed and named buffers"]["an unnamed buffer's key is stable, so a cycle is detected"] = function()
  local ws = workspace.new()
  local doc = assert(ws:open_text("a:\n  $ref: '#/b'\nb:\n  $ref: '#/a'\n", { bufnr = 4 }))
  expect.equality(refs.check_text("#/a", doc.identity).key, "buffer:4#/a")
  expect.equality(refs.check_text("#/a", doc.identity).key, refs.check_text("#/a", doc.identity).key)
  expect.equality(refs.follow(ws, doc, refs.check_text("#/a", doc.identity), V31).reason, "ref cycle")
end

T["unnamed and named buffers"]["a named buffer with no file on disk uses its name's directory"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws = workspace.new({ root = dir })
  local doc = assert(ws:open_text("y: 2\n", { name = dir .. "/unsaved.yaml", bufnr = 3 }))
  expect.equality(doc.identity, dir .. "/unsaved.yaml")
  expect.equality(doc.file, dir .. "/unsaved.yaml")
  expect.equality(open_ref(ws, doc, "./a.yaml#/x").node.value, 1)
end

T["unnamed and named buffers"]["a named buffer's unsaved text answers a ref to its own file"] = function()
  local dir = new_dir()
  write(dir .. "/own.yaml", "x: disk\n")
  local ws = workspace.new({ root = dir })
  local doc = assert(ws:open_text("x: buffer\n", { name = dir .. "/own.yaml", bufnr = 3 }))
  expect.equality(open_ref(ws, doc, "./own.yaml#/x").node.value, "buffer")
  expect.equality(ws:loaded_files(), {})
end

T["identity"] = MiniTest.new_set()

T["identity"]["is the real path of a file, through a symlink"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  assert(vim.uv.fs_symlink(dir .. "/a.yaml", dir .. "/b.yaml"))
  expect.equality(workspace.identity({ file = dir .. "/b.yaml" }), dir .. "/a.yaml")
  expect.equality(workspace.identity({ name = dir .. "/a.yaml", bufnr = 1 }), dir .. "/a.yaml")
end

T["identity"]["is the absolute name with no file on disk"] = function()
  local dir = new_dir()
  expect.equality(workspace.identity({ name = dir .. "/x/../none.yaml", bufnr = 1 }), dir .. "/none.yaml")
end

T["identity"]["is the buffer number for an unnamed buffer"] = function()
  expect.equality(workspace.identity({ bufnr = 12 }), "buffer:12")
  expect.equality(workspace.identity({ name = "", bufnr = 12 }), "buffer:12")
end

T["opening"] = MiniTest.new_set()

T["opening"]["a missing file and a directory give a read failure"] = function()
  local dir = new_dir()
  local ws = workspace.new()
  local doc, err = ws:open_file(dir .. "/missing.yaml")
  expect.equality(doc, nil)
  err = assert(err, "a read failure")
  expect.equality(err.kind, "read")
  expect.equality(err.reason:find("ENOENT", 1, true) ~= nil, true)

  local _, dir_err = ws:open_file(dir)
  expect.equality(dir_err, { kind = "read", reason = "is a directory" })
end

T["opening"]["a FIFO does not block"] = function()
  local dir = new_dir()
  vim.fn.system({ "mkfifo", dir .. "/x.yaml" })
  local _, err = workspace.new():open_file(dir .. "/x.yaml")
  expect.equality(err, { kind = "read", reason = "not a regular file" })
end

T["document cache"] = MiniTest.new_set()

T["document cache"]["one Doc per real path"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  assert(vim.uv.fs_symlink(dir .. "/a.yaml", dir .. "/b.yaml"))
  local ws, doc = open_root(dir)
  local first = open_ref(ws, doc, "./a.yaml#")
  local second = open_ref(ws, doc, "./sub/../a.yaml#")
  local linked = open_ref(ws, doc, "./b.yaml#")
  expect.equality(first.doc == second.doc, true)
  expect.equality(first.doc == linked.doc, true)
  expect.equality(ws:loaded_files(), { dir .. "/a.yaml" })
end

T["document cache"]["a ref to the root document returns it without loading"] = function()
  local ws, doc = open_multi()
  expect.equality(open_ref(ws, doc, "./root.yaml#").doc == doc, true)
  expect.equality(ws:loaded_files(), {})
end

T["document cache"]["an external Doc carries no bufnr"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws = workspace.new({ root = dir })
  local doc = assert(ws:open_text("y: 2\n", { name = dir .. "/root.yaml", bufnr = 8 }))
  expect.equality(tree.get(doc.root, "y").pos.bufnr, 8)

  local result = open_ref(ws, doc, "./a.yaml#/x")
  expect.equality(result.doc.bufnr, nil)
  expect.equality(result.node.pos.bufnr, nil)
  expect.equality(result.node.pos.file, dir .. "/a.yaml")
end

T["document cache"]["separate workspaces share nothing"] = function()
  local dir = new_dir()
  write(dir .. "/a.yaml", "x: 1\n")
  local ws_a, doc_a = open_root(dir)
  local ws_b = workspace.new({ root = dir })
  assert(ws_b:open_file(dir .. "/root.yaml"))
  open_ref(ws_a, doc_a, "./a.yaml")
  expect.equality(#ws_a:loaded_files(), 1)
  expect.equality(#ws_b:loaded_files(), 0)
end

return T
