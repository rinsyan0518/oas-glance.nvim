local helpers = dofile("tests/helpers.lua")

local child = helpers.new_child()
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.boot()
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local PETSTORE = "tests/fixtures/petstore-31.yaml"

local function pane(filetype)
  return child.lua(
    [[
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == ... then
        return { win = win, buf = buf }
      end
    end
  ]],
    { filetype }
  )
end

local function lines(filetype)
  return child.api.nvim_buf_get_lines(pane(filetype).buf, 0, -1, false)
end

local function focus(filetype)
  child.api.nvim_set_current_win(pane(filetype).win)
end

local function list_goto(text)
  focus("oasglance-list")
  for index, line in ipairs(lines("oasglance-list")) do
    if line:find(text, 1, true) then
      child.type_keys(tostring(index) .. "G")
      return
    end
  end
  error("no list row with " .. text, 0)
end

--- Takes both references with the list focused, then both with the detail pane focused.
local function expect_view(name)
  for _, side in ipairs({ "list", "detail" }) do
    focus("oasglance-" .. side)
    helpers.expect_screen(child, name .. "-" .. side)
    helpers.expect_highlights(child, name .. "-" .. side)
  end
end

local function open(file)
  child.cmd("OasGlance " .. file)
end

T["overview"] = function()
  open(PETSTORE)
  expect.equality(lines("oasglance-detail")[5], "No problems so far.")
  expect.equality(lines("oasglance-list")[3], "")
  expect_view("view-overview")
end

T["operation"] = function()
  open(PETSTORE)
  list_goto("GET     /pets/{petId}")
  expect_view("view-operation")
end

T["deprecated"] = function()
  open(PETSTORE)
  list_goto("DELETE")
  expect_view("view-deprecated")

  local foreground = child.lua_get('vim.api.nvim_get_hl(0, { name = "OasGlanceMethodDelete", link = false }).fg')
  expect.equality(type(foreground), "number")
  local wanted = string.format("foreground=#%06x", foreground)
  local both = false
  for _, line in ipairs(helpers.highlight_lines(child)) do
    if line:find("strikethrough=true", 1, true) and line:find(wanted, 1, true) then
      both = true
    end
  end
  expect.equality(both, true)
end

T["schema"] = function()
  open(PETSTORE)
  list_goto("   Pet")
  expect.equality(lines("oasglance-detail")[1], "Pet  object")
  expect_view("view-schema")
end

T["types a"] = function()
  open("tests/fixtures/types.yaml")
  list_goto("TypesA")
  expect_view("view-types-a")
end

T["types b"] = function()
  open("tests/fixtures/types.yaml")
  list_goto("TypesB")
  expect_view("view-types-b")
end

T["help"] = function()
  open(PETSTORE)
  focus("oasglance-detail")
  child.type_keys("?")
  expect.equality(lines("oasglance-detail")[1], "List pane")
  expect_view("view-help")
  expect.equality(lines("oasglance-detail")[1], "List pane")
end

T["methods"] = function()
  open("tests/fixtures/methods.yaml")
  expect_view("view-methods")
end

T["status"] = function()
  open("tests/fixtures/statuses.yaml")
  list_goto("GET")
  expect_view("view-status")
end

local function detail_goto(text)
  focus("oasglance-detail")
  for index, line in ipairs(lines("oasglance-detail")) do
    if line:find(text, 1, true) then
      child.type_keys(tostring(index) .. "G")
      return index
    end
  end
  error("no detail row with " .. text, 0)
end

T["expanded ref"] = function()
  open(PETSTORE)
  list_goto("GET     /pets/{petId}")
  detail_goto("▸ → Pet")
  child.type_keys("<CR>")
  local row = detail_goto("parent")
  local first, last = child.fn.line("w0"), child.fn.line("w$")
  expect.equality(first <= row and row <= last, true)
  expect.equality(lines("oasglance-detail")[row], "      parent    ↻ Pet  cycle")
  expect_view("view-expanded-ref")
end

T["cycle"] = function()
  open("tests/fixtures/cycles.yaml")
  list_goto("   A")
  detail_goto("→ B")
  child.type_keys("<CR>")
  expect.equality(lines("oasglance-detail")[4], "    a  ↻ A  cycle")
  expect_view("view-cycle")
end

T["ref-only cycle"] = function()
  open("tests/fixtures/cycles.yaml")
  list_goto("   UsesLoop")
  detail_goto("loop")
  child.type_keys("<CR>")
  expect.equality(lines("oasglance-detail")[3], "  loop  ✗ #/components/schemas/LoopA  ref cycle")
  expect.equality(lines("oasglance-list")[3], " ! 1 problem so far")
  expect_view("view-ref-only-cycle")
end

