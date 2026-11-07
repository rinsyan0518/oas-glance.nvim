# Parsing

How YAML and JSON documents are read, the limits of the parser, and how parse problems are reported.

## YAML parsed with tree-sitter

YAML is parsed with the tree-sitter yaml parser. Users must install it. The plugin loads it from `parser/yaml.*` on `runtimepath` and does not depend on nvim-treesitter.

## JSON through tree-sitter YAML

JSON documents are parsed by the tree-sitter yaml parser, and `vim.json.decode` is not used for documents.

Jump to source needs positions, and the list needs spec order, and `vim.json.decode` loses both. A single path also means a single parser to install.

The parser accepts a leading BOM without an error, and first-row columns already count its 3 bytes, so the BOM is stripped only when a file also has a real syntax error.

## YAML line limit

YAML with more than 32768 lines cannot be handled by the parser. The plugin detects it and gives a dedicated error that suggests converting to JSON, and an external file gets the `too many lines` reason.

The parser's scanner stores rows in 16 bits, so such a document parses as one error tree. JSON is unaffected. The error fires only for a document over the limit whose tree has an error and that is not flow-style, so large JSON and documents within the limit keep their normal handling.

## Lost root is a known limitation

A file whose syntax error makes the parser lose the document root is refused as "not an OpenAPI document", with no line number. This covers most errors inside a JSON root and some YAML errors.

It is a known limitation of the parser's error recovery.

## Problem count says "so far"

The problem count grows as refs resolve. It is worded "so far", with a hint that references are checked when opened.

Refs stay lazy for large specs, so the count is never known to be complete. A plain count, or no count at all, would imply that the document was checked when it was not.
