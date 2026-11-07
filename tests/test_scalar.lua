local scalar = require("oas-glance.internal.scalar")

local expect = MiniTest.expect

local T = MiniTest.new_set()

local function add_rows(set, rows, run)
  for _, row in ipairs(rows) do
    set[row[1]] = function()
      run(row)
    end
  end
end

local function expect_text(row)
  expect.equality(scalar.text(row[2], row[3], row[5]), row[4])
end

T["escapes"] = MiniTest.new_set()
add_rows(T["escapes"], {
  { "quote", [["a\"b"]], "double", 'a"b' },
  { "backslash", [["a\\b"]], "double", "a\\b" },
  { "slash", [["a\/b"]], "double", "a/b" },
  { "backspace", [["\b"]], "double", "\b" },
  { "form feed", [["\f"]], "double", "\f" },
  { "newline", [["\n"]], "double", "\n" },
  { "carriage return", [["\r"]], "double", "\r" },
  { "tab", [["\t"]], "double", "\t" },
  { "literal tab escape", '"\\\t"', "double", "\t" },
  { "nul", [["\0"]], "double", "\0" },
  { "bell", [["\a"]], "double", "\a" },
  { "vertical tab", [["\v"]], "double", "\v" },
  { "escape", [["\e"]], "double", "\27" },
  { "space", [["\ "]], "double", " " },
  { "next line", [["\N"]], "double", "\194\133" },
  { "no-break space", [["\_"]], "double", "\194\160" },
  { "line separator", [["\L"]], "double", "\226\128\168" },
  { "paragraph separator", [["\P"]], "double", "\226\128\169" },
  { "x", [["\x41"]], "double", "A" },
  { "x above ascii", [["\xE9"]], "double", "\195\169" },
  { "u ascii", '"\\u0041"', "double", "A" },
  { "u nul", '"\\u0000"', "double", "\0" },
  { "u two bytes", '"\\u00e9"', "double", "\195\169" },
  { "u three bytes", '"\\u3042"', "double", "\227\129\130" },
  { "U four bytes", [["\U0001F600"]], "double", "\240\159\152\128" },
  { "U above unicode", [["\U00110000"]], "double", "\239\191\189" },
  { "unknown escape stays", [["\q"]], "double", "\\q" },
  { "short u stays", [["\u12"]], "double", "\\u12" },
  { "single quote doubled", "'it''s'", "single", "it's" },
  { "backslash is literal in single", [['a\nb']], "single", "a\\nb" },
  { "backslash is literal in plain", [[a\nb]], "plain", "a\\nb" },
}, expect_text)

T["surrogates"] = MiniTest.new_set()
add_rows(T["surrogates"], {
  { "pair", '"\\uD83D\\uDE00"', "double", "\240\159\152\128" },
  { "lowest pair", '"\\uD800\\uDC00"', "double", "\240\144\128\128" },
  { "highest pair", '"\\uDBFF\\uDFFF"', "double", "\244\143\191\191" },
  { "lone high", [["\uD83D"]], "double", "\239\191\189" },
  { "lone low", [["\uDE00"]], "double", "\239\191\189" },
  { "high then text", [["\uD83Dx"]], "double", "\239\191\189x" },
  { "high then non-low escape", '"\\uD83D\\u0041"', "double", "\239\191\189A" },
  { "two highs", [["\uD83D\uD83D"]], "double", "\239\191\189\239\191\189" },
  { "U in surrogate range", [["\U0000D83D"]], "double", "\239\191\189" },
}, expect_text)

T["folding"] = MiniTest.new_set()
add_rows(T["folding"], {
  { "plain single break", "a\n  b", "plain", "a b" },
  { "plain blank line", "a\n\n  b", "plain", "a\nb" },
  { "plain two blank lines", "a\n\n\n  b", "plain", "a\n\nb" },
  { "plain trailing space on a line", "a  \n  b", "plain", "a b" },
  { "plain crlf", "a\r\n  b", "plain", "a b" },
  { "single single break", "'a\n  b'", "single", "a b" },
  { "single keeps edge spaces", "' a '", "single", " a " },
  { "double single break", '"a\n  b"', "double", "a b" },
  { "double blank line", '"a\n\n  b"', "double", "a\nb" },
  { "double whitespace-only line", '"a\n   \n  b"', "double", "a\nb" },
  { "double crlf", '"a\r\n  b"', "double", "a b" },
  { "double trailing break", '"a\n  "', "double", "a " },
  { "double escaped break joins", '"a\\\n  b"', "double", "ab" },
  { "double escaped break keeps spaces before", '"a  \\\n  b"', "double", "a  b" },
  { "double escaped break then blank", '"a\\\n\n  b"', "double", "a\nb" },
  { "double escaped newline is not folded", [["a\n b"]], "double", "a\n b" },
  { "double escaped tab before break stays", '"a\\t\n  b"', "double", "a\t b" },
}, expect_text)

