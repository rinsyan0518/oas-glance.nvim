local M = {}

local PREFIXES = { path = true, tag = true, schema = true }

---@class oas_glance.FilterTerm
---@field kind "path"|"tag"|"schema"|"any"
---@field text string Case-folded.

---@class oas_glance.FilterRange
---@field field "path"|"tag"|"name"
---@field tag string? The tag this range is in, when `field` is "tag".
---@field col integer 0-based byte column in that text.
---@field end_col integer

---@param char string
---@return integer
local function char_length(char)
  local byte = char:byte()
  if byte < 0xC0 then
    return 1
  end
  if byte < 0xE0 then
    return 2
  end
  return byte < 0xF0 and 3 or 4
end

--- Folds case. The second result maps each folded byte to its source character, for non-ASCII text.
---@param text string
---@return string folded
---@return { first: integer, last: integer }[]? map
local function fold(text)
  if not text:find("[\128-\255]") then
    return text:lower(), nil
  end
  local parts, map = {}, {}
  local index = 1
  while index <= #text do
    local last = math.min(index + char_length(text:sub(index, index)) - 1, #text)
    local folded = vim.fn.tolower(text:sub(index, last))
    parts[#parts + 1] = folded
    for _ = 1, #folded do
      map[#map + 1] = { first = index, last = last }
    end
    index = last + 1
  end
  return table.concat(parts), map
end

--- Every occurrence of a folded needle, as 0-based byte ranges of the source text.
---@param text string
---@param needle string
---@return { col: integer, end_col: integer }[]? ranges Nil when there is no match.
local function find_all(text, needle)
  local folded, map = fold(text)
  if needle == "" then
    return {}
  end
  local ranges = {}
  local index = 1
  while true do
    local first, last = folded:find(needle, index, true)
    if not first then
      break
    end
    if map then
      ranges[#ranges + 1] = { col = map[first].first - 1, end_col = map[last].last }
    else
      ranges[#ranges + 1] = { col = first - 1, end_col = last }
    end
    index = last + 1
  end
  return #ranges > 0 and ranges or nil
end

--- Splits on whitespace. A prefix is lowercase, and any other colon is part of a bare term.
---@param text string
---@return oas_glance.FilterTerm[]
function M.parse(text)
  local terms = {}
  for word in text:gmatch("%S+") do
    local prefix, rest = word:match("^(%l+):(.*)$")
    if prefix and PREFIXES[prefix] then
      terms[#terms + 1] = { kind = prefix, text = (fold(rest)) }
    else
      terms[#terms + 1] = { kind = "any", text = (fold(word)) }
    end
  end
  return terms
end

---@param ranges oas_glance.FilterRange[]
---@param field "path"|"tag"|"name"
---@param tag string?
---@param found { col: integer, end_col: integer }[]
local function add_ranges(ranges, field, tag, found)
  for _, range in ipairs(found) do
    ranges[#ranges + 1] = { field = field, tag = tag, col = range.col, end_col = range.end_col }
  end
end

---@param term oas_glance.FilterTerm
---@param row { path?: string, tags?: string[], name?: string }
---@param ranges oas_glance.FilterRange[]
---@return boolean
local function match_term(term, row, ranges)
  local matched = false
  if (term.kind == "path" or term.kind == "any") and row.path then
    local found = find_all(row.path, term.text)
    if found then
      matched = true
      add_ranges(ranges, "path", nil, found)
    end
  end
  if term.kind == "tag" or term.kind == "any" then
    for _, tag in ipairs(row.tags or {}) do
      local found = find_all(tag, term.text)
      if found then
        matched = true
        add_ranges(ranges, "tag", tag, found)
      end
    end
  end
  if (term.kind == "schema" or term.kind == "any") and row.name then
    local found = find_all(row.name, term.text)
    if found then
      matched = true
      add_ranges(ranges, "name", nil, found)
    end
  end
  return matched
end

--- Whether a row matches every term. An operation row has a path and tags, and a schema row only a name.
---@param terms oas_glance.FilterTerm[]
---@param row { path?: string, tags?: string[], name?: string }
---@return boolean matched
---@return oas_glance.FilterRange[] ranges Empty unless matched.
function M.match(terms, row)
  local ranges = {}
  for _, term in ipairs(terms) do
    if not match_term(term, row, ranges) then
      return false, {}
    end
  end
  return true, ranges
end

return M
