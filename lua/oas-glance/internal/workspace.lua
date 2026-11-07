local tree = require("oas-glance.internal.tree")

local M = {}

local DEFAULT_MAX_FILES = 512
local DEFAULT_MAX_FILE_BYTES = 16 * 1024 * 1024
local DEFAULT_MAX_DEPTH = 64

---@class oas_glance.Workspace
---@field root string? The boundary for external refs.
---@field root_doc oas_glance.Doc?
---@field max_files integer
---@field max_file_bytes integer
---@field max_depth integer
---@field package _root_option string?
---@field package _docs table<string, oas_glance.Doc>
---@field package _failed table<string, string> The reason a file failed, so a second opening gives it again.
---@field package _loaded string[]
local Workspace = {}
Workspace.__index = Workspace

--- Collapses `.` and `..` in an absolute path without touching the filesystem.
---@param path string
---@return string
local function collapse(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

---@param path string
---@return string
local function absolute(path)
  if path:sub(1, 1) == "/" then
    return collapse(path)
  end
  return collapse((vim.uv.cwd() or "") .. "/" .. path)
end

---@param dir string
---@param name string
---@return string
local function join(dir, name)
  return dir == "/" and "/" .. name or dir .. "/" .. name
end

---@param path string
---@return string
local function dirname(path)
  return path:match("^(.+)/[^/]*$") or "/"
end

---@param root string
---@param path string
---@return boolean
local function is_inside(root, path)
  return path == root or root == "/" or vim.startswith(path, root .. "/")
end

---@param path string
---@return string
local function real_or_absolute(path)
  local abs = absolute(path)
  return vim.uv.fs_realpath(abs) or abs
end

---@param text string
---@param opts { file?: string, bufnr?: integer }
---@return oas_glance.Doc?
---@return oas_glance.OpenError?
local function safe_parse(text, opts)
  local ok, doc, err = pcall(tree.parse, text, opts)
  if not ok then
    return nil, { kind = "parse", reason = tostring(doc) }
  end
  if not doc then
    return nil, err or { kind = "parse", reason = "the parser returned no tree" }
  end
  return doc
end

--- Reads a regular file. Callers check the type first, so a FIFO cannot block here.
---@param path string
---@return string?
---@return string? reason
local function read_file(path)
  local file, reason = io.open(path, "rb")
  if not file then
    return nil, reason
  end
  local text = file:read("*a")
  file:close()
  if not text then
    return nil, "cannot read " .. path
  end
  return text
end

--- A document's identity: its real path, its absolute name with no file on disk, or its buffer number.
---@param opts { file?: string, name?: string, bufnr?: integer }
---@return string
function M.identity(opts)
  local path = opts.file or opts.name
  if path and path ~= "" then
    return real_or_absolute(path)
  end
  return "buffer:" .. tostring(opts.bufnr)
end

---@param opts? { root?: string, max_files?: integer, max_file_bytes?: integer, max_depth?: integer }
---@return oas_glance.Workspace
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    max_files = opts.max_files or DEFAULT_MAX_FILES,
    max_file_bytes = opts.max_file_bytes or DEFAULT_MAX_FILE_BYTES,
    max_depth = opts.max_depth or DEFAULT_MAX_DEPTH,
    _root_option = opts.root,
    _docs = {},
    _failed = {},
    _loaded = {},
  }, Workspace)
end

--- True when `path` is the home directory or one of its ancestors.
---@param path string
---@return boolean
local function covers_home(path)
  if path == "/" then
    return true
  end
  local home = vim.uv.os_homedir()
  if not home or home == "" then
    return false
  end
  home = vim.uv.fs_realpath(home) or (home:gsub("(.)/+$", "%1"))
  return home == path or vim.startswith(home, path .. "/")
end

---@param dir string
---@return string
local function nearest_git_root(dir)
  local current = dir
  while true do
    if vim.uv.fs_stat(join(current, ".git")) then
      return covers_home(current) and dir or current
    end
    if current == "/" then
      return dir
    end
    current = dirname(current)
  end
end

---@param doc oas_glance.Doc
---@param identity string
---@param real_dir string?
function Workspace:_set_root_doc(doc, identity, real_dir)
  doc.identity = identity
  doc.real_dir = real_dir
  self.root_doc = doc
  self._docs[identity] = doc
  if self._root_option then
    self.root = real_or_absolute(self._root_option)
  elseif real_dir then
    self.root = nearest_git_root(real_dir)
  end
end

