# Refs

How `$ref`s are bounded, when they are checked and loaded, and how they render before and after they are opened.

## Boundary for local refs

Local `$ref`s may reach files inside the nearest ancestor that has `.git`, otherwise inside the document's directory. The home directory and its ancestors never become the root this way, even when they have `.git`. `refs.root` overrides this.

The document's directory alone would break the common `../common/` layout, and no boundary at all would let a downloaded spec read any file the user can read. A home directory kept in git would otherwise let a document anywhere under it show files such as credentials.

## Outside the root hides existence

A ref that leaves the root gives the same `outside root` reason whether or not its target exists, symlinks included.

Otherwise an untrusted document could probe which files exist on the user's machine. This supports the [boundary for local refs](#boundary-for-local-refs).

## Refs with control characters refused

A `$ref` holding any control character, U+0000 to U+001F or U+007F, is refused with `not allowed` before any filesystem call.

A file name with a newline could let jump to source run arbitrary code, and this rule removes the whole class for names that come from a document. No real spec needs such characters.

## Refs start closed

Every `$ref` in a detail view starts closed, including the one in the first response.

This keeps rows few and loads no external file until asked. The cost is that an operation whose responses are all refs shows no fields until the user expands one. The alternative was to open the ref in the first response automatically, one level deep.

## Closed local refs unchecked

A closed local `#/...` `$ref` is unchecked until opened, like an external one. It shows `▸ → Name` while closed, and `✗ #/...  no such pointer` after opening if the target is missing. The cycle marker for local refs is unchanged.

## Closed external refs unchecked

A closed external `$ref`'s target is checked only when the ref is opened. While closed it renders as an ordinary `▸ → name` row, with no broken marker. Remote refs are the exception, see [Remote refs are broken from the start](#remote-refs-are-broken-from-the-start).

## Remote refs not loaded

Remote `$ref`s are never loaded and show as a broken row.

A viewer that fetches URLs named by a document leaks information, which is a poor default.

## Remote refs are broken from the start

A remote `$ref` (`http` or `https`) is a broken row from the start, with no fold marker and no need to open it. It joins Problems when rendered. Other refs whose failure is known from their text alone, with no file or tree access, behave the same way, which covers `not allowed` and `unsupported ref`.

The rule extends beyond remote refs because none of these refs has a target to check.
