local curl = require("oas-glance.internal.curl")
local detail = require("oas-glance.internal.render.detail")
local highlights = require("oas-glance.internal.highlights")
local lines = require("oas-glance.internal.render.lines")
local list = require("oas-glance.internal.render.list")
local model = require("oas-glance.internal.model")
local tree = require("oas-glance.internal.tree")
local workspace = require("oas-glance.internal.workspace")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("oas-glance")
local BASE_PRIORITY = 100
local AUGROUP = vim.api.nvim_create_augroup("oas-glance-ui", { clear = true })
local HEADER_ROW = 2
local BOM_BYTES = 3
local SEP = "\31"
local REPLACEMENT = "\239\191\189"

local MESSAGES = {
  missing = "oas-glance: the tree-sitter \"yaml\" parser was not found on 'runtimepath' (parser/yaml.*). See :help oas-glance-parser",
  load = 'oas-glance: cannot load the tree-sitter "yaml" parser: %s',
  read = "oas-glance: cannot read %s: %s",
  not_openapi = "oas-glance: not an OpenAPI document: %s",
  swagger = "oas-glance: OpenAPI 2.0 (Swagger) is not supported yet: %s. Supported versions: 3.0, 3.1.",
  unsupported = "oas-glance: OpenAPI %s is not supported: %s. Supported versions: 3.0, 3.1.",
  buffer_gone = "oas-glance: the source buffer no longer exists",
  not_regular = "oas-glance: the source file is no longer a regular file",
  lines = 'oas-glance: %s has %d lines; the tree-sitter "yaml" parser fails on YAML over 32768 lines. Convert it to JSON to view it. See :help oas-glance-limits',
  curl_none = "oas-glance: show an operation to build a cURL command",
  curl_broken = "oas-glance: this path item did not load, so no cURL command is built",
  curl_webhook = "oas-glance: a webhook has no server URL, so no cURL command is built",
}

local CURL_MIN_HEIGHT = 3
local CURL_MAX_HEIGHT = 15

---@class oas_glance.Session
---@field identity string
---@field config table
---@field tabpage integer
---@field list_win integer
---@field detail_win integer
---@field list_buf integer
---@field detail_buf integer
---@field document table
---@field file_name string
---@field origin_win integer
---@field file string? The real path of a document opened by `:OasGlance {file}`.
---@field display string The name for messages, as given or as the buffer holds it.
---@field root string? The ref root found at open, as an absolute path.
---@field source_buf integer?
---@field list_open table<string, boolean>
---@field filter string? The active filter. Nil when none is active.
---@field list_result oas_glance.RenderResult?
---@field list_row integer? The list row last shown, 1-based.
---@field shown_count integer? The problem count the header row shows.
---@field target table?
---@field detail_result oas_glance.RenderResult?
---@field detail_open table<any, table<string, boolean|string>>
---@field history { target: table, cursor: integer }[]
---@field pane_name string The list buffer's name, which the other buffers' names extend.
---@field curl_buf integer?
---@field curl_win integer?
---@field curl_key string? The `target_key` of the operation last built into the cURL buffer.

---@type table<string, oas_glance.Session>
local sessions = {}

---@param message string
local function fatal(message)
  vim.notify(message, vim.log.levels.ERROR)
end

--- A libuv error reads `ENOENT: no such file or directory: /path`. The message names the file already.
---@param reason string?
---@return string
local function read_reason(reason)
  reason = reason or "unknown error"
  return reason:match("^E%u+: ([^:]+)") or reason
end

---@param session oas_glance.Session?
---@return boolean
local function is_alive(session)
  return session ~= nil
    and vim.api.nvim_tabpage_is_valid(session.tabpage)
    and vim.api.nvim_buf_is_valid(session.list_buf)
    and vim.api.nvim_buf_is_valid(session.detail_buf)
end

