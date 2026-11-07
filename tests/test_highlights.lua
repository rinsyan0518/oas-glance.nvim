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

-- Copied from spec 6 rather than read from the module, so a wrong link in the module fails. False is no link.
local EXPECTED = {
  OasGlanceMethodGet = "DiagnosticHint",
  OasGlanceMethodPost = "DiagnosticOk",
  OasGlanceMethodPut = "DiagnosticWarn",
  OasGlanceMethodPatch = "DiagnosticInfo",
  OasGlanceMethodDelete = "DiagnosticError",
  OasGlanceMethodHead = "Comment",
  OasGlanceMethodOptions = "Comment",
  OasGlanceMethodTrace = "Comment",
  OasGlancePath = "Identifier",
  OasGlancePathParam = "Special",
  OasGlanceTitle = "Title",
  OasGlanceMuted = "Comment",
  OasGlanceSection = "Title",
  OasGlanceGroup = "Directory",
  OasGlanceSchemaName = "Type",
  OasGlanceFold = "Special",
  OasGlanceProperty = "Identifier",
  OasGlanceRequired = "DiagnosticError",
  OasGlanceType = "Type",
  OasGlanceFormat = "Comment",
  OasGlanceNull = "Comment",
  OasGlanceEnum = "String",
  OasGlanceDefault = "Constant",
  OasGlanceConstraint = "Comment",
  OasGlanceDescription = false,
  OasGlanceLocation = "Comment",
  OasGlanceComposition = "Keyword",
  OasGlanceDeprecated = "DiagnosticDeprecated",
  OasGlanceRef = "Underlined",
  OasGlanceCycle = "DiagnosticWarn",
  OasGlanceBroken = "DiagnosticError",
  OasGlanceProblem = "DiagnosticWarn",
  OasGlanceStatusOther = "Comment",
  OasGlanceStatus2xx = "DiagnosticOk",
  OasGlanceStatus4xx = "DiagnosticWarn",
  OasGlanceStatus5xx = "DiagnosticError",
  OasGlanceFilter = "Question",
  OasGlanceMatch = "Search",
  OasGlanceHint = "Comment",
}

local READ_LINKS = [==[
  local links = {}
  for _, group in ipairs(require("oas-glance.internal.highlights").GROUPS) do
    links[group[1]] = vim.api.nvim_get_hl(0, { name = group[1] }).link or false
  end
  return links
]==]

T["OasGlanceDescription exists and is empty"] = function()
  child.lua('require("oas-glance.internal.highlights").setup()')
  expect.equality(child.fn.hlexists("OasGlanceDescription"), 1)
  local definition = child.lua('return vim.api.nvim_get_hl(0, { name = "OasGlanceDescription" })')
  definition.default = nil
  expect.equality(definition, {})
end

T["a user's OasGlanceDescription survives setup and a colorscheme"] = function()
  child.lua([[
    vim.api.nvim_set_hl(0, "OasGlanceDescription", { fg = "#123456" })
    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function()
        vim.api.nvim_set_hl(0, "OasGlanceDescription", { fg = "#654321" })
      end,
    })
    require("oas-glance.internal.highlights").setup()
  ]])
  local fg = 'return vim.api.nvim_get_hl(0, { name = "OasGlanceDescription" }).fg'
  expect.equality(child.lua(fg), 0x123456)
  child.cmd("colorscheme quiet")
  expect.equality(child.lua(fg), 0x654321)
end

