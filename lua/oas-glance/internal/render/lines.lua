local M = {}

local REPLACEMENT = "\239\191\189"
local CONTROL = "[%z\1-\9\11-\31\127]"
local C1_CONTROL = "\194[\128-\159]"

M.DEFAULT_ICONS = {
  expanded = "▾",
  collapsed = "▸",
  ref = "→",
  cycle = "↻",
  broken = "✗",
  required = "*",
  deprecated = "~",
  problem = "!",
}

---@class oas_glance.Span
---@field row integer 0-based.
---@field col integer 0-based byte column.
---@field end_col integer
---@field group string
---@field priority integer? Set on a span that overlays others.

---@class oas_glance.RowAction
---@field select table? What the detail pane shows for a list row.
---@field toggle string? The key in the view's `open` state.
---@field expanded boolean? Whether a row with `toggle` is drawn open.
---@field ref table? The row's `$ref`.
---@field cycle boolean?
---@field limit boolean? The row limit row.
---@field pos oas_glance.Pos?
---@field broken { target: string, reason: string, pos: oas_glance.Pos? }?

---@class oas_glance.RenderResult
---@field lines string[]
---@field spans oas_glance.Span[]
---@field rows table<integer, oas_glance.RowAction> Keyed by 0-based row.

---@param overrides table?
---@return table
function M.icons(overrides)
  return vim.tbl_extend("force", M.DEFAULT_ICONS, overrides or {})
end

--- Keeps newlines, which split lines, and replaces every other control character.
---@param text string
---@return string
function M.clean(text)
  local cleaned = text:gsub("\r\n", "\n"):gsub(CONTROL, REPLACEMENT):gsub(C1_CONTROL, REPLACEMENT)
  return cleaned
end

--- Display width, for padding.
---@param text string
---@return integer
function M.width(text)
  local flat = M.clean(text):gsub("\n", " ")
  return vim.api.nvim_strwidth(flat)
end

---@class oas_glance.LineBuilder
---@field lines string[]
---@field spans oas_glance.Span[]
---@field rows table<integer, oas_glance.RowAction>
---@field stopped boolean Set once a row did not fit, so callers stop descending.
---@field package _limit integer?
---@field package _icons table
local Builder = {}
Builder.__index = Builder

---@param opts { limit?: integer, icons: table }
---@return oas_glance.LineBuilder
function M.builder(opts)
  return setmetatable({
    lines = {},
    spans = {},
    rows = {},
    stopped = false,
    _limit = opts.limit,
    _icons = opts.icons,
  }, Builder)
end

---@param line string
---@param spans { col: integer, end_col: integer, group: string }[]
---@param action oas_glance.RowAction?
function Builder:_flush(line, spans, action)
  if self._limit and #self.lines >= self._limit then
    self.stopped = true
    return
  end
  local row = #self.lines
  self.lines[row + 1] = line
  self.rows[row] = action
  for _, span in ipairs(spans) do
    self.spans[#self.spans + 1] = { row = row, col = span.col, end_col = span.end_col, group = span.group }
  end
end

--- Adds a row from `{ text, group }` segments. A newline in a segment starts a further row.
---@param segments { [1]: string?, [2]: string? }[]
---@param action oas_glance.RowAction?
---@param continuation string? What a further row starts with.
---@return integer? row The row added, or nil when the limit stopped it.
function Builder:add(segments, action, continuation)
  if self.stopped then
    return nil
  end
  local first_row = #self.lines
  local current_action = action
  local line, spans = "", {}
  for _, segment in ipairs(segments) do
    local text, group = segment[1], segment[2]
    if text and text ~= "" then
      for index, piece in ipairs(vim.split(M.clean(text), "\n", { plain = true })) do
        if index > 1 then
          self:_flush(line, spans, current_action)
          if self.stopped then
            return nil
          end
          current_action = action and action.pos and { pos = action.pos } or nil
          line, spans = continuation or "", {}
        end
        if piece ~= "" then
          if group then
            spans[#spans + 1] = { col = #line, end_col = #line + #piece, group = group }
          end
          line = line .. piece
        end
      end
    end
  end
  self:_flush(line, spans, current_action)
  if self.stopped then
    return nil
  end
  return first_row
end

function Builder:blank()
  self:add({})
end

--- Adds a span over text already added.
---@param row integer
---@param col integer
---@param end_col integer
---@param group string
---@param priority integer?
function Builder:overlay(row, col, end_col, group, priority)
  self.spans[#self.spans + 1] = { row = row, col = col, end_col = end_col, group = group, priority = priority }
end

---@return oas_glance.RenderResult
function Builder:result()
  if self.stopped then
    local row = #self.lines
    local text = string.format("%s stopped at %d rows (max_detail_rows)", self._icons.problem, self._limit)
    self.lines[row + 1] = text
    self.rows[row] = { limit = true }
    self:overlay(row, 0, #text, "OasGlanceProblem")
  end
  return { lines = self.lines, spans = self.spans, rows = self.rows }
end

return M