---@param identity string
---@return boolean focused
local function focus(identity)
  local session = sessions[identity]
  if not is_alive(session) then
    sessions[identity] = nil
    return false
  end
  ---@cast session oas_glance.Session
  if vim.api.nvim_get_current_tabpage() ~= session.tabpage then
    vim.api.nvim_set_current_tabpage(session.tabpage)
  end
  return true
end

---@param buf integer
---@param spans oas_glance.Span[]
---@param only_row integer? Adds the spans of this row alone.
local function add_spans(buf, spans, only_row)
  for _, span in ipairs(spans) do
    if span.end_col > span.col and (only_row == nil or span.row == only_row) then
      vim.api.nvim_buf_set_extmark(buf, NAMESPACE, span.row, span.col, {
        end_col = span.end_col,
        hl_group = span.group,
        priority = span.priority or BASE_PRIORITY,
      })
    end
  end
end

---@param buf integer
---@param result oas_glance.RenderResult
local function write(buf, result)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
  add_spans(buf, result.spans)
end

---@param session oas_glance.Session
---@return table
local function render_options(session)
  local config = session.config
  return {
    icons = config.icons,
    max_detail_rows = config.max_detail_rows,
    max_depth = config.refs.max_depth,
  }
end

---@param session oas_glance.Session
---@return integer
local function problem_count(session)
  return detail.problem_count(model.diagnostics(session.document))
end

---@param session oas_glance.Session
---@param count integer
---@return oas_glance.RenderResult
local function list_result(session, count)
  local opts = render_options(session)
  opts.open = session.list_open
  opts.problem_count = count
  opts.filter = session.filter
  return list.render(session.document, opts)
end

---@param session oas_glance.Session
local function render_list(session)
  session.shown_count = problem_count(session)
  session.list_result = list_result(session, session.shown_count)
  write(session.list_buf, session.list_result)
end

--- Redraws the header row alone, and only when the count changed, so list rows and the cursor stay put.
---@param session oas_glance.Session
local function refresh_count(session)
  local count = problem_count(session)
  if count == session.shown_count then
    return
  end
  session.shown_count = count
  -- The filter line replaces the header rows, and clearing the filter renders the list in full.
  if session.filter then
    return
  end
  local result = list_result(session, count)
  session.list_result = result
  local buf = session.list_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, HEADER_ROW, HEADER_ROW + 1, false, { result.lines[HEADER_ROW + 1] })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, HEADER_ROW, HEADER_ROW + 1)
  add_spans(buf, result.spans, HEADER_ROW)
end

--- The key of a view and its expansion state. It is text from the document, so it survives a reload.
--- A schema reached by `definition` that is not listed uses its ref key.
---@param target table
---@return string
local function target_key(target)
  local operation = target.operation
  if operation then
    return table.concat({ "operation", operation.section or "", operation.path or "", operation.method or "" }, SEP)
  end
  if target.view_key then
    return target.view_key
  end
  if target.schema then
    return "schema" .. SEP .. tostring(target.schema.key)
  end
  return target.kind
end

---@param a table?
---@param b table
---@return boolean
local function same_target(a, b)
  return a ~= nil and a.kind == b.kind and target_key(a) == target_key(b)
end

---@param session oas_glance.Session
---@param target table
---@return oas_glance.RenderResult
local function render_target(session, target)
  local document = session.document
  local opts = render_options(session)
  local key = target_key(target)
  session.detail_open[key] = session.detail_open[key] or {}
  opts.open = session.detail_open[key]
  opts.resolve = function(ref)
    return model.open_ref(document, ref)
  end
  opts.report = function(ref)
    model.report_broken(document, ref)
  end

  if target.kind == "operation" then
    return detail.operation(model.operation(document, target.operation), opts)
  end
  if target.kind == "schema" then
    return detail.schema(target.schema, target.value or model.schema(document, target.schema), opts)
  end
  if target.kind == "help" then
    opts.keymaps = session.config.keymaps
    return detail.help(opts)
  end
  opts.diagnostics = model.diagnostics(document)
  opts.file_name = session.file_name
  opts.file = document._doc.file
  return detail.overview(document, opts)