--- The screen cells of a buffer line's text, as `{ col = attrs }` for every cell with attributes.
local function text_cells(cells, win, text)
  local line = child.fn.index(child.api.nvim_buf_get_lines(0, 0, -1, false), text) + 1
  local start = child.fn.screenpos(win, line, #text:match("^ *") + 1)
  local found = {}
  for _, run in ipairs(cells) do
    local row, from, to, attrs = run:match("^(%d+):(%d+)-(%d+) (.*)$")
    if row and tonumber(row) == start.row - 1 then
      for col = tonumber(from), tonumber(to) do
        found[col] = attrs
      end
    end
  end
  local result = {}
  for col = start.col - 1, start.col - 2 + #vim.trim(text) do
    result[#result + 1] = found[col] or ""
  end
  return result
end

-- A link to `Normal` would add its colours to both rows.
T["a description takes the window's colours, and cursorline shows through"] = function()
  child.cmd("OasGlance tests/fixtures/petstore-31.yaml")
  -- Rows are set by motions, because a search would highlight the text.
  local function goto_line(text)
    child.type_keys((child.fn.index(child.api.nvim_buf_get_lines(0, 0, -1, false), text) + 1) .. "G")
  end
  goto_line("   GET     /pets/{petId}")
  child.cmd("wincmd l")
  goto_line("    The id of the pet")
  local win = child.api.nvim_get_current_win()
  local cursorline = string.format(
    "background=#%06x",
    child.lua('return vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg')
  )
  local cells = helpers.highlight_lines(child)

  local under_cursor = text_cells(cells, win, "    The id of the pet")
  expect.equality(#under_cursor, #"The id of the pet")
  for _, attrs in ipairs(under_cursor) do
    expect.equality(attrs, cursorline)
  end
  local elsewhere = text_cells(cells, win, "Info for a specific pet")
  expect.equality(#elsewhere, #"Info for a specific pet")
  for _, attrs in ipairs(elsewhere) do
    expect.equality(attrs, "")
  end
end

T["every group links as the spec says"] = function()
  child.lua('require("oas-glance.internal.highlights").setup()')
  expect.equality(child.lua(READ_LINKS), EXPECTED)
end

T["the module has no group the spec lacks"] = function()
  local names = child.lua([[
    return vim.tbl_map(function(group)
      return group[1]
    end, require("oas-glance.internal.highlights").GROUPS)
  ]])
  table.sort(names)
  local expected = vim.tbl_keys(EXPECTED)
  table.sort(expected)
  expect.equality(names, expected)
end

T["requiring the module defines nothing"] = function()
  child.lua('require("oas-glance.internal.highlights")')
  expect.equality(child.lua('return vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = "OasGlanceTitle" }))'), true)
end

T["a user's prior definition survives"] = function()
  child.lua([[
    vim.api.nvim_set_hl(0, "OasGlanceTitle", { fg = "#123456", bold = true })
    vim.api.nvim_set_hl(0, "OasGlancePath", { link = "String" })
    require("oas-glance.internal.highlights").setup()
  ]])
  local title = child.lua('return vim.api.nvim_get_hl(0, { name = "OasGlanceTitle" })')
  expect.equality({ title.fg, title.bold, title.link }, { 0x123456, true, nil })
  expect.equality(child.lua('return vim.api.nvim_get_hl(0, { name = "OasGlancePath" }).link'), "String")
  expect.equality(child.lua('return vim.api.nvim_get_hl(0, { name = "OasGlanceType" }).link'), "Type")
end

T["links return after a colorscheme"] = function()
  child.lua('require("oas-glance.internal.highlights").setup()')
  child.cmd("colorscheme quiet")
  expect.equality(child.lua(READ_LINKS), EXPECTED)
end

-- `:hi clear` restores a default link by itself, so the links returning cannot prove the autocommand. A spy does.
local COUNT_DEFINES_ON_COLORSCHEME = [[
  local highlights = require("oas-glance.internal.highlights")
  local calls = 0
  highlights.define = function()
    calls = calls + 1
  end
  vim.cmd("colorscheme quiet")
  return calls
]]

T["a colorscheme defines the groups again after setup"] = function()
  child.lua('require("oas-glance.internal.highlights").setup()')
  expect.equality(child.lua(COUNT_DEFINES_ON_COLORSCHEME), 1)
end

T["a colorscheme defines nothing without setup"] = function()
  child.lua('require("oas-glance.internal.highlights").define()')
  expect.equality(child.lua(COUNT_DEFINES_ON_COLORSCHEME), 0)
end

T["setup twice leaves one autocommand"] = function()
  child.lua([[
    local highlights = require("oas-glance.internal.highlights")
    highlights.setup()
    highlights.setup()
  ]])
  local count = child.lua('return #vim.api.nvim_get_autocmds({ group = "oas-glance-highlights" })')
  expect.equality(count, 1)
end

T["definitions carry links only"] = function()
  local colours = child.lua([[
    require("oas-glance.internal.highlights").setup()
    local found = {}
    for _, group in ipairs(require("oas-glance.internal.highlights").GROUPS) do
      local definition = vim.api.nvim_get_hl(0, { name = group[1] })
      for key in pairs(definition) do
        if key ~= "link" and key ~= "default" then
          found[#found + 1] = group[1] .. "." .. key
        end
      end
    end
    table.sort(found)
    return found
  ]])
  expect.equality(colours, {})
end

T["no Lua file holds a hex colour"] = function()
  local files = vim.fn.glob("lua/**/*.lua", false, true)
  table.sort(files)
  expect.equality(#files > 0, true)
  local found = {}
  for _, file in ipairs(files) do
    for number, line in ipairs(vim.fn.readfile(file)) do
      if line:find("#%x%x%x%x%x%x") then
        found[#found + 1] = file .. ":" .. number
      end
    end
  end
  expect.equality(found, {})
end

return T
