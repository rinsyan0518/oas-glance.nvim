local helpers = dofile("tests/helpers.lua")

local child = MiniTest.new_child_neovim()
local expect = MiniTest.expect

local file

---@return integer?
local function list_buf()
  local buf = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "oasglance-list" then
        return buf
      end
    end
    return -1
  ]])
  return buf ~= -1 and buf or nil
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      local text = table.concat(vim.fn.readfile("tests/fixtures/petstore-31.yaml", "b"), "\n")
      file = helpers.write_temp(text, "pet store %#.yaml")
      vim.env.OAS_GLANCE_TRY_FILE = file
      child.restart({ "-u", "scripts/try_init.lua" })
      vim.env.OAS_GLANCE_TRY_FILE = nil
      -- VimEnter may fire after the RPC connection is up.
      vim.wait(5000, function()
        return list_buf() ~= nil
      end, 50)
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T["sets only image paths and the help copy"] = function()
  local vimruntime = child.lua_get("vim.env.VIMRUNTIME")
  -- Neovim's own start-up adds netrw and matchit from $VIMRUNTIME.
  local expected = table.concat({
    "/work",
    "/opt/tree-sitter-yaml",
    "/tmp/oas-glance-try",
    vimruntime,
    vimruntime .. "/pack/dist/opt/netrw",
    vimruntime .. "/pack/dist/opt/matchit",
    "/opt/nvim/lib/nvim",
  }, ",")
  expect.equality(child.lua_get("vim.o.runtimepath"), expected)
  expect.equality(child.lua_get("vim.o.packpath"), vimruntime)
end

T["reads no user config and loads the plugin"] = function()
  expect.equality(child.lua_get("vim.env.MYVIMRC or ''"), "")
  expect.equality(child.lua_get("vim.g.loaded_oas_glance"), 1)
end

T["opens the file from the environment"] = function()
  local buf = list_buf()
  expect.no_equality(buf, nil)
  ---@cast buf integer
  local text = table.concat(child.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  expect.equality(text:find("Petstore", 1, true) ~= nil, true)
  expect.equality(child.lua_get("vim.b[...].oas_glance_identity", { buf }), vim.uv.fs_realpath(file))
end

T["opens the help"] = function()
  child.cmd("help oas-glance-limits")
  expect.equality(child.bo.buftype, "help")
  expect.equality(child.api.nvim_buf_get_name(0), "/tmp/oas-glance-try/doc/oas-glance.txt")
end

return T
