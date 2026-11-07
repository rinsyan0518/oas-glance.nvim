local M = {}

local SCREENSHOT_DIR = "tests/screenshots/"
local SNAPSHOT_DIR = "tests/snapshots/"
local COLOUR_KEYS = { fg = true, bg = true, sp = true, foreground = true, background = true, special = true }

local updating = vim.env.OAS_GLANCE_UPDATE_REFERENCES == "1"

local function require_reference(path)
  if not updating and vim.fn.filereadable(path) == 0 then
    error("Missing reference " .. path .. ", run: make update-screenshots", 0)
  end
end

local function sorted_keys(tbl)
  local keys = vim.tbl_keys(tbl)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function format_value(key, value)
  if type(value) == "number" and COLOUR_KEYS[key] then
    return string.format("#%06x", value)
  end
  return vim.inspect(value, { newline = " ", indent = "" })
end

local function format_map(tbl)
  local parts = {}
  for _, key in ipairs(sorted_keys(tbl)) do
    parts[#parts + 1] = tostring(key) .. "=" .. format_value(key, tbl[key])
  end
  return table.concat(parts, " ")
end

local function read_highlights(child)
  return child.lua([[
    local namespaces = {}
    for name, id in pairs(vim.api.nvim_get_namespaces()) do
      namespaces[id] = name
    end

    local marks, groups = {}, {}

    local function add_group(value)
      if type(value) == "number" then
        value = vim.fn.synIDattr(value, "name")
      end
      if type(value) == "table" then
        for _, item in ipairs(value) do
          add_group(item)
        end
      elseif type(value) == "string" and value ~= "" then
        groups[value] = vim.api.nvim_get_hl(0, { name = value, link = false })
      end
    end

    local function add_chunks(chunks)
      for _, chunk in ipairs(chunks or {}) do
        add_group(chunk[2])
      end
    end

    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
      local details = mark[4]
      details.namespace = namespaces[details.ns_id] or ""
      details.ns_id = nil
      marks[#marks + 1] = { row = mark[2], col = mark[3], details = details }
      for key, value in pairs(details) do
        if key == "hl_group" or key:match("_hl_group$") then
          add_group(value)
        end
      end
      add_chunks(details.virt_text)
      for _, line in ipairs(details.virt_lines or {}) do
        add_chunks(line)
      end
    end

    -- Extmark details keep only the last group of an hl_group array, so resolved cell colours are recorded too.
    -- The first inspection resets the attribute tables, so results are only valid after a further redraw.
    vim.api.nvim__inspect_cell(1, 0, 0)
    vim.cmd("redraw!")
    local cells = {}
    for row = 0, vim.o.lines - 1 do
      for col = 0, vim.o.columns - 1 do
        local attrs = vim.api.nvim__inspect_cell(1, row, col)[2]
        if not vim.tbl_isempty(attrs) then
          cells[#cells + 1] = { row = row, col = col, attrs = attrs }
        end
      end
    end
    return { marks = marks, groups = groups, cells = cells }
  ]])
end

local function render_cells(cells)
  local lines = {}
  local run
  local function flush()
    if run then
      lines[#lines + 1] = string.format("%d:%d-%d %s", run.row, run.first, run.last, run.attrs)
    end
  end
  for _, cell in ipairs(cells) do
    local attrs = format_map(cell.attrs)
    if run and run.row == cell.row and run.last + 1 == cell.col and run.attrs == attrs then
      run.last = cell.col
    else
      flush()
      run = { row = cell.row, first = cell.col, last = cell.col, attrs = attrs }
    end
  end
  flush()
  return lines
end

-- The extmark ID is left out and the namespace is shown by name, since both IDs depend on creation order.
local function render_highlights(data)
  local mark_lines = {}
  for _, mark in ipairs(data.marks) do
    mark_lines[#mark_lines + 1] = string.format("%d:%d %s", mark.row, mark.col, format_map(mark.details))
  end
  table.sort(mark_lines)

  local lines = { "# extmarks" }
  vim.list_extend(lines, mark_lines)
  lines[#lines + 1] = "# highlights"
  for _, group in ipairs(sorted_keys(data.groups)) do
    lines[#lines + 1] = group .. " " .. format_map(data.groups[group])
  end
  lines[#lines + 1] = "# screen cells"
  vim.list_extend(lines, render_cells(data.cells))
  return lines
end

--- Joins lines with `\n`, with a final one unless `final_newline` is false.
local function join_lines(lines, final_newline)
  return table.concat(lines, "\n") .. (final_newline == false and "" or "\n")
end

--- A valid OpenAPI 3.1 document in block style, exactly `n` lines long.
---@param n integer
---@param opts? { final_newline?: boolean, leading_comment?: boolean, syntax_error?: boolean }
---@return string
function M.block_yaml(n, opts)
  opts = opts or {}
  local lines = {}
  if opts.leading_comment then
    lines[#lines + 1] = "# Generated for the line limit."
    lines[#lines + 1] = "# It has a block root."
  end
  vim.list_extend(lines, {
    "openapi: 3.1.0",
    "info:",
    "  title: Generated",
    "  version: 1.0.0",
    "paths: {}",
    "components:",
    "  schemas:",
    "    Pad:",
    "      type: object",
    "      properties:",
  })
  local pad = n - #lines
  assert(pad >= 1, "too few lines")
  for i = 1, pad do
    lines[#lines + 1] = ("        p%d: { type: string }"):format(i)
  end
  -- An unclosed flow sequence, which the parser recovers from with the root intact.
  if opts.syntax_error then
    lines[#lines - math.floor(pad / 2)] = "        bad: [broken"
  end
  return join_lines(lines, opts.final_newline)
end

--- Pretty JSON of the same shape as `block_yaml`, exactly `n` lines long.
--- `syntax_error` adds a stray `}` line after the root, because an error inside the root loses it.
---@param n integer
---@param opts? { syntax_error?: boolean }
---@return string
function M.pretty_json(n, opts)
  opts = opts or {}
  local head = {
    "{",
    '  "openapi": "3.1.0",',
    '  "info": { "title": "Generated", "version": "1.0.0" },',
    '  "paths": {},',
    '  "components": {',
    '    "schemas": {',
    '      "Pad": {',
    '        "type": "object",',
    '        "properties": {',
  }
  local tail = { "        }", "      }", "    }", "  }", "}" }
  if opts.syntax_error then
    tail[#tail + 1] = "}"
  end
  local pad = n - #head - #tail
  assert(pad >= 1, "too few lines")
  local lines = head
  for i = 1, pad do
    local comma = i < pad and "," or ""
    lines[#lines + 1] = ('          "p%d": { "type": "string" }%s'):format(i, comma)
  end
  vim.list_extend(lines, tail)
  return join_lines(lines)
end

--- Writes text to a new temporary file and returns its path.
---@param text string
---@param name? string The basename, inside a new temporary directory.
---@return string
function M.write_temp(text, name)
  local path = vim.fn.tempname()
  if name then
    vim.fn.mkdir(path, "p")
    path = path .. "/" .. name
  end
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
  return path
end

function M.new_child()
  local child = MiniTest.new_child_neovim()
  child.boot = function()
    child.restart({ "-u", "scripts/minimal_init.lua" })
    -- Pin the nightly default so references match across Neovim versions.
    child.api.nvim_set_hl(0, "TabLineSel", { bold = true, fg = "fg", bg = "bg", cterm = { nocombine = true } })
  end
  return child
end

function M.highlight_groups(child)
  return sorted_keys(read_highlights(child).groups)
end

function M.highlight_lines(child)
  return render_highlights(read_highlights(child))
end

function M.expect_screen(child, name)
  local path = SCREENSHOT_DIR .. name
  require_reference(path)
  MiniTest.expect.reference_screenshot(child.get_screenshot(), path, { force = updating })
end

function M.expect_highlights(child, name)
  local path = SNAPSHOT_DIR .. name .. ".txt"
  require_reference(path)
  local observed = render_highlights(read_highlights(child))

  if updating then
    vim.fn.mkdir(SNAPSHOT_DIR, "p")
    vim.fn.writefile(observed, path)
    return
  end

  local reference = vim.fn.readfile(path)
  if not vim.deep_equal(reference, observed) then
    error(
      string.format(
        "Text snapshot differs from %s\nReference:\n%s\n\nObserved:\n%s",
        path,
        table.concat(reference, "\n"),
        table.concat(observed, "\n")
      ),
      0
    )
  end
end

return M
