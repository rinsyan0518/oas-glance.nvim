local vimruntime = vim.env.VIMRUNTIME
local help_dir = "/tmp/oas-glance-try/doc"

vim.o.runtimepath = table.concat({
  "/work",
  "/opt/tree-sitter-yaml",
  "/tmp/oas-glance-try",
  vimruntime,
  -- The bundled parsers, as `:help` needs vimdoc.
  "/opt/nvim/lib/nvim",
}, ",")
vim.o.packpath = vimruntime

-- /work is read-only, so the help tags are built in a copy.
vim.fn.mkdir(help_dir, "p")
vim.fn.writefile(vim.fn.readfile("/work/doc/oas-glance.txt", "b"), help_dir .. "/oas-glance.txt", "b")
vim.cmd.helptags(help_dir)

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("oas-glance").open(vim.env.OAS_GLANCE_TRY_FILE)
  end,
})
