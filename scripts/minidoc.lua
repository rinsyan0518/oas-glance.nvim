local files = vim.tbl_filter(function(file)
  return not vim.startswith(file, "lua/oas-glance/internal/") and file ~= "lua/oas-glance/health.lua"
end, vim.fn.glob("lua/**/*.lua", false, true))
table.sort(files)

-- The default write_post hook also writes doc/tags, which is not a tracked output.
MiniDoc.generate(files, vim.env.OAS_GLANCE_DOC_OUTPUT, {
  hooks = {
    write_post = function() end,
  },
})
