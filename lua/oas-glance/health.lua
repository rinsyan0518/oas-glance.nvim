local M = {}

function M.check()
  vim.health.start("oas-glance")

  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim 0.12 or later")
  else
    vim.health.error("Neovim 0.12 or later is required")
  end

  local ok, kind, reason = require("oas-glance.internal.tree").parser_status()
  local paths = vim.api.nvim_get_runtime_file("parser/yaml.*", true)
  if ok then
    vim.health.ok('tree-sitter "yaml" parser: ' .. paths[1])
  elseif kind == "missing" then
    vim.health.error(
      "the tree-sitter \"yaml\" parser was not found on 'runtimepath' (parser/yaml.*)",
      { "Install it with any installer that puts parser/yaml.* on 'runtimepath'. See :help oas-glance-parser" }
    )
  else
    -- The file can go between the check and this lookup, so the path is shown only when there is one.
    vim.health.error(
      'cannot load the tree-sitter "yaml" parser: ' .. tostring(reason),
      paths[1] and { "Found: " .. paths[1] } or nil
    )
  end
end

return M