end

---@param win integer
---@param buf integer
---@param row integer 1-based.
local function set_row(win, buf, row)
  vim.api.nvim_win_set_cursor(win, { math.max(math.min(row, vim.api.nvim_buf_line_count(buf)), 1), 0 })
end

--- Renders the detail pane again, for the same target, keeping the cursor row.
---@param session oas_glance.Session
local function redraw_detail(session)
  local row = vim.api.nvim_win_get_cursor(session.detail_win)[1]
  session.detail_result = render_target(session, session.target)
  write(session.detail_buf, session.detail_result)
  set_row(session.detail_win, session.detail_buf, row)
  refresh_count(session)
end

---@type fun(session: oas_glance.Session, force: boolean?)
local refresh_curl

--- Shows a target in the detail pane. An unchanged target is not rendered again unless `force` is set.
--- `curl_rebuild` rebuilds an open cURL window even for the operation it already holds.
---@param session oas_glance.Session
---@param target table
---@param opts? { force?: boolean, cursor?: integer, curl_rebuild?: boolean }
local function show(session, target, opts)
  opts = opts or {}
  if not opts.force and same_target(session.target, target) then
    return
  end
  session.target = target
  session.detail_result = render_target(session, target)
  write(session.detail_buf, session.detail_result)
  set_row(session.detail_win, session.detail_buf, opts.cursor or 1)
  refresh_count(session)
  refresh_curl(session, opts.curl_rebuild)
end

---@param session oas_glance.Session
---@return oas_glance.RowAction?
local function list_action(session)
  local row = vim.api.nvim_win_get_cursor(session.list_win)[1] - 1
  return session.list_result and session.list_result.rows[row]
end

---@param session oas_glance.Session
---@return oas_glance.RowAction?
local function detail_action(session)
  local row = vim.api.nvim_win_get_cursor(session.detail_win)[1] - 1
  return session.detail_result and session.detail_result.rows[row]
end

--- Entering the list also fires `CursorMoved`, so only a change of row counts as moving onto it.
---@param session oas_glance.Session
local function preview(session)
  local row = vim.api.nvim_win_get_cursor(session.list_win)[1]
  if row == session.list_row then
    return
  end
  session.list_row = row
  local action = list_action(session)
  if action and action.select and not same_target(session.target, action.select) then
    session.history = {}
    show(session, action.select)
  end
end

---@param session oas_glance.Session
---@param key string
local function toggle_group(session, key)
  -- Groups are held open while filtering, so their own state is left for when the filter clears.
  if session.filter then
    return
  end
  session.list_open[key] = session.list_open[key] == false
  local cursor = vim.api.nvim_win_get_cursor(session.list_win)
  render_list(session)
  set_row(session.list_win, session.list_buf, cursor[1])
end

--- The 1-based row that still shows what `before` showed, if any.
---@param session oas_glance.Session
---@param before oas_glance.RowAction?
---@return integer?
local function same_row(session, before)
  if not before then
    return nil
  end
  local rows = session.list_result.rows
  for row = 0, #session.list_result.lines - 1 do
    local action = rows[row]
    if action then
      local same_select = before.select and action.select and same_target(before.select, action.select)
      local same_toggle = before.toggle and action.toggle == before.toggle
      if same_select or same_toggle then
        return row + 1
      end
    end
  end
  return nil
end

--- The 1-based row of the first operation or schema.
---@param session oas_glance.Session
---@return integer?
local function first_match(session)
  local rows = session.list_result.rows
  for row = 0, #session.list_result.lines - 1 do
    local select = rows[row] and rows[row].select
    if select and (select.kind == "operation" or select.kind == "schema") then
      return row + 1
    end
  end
  return nil
end