T["block"] = MiniTest.new_set()
add_rows(T["block"], {
  { "literal clip", "|\n  a\n  b\n", "literal", "a\nb\n" },
  { "literal clip drops extra breaks", "|\n  a\n\n\n", "literal", "a\n" },
  { "literal clip without a final break", "|\n  a", "literal", "a\n" },
  { "literal strip", "|-\n  a\n\n", "literal", "a" },
  { "literal keep", "|+\n  a\n\n", "literal", "a\n\n" },
  { "literal keeps inner indent", "|\n  a\n    b\n  c\n", "literal", "a\n  b\nc\n" },
  { "literal keeps blank lines", "|\n  a\n\n  b\n", "literal", "a\n\nb\n" },
  { "literal leading blank line", "|\n\n  a\n", "literal", "\na\n" },
  { "literal crlf", "|\r\n  a\r\n  b\r\n", "literal", "a\nb\n" },
  { "empty clip", "|\n", "literal", "" },
  { "empty strip", "|-\n", "literal", "" },
  { "empty keep with blanks", "|+\n\n\n", "literal", "\n\n" },
  { "comment in the header", "| # note\n  a\n", "literal", "a\n" },
  { "folded clip", ">\n  a\n  b\n", "folded", "a b\n" },
  { "folded strip", ">-\n  a\n  b\n", "folded", "a b" },
  { "folded keep", ">+\n  a\n\n", "folded", "a\n\n" },
  { "folded blank line", ">\n  a\n\n  b\n", "folded", "a\nb\n" },
  { "folded two blank lines", ">\n  a\n\n\n  b\n", "folded", "a\n\nb\n" },
  { "folded more indented", ">\n  a\n    b\n  c\n", "folded", "a\n  b\nc\n" },
  { "folded leading blank line", ">\n\n  a\n", "folded", "\na\n" },
  { "indicator keeps extra indent", "|2\n    a\n", "literal", "  a\n", 0 },
  { "indicator adds to the parent indent", "|1\n     a\n", "literal", "  a\n", 2 },
  { "indicator then chomp", "|2-\n    a\n", "literal", "  a", 0 },
  { "chomp then indicator", "|-2\n    a\n", "literal", "  a", 0 },
  { "indicator with folded", ">2\n    a\n", "folded", "  a\n", 0 },
  { "auto indent ignores blank lines", "|\n\n    a\n", "literal", "\na\n" },
}, expect_text)

T["core types"] = MiniTest.new_set()
add_rows(T["core types"], {
  { "empty", "", "null", nil },
  { "tilde", "~", "null", nil },
  { "null", "null", "null", nil },
  { "Null", "Null", "null", nil },
  { "NULL", "NULL", "null", nil },
  { "true", "true", "bool", true },
  { "True", "True", "bool", true },
  { "TRUE", "TRUE", "bool", true },
  { "false", "false", "bool", false },
  { "False", "False", "bool", false },
  { "FALSE", "FALSE", "bool", false },
  { "int", "12", "int", 12 },
  { "signed int", "+12", "int", 12 },
  { "negative int", "-12", "int", -12 },
  { "leading zero", "012", "int", 12 },
  { "octal", "0o17", "int", 15 },
  { "hex", "0xFF", "int", 255 },
  { "minus zero", "-0", "int", 0 },
  { "float", "1.5", "float", 1.5 },
  { "signed float", "+1.5", "float", 1.5 },
  { "leading dot", ".5", "float", 0.5 },
  { "trailing dot", "1.", "float", 1 },
  { "exponent", "1E+2", "float", 100 },
  { "lower exponent", "1e-2", "float", 0.01 },
  { "inf", ".inf", "float", math.huge },
  { "negative inf", "-.Inf", "float", -math.huge },
  { "yes is a string", "yes", "string", "yes" },
  { "nUll is a string", "nUll", "string", "nUll" },
  { "version is a string", "3.1.0", "string", "3.1.0" },
  { "0o8 is a string", "0o8", "string", "0o8" },
  { "signed hex is a string", "-0x10", "string", "-0x10" },
  { "e alone is a string", "e5", "string", "e5" },
  { "dot alone is a string", ".", "string", "." },
  { "inf without dot is a string", "inf", "string", "inf" },
  { "nan without dot is a string", "nan", "string", "nan" },
  { "status is an int", "200", "int", 200 },
  { "status range is a string", "2XX", "string", "2XX" },
}, function(row)
  local value, scalar_type = scalar.decode(row[2], "plain")
  expect.equality(scalar_type, row[3])
  expect.equality(value, row[4])
end)

T["core types"]["nan"] = function()
  for _, raw in ipairs({ ".nan", ".NaN", ".NAN" }) do
    local value, scalar_type = scalar.decode(raw, "plain")
    expect.equality(scalar_type, "float")
    expect.equality(value ~= value, true)
  end
end

T["core types"]["keeps a large int's magnitude"] = function()
  local value, scalar_type = scalar.decode("12345678901234567890", "plain")
  expect.equality(scalar_type, "int")
  expect.equality(value, 12345678901234567890)
end

T["core types"]["minus zero keeps its sign"] = function()
  local value = scalar.decode("-0", "plain")
  expect.equality(1 / value, -math.huge)
end

T["core types"]["multi-line plain is a string"] = function()
  local value, scalar_type = scalar.decode("1\n  2", "plain")
  expect.equality(scalar_type, "string")
  expect.equality(value, "1 2")
end

T["decode"] = MiniTest.new_set()
add_rows(T["decode"], {
  { "quoted number stays text", [["12"]], "double", "12" },
  { "quoted null stays text", "'null'", "single", "null" },
  { "literal number stays text", "|\n  12\n", "literal", "12\n" },
  { "folded number stays text", ">-\n  12\n", "folded", "12" },
}, function(row)
  local value, scalar_type = scalar.decode(row[2], row[3])
  expect.equality(scalar_type, "string")
  expect.equality(value, row[4])
end)

T["text of a plain key keeps its spelling"] = function()
  expect.equality(scalar.text("200", "plain"), "200")
  expect.equality(scalar.text("null", "plain"), "null")
end

return T
