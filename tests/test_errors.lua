local helpers = dofile("tests/helpers.lua")

local child = helpers.new_child()
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.boot()
      -- A long message would raise a hit-enter prompt, so notifications are recorded instead.
      child.lua([[
        _G.notes = {}
        vim.notify = function(message, level)
          table.insert(_G.notes, { message = message, level = level })
        end
      ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local ERROR = vim.log.levels.ERROR
local SUPPORTED = " Supported versions: 3.0, 3.1."

--- Runs a command and expects one ERROR notification with that text, and no new tabpage.
local function expect_fatal(command, message)
  child.cmd(command)
  expect.equality(child.lua_get("_G.notes"), { { message = message, level = ERROR } })
  expect.equality(child.fn.tabpagenr("$"), 1)
  expect.equality(#child.api.nvim_list_wins(), 1)
end

local function view_text(lines)
  child.cmd("enew")
  child.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  child.cmd("OasGlance")
end

T["parser missing"] = function()
  child.lua('vim.opt.runtimepath:remove("/opt/tree-sitter-yaml")')
  expect_fatal(
    "OasGlance tests/fixtures/petstore-31.yaml",
    "oas-glance: the tree-sitter \"yaml\" parser was not found on 'runtimepath' (parser/yaml.*). See :help oas-glance-parser"
  )
end

T["parser fails to load"] = function()
  child.lua([[
    local dir = vim.fn.tempname() .. "-bad-parser"
    vim.fn.mkdir(dir .. "/parser", "p")
    vim.fn.writefile({ "not a shared object" }, dir .. "/parser/yaml.so")
    vim.opt.runtimepath:prepend(dir)
  ]])
  child.cmd("OasGlance tests/fixtures/petstore-31.yaml")
  local notes = child.lua_get("_G.notes")
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, ERROR)
  local prefix = 'oas-glance: cannot load the tree-sitter "yaml" parser: '
  expect.equality(notes[1].message:sub(1, #prefix), prefix)
  expect.equality(#notes[1].message > #prefix, true)
  expect.equality(child.fn.tabpagenr("$"), 1)
end

T["unreadable"] = MiniTest.new_set()

T["unreadable"]["a missing path"] = function()
  expect_fatal(
    "OasGlance tests/fixtures/no-such.yaml",
    "oas-glance: cannot read tests/fixtures/no-such.yaml: no such file or directory"
  )
end

T["unreadable"]["a directory"] = function()
  expect_fatal("OasGlance tests/fixtures", "oas-glance: cannot read tests/fixtures: is a directory")
end

T["file name"] = MiniTest.new_set()

T["file name"]["is the name as given"] = function()
  expect_fatal(
    "OasGlance tests/fixtures/not-openapi.yaml",
    "oas-glance: not an OpenAPI document: tests/fixtures/not-openapi.yaml"
  )
end

T["file name"]["is the name the buffer holds"] = function()
  child.cmd("edit tests/fixtures/not-openapi.yaml")
  expect_fatal("OasGlance", "oas-glance: not an OpenAPI document: tests/fixtures/not-openapi.yaml")
end

T["file name"]["is [No Name] for an unnamed buffer"] = function()
  child.cmd("enew")
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "a: 1" })
  child.cmd("OasGlance")
  expect.equality(child.lua_get("_G.notes"), {
    { message = "oas-glance: not an OpenAPI document: [No Name]", level = ERROR },
  })
  expect.equality(child.fn.tabpagenr("$"), 1)
end

T["versions"] = MiniTest.new_set()

T["versions"]["swagger 2.0"] = function()
  expect_fatal(
    "OasGlance tests/fixtures/swagger-20.yaml",
    "oas-glance: OpenAPI 2.0 (Swagger) is not supported yet: tests/fixtures/swagger-20.yaml." .. SUPPORTED
  )
end

T["versions"]["3.2"] = function()
  expect_fatal(
    "OasGlance tests/fixtures/version-32.yaml",
    "oas-glance: OpenAPI 3.2.0 is not supported: tests/fixtures/version-32.yaml." .. SUPPORTED
  )
end

T["versions"]["openapi decides over swagger"] = function()
  view_text({ "openapi: 3.2.0", 'swagger: "2.0"' })
  expect.equality(child.lua_get("_G.notes"), {
    { message = "oas-glance: OpenAPI 3.2.0 is not supported: [No Name]." .. SUPPORTED, level = ERROR },
  })
end

T["versions"]["a non-scalar openapi counts as no key"] = function()
  view_text({ "openapi: {}" })
  expect.equality(child.lua_get("_G.notes"), {
    { message = "oas-glance: not an OpenAPI document: [No Name]", level = ERROR },
  })
  expect.equality(child.fn.tabpagenr("$"), 1)
end

T["known limitation, pinned (docs/design/parsing.md)"] = MiniTest.new_set()

T["known limitation, pinned (docs/design/parsing.md)"]["a JSON missing comma loses the root and is not an OpenAPI document"] = function()
  expect_fatal(
    "OasGlance tests/fixtures/json-missing-comma.json",
    "oas-glance: not an OpenAPI document: tests/fixtures/json-missing-comma.json"
  )
end

T["line limit"] = MiniTest.new_set()

local LIMIT_TEXT = 'the tree-sitter "yaml" parser fails on YAML over 32768 lines. '
  .. "Convert it to JSON to view it. See :help oas-glance-limits"

local function limit_message(file, n)
  return ("oas-glance: %s has %d lines; %s"):format(file, n, LIMIT_TEXT)
end

local large_dir
--- Writes each generated document once, so no large text goes over RPC.
local function large_files()
  if large_dir then
    return large_dir
  end
  large_dir = vim.fn.tempname()
  vim.fn.mkdir(large_dir, "p")
  local files = {
    ["over.yaml"] = helpers.block_yaml(32769),
    ["over-comment.yaml"] = helpers.block_yaml(32769 + 2, { leading_comment = true }),
    ["at.yaml"] = helpers.block_yaml(32768),
    ["at-no-newline.yaml"] = helpers.block_yaml(32768, { final_newline = false }),
    ["at-broken.yaml"] = helpers.block_yaml(32768, { syntax_error = true }),
    ["big.json"] = helpers.pretty_json(40003),
    ["big-broken.json"] = helpers.pretty_json(40003, { syntax_error = true }),
    ["root.yaml"] = table.concat({
      "openapi: 3.1.0",
      "info: { title: Root, version: '1' }",
      "paths: {}",
      "components:",
      "  schemas:",
      "    S:",
      "      properties:",
      "        big:",
      "          $ref: ./over.yaml#/components/schemas/Pad",
      "",
    }, "\n"),
  }
  for name, text in pairs(files) do
    local file = assert(io.open(large_dir .. "/" .. name, "wb"))
    file:write(text)
    file:close()
  end
  return large_dir
end

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

local function pane_lines(filetype)
  return child.api.nvim_buf_get_lines(pane(filetype).buf, 0, -1, false)
end

--- Moves the cursor of a pane to a row with a motion, so `CursorMoved` runs.
local function pane_goto(filetype, row)
  child.api.nvim_set_current_win(pane(filetype).win)
  child.type_keys(tostring(row) .. "G")
end

local function row_of(all, text)
  for index, line in ipairs(all) do
    if line:find(text, 1, true) then
      return index
    end
  end
  error("no line with " .. text .. " in:\n" .. table.concat(all, "\n"), 0)
end

--- Expects the limit message for the last command, at ERROR level, and no new tabpage.
local function expect_refused(file, n)
  expect.equality(child.lua_get("_G.notes"), { { message = limit_message(file, n), level = ERROR } })
  expect.equality(child.fn.tabpagenr("$"), 1)
  child.lua("_G.notes = {}")
end

T["line limit"]["refuses block YAML over the limit"] = function()
  local dir = large_files()
  child.cmd("OasGlance " .. dir .. "/over.yaml")
  expect_refused(dir .. "/over.yaml", 32769)

  child.cmd("enew")
  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn.readfile(...))", { dir .. "/over.yaml" })
  expect.equality(child.api.nvim_buf_line_count(0), 32769)
  child.cmd("OasGlance")
  expect_refused("[No Name]", 32769)

  child.cmd("OasGlance " .. dir .. "/over-comment.yaml")
  expect_refused(dir .. "/over-comment.yaml", 32771)

  -- Reload: the view stays as it was.
  local path = vim.fn.tempname() .. "-small.yaml"
  local file = assert(io.open(path, "wb"))
  file:write(helpers.block_yaml(12))
  file:close()
  child.cmd("OasGlance " .. path)
  expect.equality(child.lua_get("_G.notes"), {})
  local before =
    { list = pane_lines("oasglance-list"), detail = pane_lines("oasglance-detail"), tabs = child.fn.tabpagenr("$") }
  child.lua("vim.uv.fs_copyfile(...)", { dir .. "/over.yaml", path })
  child.type_keys("R")
  expect.equality(child.lua_get("_G.notes"), { { message = limit_message(path, 32769), level = ERROR } })
  local after =
    { list = pane_lines("oasglance-list"), detail = pane_lines("oasglance-detail"), tabs = child.fn.tabpagenr("$") }
  expect.equality(after, before)
end

T["line limit"]["opens what is not refused"] = function()
  local dir = large_files()
  for _, name in ipairs({ "at.yaml", "at-no-newline.yaml", "big.json", "big-broken.json", "at-broken.yaml" }) do
    child.cmd("OasGlance " .. dir .. "/" .. name)
    expect.equality(child.lua_get("_G.notes"), {})
    local list = pane_lines("oasglance-list")
    expect.equality(list[1], " Generated 1.0.0")
    expect.equality(row_of(list, "Pad") > 0, true)
    local broken = name:find("broken", 1, true) ~= nil
    expect.equality(list[3]:sub(1, 3) == " ! ", broken)
    child.type_keys("q")
    expect.equality(child.fn.tabpagenr("$"), 1)
  end

  -- An external ref to a file over the limit.
  child.lua("require('oas-glance').setup(...)", { { refs = { root = vim.uv.fs_realpath(dir) } } })
  child.cmd("OasGlance " .. dir .. "/root.yaml")
  pane_goto("oasglance-list", row_of(pane_lines("oasglance-list"), "   S"))
  local detail = pane_lines("oasglance-detail")
  local row = row_of(detail, " big ")
  expect.equality(detail[row]:sub(1, #"▸ big  → "), "▸ big  → ")
  pane_goto("oasglance-detail", row)
  child.type_keys("za")
  detail = pane_lines("oasglance-detail")
  expect.equality(detail[row], "  big  ✗ ./over.yaml#/components/schemas/Pad  too many lines")
  expect.equality(pane_lines("oasglance-list")[3], " ! 1 problem so far")
  expect.equality(child.lua_get("_G.notes"), {})
end

return T
