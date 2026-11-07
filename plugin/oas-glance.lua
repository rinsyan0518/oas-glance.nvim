if vim.g.loaded_oas_glance == 1 then
  return
end
vim.g.loaded_oas_glance = 1

vim.api.nvim_create_user_command("OasGlance", function(args)
  require("oas-glance").open(args.args ~= "" and args.args or nil)
end, { nargs = "?", complete = "file", desc = "View an OpenAPI document" })
