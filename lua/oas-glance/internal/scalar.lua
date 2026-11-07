local M = {}

local REPLACEMENT = "\239\191\189"

local SIMPLE_ESCAPES = {
  ["0"] = "\0",
  a = "\a",
  b = "\b",
  t = "\t",
  ["\t"] = "\t",
  n = "\n",
  v = "\v",
  f = "\f",
  r = "\r",
  e = "\27",
  [" "] = " ",
  ['"'] = '"',
  ["/"] = "/",
  ["\\"] = "\\",
  N = "\194\133",
  _ = "\194\160",
  L = "\226\128\168",
  P = "\226\128\169",
}

local HEX_LENGTHS = { x = 2, u = 4, U = 8 }

local FOLD_PATTERNS = { plain = "[\r\n]", single = "['\r\n]", double = "[\\\r\n]" }

local NULLS = { [""] = true, ["~"] = true, null = true, Null = true, NULL = true }
local BOOLS = { ["true"] = true, True = true, TRUE = true, ["false"] = false, False = false, FALSE = false }
local INFINITIES = { [".inf"] = true, [".Inf"] = true, [".INF"] = true }
local NANS = { [".nan"] = true, [".NaN"] = true, [".NAN"] = true }

---@param code_point integer
---@return string
local function utf8_encode(code_point)
  if code_point < 0 or code_point > 0x10FFFF or (code_point >= 0xD800 and code_point <= 0xDFFF) then
    return REPLACEMENT
  end
  if code_point < 0x80 then
    return string.char(code_point)
  end
  local continuation = {}
  local first_limit = 0x40
  local rest = code_point
  while rest >= first_limit do
    table.insert(continuation, 1, string.char(0x80 + rest % 0x40))
    rest = math.floor(rest / 0x40)
    first_limit = first_limit / 2
  end
  return string.char(0x100 - first_limit * 2 + rest) .. table.concat(continuation)
end

---@param text string
---@param start integer
---@param length integer
---@return integer?
local function read_hex(text, start, length)
  local hex = text:sub(start, start + length - 1)
  if #hex == length and hex:match("^%x+$") then
    return tonumber(hex, 16)
  end
end

--- Consumes consecutive line breaks and the whitespace after them.
---@param text string
---@param start integer Index of the first break.
---@return integer next_index
---@return integer breaks
local function skip_breaks(text, start)
  local index, breaks = start, 0
  while true do
    local after = text:match("^\r\n()", index) or text:match("^[\r\n]()", index)
    if not after then
      return index, breaks
    end
    breaks = breaks + 1
    index = text:match("^[ \t]*()", after)
  end
end

--- Decodes the escape at `start`, the index of its backslash.
---@param text string
---@param start integer
---@return string decoded
---@return integer next_index
local function decode_escape(text, start)
  local letter = text:sub(start + 1, start + 1)
  local simple = SIMPLE_ESCAPES[letter]
  if simple then
    return simple, start + 2
  end

  local length = HEX_LENGTHS[letter]
  local code_point = length and read_hex(text, start + 2, length)
  if not code_point then
    return "\\" .. letter, start + 2
  end

  local after = start + 2 + length
  if letter == "u" and code_point >= 0xD800 and code_point <= 0xDBFF and text:sub(after, after + 1) == "\\u" then
    local low = read_hex(text, after + 2, 4)
    if low and low >= 0xDC00 and low <= 0xDFFF then
      return utf8_encode(0x10000 + (code_point - 0xD800) * 0x400 + (low - 0xDC00)), after + 6
    end
  end
  return utf8_encode(code_point), after
end