--- Opens the document the user asked for from disk. The limits do not apply to it.
---@param path string
---@return oas_glance.Doc?
---@return oas_glance.OpenError?
function Workspace:open_file(path)
  local abs = absolute(path)
  local real, realpath_error = vim.uv.fs_realpath(abs)
  if not real then
    return nil, { kind = "read", reason = realpath_error }
  end
  local stat, stat_error = vim.uv.fs_stat(real)
  if not stat then
    return nil, { kind = "read", reason = stat_error }
  end
  if stat.type ~= "file" then
    return nil, { kind = "read", reason = stat.type == "directory" and "is a directory" or "not a regular file" }
  end
  local text, read_error = read_file(real)
  if not text then
    return nil, { kind = "read", reason = read_error }
  end

  local doc, err = safe_parse(text, { file = real })
  if not doc then
    return nil, err
  end
  local lines = tree.line_limit(text, tree.has_error(doc))
  if lines then
    return nil, { kind = "lines", n = lines }
  end
  self:_set_root_doc(doc, real, dirname(real))
  return doc
end

--- Opens the document from buffer text. An unnamed buffer has no base for file refs.
---@param text string
---@param opts { name?: string, bufnr: integer }
---@return oas_glance.Doc?
---@return oas_glance.OpenError?
function Workspace:open_text(text, opts)
  local named = opts.name ~= nil and opts.name ~= ""
  local abs = named and absolute(opts.name) or nil
  local doc, err = safe_parse(text, { file = abs, bufnr = opts.bufnr })
  if not doc then
    return nil, err
  end
  local lines = tree.line_limit(text, tree.has_error(doc))
  if lines then
    return nil, { kind = "lines", n = lines }
  end
  local real_dir = abs and real_or_absolute(dirname(abs)) or nil
  self:_set_root_doc(doc, M.identity({ name = abs, bufnr = opts.bufnr }), real_dir)
  return doc
end

--- Open checks 4 to 6 up to the real path. Each component is resolved in turn, so nothing is touched outside the root.
---@param target string A lexically collapsed path inside the root.
---@return string? real
---@return string? reason
function Workspace:_walk_to_real(target)
  local root = self.root --[[@as string]]
  local current = root
  for part in target:sub(#root + 1):gmatch("[^/]+") do
    local candidate = join(current, part)
    local stat = vim.uv.fs_lstat(candidate)
    if not stat then
      return nil, "not found"
    end
    if stat.type == "link" then
      local resolved = vim.uv.fs_realpath(candidate)
      if not resolved or not is_inside(root, resolved) then
        return nil, "outside root"
      end
      current = resolved
    else
      current = candidate
    end
  end

  local real = vim.uv.fs_realpath(current)
  if not real then
    return nil, "not found"
  end
  if not is_inside(root, real) then
    return nil, "outside root"
  end
  return real
end

--- The open checks of an external ref, then the per-file cache.
---@param from oas_glance.Doc The referring document.
---@param path string The ref's file part.
---@return oas_glance.Doc?
---@return string? reason
function Workspace:load_external(from, path)
  if not from.real_dir or not self.root then
    return nil, "no base path"
  end
  if path:sub(1, 1) == "/" then
    return nil, "outside root"
  end
  local target = collapse(from.real_dir .. "/" .. path)
  if not is_inside(self.root, target) then
    return nil, "outside root"
  end
  if not (target:match("%.ya?ml$") or target:match("%.json$")) then
    return nil, "bad file type"
  end

  local real, reason = self:_walk_to_real(target)
  if not real then
    return nil, reason
  end

  local cached = self._docs[real]
  if cached then
    return cached
  end
  if self._failed[real] then
    return nil, self._failed[real]
  end

  local stat = vim.uv.fs_stat(real)
  if not stat then
    return nil, "not found"
  end
  if stat.type ~= "file" then
    return nil, "bad file type"
  end
  if stat.size > self.max_file_bytes then
    return nil, "too large"
  end
  if #self._loaded >= self.max_files then
    return nil, "too many files"
  end

  local text = read_file(real)
  if not text then
    return nil, "not found"
  end
  self._loaded[#self._loaded + 1] = real

  local doc = safe_parse(text, { file = real })
  if not doc then
    self._failed[real] = "parse failed"
    return nil, "parse failed"
  end
  -- Before the cache and the pointer walk, so `parse failed` cannot stand in for it.
  if tree.line_limit(text, tree.has_error(doc)) then
    self._failed[real] = "too many lines"
    return nil, "too many lines"
  end
  doc.identity = real
  doc.real_dir = dirname(real)
  self._docs[real] = doc
  return doc
end

--- Real paths of the external files read so far, in load order.
---@return string[]
function Workspace:loaded_files()
  return vim.list_slice(self._loaded)
end

return M
