--- *oas-glance* Display OpenAPI schemas in Neovim
---
--- A two-pane viewer for OpenAPI 3.0 and 3.1 documents in YAML or JSON.
--- The list pane on the left shows operations by tag, webhooks and schemas.
--- The detail pane on the right shows the row under the cursor.
---
--- Commands ~
---
--- `:OasGlance` views the current buffer, including unsaved text.
--- `:OasGlance {file}` views a file from disk.
---
--- The panes open in a new tabpage. Running the command on a document that is
--- already open focuses its tabpage.
---
--- In the detail pane every `$ref` starts closed. `<CR>` or `za` opens it in
--- place, and a ref back to a schema already above the row shows
--- `↻ Name  cycle`. `gd` shows the ref's target as its own view, and `<BS>`
--- returns. `gs` opens the source of the row under the cursor in the window
--- `:OasGlance` was started from, or in a new tabpage if that window is gone.
--- `gc` in either pane opens a cURL command for the operation shown, in an
--- editable buffer below the detail pane. oas-glance never sends it. Unknown
--- values are shell variables such as `"${PET_ID}"`, and a request body comes
--- from the first example or is generated from the schema, which may open
--- `$ref`s.
--- While the split is open it follows the operation shown, and `R` rebuilds
--- it. A new command replaces the text, edits included, and one `u` in the
--- split brings them back. Other views keep the last command. Closing the
--- split stops this until the next `gc`.
--- The list header counts the problems found so far, because refs are only
--- checked when opened.
---
--- External refs are relative file refs such as `./common.yaml#/Pet`, inside
--- `refs.root`. A closed ref looks the same whether or not its target exists,
--- and opening a broken one shows `✗ {target}  {reason}`. Remote refs are not
--- loaded and show `remote not loaded` from the start. `R` reads the file or the
--- buffer again. It keeps the fold and expansion state where the same rows still
--- exist, and clears the `<BS>` history.
---
--- `f` in the list pane asks for a filter, and `F` clears it, as does an empty
--- answer. Terms are split on whitespace and a row must match all of them.
--- `path:x`, `tag:x` and `schema:x` match one field, and a bare `x` matches any
--- of the three. Matching ignores case and has no patterns. Schema rows have
--- only a name, so `path:` and `tag:` hide them. While a filter is active the
--- groups are open, and their fold state returns when it is cleared.
---
--- Requirements ~
---
--- Neovim 0.12 or later, and the tree-sitter "yaml" parser. See |oas-glance-parser|.

---@tag oas-glance-parser
---@text Parser ~
---
--- oas-glance reads YAML and JSON with the tree-sitter "yaml" parser. Any
--- installer that puts `parser/yaml.*` on 'runtimepath' works, for example
--- nvim-treesitter's `:TSInstall yaml`. Without it `:OasGlance` stops with:
--- >
---   oas-glance: the tree-sitter "yaml" parser was not found on 'runtimepath'
--- <
--- Support starts at Neovim 0.12. `:checkhealth oas-glance` reports the Neovim
--- version and the parser's path, or why the parser cannot be used.

---@tag oas-glance-limits
---@text Limits ~
---
--- The tree-sitter "yaml" parser fails on block-style YAML over 32768 lines.
--- `:OasGlance` refuses such a document, and an external ref to one shows
--- `too many lines`:
--- >
---   oas-glance: {file} has {n} lines; the tree-sitter "yaml" parser fails on
---   YAML over 32768 lines. Convert it to JSON to view it.
--- <
--- JSON has no such limit, so converting the document to JSON is the
--- workaround.
---
--- Block-style YAML lines over 32767 columns may also be misparsed. This is
--- not detected.
---
--- Some syntax errors, including most in JSON such as a missing comma, are
--- reported as "not an OpenAPI document" with no line number. Check the file's
--- syntax, for example with a JSON or YAML linter.
---
--- External refs stop at `refs.max_files` files and `refs.max_file_bytes` bytes
--- per file. Ref chains and inline nesting stop at `refs.max_depth`, and each
--- detail view renders at most `max_detail_rows` rows. See |oas-glance.setup()|.

---@tag oas-glance-highlights
---@text Highlights ~
---
--- Each group is defined with `default = true`, so a definition of your own
--- wins. They are defined again after `:colorscheme`, which clears them.
---
--- Group                  Default link
---   OasGlanceMethodGet       DiagnosticHint
---   OasGlanceMethodPost      DiagnosticOk
---   OasGlanceMethodPut       DiagnosticWarn
---   OasGlanceMethodPatch     DiagnosticInfo
---   OasGlanceMethodDelete    DiagnosticError
---   OasGlanceMethodHead      Comment
---   OasGlanceMethodOptions   Comment
---   OasGlanceMethodTrace     Comment
---   OasGlancePath            Identifier
---   OasGlancePathParam       Special
---   OasGlanceTitle           Title
---   OasGlanceMuted           Comment
---   OasGlanceSection         Title
---   OasGlanceGroup           Directory
---   OasGlanceSchemaName      Type
---   OasGlanceFold            Special
---   OasGlanceProperty        Identifier
---   OasGlanceRequired        DiagnosticError
---   OasGlanceType            Type
---   OasGlanceFormat          Comment
---   OasGlanceNull            Comment
---   OasGlanceEnum            String
---   OasGlanceDefault         Constant
---   OasGlanceConstraint      Comment
---   OasGlanceDescription     none: empty, so the window's colours show
---   OasGlanceLocation        Comment
---   OasGlanceComposition     Keyword
---   OasGlanceDeprecated      DiagnosticDeprecated
---   OasGlanceRef             Underlined
---   OasGlanceCycle           DiagnosticWarn
---   OasGlanceBroken          DiagnosticError
---   OasGlanceProblem         DiagnosticWarn
---   OasGlanceStatusOther     Comment
---   OasGlanceStatus2xx       DiagnosticOk
---   OasGlanceStatus4xx       DiagnosticWarn
---   OasGlanceStatus5xx       DiagnosticError
---   OasGlanceFilter          Question
---   OasGlanceMatch           Search
---   OasGlanceHint            Comment

