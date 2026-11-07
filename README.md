# oas-glance

A two-pane Neovim viewer for OpenAPI 3.0 and 3.1 documents in YAML or JSON. Operations by tag, webhooks and schemas are listed on the left, the row under the cursor is shown in detail on the right, and `$ref`s open in place.

## Requirements

- Neovim 0.12 or later.
- The tree-sitter `yaml` parser, from any installer that puts `parser/yaml.*` on `runtimepath`, for example nvim-treesitter's `:TSInstall yaml`.

`:checkhealth oas-glance` checks both.

## Installation

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/rinsyan0518/oas-glance.nvim" })
```

With lazy.nvim:

```lua
{ "rinsyan0518/oas-glance.nvim", cmd = "OasGlance" } -- lazy.nvim
```

## Usage

`:OasGlance` views the current buffer, and `:OasGlance {file}` views a file. See `:help oas-glance` for details.

`gc` opens a cURL command for the operation shown in an editable split below the detail pane. oas-glance never runs it. While the split is open it follows the operation shown, and `R` rebuilds it. A new command replaces the text, edits included, and one `u` in the split brings them back. Other views keep the last command, and closing the split stops this until the next `gc`.

### List pane

| Action | Keys |
| --- | --- |
| `select` | `<CR>` |
| `toggle` | `za` |
| `filter` | `f` |
| `clear_filter` | `F` |
| `source` | `gs` |
| `curl` | `gc` |
| `reload` | `R` |
| `help` | `?` |
| `close` | `q` |

### Detail pane

| Action | Keys |
| --- | --- |
| `toggle` | `<CR>`, `za` |
| `definition` | `gd` |
| `back` | `<BS>` |
| `source` | `gs` |
| `curl` | `gc` |
| `reload` | `R` |
| `help` | `?` |
| `close` | `q` |

## Configuration

Calling `setup()` is optional. For example:

```lua
require("oas-glance").setup({
  list_width = 40,
  keymaps = { list = { filter = "<leader>f" } },
  refs = { root = vim.fn.expand("~/api") },
})
```

See `:help oas-glance.setup()` for every option and `:help oas-glance-highlights` for the highlight groups.

## Limits

- YAML over 32768 lines is refused. Convert the document to JSON to view it.
- Some syntax errors, most JSON ones included, are reported as "not an OpenAPI document" with no line number.
- Remote `$ref`s are not loaded.

See `:help oas-glance-limits`.

## Try it

`make try` opens the viewer in the development image. It needs only Docker on an arm64 or amd64 host, plus `make`, `git` and a POSIX shell, as in [Development](#development). Quit with `:qa`.

```sh
make try                                       # tests/fixtures/petstore-31.yaml
make try FILE=tests/fixtures/multi/root.yaml
mkdir -p tmp/try && cp "$HOME/api/openapi.yaml" tmp/try/ && make try FILE=tmp/try/openapi.yaml
```

Only files inside this repository open. To try your own spec, copy it and any files it refers to into the git-ignored `tmp/`.

## Development

The host needs only Docker, `make`, `git` and a POSIX shell. The development image is Linux arm64 and amd64.

| Command | Purpose |
| --- | --- |
| `make image` | Build the pinned image |
| `make clean-image` | Remove this project's images |
| `make check` | Run every check below without rewriting source files |
| `make test` | Run all tests |
| `make test-file FILE=tests/x.lua` | Run one test file |
| `make try [FILE=path]` | Open the viewer, see [Try it](#try-it) |
| `make update-screenshots` | Regenerate screen references and text snapshots |
| `make lint` | Run selene |
| `make format` | Rewrite Lua with StyLua |
| `make format-check` | Check formatting without rewriting |
| `make typecheck` | Run LuaLS `--check` |
| `make doc` | Generate `doc/oas-glance.txt` |
| `make doc-check` | Fail if `doc/oas-glance.txt` is out of date |

The design and its reasons are described in `docs/design/`. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request.

## License

MIT. See [LICENSE](LICENSE).