---@param text string
---@param style "plain"|"single"|"double"
---@return string
local function fold(text, style)
  local pattern = FOLD_PATTERNS[style]
  local parts = {}
  local index = 1
  while true do
    local found = text:find(pattern, index)
    if not found then
      parts[#parts + 1] = text:sub(index)
      return table.concat(parts)
    end

    local literal = text:sub(index, found - 1)
    local char = text:sub(found, found)
    if char == "\\" then
      parts[#parts + 1] = literal
      local next_char = text:sub(found + 1, found + 1)
      if next_char == "\n" or next_char == "\r" then
        local after, breaks = skip_breaks(text, found + 1)
        parts[#parts + 1] = string.rep("\n", breaks - 1)
        index = after
      else
        local decoded, after = decode_escape(text, found)
        parts[#parts + 1] = decoded
        index = after
      end
    elseif char == "'" then
      parts[#parts + 1] = literal .. "'"
      index = text:sub(found + 1, found + 1) == "'" and found + 2 or found + 1
    else
      parts[#parts + 1] = literal:gsub("[ \t]+$", "")
      local after, breaks = skip_breaks(text, found)
      parts[#parts + 1] = breaks == 1 and " " or string.rep("\n", breaks - 1)
      index = after
    end
  end
end

---@param raw string
---@param quote string
---@return string
local function unquote(raw, quote)
  if #raw >= 2 and raw:sub(-1) == quote then
    return raw:sub(2, -2)
  end
  return raw:sub(2)
end

---@param lines string[]
---@return string
local function fold_block_lines(lines)
  local parts = {}
  local pending_breaks = 0
  local previous_more_indented
  for _, line in ipairs(lines) do
    if line == "" then
      pending_breaks = pending_breaks + 1
    else
      local more_indented = line:match("^[ \t]") ~= nil
      local foldable = previous_more_indented == false and not more_indented
      if previous_more_indented ~= nil and not foldable then
        parts[#parts + 1] = string.rep("\n", pending_breaks + 1)
      elseif foldable and pending_breaks == 0 then
        parts[#parts + 1] = " "
      else
        parts[#parts + 1] = string.rep("\n", pending_breaks)
      end
      parts[#parts + 1] = line
      pending_breaks = 0
      previous_more_indented = more_indented
    end
  end
  return table.concat(parts)
end

--- Decodes a block scalar, header included. `parent_indent` applies only to an indent indicator.
---@param raw string
---@param parent_indent? integer
---@return string
function M.block(raw, parent_indent)
  local header, body = raw:match("^([^\r\n]*)\r?\n?(.*)$")
  body = body:gsub("\r\n?", "\n")
  local indicators = header:match("^[|>]([-+0-9]*)") or ""
  local chomp = indicators:match("[-+]")
  local digit = indicators:match("%d")

  local lines = vim.split(body, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end

  local indent = math.huge
  if digit then
    indent = (parent_indent or 0) + tonumber(digit)
  else
    for _, line in ipairs(lines) do
      local lead = line:match("^( *)[^ ]")
      if lead then
        indent = #lead
        break
      end
    end
  end

  for index, line in ipairs(lines) do
    local lead = #line:match("^ *")
    lines[index] = line:sub(math.min(lead, indent) + 1)
  end

  local trailing = 0
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
    trailing = trailing + 1
  end

  local has_content = #lines > 0
  local text = header:sub(1, 1) == ">" and fold_block_lines(lines) or table.concat(lines, "\n")
  if chomp == "-" then
    return text
  end
  if has_content then
    text = text .. "\n"
  end
  if chomp == "+" then
    text = text .. string.rep("\n", trailing)
  end
  return text
end

--- Core-schema type of plain text.
---@param text string
---@return "null"|"bool"|"int"|"float"|"string"
function M.core_type(text)
  if NULLS[text] then
    return "null"
  end
  if BOOLS[text] ~= nil then
    return "bool"
  end
  if text:match("^[-+]?%d+$") or text:match("^0o[0-7]+$") or text:match("^0x%x+$") then
    return "int"
  end
  if INFINITIES[text:gsub("^[-+]", "")] or NANS[text] then
    return "float"
  end
  local mantissa = text:match("^(.-)[eE][-+]?%d+$") or text
  if mantissa:match("^[-+]?%.%d+$") or mantissa:match("^[-+]?%d+%.?%d*$") then
    return "float"
  end
  return "string"
end

---@param text string
---@param scalar_type string
---@return any
local function coerce(text, scalar_type)
  if scalar_type == "bool" then
    return BOOLS[text]
  end
  if scalar_type == "int" or scalar_type == "float" then
    if NANS[text] then
      return 0 / 0
    end
    local sign, unsigned = text:match("^([-+]?)(.*)$")
    local magnitude
    if INFINITIES[unsigned] then
      magnitude = math.huge
    elseif unsigned:sub(1, 2) == "0o" then
      magnitude = tonumber(unsigned:sub(3), 8)
    else
      magnitude = tonumber(unsigned)
    end
    return sign == "-" and -magnitude or magnitude
  end
  if scalar_type == "string" then
    return text
  end
  return nil
end

--- Decoded text regardless of type, as used for mapping keys.
---@param raw string
---@param style "plain"|"single"|"double"|"literal"|"folded"
---@param parent_indent? integer
---@return string
function M.text(raw, style, parent_indent)
  if style == "double" then
    return fold(unquote(raw, '"'), "double")
  end
  if style == "single" then
    return fold(unquote(raw, "'"), "single")
  end
  if style == "plain" then
    return fold(raw, "plain")
  end
  return M.block(raw, parent_indent)
end

--- A null scalar has a nil value.
---@param raw string
---@param style "plain"|"single"|"double"|"literal"|"folded"
---@param parent_indent? integer
---@return any value
---@return "null"|"bool"|"int"|"float"|"string" scalar_type
function M.decode(raw, style, parent_indent)
  local text = M.text(raw, style, parent_indent)
  if style ~= "plain" then
    return text, "string"
  end
  local scalar_type = M.core_type(text)
  return coerce(text, scalar_type), scalar_type
end

return M
