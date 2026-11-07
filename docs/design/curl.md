# cURL

The viewer can build a cURL command for the operation it shows. This document covers where the command appears, what it contains, and how text from an untrusted document is kept from doing harm.

## cURL command action

The `curl` action, on `gc` by default in both the list and detail panes, builds a cURL command for the operation shown. The plugin never sends a request. The user edits the command and runs it in their own terminal.

## Opens in a scratch split

The command opens in an editable scratch buffer, in a horizontal split below the detail pane, rather than going to a register. Pressing the key again reuses the window and replaces its content. The open window also [follows the shown operation](#follows-the-shown-operation). The buffer has `filetype=sh`, asks for no save, and closes with the viewer.

## Follows the shown operation

While the cURL window is open, it is rebuilt whenever the detail pane comes to show a different operation, reload included. The text is always overwritten, even after the user edited it, and the replacement is one undoable change, so `u` brings the earlier text back. When the detail pane shows something other than an operation, the text stays as it is and no message appears. The warnings remain for an explicit `gc` only.

An unchanged operation is not rebuilt, so going into a schema and back keeps the user's edits. A reload always rebuilds, because the document may have changed.

## Required parameters only

The command includes the required query, header and cookie parameters and leaves the optional ones out. Path parameters are always included.

The command then runs as it is once its variables are set, and stays short. Optional parameters are easy to add by hand in the editable buffer.

## Body from examples or the schema

The request body is the media type's first example when it has one. Otherwise it is generated from the schema, taking for each value its example, then default, then first enum value, then const, then a placeholder for its type such as `"string"`, `0` or `true`. Generation is deterministic, with no current-time values.

Generation may open schema `$ref`s, which can load external files and raise the problem count, and that is accepted.

## Auth from the first security requirement

The command includes auth from the first security requirement only. An `apiKey` goes in a header, the query or a cookie, by its `in`. HTTP bearer gives `Authorization: Bearer ${TOKEN}`, and HTTP basic gives `-u "${USERNAME}:${PASSWORD}"`. OAuth2 and OpenID Connect are treated as bearer. An empty security list, or `{}`, gives no auth.

## Relative server uses the base URL

When the chosen server URL is relative, including the default `/`, the cURL URL starts with the shell variable `${BASE_URL}`.

OpenAPI resolves a relative server URL against the document's location, and a local file gives no usable host. A variable follows the rule that [unknown values are shell variables](#placeholders-are-shell-variables).

## Placeholders are shell variables

Values the document does not give, such as path parameters, required query parameters and auth tokens, become shell variables in double quotes, for example `"${PET_ID}"` or `"${TOKEN}"`. A parameter's example is used when it has one.

A placeholder inside a longer value is joined to [single-quoted literals](#literals-are-single-quoted), as in `'Authorization: Bearer '"${TOKEN}"`. Only the variable reference is ever inside double quotes.

## Literals are single-quoted

Every literal value in the command, whether written by the plugin or taken from the document, is single-quoted. No document text is ever inside double quotes.

A pasted command is then inert in bash and zsh: `$`, backticks and history expansion with `!` cannot apply to document text.

## Descriptive line never runs

The command's descriptive first line is written so that no shell runs it, as the argument of `:` in single quotes rather than as a `#` comment.

Interactive zsh does not treat `#` as a comment by default, so a `#` line would run as a command when pasted.

## URL passed with --url

The request URL is passed with `--url`.

A server URL from the document can then never become a curl option, even when it starts with `-`.

## Header names must be tokens

A header or `apiKey` name that is not an HTTP token is skipped.

Such a name is never valid, and one starting with `@` would make curl read a file.

## Size budget

Building the command has a size budget. Past it, the remaining values are omitted and the command says so.

Crafted YAML anchors or `$ref` fan-out could otherwise make the command huge and hang the editor.

## Placeholders avoid reserved names

A placeholder never takes a name that common environment, shell or proxy variables use, such as `PATH`, `USER`, `HOME` or `HTTPS_PROXY`. The variable gets a suffix instead.

The user sets each placeholder as a shell variable before running the command. Setting one of these names would break the user's shell or change what curl does.

## Document text stays inert

Text from the OpenAPI document cannot make the pasted command run anything in the shell, cannot make curl read a local file the user did not name, and cannot put raw control bytes into the text the user pastes. Besides [single quoting](#literals-are-single-quoted), [the descriptive line](#descriptive-line-never-runs), [`--url`](#url-passed-with---url) and [token header names](#header-names-must-be-tokens), multipart text fields use `--form-string`, and a multipart file field whose name curl would reinterpret makes the whole body a file the user supplies. Control characters are replaced or percent-encoded.

An untrusted document could otherwise make a pasted command run shell code, upload a local file such as `.env`, or send keystrokes such as ^C or ESC to the user's terminal.
