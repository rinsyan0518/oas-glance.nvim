local M = {}

local AUGROUP = "oas-glance-highlights"

---@type { [1]: string, [2]: string? }[]
M.GROUPS = {
  { "OasGlanceMethodGet", "DiagnosticHint" },
  { "OasGlanceMethodPost", "DiagnosticOk" },
  { "OasGlanceMethodPut", "DiagnosticWarn" },
  { "OasGlanceMethodPatch", "DiagnosticInfo" },
  { "OasGlanceMethodDelete", "DiagnosticError" },
  { "OasGlanceMethodHead", "Comment" },
  { "OasGlanceMethodOptions", "Comment" },
  { "OasGlanceMethodTrace", "Comment" },
  { "OasGlancePath", "Identifier" },
  { "OasGlancePathParam", "Special" },
  { "OasGlanceTitle", "Title" },
  { "OasGlanceMuted", "Comment" },
  { "OasGlanceSection", "Title" },
  { "OasGlanceGroup", "Directory" },
  { "OasGlanceSchemaName", "Type" },
  { "OasGlanceFold", "Special" },
  { "OasGlanceProperty", "Identifier" },
  { "OasGlanceRequired", "DiagnosticError" },
  { "OasGlanceType", "Type" },
  { "OasGlanceFormat", "Comment" },
  { "OasGlanceNull", "Comment" },
  { "OasGlanceEnum", "String" },
  { "OasGlanceDefault", "Constant" },
  { "OasGlanceConstraint", "Comment" },
  -- No link, so the text takes the window's colours and `cursorline` shows through.
  { "OasGlanceDescription" },
  { "OasGlanceLocation", "Comment" },
  { "OasGlanceComposition", "Keyword" },
  { "OasGlanceDeprecated", "DiagnosticDeprecated" },
  { "OasGlanceRef", "Underlined" },
  { "OasGlanceCycle", "DiagnosticWarn" },
  { "OasGlanceBroken", "DiagnosticError" },
  { "OasGlanceProblem", "DiagnosticWarn" },
  { "OasGlanceStatusOther", "Comment" },
  { "OasGlanceStatus2xx", "DiagnosticOk" },
  { "OasGlanceStatus4xx", "DiagnosticWarn" },
  { "OasGlanceStatus5xx", "DiagnosticError" },
  { "OasGlanceFilter", "Question" },
  { "OasGlanceMatch", "Search" },
  { "OasGlanceHint", "Comment" },
}

--- Defines every group as a default link, or empty, so a user's own definition wins.
function M.define()
  for _, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group[1], { link = group[2], default = true })
  end
end

--- Defines the groups, and again after each `:colorscheme`, which clears them.
function M.setup()
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
    callback = function()
      M.define()
    end,
  })
end

return M