T["overview with notes"] = function()
  open("tests/fixtures/notes-30.yaml")
  list_goto("   Pet")
  list_goto(" OpenAPI")
  local shown = lines("oasglance-detail")
  expect.equality(vim.list_slice(shown, #shown - 4), {
    "No problems so far.",
    "References are checked when opened.",
    "",
    "Notes 1",
    "  line 12  $ref siblings are ignored in OpenAPI 3.0",
  })
  expect.equality(lines("oasglance-list")[3], "")
  expect_view("view-overview-notes")
end

local function overview_and_header()
  list_goto(" Petstore")
  return { header = lines("oasglance-list")[3], overview = lines("oasglance-detail") }
end

T["row limit"] = function()
  open(PETSTORE)
  list_goto("   Pet")
  local unlimited = overview_and_header()
  child.type_keys("q")

  child.lua("require('oas-glance').setup({ max_detail_rows = 15 })")
  open(PETSTORE)
  list_goto("   Pet")
  focus("oasglance-detail")
  child.type_keys("G")
  local shown = lines("oasglance-detail")
  expect.equality(#shown, 16)
  expect.equality(shown[16], "! stopped at 15 rows (max_detail_rows)")
  expect.equality(child.api.nvim_win_get_cursor(0), { 16, 0 })
  expect_view("view-row-limit")

  expect.equality(overview_and_header(), unlimited)
end

-- The built-in prompt, as spec 9 says.
local function filter_by(text)
  focus("oasglance-list")
  child.type_keys("f", text, "<CR>")
end

T["filter"] = function()
  open(PETSTORE)
  filter_by("tag:pet path:/pets")
  expect.equality(lines("oasglance-list")[1], " Filter: tag:pet path:/pets")
  expect.equality(lines("oasglance-detail")[1], "Petstore 1.0.0")
  expect_view("view-filter")
end

local MULTI_DIR = "tests/fixtures/multi"

local function open_multi(file)
  local root = child.lua_get("vim.uv.fs_realpath(...)", { MULTI_DIR })
  child.lua("require('oas-glance').setup(...)", { { refs = { root = root } } })
  open(MULTI_DIR .. "/" .. file)
end

local function detail_toggle(text)
  focus("oasglance-detail")
  for index, line in ipairs(lines("oasglance-detail")) do
    if line:find(text, 1, true) then
      child.type_keys(tostring(index) .. "G", "<CR>")
      return
    end
  end
  error("no detail row with " .. text, 0)
end

T["closed ref"] = function()
  expect.equality(vim.uv.fs_stat(MULTI_DIR .. "/gone.yaml"), nil)
  open_multi("root.yaml")
  list_goto("   Pet")
  expect.equality(lines("oasglance-list")[3], "")
  expect_view("view-closed-ref")
end

T["broken ref"] = function()
  open_multi("root.yaml")
  list_goto("   Pet")
  detail_toggle("▸ gone")
  expect.equality(lines("oasglance-list")[3], " ! 1 problem so far")
  expect_view("view-broken-ref")
end

T["remote ref"] = function()
  open_multi("root.yaml")
  list_goto("   Remote")
  expect.equality(lines("oasglance-list")[3], " ! 1 problem so far")
  expect_view("view-remote-ref")
end

T["external ref"] = function()
  open_multi("root.yaml")
  list_goto("   Pet")
  detail_toggle("▸ owner")
  expect_view("view-external-ref")
end

T["broken path item"] = function()
  open_multi("broken-path-item.yaml")
  list_goto("/pets  not found")
  expect_view("view-broken-path-item")
end

T["overview with problems"] = function()
  open("tests/fixtures/broken-syntax.yaml")
  expect.equality(lines("oasglance-detail")[4], "Problems so far 2")
  expect_view("view-overview-problems")
end

T["problem row"] = function()
  open("tests/fixtures/broken-syntax.yaml")
  list_goto("GET     /bad")
  expect_view("view-problem-row")
end

T["no matches"] = function()
  open(PETSTORE)
  filter_by("nothing-like-this")
  expect.equality(lines("oasglance-list"), { " Filter: nothing-like-this", "", " No matches" })
  expect_view("view-no-matches")
end

T["curl"] = function()
  open(PETSTORE)
  list_goto("POST    /pets")
  child.type_keys("gc")
  expect.equality(child.bo.filetype, "sh")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), {
    ": 'createPet: POST /pets'",
    "curl -X POST --url 'https://api.example.com/v1/pets' \\",
    "  -H 'Content-Type: application/json' \\",
    "  --data-raw '{",
    '    "name": "string"',
    "  }'",
  })
  helpers.expect_screen(child, "view-curl")
  helpers.expect_highlights(child, "view-curl")
end

return T
