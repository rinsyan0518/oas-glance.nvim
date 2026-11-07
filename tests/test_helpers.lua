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

local function expect_groups(extmark_opts, groups)
  child.lua(
    [[
    local buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "text" })
    vim.api.nvim_buf_set_extmark(buffer, vim.api.nvim_create_namespace("probe"), 0, 0, ...)
  ]],
    { extmark_opts }
  )
  expect.equality(helpers.highlight_groups(child), groups)
end

T["boot"] = MiniTest.new_set()

T["boot"]["pins TabLineSel to the 0.12 default"] = function()
  expect.equality(child.api.nvim_get_hl(0, { name = "TabLineSel", link = false }), { bold = true })
end

T["highlight_groups"] = MiniTest.new_set()

T["highlight_lines"] = MiniTest.new_set()

T["highlight_lines"]["records the colour of an earlier hl_group array item"] = function()
  child.lua([[
    vim.api.nvim_set_hl(0, "ProbeA", { fg = "#111111" })
    vim.api.nvim_set_hl(0, "ProbeB", { bold = true })
    local buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "text" })
    vim.api.nvim_buf_set_extmark(buffer, vim.api.nvim_create_namespace("probe"), 0, 0, {
      end_col = 4,
      hl_group = { "ProbeA", "ProbeB" },
    })
  ]])
  local lines = helpers.highlight_lines(child)
  expect.equality(vim.tbl_contains(lines, "0:0-3 bold=true foreground=#111111"), true)
end

T["highlight_groups"]["every *_hl_group field"] = function()
  expect_groups({
    sign_text = "S",
    sign_hl_group = "ProbeSign",
    number_hl_group = "ProbeNumber",
    line_hl_group = "ProbeLine",
    cursorline_hl_group = "ProbeCursor",
  }, { "ProbeCursor", "ProbeLine", "ProbeNumber", "ProbeSign" })
end

T["highlight_groups"]["virt_text, including a group list"] = function()
  expect_groups({
    virt_text = { { "a", "ProbeA" }, { "b", { "ProbeB", "ProbeC" } } },
  }, { "ProbeA", "ProbeB", "ProbeC" })
end

T["highlight_groups"]["virt_lines"] = function()
  expect_groups({
    virt_lines = { { { "a", "ProbeA" } }, { { "b", "ProbeB" } } },
  }, { "ProbeA", "ProbeB" })
end

return T