--- Sets the filter, or clears it with nil. A hidden selection moves to the first match, as a new selection.
---@param session oas_glance.Session
---@param text string?
local function set_filter(session, text)
  if text == session.filter then
    return
  end
  local before = list_action(session)
  session.filter = text
  render_list(session)
  local kept = same_row(session, before)
  if kept then
    session.list_row = kept
    vim.api.nvim_win_set_cursor(session.list_win, { kept, 0 })
    return
  end
  vim.api.nvim_win_set_cursor(session.list_win, { first_match(session) or 1, 0 })
  session.list_row = nil
  preview(session)
end

---@param session oas_glance.Session
local function prompt_filter(session)
  vim.ui.input({ prompt = "Filter: ", default = session.filter }, function(input)
    if input == nil or not is_alive(session) then
      return
    end
    local text = vim.trim(input)
    set_filter(session, text ~= "" and text or nil)
  end)
end

---@param session oas_glance.Session
local function toggle_detail(session)
  local action = detail_action(session)
  if not action or not action.toggle then
    return
  end
  local state = not action.expanded
  if state and action.ref then
    state = action.ref.target
  end
  session.detail_open[target_key(session.target)][action.toggle] = state
  redraw_detail(session)
end

---@param session oas_glance.Session
---@param key string?
---@return table? schema_ref
local function listed_schema(session, key)
  for _, schema_ref in ipairs(key and session.document.schemas or {}) do
    if schema_ref.key == key then
      return schema_ref
    end
  end
  return nil
end

--- Moves the list cursor onto a listed schema's row, if that row is drawn.
---@param session oas_glance.Session
---@param schema_ref table
local function select_in_list(session, schema_ref)
  for row, action in pairs(session.list_result.rows) do
    if action.select and action.select.schema == schema_ref then
      session.list_row = row + 1
      vim.api.nvim_win_set_cursor(session.list_win, { row + 1, 0 })
      return
    end
  end
end

