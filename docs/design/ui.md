# UI

The viewer's windows, its limits on output, and how users configure keys and colours.

## Two-pane viewer layout

The viewer uses two panes in splits. The left pane lists endpoints grouped by tag, plus schemas. The right pane shows the selected operation or schema in detail.

## Panes open in a new tabpage

The two panes open in a new tabpage.

This leaves the user's window layout untouched. The cost is a tabline row, and jump to source switches tabpage. The alternative was splits in the current tabpage.

## Detail view row limit

A detail view stops at `max_detail_rows`, 10000 by default, and ends with a visible row saying so. That row does not count as a problem.

Repeated YAML aliases or merge keys let a small untrusted document expand to an exponential number of rows and block Neovim. Starting aliased schemas closed would miss merge keys, and a limit covers both. The option stays public so that a very large valid schema can still be shown in full.

## Keymaps configured by action

`keymaps.list` and `keymaps.detail` are keyed by action name. A value is a string, a list of strings, or `false`.

This is public API. Naming actions lets users remap a key without knowing the defaults, and a future default can change without breaking their config.

## Highlights link standard groups

Every colour comes from an `OasGlance*` group linked to a standard group with `default = true`, and the groups are re-applied on `ColorScheme`. The plugin has no hard-coded colours. The one exception is `OasGlanceDescription`, which is defined empty with `default = true`.

Colourschemes and user overrides then work without any plugin configuration. A colourscheme change clears the links, so they must be applied again. Descriptions are plain text, and every candidate link, `Normal` included, can carry a background that hides `cursorline`.
