local vimruntime = vim.env.VIMRUNTIME

vim.o.runtimepath = table.concat({
  "/work",
  "/opt/mini/mini.test",
  "/opt/mini/mini.doc",
  "/opt/tree-sitter-yaml",
  vimruntime,
}, ",")
vim.o.packpath = vimruntime

vim.cmd("language messages C")

require("mini.test").setup()
require("mini.doc").setup()