---@param session oas_glance.Session
local function definition(session)
  local action = detail_action(session)
  if not action or not action.ref or action.broken or action.ref.status == "broken" then
    return
  end
  local ref = action.ref --[[@as table]]
  local schema = model.open_ref(session.document, ref)
  if not schema then
    -- The checks failed, so the row becomes broken in place and the view stays.
    redraw_detail(session)
    return
  end

  local listed = listed_schema(session, ref.key)
  local target
  if listed then
    target = { kind = "schema", schema = listed }
  else
    target = {
      kind = "schema",
      schema = { name = ref.name or ref.target, key = ref.key, pos = schema.pos },
      value = schema,
      view_key = "ref" .. SEP .. tostring(ref.key),
    }
  end
  local history = session.history
  history[#history + 1] = { target = session.target, cursor = vim.api.nvim_win_get_cursor(session.detail_win)[1] }
  show(session, target, { force = true })
  if listed then
    select_in_list(session, listed)
  end
end

---@param session oas_glance.Session
local function back(session)
  local entry = table.remove(session.history)
  if entry then
    show(session, entry.target, { force = true, cursor = entry.cursor })
  end
end

---@param win integer?
---@return boolean
local function is_source_window(win)
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.b[vim.api.nvim_win_get_buf(win)].oas_glance_identity == nil
end

--- The window to open a source in: the start window, or a new tabpage if it is gone or shows a pane.
---@param session oas_glance.Session
local function source_window(session)
  if is_source_window(session.origin_win) then
    vim.api.nvim_set_current_win(session.origin_win)
  else
    vim.api.nvim_cmd({ cmd = "tabnew" }, {})
    session.origin_win = vim.api.nvim_get_current_win()
  end
end

---@param session oas_glance.Session
---@param pos oas_glance.Pos?
local function jump(session, pos)
  if not pos or (not pos.file and not pos.bufnr) then
    return
  end
  if pos.bufnr then
    if not vim.api.nvim_buf_is_valid(pos.bufnr) then
      vim.notify(MESSAGES.buffer_gone, vim.log.levels.WARN)
      return
    end
    source_window(session)
    vim.api.nvim_win_set_buf(0, pos.bufnr)
  else
    -- The file was regular when it was read, but reading a FIFO put there since would block Neovim.
    local stat = vim.uv.fs_stat(pos.file)
    if stat and stat.type ~= "file" then
      vim.notify(MESSAGES.not_regular, vim.log.levels.WARN)
      return
    end
    source_window(session)
    -- No command is built from the name, which can hold a newline. `:edit` would also refuse a modified
    -- buffer of the same file, while this reuses it.
    local buf = vim.fn.bufadd(pos.file)
    vim.bo[buf].buflisted = true
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(0, buf)
  end

  local buf = vim.api.nvim_get_current_buf()
  local row = math.min(pos.row, vim.api.nvim_buf_line_count(buf) - 1)
  local col = pos.col
  -- Neovim drops a BOM when it reads a file, and buffer text never had one.
  if not pos.bufnr and pos.row == 0 and vim.bo[buf].bomb then
    col = math.max(col - BOM_BYTES, 0)
  end
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  col = math.max(math.min(col, #line - 1), 0)
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
end

--- The operation target to build for: the one shown, or after `gd` the latest one in the history.
---@param session oas_glance.Session
---@return table? target
---@return string? message A key of `MESSAGES` when nothing is built.
local function curl_target(session)
  local target = session.target
  if target and target.kind == "schema" then
    target = nil
    for index = #session.history, 1, -1 do
      if session.history[index].target.kind == "operation" then
        target = session.history[index].target
        break
      end
    end
  end
  if not target or target.kind ~= "operation" then
    return nil, "curl_none"
  end
  local row = target.operation
  if row.broken then
    return nil, "curl_broken"
  end
  if row.section == "webhooks" then
    return nil, "curl_webhook"
  end
  return target
end

---@param session oas_glance.Session
---@return integer
local function curl_buffer(session)
  if session.curl_buf and vim.api.nvim_buf_is_valid(session.curl_buf) then
    return session.curl_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sh"
  vim.b[buf].oas_glance_identity = session.identity
  -- The name was free at open, but another buffer may have taken it since.
  pcall(vim.api.nvim_buf_set_name, buf, session.pane_name .. ":curl")
  session.curl_buf = buf
  return buf
end

--- Builds the command for an operation target into the buffer, as one undoable change.
---@param session oas_glance.Session
---@param target table
---@param buf integer
local function fill_curl(session, target, buf)
  local document = session.document
  local text =
    curl.build(document, model.operation(document, target.operation), { max_depth = session.config.refs.max_depth })
  -- Ends the undo block, so `u` restores the text before the replacement and nothing else.
  vim.api.nvim_buf_call(buf, function()
    vim.go.undolevels = vim.go.undolevels
  end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  session.curl_key = target_key(target)
end

--- The cURL window is valid, in the session's tabpage, and shows the cURL buffer.
---@param session oas_glance.Session
---@return boolean
local function curl_window_open(session)
  local win, buf = session.curl_win, session.curl_buf
  return win ~= nil
    and buf ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_win_get_tabpage(win) == session.tabpage
    and vim.api.nvim_win_get_buf(win) == buf
end

--- Builds the command and shows it in the split below the detail pane, which gets focus.
---@param session oas_glance.Session
local function open_curl(session)
  local target, message = curl_target(session)
  if not target then
    vim.notify(MESSAGES[message], vim.log.levels.WARN)
    return
  end
  local buf = curl_buffer(session)
  fill_curl(session, target, buf)
  local win = session.curl_win
  if curl_window_open(session) then
    ---@cast win integer
    vim.api.nvim_set_current_win(win)
  else
    win = vim.api.nvim_open_win(buf, true, { split = "below", win = session.detail_win })
    session.curl_win = win
    vim.api.nvim_set_option_value("winfixheight", true, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("statusline", " oas-glance curl", { win = win, scope = "local" })
    -- Screen lines, so a wrapped line does not push the last one out of view.
    local screen_lines = vim.api.nvim_win_text_height(win, {}).all
    vim.api.nvim_win_set_config(win, { height = math.min(math.max(screen_lines, CURL_MIN_HEIGHT), CURL_MAX_HEIGHT) })
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  -- Generating the body may have opened refs, and found some broken.
  redraw_detail(session)
end

--- Rebuilds an open cURL window for the operation now shown, without moving focus.
--- The same operation is skipped unless `force` is set, so edits survive `gd` and back.
refresh_curl = function(session, force)
  if not curl_window_open(session) then
    return
  end
  local target = session.target
  if not target or target.kind ~= "operation" or target.operation.broken or target.operation.section == "webhooks" then
    return
  end
  if not force and target_key(target) == session.curl_key then
    return
  end
  local win = session.curl_win --[[@as integer]]
  local buf = session.curl_buf --[[@as integer]]
  -- An error from a `CursorMoved` callback would show on every move.
  if not vim.bo[buf].modifiable then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  fill_curl(session, target, buf)
  set_row(win, buf, row)
  redraw_detail(session)
end

---@param session oas_glance.Session
local function close(session)
  sessions[session.identity] = nil
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(session.tabpage)
    vim.api.nvim_cmd({ cmd = "tabclose" }, {})
    return
  end
  -- Closing the last tabpage would quit Neovim, so an empty window replaces the panes.
  vim.api.nvim_set_current_win(session.list_win)
  vim.api.nvim_cmd({ cmd = "enew" }, {})
  vim.api.nvim_cmd({ cmd = "only" }, {})
end

--- Closes the session and wipes its buffers, also one still shown elsewhere, so their names are free.
---@param session oas_glance.Session
local function close_and_wipe(session)
  close(session)
  for _, buf in ipairs({ session.list_buf, session.detail_buf, session.curl_buf or -1 }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

---@type fun(session: oas_glance.Session)
local reload

---@param session oas_glance.Session
---@return table<string, table<string, fun()>>
local function handlers(session)
  local function help()
    show(session, { kind = "help" })
  end
  local function close_session()
    close_and_wipe(session)
  end
  local function reload_session()
    reload(session)
  end
  local function curl_command()
    open_curl(session)
  end
  return {
    list = {
      select = function()
        local action = list_action(session)
        if action and action.toggle then
          toggle_group(session, action.toggle)
        else
          vim.api.nvim_set_current_win(session.detail_win)
        end
      end,
      toggle = function()
        local action = list_action(session)
        if action and action.toggle then
          toggle_group(session, action.toggle)
        end
      end,
      filter = function()
        prompt_filter(session)
      end,
      clear_filter = function()
        set_filter(session, nil)
      end,
      source = function()
        local action = list_action(session)
        jump(session, action and action.pos)
      end,
      curl = curl_command,
      reload = reload_session,
      help = help,
      close = close_session,
    },
    detail = {
      toggle = function()
        toggle_detail(session)
      end,
      definition = function()
        definition(session)
      end,
      back = function()
        back(session)
      end,
      source = function()
        local action = detail_action(session)
        jump(session, action and action.pos)
      end,
      curl = curl_command,
      reload = reload_session,
      help = help,
      close = close_session,
    },
  }
end

---@param value string|string[]|false
---@return string[]
local function keys_of(value)
  if value == false or value == nil then
    return {}
  end
  if type(value) == "table" then
    return value
  end
  return { value }
end

---@param session oas_glance.Session
local function set_keymaps(session)
  local actions = handlers(session)
  for _, pane in ipairs({ "list", "detail" }) do
    local buf = pane == "list" and session.list_buf or session.detail_buf
    local configured = session.config.keymaps[pane]
    local names = vim.tbl_keys(actions[pane])
    table.sort(names)
    for _, name in ipairs(names) do
      for _, lhs in ipairs(keys_of(configured[name])) do
        vim.keymap.set("n", lhs, actions[pane][name], {
          buffer = buf,
          nowait = true,
          silent = true,
          desc = "oas-glance " .. pane .. " " .. name,
        })
      end
    end
  end
end

---@param filetype string
---@param identity string
---@return integer
local function create_buffer(filetype, identity)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  vim.b[buf].oas_glance_identity = identity
  return buf
end

---@param name string
---@return boolean
local function name_taken(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return true
    end
  end
  return false
end

--- `oas-glance://{name}` and `oas-glance://{name}:detail`, with the lowest number that leaves both free and
--- `:curl` too, so the cURL buffer created later can take that name.
---@param session oas_glance.Session
local function name_panes(session)
  local base = lines.clean(session.file_name):gsub("\n", REPLACEMENT)
  local number = 1
  while true do
    local name = "oas-glance://" .. base .. (number == 1 and "" or string.format(" (%d)", number))
    local detail_name = name .. ":detail"
    if not name_taken(name) and not name_taken(detail_name) and not name_taken(name .. ":curl") then
      vim.api.nvim_buf_set_name(session.list_buf, name)
      vim.api.nvim_buf_set_name(session.detail_buf, detail_name)
      session.pane_name = name
      return
    end
    number = number + 1
  end
end

---@param win integer
---@param options table<string, any>
local function set_window_options(win, options)
  local names = vim.tbl_keys(options)
  table.sort(names)
  for _, name in ipairs(names) do
    vim.api.nvim_set_option_value(name, options[name], { win = win, scope = "local" })
  end
end

local COMMON_WINDOW = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = true,
  list = false,
  spell = false,
  colorcolumn = "",
  fillchars = "eob: ",
}

---@param session oas_glance.Session
local function open_windows(session)
  vim.api.nvim_cmd({ cmd = "sbuffer", args = { tostring(session.list_buf) }, mods = { tab = vim.fn.tabpagenr() } }, {})
  session.tabpage = vim.api.nvim_get_current_tabpage()
  session.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_cmd(
    { cmd = "sbuffer", args = { tostring(session.detail_buf) }, mods = { vertical = true, split = "belowright" } },
    {}
  )
  session.detail_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(session.list_win)

  set_window_options(
    session.list_win,
    vim.tbl_extend("force", COMMON_WINDOW, { wrap = false, winfixwidth = true, statusline = " oas-glance list" })
  )
  set_window_options(
    session.detail_win,
    vim.tbl_extend(
      "force",
      COMMON_WINDOW,
      { wrap = true, linebreak = true, breakindent = true, statusline = " oas-glance detail" }
    )
  )
  vim.api.nvim_win_set_config(session.list_win, { width = session.config.list_width })
end

--- Reads the document, or reports the fatal message and returns nil.
--- A reload passes the display name and the ref root found at open, so neither depends on the cwd later.
---@param config table
---@param file string?
---@param bufnr integer
---@param again? { display: string, root: string? }
---@return table? document
---@return string? identity
---@return string? display
---@return string? root The ref root, as an absolute path.
local function read_document(config, file, bufnr, again)
  local name = file == nil and vim.api.nvim_buf_get_name(bufnr) or nil
  local display = again and again.display or file or vim.fn.bufname(bufnr)
  if display == "" then
    display = "[No Name]"
  end

  local ws = workspace.new({
    root = again and again.root or config.refs.root,
    max_files = config.refs.max_files,
    max_file_bytes = config.refs.max_file_bytes,
    max_depth = config.refs.max_depth,
  })
  local doc, err
  if file then
    doc, err = ws:open_file(file)
  else
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
    doc, err = ws:open_text(text, { name = name ~= "" and name or nil, bufnr = bufnr })
  end
  if not doc then
    err = err or {}
    if err.kind == "missing" then
      fatal(MESSAGES.missing)
    elseif err.kind == "load" then
      fatal(MESSAGES.load:format(err.reason or "unknown error"))
    elseif err.kind == "lines" then
      fatal(MESSAGES.lines:format(display, err.n))
    else
      fatal(MESSAGES.read:format(display, read_reason(err.reason)))
    end
    return nil
  end

  local document, classification = model.load(ws, doc)
  if not document then
    if classification.kind == "swagger" then
      fatal(MESSAGES.swagger:format(display))
    elseif classification.kind == "unsupported" then
      fatal(MESSAGES.unsupported:format(classification.version, display))
    else
      fatal(MESSAGES.not_openapi:format(display))
    end
    return nil
  end
  return document, doc.identity, display, ws.root
end

--- Reads the document again. A failure gives its fatal message and leaves the view as it was.
--- The history goes, because it holds targets of the old model. Fold and expansion state are keyed by
--- text, so they hold wherever the same group, view and tree path still exist.
reload = function(session)
  if session.source_buf and not vim.api.nvim_buf_is_valid(session.source_buf) then
    fatal(MESSAGES.buffer_gone)
    return
  end
  local document = read_document(
    session.config,
    session.file,
    session.source_buf or 0,
    { display = session.display, root = session.root }
  )
  if not document then
    return
  end

  local old = session.target
  local old_key = old and target_key(old)
  local detail_row = vim.api.nvim_win_get_cursor(session.detail_win)[1]
  session.document = document
  session.history = {}
  render_list(session)

  if old and (old.kind == "overview" or old.kind == "help") then
    show(session, old, { force = true, cursor = detail_row, curl_rebuild = true })
    return
  end
  local rows = session.list_result.rows
  for row = 0, #session.list_result.lines - 1 do
    local select = rows[row] and rows[row].select
    if select and target_key(select) == old_key then
      session.list_row = row + 1
      vim.api.nvim_win_set_cursor(session.list_win, { row + 1, 0 })
      show(session, select, { force = true, cursor = detail_row, curl_rebuild = true })
      return
    end
  end
  -- The old target is gone, or was not listed, so the row under the cursor is shown.
  session.list_row = vim.api.nvim_win_get_cursor(session.list_win)[1]
  local action = list_action(session)
  show(session, action and action.select or { kind = "overview" }, { force = true, curl_rebuild = true })
end

--- Opens the viewer for a file, or for the current buffer when `file` is nil.
---@param config table The merged config from `init.lua`.
---@param file string?
function M.open(config, file)
  local current_win = vim.api.nvim_get_current_win()
  -- A pane of any session is never a start window, because its buffer is wiped when replaced.
  local origin_win = is_source_window(current_win) and current_win or -1
  local bufnr = vim.api.nvim_get_current_buf()
  if not file then
    local own = vim.b[bufnr].oas_glance_identity
    if own and focus(own) then
      return
    end
  end

  local ok, kind, reason = tree.parser_status()
  if not ok then
    fatal(kind == "missing" and MESSAGES.missing or MESSAGES.load:format(reason or "unknown error"))
    return
  end

  local identity
  if file then
    identity = workspace.identity({ file = file })
  else
    local name = vim.api.nvim_buf_get_name(bufnr)
    identity = workspace.identity({ name = name ~= "" and name or nil, bufnr = bufnr })
  end
  if focus(identity) then
    return
  end

  local document, doc_identity, display, root = read_document(config, file, bufnr)
  if not document then
    return
  end
  ---@cast doc_identity string
  ---@cast display string

  highlights.setup()
  local session = {
    identity = doc_identity,
    config = config,
    document = document,
    file_name = vim.fs.basename(display),
    origin_win = origin_win,
    -- The real path, so `R` reads the same file after a change of the cwd.
    file = file and doc_identity or nil,
    display = display,
    root = root,
    source_buf = file == nil and bufnr or nil,
    list_open = {},
    detail_open = {},
    history = {},
  }
  session.list_buf = create_buffer("oasglance-list", doc_identity)
  session.detail_buf = create_buffer("oasglance-detail", doc_identity)
  ---@cast session oas_glance.Session
  sessions[doc_identity] = session
  name_panes(session)

  open_windows(session)
  set_keymaps(session)
  render_list(session)
  vim.api.nvim_win_set_cursor(session.list_win, { 1, 0 })
  preview(session)

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = AUGROUP,
    buffer = session.list_buf,
    callback = function()
      preview(session)
    end,
  })
end

return M