local M = {}

local LIST_ACTIONS = { "select", "toggle", "filter", "clear_filter", "source", "curl", "reload", "help", "close" }
local DETAIL_ACTIONS = { "toggle", "definition", "back", "source", "curl", "reload", "help", "close" }

local DEFAULT_KEYMAPS = {
  list = {
    select = "<CR>",
    toggle = "za",
    filter = "f",
    clear_filter = "F",
    source = "gs",
    curl = "gc",
    reload = "R",
    help = "?",
    close = "q",
  },
  detail = {
    toggle = { "<CR>", "za" },
    definition = "gd",
    back = "<BS>",
    source = "gs",
    curl = "gc",
    reload = "R",
    help = "?",
    close = "q",
  },
}

local DEFAULTS = {
  list_width = 36,
  max_detail_rows = 10000,
  icons = {
    expanded = "▾",
    collapsed = "▸",
    ref = "→",
    cycle = "↻",
    broken = "✗",
    required = "*",
    deprecated = "~",
    problem = "!",
  },
  keymaps = { list = {}, detail = {} },
  refs = {
    root = nil,
    max_files = 512,
    max_file_bytes = 16 * 1024 * 1024,
    max_depth = 64,
  },
}

local config

-- Every action of each pane, with the user's values in place of the defaults.
local function merge_keymaps(user)
  local merged = {}
  local unknown = {}
  for _, pane in ipairs({ "list", "detail" }) do
    local known = pane == "list" and LIST_ACTIONS or DETAIL_ACTIONS
    local given = user[pane] or {}
    for name in pairs(given) do
      if not vim.tbl_contains(known, name) then
        unknown[#unknown + 1] = pane .. "." .. tostring(name)
      end
    end

    merged[pane] = {}
    for _, action in ipairs(known) do
      local value = given[action]
      if value == nil then
        value = DEFAULT_KEYMAPS[pane][action]
      end
      merged[pane][action] = value
    end
  end
  table.sort(unknown)
  for _, name in ipairs(unknown) do
    vim.notify(string.format("oas-glance: unknown keymap action %s, ignored", name), vim.log.levels.WARN)
  end
  return merged
end

local function merge(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts)
  merged.keymaps = merge_keymaps(opts.keymaps or {})
  return merged
end

---@tag oas-glance.setup()
---@signature oas-glance.setup(opts)
---@text Configures oas-glance. Calling it is optional. Defaults:
--- >lua
---   require("oas-glance").setup({
---     list_width = 36,
---     -- Rows each detail view renders at most, counted before wrapping.
---     -- A last row `! stopped at {limit} rows (max_detail_rows)` follows.
---     max_detail_rows = 10000,
---     icons = {
---       expanded = "▾", collapsed = "▸", ref = "→", cycle = "↻", broken = "✗",
---       required = "*", deprecated = "~", problem = "!",
---     },
---     -- Keyed by pane and action. A string or a list of strings replaces the
---     -- action's default keys, and false disables the action.
---     -- For example: list = { filter = "<leader>f", help = false }
---     keymaps = { list = {}, detail = {} },
---     refs = {
---       -- Local $refs stay inside the nearest ancestor with .git below $HOME,
---       -- otherwise inside the document's directory
---       root = nil,
---       max_files = 512,
---       max_file_bytes = 16 * 1024 * 1024,
---       max_depth = 64,
---     },
---   })
--- <
--- List pane actions and default keys:
---   `select` `<CR>`       Toggle a group, or focus the detail pane
---   `toggle` `za`         Toggle the group under the cursor
---   `filter` `f`          Filter prompt
---   `clear_filter` `F`    Clear the filter
---   `source` `gs`         Jump to source
---   `curl` `gc`           Open a cURL command for the operation
---   `reload` `R`          Reload from disk or the buffer
---   `help` `?`            Show key help in the detail pane
---   `close` `q`           Close the tabpage
---
--- Detail pane actions and default keys:
---   `toggle` `<CR>`, `za` Expand or collapse the row
---   `definition` `gd`     Jump to the definition of a `$ref`
---   `back` `<BS>`         Back to the previous detail view
---   `source` `gs`         Jump to the source of the row
---   `curl` `gc`           Open a cURL command for the operation
---   `reload`, `help`, `close` as in the list pane
---
--- An unknown action name gives a warning and is ignored.
---@param opts table? Options to merge over the defaults.
function M.setup(opts)
  config = merge(opts)
end

---@tag oas-glance.open()
---@signature oas-glance.open(file)
---@text Opens the viewer, as `:OasGlance` does. With no {file} it views the
--- current buffer. A document that cannot be viewed gives an error message
--- and opens nothing.
---@param file string? A path to read from disk.
function M.open(file)
  if not config then
    config = merge()
  end
  require("oas-glance.internal.ui").open(config, file)
end

return M
