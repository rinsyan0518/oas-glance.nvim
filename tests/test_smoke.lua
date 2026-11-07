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

local function expect_only_image_paths(option)
  local vimruntime = child.lua_get("vim.env.VIMRUNTIME")
  for _, path in ipairs(vim.split(child.lua_get("vim.o." .. option), ",")) do
    local allowed = path == "/work" or path == vimruntime or vim.startswith(path, "/opt/")
    expect.equality(
      { option = option, path = path, allowed = allowed },
      { option = option, path = path, allowed = true }
    )
  end
end

T["runtime"] = MiniTest.new_set()

T["runtime"]["searches no user directory"] = function()
  expect_only_image_paths("runtimepath")
  expect_only_image_paths("packpath")
end

T["runtime"]["loads the plugin file"] = function()
  expect.equality(child.lua_get("vim.g.loaded_oas_glance"), 1)
  local scripts = child.lua_get('vim.api.nvim_exec2("scriptnames", { output = true }).output')
  expect.equality(scripts:find("/work/plugin/oas-glance.lua", 1, true) ~= nil, true)
end

T["runtime"]["reads no user config"] = function()
  expect.equality(child.lua_get("vim.env.MYVIMRC or ''"), "")
  local scripts = child.lua_get('vim.api.nvim_exec2("scriptnames", { output = true }).output')
  expect.equality(scripts:find("/work/scripts/minimal_init.lua", 1, true) ~= nil, true)
end

T["runtime"]["runs on a supported arch with every tool"] = function()
  local machine = child.lua_get("vim.uv.os_uname().machine")
  expect.equality(
    { machine = machine, supported = machine == "aarch64" or machine == "x86_64" },
    { machine = machine, supported = true }
  )
  for _, tool in ipairs({ "nvim", "stylua", "lua-language-server", "selene" }) do
    expect.equality({ tool = tool, executable = child.fn.executable(tool) }, { tool = tool, executable = 1 })
  end
end

T["runtime"]["finds the yaml parser in one place"] = function()
  expect.equality(
    child.lua_get('vim.api.nvim_get_runtime_file("parser/yaml.*", true)'),
    { "/opt/tree-sitter-yaml/parser/yaml.so" }
  )
end

T["runtime"]["parses yaml with the parser"] = function()
  local has_error = child.lua([[
    vim.treesitter.language.add("yaml")
    local parser = vim.treesitter.get_string_parser("a: 1", "yaml")
    return parser:parse()[1]:root():has_error()
  ]])
  expect.equality(has_error, false)
end

T["runtime"]["ships the parser license and no compiler"] = function()
  expect.equality(child.lua_get('vim.fn.filereadable("/opt/tree-sitter-yaml/parser/LICENSE")'), 1)
  expect.equality(child.lua_get('vim.fn.executable("gcc")'), 0)
end

T["runtime"]["defines the command and loads no module"] = function()
  expect.equality(child.fn.exists(":OasGlance"), 2)
  expect.equality(child.fn.exists(":Oas" .. "View"), 0)
  expect.equality(child.lua_get("package.loaded['oas-glance'] == nil"), true)
  expect.equality(child.lua_get("package.loaded['oas-glance.internal.ui'] == nil"), true)
end

return T
