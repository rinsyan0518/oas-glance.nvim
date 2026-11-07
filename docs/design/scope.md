# Scope

What the plugin covers: the OpenAPI versions it reads, and its features.

## OpenAPI versions

The plugin supports OpenAPI 3.0 and 3.1, normalised to one internal model. A 2.0 document gets a clear error.

An error is better than a wrong rendering.

## OpenAPI 3.2 gets a clear error

An OpenAPI 3.2 document gets the same clear error as 2.0.

Rendering 3.2 as 3.1 would silently drop fields such as `query` and `additionalOperations`.

## Features

Besides the list and the schema detail, the plugin has jump to source, `$ref` expansion in place, jump to definition with a visible cycle marker, search and filtering by path, tag and schema name, loading `$ref`s that point at other files, and a sample cURL command for the operation shown.
