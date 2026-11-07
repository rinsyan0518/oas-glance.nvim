local helpers = dofile("tests/helpers.lua")

local child = helpers.new_child()
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.boot()
      child.lua([[
        _G.notes = {}
        vim.notify = function(message, level)
          table.insert(_G.notes, { message = message, level = level })
        end
      ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local PETSTORE = "tests/fixtures/petstore-31.yaml"
local WARN = vim.log.levels.WARN

local function pane(filetype)
  return child.lua(
    [[
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == ... then
        return { win = win, buf = buf }
      end
    end
  ]],
    { filetype }
  )
end

local function lines(filetype)
  return child.api.nvim_buf_get_lines(pane(filetype).buf, 0, -1, false)
end

local function list_lines()
  return lines("oasglance-list")
end

local function detail_lines()
  return lines("oasglance-detail")
end

local function current_filetype()
  return child.lua_get("vim.bo.filetype")
end

local function row_of(all, text)
  for index, line in ipairs(all) do
    if line:find(text, 1, true) then
      return index
    end
  end
  error("no line with " .. text .. " in:\n" .. table.concat(all, "\n"), 0)
end

--- Moves the list cursor to the first row holding `text`, with a motion, so `CursorMoved` runs.
local function list_goto(text)
  child.api.nvim_set_current_win(pane("oasglance-list").win)
  child.type_keys(tostring(row_of(list_lines(), text)) .. "G")
end

local function setup(opts)
  child.lua("require('oas-glance').setup(...)", { opts })
end

local function keys_of(filetype)
  local buf = pane(filetype).buf
  local found = {}
  for _, map in ipairs(child.api.nvim_buf_get_keymap(buf, "n")) do
    found[map.lhs] = map.desc
  end
  return found
end

local function temp_path(name)
  return child.lua_get("vim.fn.tempname()") .. "-" .. name
end

local function write_file(path, text_lines)
  child.fn.writefile(text_lines, path)
end

local function alias_doubling(levels)
  local out = {
    "openapi: 3.1.0",
    "info: { title: Doubling, version: '1' }",
    "paths: {}",
    "x-levels:",
    "  l0: &l0",
    "    type: string",
  }
  for level = 1, levels do
    out[#out + 1] = string.format("  l%d: &l%d", level, level)
    out[#out + 1] = "    properties:"
    out[#out + 1] = string.format("      a: *l%d", level - 1)
    out[#out + 1] = string.format("      b: *l%d", level - 1)
  end
  out[#out + 1] = "components:"
  out[#out + 1] = "  schemas:"
  out[#out + 1] = string.format("    Top: *l%d", levels)
  return out
end

-- Opening

T["open"] = MiniTest.new_set()

T["open"]["the current buffer shows its unsaved text"] = function()
  child.cmd("edit " .. PETSTORE)
  child.api.nvim_buf_set_lines(0, 2, 3, false, { "  title: Edited" })
  child.cmd("OasGlance")
  expect.equality(list_lines()[1], " Edited 1.0.0")
  expect.equality(child.fn.tabpagenr("$"), 2)
end

T["open"]["a file argument reads the disk"] = function()
  child.cmd("edit " .. PETSTORE)
  child.api.nvim_buf_set_lines(0, 2, 3, false, { "  title: Edited" })
  child.cmd("tabnew")
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(list_lines()[1], " Petstore 1.0.0")
end

T["open"]["a file name with a space, % and #"] = function()
  local path = temp_path("a b%c#d.yaml")
  child.fn.writefile(child.fn.readfile(PETSTORE), path)
  -- -complete=file expands `%` and `#` as `:edit` does, so the name is escaped as for `:edit`.
  child.cmd("OasGlance " .. child.fn.fnameescape(path))
  expect.equality(child.lua_get("_G.notes"), {})
  expect.equality(list_lines()[1], " Petstore 1.0.0")
end

-- Layout

T["layout"] = MiniTest.new_set()

T["layout"]["windows, buffers and options follow spec 6"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local list, detail = pane("oasglance-list"), pane("oasglance-detail")
  expect.equality(current_filetype(), "oasglance-list")
  expect.equality(child.api.nvim_win_get_width(list.win), 36)
  expect.equality(child.api.nvim_win_get_width(detail.win), 43)

  local function wo(win, name)
    return child.api.nvim_get_option_value(name, { win = win })
  end
  local function bo(buf, name)
    return child.api.nvim_get_option_value(name, { buf = buf })
  end
  expect.equality(
    { wo(list.win, "winfixwidth"), wo(list.win, "wrap"), wo(list.win, "statusline") },
    { true, false, " oas-glance list" }
  )
  expect.equality(
    { wo(detail.win, "wrap"), wo(detail.win, "linebreak"), wo(detail.win, "breakindent") },
    { true, true, true }
  )
  expect.equality(wo(detail.win, "statusline"), " oas-glance detail")
  for _, win in ipairs({ list.win, detail.win }) do
    expect.equality(
      { wo(win, "number"), wo(win, "relativenumber"), wo(win, "signcolumn"), wo(win, "cursorline") },
      { false, false, "no", true }
    )
  end
  for _, buf in ipairs({ list.buf, detail.buf }) do
    expect.equality({ bo(buf, "buftype"), bo(buf, "modifiable") }, { "nofile", false })
  end
end

T["layout"]["list_width is honoured"] = function()
  setup({ list_width = 30 })
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(child.api.nvim_win_get_width(pane("oasglance-list").win), 30)
end

T["layout"]["no window floats"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("?")
  local relative = child.lua([[
    local found = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      found[#found + 1] = vim.api.nvim_win_get_config(win).relative
    end
    return found
  ]])
  for _, value in ipairs(relative) do
    expect.equality(value, "")
  end
end

-- Moving and actions

T["actions"] = MiniTest.new_set()

T["actions"]["the header row shows the overview"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(detail_lines()[1], "Petstore 1.0.0")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 0 })
end

T["actions"]["moving updates the detail pane without moving focus"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("j")
  expect.equality(detail_lines()[1], "Petstore 1.0.0")
  list_goto("GET     /pets/{petId}")
  expect.equality(detail_lines()[1], "GET /pets/{petId}")
  expect.equality(current_filetype(), "oasglance-list")
  list_goto("NewPet")
  expect.equality(detail_lines()[1], "NewPet  object")
end

T["actions"]["an unchanged target is not rendered again"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local buf = pane("oasglance-detail").buf
  local tick = child.api.nvim_buf_get_changedtick(buf)
  child.type_keys("j")
  child.type_keys("j")
  expect.equality(child.api.nvim_buf_get_changedtick(buf), tick)
  list_goto("POST    /pets")
  expect.equality(child.api.nvim_buf_get_changedtick(buf) > tick, true)
end

T["actions"]["a group row keeps the detail pane"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /health")
  list_goto("(untagged)")
  expect.equality(detail_lines()[1], "GET /health")
end

T["actions"]["<CR> and za toggle a group"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("▾ pets 4")
  child.type_keys("<CR>")
  expect.equality(list_lines()[5], "▸ pets 4")
  expect.equality(list_lines()[6], "▾ store 1")
  expect.equality(child.api.nvim_win_get_cursor(0), { 5, 0 })
  child.type_keys("za")
  expect.equality(list_lines()[5], "▾ pets 4")
  expect.equality(list_lines()[6], "   GET     /pets")
  expect.equality(current_filetype(), "oasglance-list")
end

T["actions"]["<CR> on another row focuses the detail pane"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("POST    /pets")
  child.type_keys("<CR>")
  expect.equality(current_filetype(), "oasglance-detail")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, 1, false), { "POST /pets" })
end

T["actions"]["za on an operation row does nothing"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("POST    /pets")
  local before = list_lines()
  child.type_keys("za")
  expect.equality(list_lines(), before)
  expect.equality(current_filetype(), "oasglance-list")
end

T["actions"]["? shows help from either pane"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("?")
  expect.equality(detail_lines()[1], "List pane")
  expect.equality(current_filetype(), "oasglance-list")
  list_goto("POST    /pets")
  expect.equality(detail_lines()[1], "POST /pets")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("?")
  expect.equality(detail_lines()[1], "List pane")
end

T["actions"]["entering the list without moving keeps the detail pane"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("POST    /pets")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("?")
  child.cmd("wincmd h")
  expect.equality(current_filetype(), "oasglance-list")
  expect.equality(detail_lines()[1], "List pane")
  child.type_keys("k")
  expect.equality(detail_lines()[1], "GET /pets")
end

T["actions"]["q closes the tabpage from either pane"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("q")
  expect.equality(child.fn.tabpagenr("$"), 1)
  expect.equality(child.lua_get("vim.fn.reg_recording()"), "")
  child.cmd("OasGlance " .. PETSTORE)
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("q")
  expect.equality(child.fn.tabpagenr("$"), 1)
  expect.equality(
    child.lua_get(
      "#vim.tbl_filter(function(b) return vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype:find('^oasglance') ~= nil end, vim.api.nvim_list_bufs())"
    ),
    0
  )
end

T["actions"]["q on the only tabpage leaves one empty window"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.cmd("tabonly")
  child.type_keys("q")
  expect.equality(child.fn.tabpagenr("$"), 1)
  expect.equality(#child.api.nvim_list_wins(), 1)
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "" })
  expect.equality(child.lua_get("vim.bo.filetype"), "")
  expect.equality(child.is_running(), true)
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(child.fn.tabpagenr("$"), 2)
  expect.equality(list_lines()[1], " Petstore 1.0.0")
end

-- Document identity

T["identity"] = MiniTest.new_set()

T["identity"]["a file twice focuses one tabpage"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.cmd("tabfirst")
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality({ child.fn.tabpagenr("$"), child.fn.tabpagenr() }, { 2, 2 })
end

T["identity"]["a symlink to the file focuses the same tabpage"] = function()
  local link = temp_path("link.yaml")
  child.lua("vim.uv.fs_symlink(...)", { child.fn.fnamemodify(PETSTORE, ":p"), link })
  child.cmd("OasGlance " .. PETSTORE)
  child.cmd("tabfirst")
  child.cmd("OasGlance " .. link)
  expect.equality({ child.fn.tabpagenr("$"), child.fn.tabpagenr() }, { 2, 2 })
end

T["identity"]["a named buffer and its file are one document, in either order"] = function()
  child.cmd("edit " .. PETSTORE)
  child.cmd("OasGlance")
  child.cmd("tabfirst")
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality({ child.fn.tabpagenr("$"), child.fn.tabpagenr() }, { 2, 2 })

  child.type_keys("q")
  child.cmd("OasGlance " .. PETSTORE)
  child.cmd("tabfirst")
  child.cmd("OasGlance")
  expect.equality({ child.fn.tabpagenr("$"), child.fn.tabpagenr() }, { 2, 2 })
end

T["identity"]["two unnamed buffers open two tabpages, and each re-focuses its own"] = function()
  local text = child.fn.readfile(PETSTORE)
  child.cmd("enew")
  local first = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(first, 0, -1, false, text)
  child.cmd("OasGlance")
  local first_tab = child.api.nvim_get_current_tabpage()
  child.cmd("tabfirst")
  child.cmd("enew")
  local second = child.api.nvim_get_current_buf()
  text[3] = "  title: Second"
  child.api.nvim_buf_set_lines(second, 0, -1, false, text)
  child.cmd("OasGlance")
  local second_tab = child.api.nvim_get_current_tabpage()
  expect.equality({ child.fn.tabpagenr("$"), list_lines()[1] }, { 3, " Second 1.0.0" })
  expect.equality(first_tab ~= second_tab, true)

  child.cmd("tabfirst")
  child.api.nvim_set_current_buf(first)
  child.cmd("OasGlance")
  expect.equality({ child.fn.tabpagenr("$"), child.api.nvim_get_current_tabpage() }, { 3, first_tab })
  expect.equality(list_lines()[1], " Petstore 1.0.0")
  child.cmd("tabfirst")
  child.api.nvim_set_current_buf(second)
  child.cmd("OasGlance")
  expect.equality({ child.fn.tabpagenr("$"), child.api.nvim_get_current_tabpage() }, { 3, second_tab })
end

T["identity"]["no argument from a pane changes nothing"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("POST    /pets")
  local function state()
    return child.lua([[
      local wins = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        wins[#wins + 1] = { win, vim.api.nvim_win_get_cursor(win) }
      end
      local detail
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "oasglance-detail" then
          detail = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
      end
      return {
        tabs = vim.fn.tabpagenr("$"),
        tab = vim.fn.tabpagenr(),
        win = vim.api.nvim_get_current_win(),
        wins = wins,
        detail = detail,
      }
    ]])
  end
  for _, filetype in ipairs({ "oasglance-list", "oasglance-detail" }) do
    child.api.nvim_set_current_win(pane(filetype).win)
    local before = state()
    child.cmd("OasGlance")
    expect.equality(state(), before)
  end
  expect.equality(child.lua_get("_G.notes"), {})
end

T["identity"]["a named buffer with no file re-focuses by its name"] = function()
  local path = temp_path("unsaved.yaml")
  child.cmd("edit " .. path)
  child.api.nvim_buf_set_lines(0, 0, -1, false, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance")
  child.cmd("tabfirst")
  child.cmd("OasGlance")
  expect.equality({ child.fn.tabpagenr("$"), child.fn.tabpagenr() }, { 2, 2 })
end

T["identity"]["after q the command opens a new tabpage"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("q")
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(child.fn.tabpagenr("$"), 2)
  expect.equality(list_lines()[1], " Petstore 1.0.0")
end

-- Pane buffer names

T["pane names"] = MiniTest.new_set()

local function pane_names()
  return {
    child.api.nvim_buf_get_name(pane("oasglance-list").buf),
    child.api.nvim_buf_get_name(pane("oasglance-detail").buf),
  }
end

local function expect_names(name)
  expect.equality(pane_names(), { "oas-glance://" .. name, "oas-glance://" .. name .. ":detail" })
end

local function all_buffer_names()
  local names = vim.tbl_map(child.api.nvim_buf_get_name, child.api.nvim_list_bufs())
  table.sort(names)
  return names
end

local function petstore_copies(count)
  local paths = {}
  for index = 1, count do
    local dir = temp_path("copy" .. index)
    child.fn.mkdir(dir, "p")
    paths[index] = dir .. "/petstore.yaml"
    write_file(paths[index], child.fn.readfile(PETSTORE))
  end
  return paths
end

T["pane names"]["both panes are named after a file"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  expect_names("petstore-31.yaml")
end

T["pane names"]["an unnamed buffer"] = function()
  child.cmd("enew")
  child.api.nvim_buf_set_lines(0, 0, -1, false, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance")
  expect_names("[No Name]")
end

T["pane names"]["a space, % and # stay as they are"] = function()
  local path = temp_path("a b%c#d.yaml")
  write_file(path, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance " .. child.fn.fnameescape(path))
  local base = vim.fs.basename(path)
  expect.equality(base:find("a b%c#d.yaml", 1, true) ~= nil, true)
  expect_names(base)
end

T["pane names"]["control characters become U+FFFD"] = function()
  local dir = temp_path("control")
  child.fn.mkdir(dir, "p")
  local path = dir .. "/a\1b\nc\127.yaml"
  write_file(path, child.fn.readfile(PETSTORE))
  child.lua("require('oas-glance').open(...)", { path })
  expect_names("a\239\191\189b\239\191\189c\239\191\189.yaml")
end

T["pane names"]["same-named files take the lowest free number"] = function()
  local a, b, c = unpack(petstore_copies(3))
  child.cmd("OasGlance " .. a)
  local a_tab = child.api.nvim_get_current_tabpage()
  expect_names("petstore.yaml")
  child.cmd("OasGlance " .. b)
  expect_names("petstore.yaml (2)")
  child.cmd("OasGlance " .. c)
  expect_names("petstore.yaml (3)")

  -- Closing A wipes both its pane buffers, so the plain name is free for the next view.
  child.type_keys("q")
  child.api.nvim_set_current_tabpage(a_tab)
  child.type_keys("q")
  expect.equality(vim.tbl_contains(all_buffer_names(), "oas-glance://petstore.yaml"), false)
  child.cmd("OasGlance " .. c)
  expect_names("petstore.yaml")
end

T["pane names"]["re-focusing a document keeps its names"] = function()
  local a, b = unpack(petstore_copies(2))
  child.cmd("OasGlance " .. a)
  child.cmd("OasGlance " .. b)
  local before = all_buffer_names()
  child.cmd("tabfirst")
  child.cmd("OasGlance " .. a)
  expect_names("petstore.yaml")
  expect.equality(all_buffer_names(), before)
end

T["pane names"]["no argument from a named pane focuses its document"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local tab = child.api.nvim_get_current_tabpage()
  local before = all_buffer_names()
  for _, filetype in ipairs({ "oasglance-list", "oasglance-detail" }) do
    child.api.nvim_set_current_win(pane(filetype).win)
    child.cmd("OasGlance")
    expect.equality({ child.fn.tabpagenr("$"), child.api.nvim_get_current_tabpage() }, { 2, tab })
    expect.equality(current_filetype(), filetype)
  end
  expect.equality(all_buffer_names(), before)
  expect.equality(child.lua_get("_G.notes"), {})
end

T["pane names"]["q wipes both pane buffers, also one shown in another tabpage"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local list_buf = pane("oasglance-list").buf
  local detail_buf = pane("oasglance-detail").buf
  child.cmd("tab sbuffer " .. detail_buf)
  child.cmd("tabprevious")
  child.type_keys("q")
  expect.equality({ child.api.nvim_buf_is_valid(list_buf), child.api.nvim_buf_is_valid(detail_buf) }, { false, false })
end

T["pane names"]["the tabline shows the full file name"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.cmd("redraw")
  local row = {}
  for col = 1, child.o.columns do
    row[col] = child.fn.screenstring(1, col)
  end
  expect.equality(table.concat(row):find("petstore-31.yaml", 1, true) ~= nil, true)
end

-- Keymap config

T["keymaps"] = MiniTest.new_set()

T["keymaps"]["the defaults"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local list = keys_of("oasglance-list")
  for _, lhs in ipairs({ "<CR>", "za", "f", "F", "gs", "gc", "R", "?", "q" }) do
    expect.equality({ lhs = lhs, mapped = list[lhs] ~= nil }, { lhs = lhs, mapped = true })
  end
  local detail = keys_of("oasglance-detail")
  for _, lhs in ipairs({ "<CR>", "za", "gd", "<BS>", "gs", "gc", "R", "?", "q" }) do
    expect.equality({ lhs = lhs, mapped = detail[lhs] ~= nil }, { lhs = lhs, mapped = true })
  end
end

T["keymaps"]["a string or a list replaces the defaults, and others keep theirs"] = function()
  setup({ keymaps = { list = { help = "g?", close = { "Q", "gq" } } } })
  child.cmd("OasGlance " .. PETSTORE)
  local list = keys_of("oasglance-list")
  expect.equality(list["?"], nil)
  expect.equality(list["q"], nil)
  expect.equality(
    { list["g?"], list["Q"], list["gq"] },
    { "oas-glance list help", "oas-glance list close", "oas-glance list close" }
  )
  expect.equality(list["za"], "oas-glance list toggle")
  expect.equality(keys_of("oasglance-detail")["q"], "oas-glance detail close")

  child.type_keys("g?")
  expect.equality(detail_lines()[1], "List pane")
  child.type_keys("gq")
  expect.equality(child.fn.tabpagenr("$"), 1)
end

T["keymaps"]["detail.toggle = x removes both <CR> and za"] = function()
  setup({ keymaps = { detail = { toggle = "x" } } })
  child.cmd("OasGlance " .. PETSTORE)
  local detail = keys_of("oasglance-detail")
  expect.equality({ detail["<CR>"], detail["za"], detail["x"] }, { nil, nil, "oas-glance detail toggle" })
end

T["keymaps"]["false removes the action's keys"] = function()
  setup({ keymaps = { list = { close = false }, detail = { help = false } } })
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(keys_of("oasglance-list")["q"], nil)
  expect.equality(keys_of("oasglance-detail")["?"], nil)
  expect.equality(keys_of("oasglance-list")["?"], "oas-glance list help")
end

T["keymaps"]["an unknown name warns once from setup, sorted by pane and action, and is ignored"] = function()
  setup({ keymaps = { list = { back = "b", zap = "z" }, detail = { nope = "n", also = "a" } } })
  expect.equality(child.lua_get("_G.notes"), {
    { message = "oas-glance: unknown keymap action detail.also, ignored", level = WARN },
    { message = "oas-glance: unknown keymap action detail.nope, ignored", level = WARN },
    { message = "oas-glance: unknown keymap action list.back, ignored", level = WARN },
    { message = "oas-glance: unknown keymap action list.zap, ignored", level = WARN },
  })
  child.cmd("OasGlance " .. PETSTORE)
  expect.equality(keys_of("oasglance-list")["b"], nil)
  expect.equality(keys_of("oasglance-detail")["n"], nil)
  expect.equality(#child.lua_get("_G.notes"), 4)
end

-- Row limit

T["max_detail_rows"] = MiniTest.new_set()

T["max_detail_rows"]["the default gives 10001 lines on a doubling document"] = function()
  local path = temp_path("doubling.yaml")
  write_file(path, alias_doubling(30))
  child.cmd("OasGlance " .. path)
  list_goto("   Top")
  local shown = detail_lines()
  expect.equality(#shown, 10001)
  expect.equality(shown[10001], "! stopped at 10000 rows (max_detail_rows)")
end

T["max_detail_rows"]["setup changes the limit"] = function()
  local path = temp_path("doubling.yaml")
  write_file(path, alias_doubling(30))
  setup({ max_detail_rows = 15 })
  child.cmd("OasGlance " .. path)
  list_goto("   Top")
  local shown = detail_lines()
  expect.equality(#shown, 16)
  expect.equality(shown[16], "! stopped at 15 rows (max_detail_rows)")
end

T["max_detail_rows"]["the list pane has no limit"] = function()
  local out = { "openapi: 3.1.0", "info: { title: Many, version: '1' }", "paths:" }
  for index = 1, 30 do
    out[#out + 1] = string.format("  /p%02d:", index)
    out[#out + 1] = "    get: {}"
  end
  local path = temp_path("many.yaml")
  write_file(path, out)
  setup({ max_detail_rows = 5 })
  child.cmd("OasGlance " .. path)
  local shown = list_lines()
  expect.equality(#shown, 35)
  expect.equality(shown[35], "   GET     /p30")
end

-- Config reaches the renderers

T["config"] = MiniTest.new_set()

T["config"]["help lists the user's keys"] = function()
  setup({ keymaps = { list = { filter = "<leader>f", help = "g?" }, detail = { toggle = "x" } } })
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("g?")
  local shown = detail_lines()
  local detail_at = row_of(shown, "Detail pane")
  local list_part = table.concat(vim.list_slice(shown, 1, detail_at - 1), "\n")
  local detail_part = table.concat(vim.list_slice(shown, detail_at), "\n")
  expect.equality(list_part:find("  <leader>f  Filter", 1, true) ~= nil, true)
  expect.equality(list_part:find("  g?  Show this help", 1, true) ~= nil, true)
  expect.equality(list_part:find("  f  Filter", 1, true), nil)
  expect.equality(list_part:find("  ?  Show this help", 1, true), nil)
  expect.equality(detail_part:find("  x  Expand or collapse the row", 1, true) ~= nil, true)
  expect.equality(detail_part:find("<CR>, za", 1, true), nil)
end

T["config"]["a disabled action has no help line"] = function()
  setup({ keymaps = { list = { help = false, filter = "g?" } } })
  child.cmd("OasGlance " .. PETSTORE)
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("?")
  local shown = detail_lines()
  local list_part = table.concat(vim.list_slice(shown, 1, row_of(shown, "Detail pane") - 1), "\n")
  expect.equality(list_part:find("Show this help", 1, true), nil)
  expect.equality(table.concat(shown, "\n"):find("  ?  Show this help", 1, true) ~= nil, true)
end

T["config"]["icons change both panes"] = function()
  setup({ icons = { problem = "E", collapsed = ">" }, max_detail_rows = 13 })
  child.cmd("OasGlance " .. PETSTORE)
  local row = row_of(list_lines(), "▾ store 1")
  list_goto("▾ store 1")
  child.type_keys("za")
  expect.equality(list_lines()[row], "> store 1")
  list_goto("   Pet")
  local shown = detail_lines()
  expect.equality(shown[#shown], "E stopped at 13 rows (max_detail_rows)")
  expect.equality(row_of(shown, "> owner") > 0, true)
end

T["config"]["refs.max_depth reaches the renderer"] = function()
  local out =
    { "openapi: 3.1.0", "info: { title: Deep, version: '1' }", "paths: {}", "components:", "  schemas:", "    Deep:" }
  local indent = "      "
  for level = 1, 5 do
    out[#out + 1] = indent .. "properties:"
    out[#out + 1] = indent .. "  n" .. level .. ":"
    indent = indent .. "    "
  end
  out[#out + 1] = indent .. "type: string"
  local path = temp_path("deep.yaml")
  write_file(path, out)

  child.cmd("OasGlance " .. path)
  list_goto("   Deep")
  expect.equality(table.concat(detail_lines(), "\n"):find("too deep", 1, true), nil)
  child.type_keys("q")

  setup({ refs = { max_depth = 3 } })
  child.cmd("OasGlance " .. path)
  list_goto("   Deep")
  local shown = detail_lines()
  expect.equality(shown[#shown]:match("✗ inline schema  too deep$") ~= nil, true)
end

-- Step 9: expansion, problems, definition, back and source

local CYCLES = "tests/fixtures/cycles.yaml"

--- Focuses the detail pane and moves to the first row holding `text`.
local function detail_goto(text)
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys(tostring(row_of(detail_lines(), text)) .. "G")
end

local function detail_line(text)
  return detail_lines()[row_of(detail_lines(), text)]
end

--- Records every line change of the list buffer from now on.
local function record_list_changes()
  child.lua(
    [[
    _G.list_changes = {}
    vim.api.nvim_buf_attach(..., false, {
      on_lines = function(_, _, _, first, last, new_last)
        table.insert(_G.list_changes, { first, last, new_last })
      end,
    })
  ]],
    { pane("oasglance-list").buf }
  )
end

local function overview_count()
  local before = child.api.nvim_get_current_win()
  list_goto(" OpenAPI")
  local heading = detail_line("so far")
  child.api.nvim_set_current_win(before)
  return heading
end

local function view_state()
  return child.lua([[
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      wins[#wins + 1] = { win, vim.api.nvim_win_get_cursor(win), vim.api.nvim_win_get_buf(win) }
    end
    local panes = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      panes[vim.bo[buf].filetype] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    return { tabs = vim.fn.tabpagenr("$"), win = vim.api.nvim_get_current_win(), wins = wins, panes = panes }
  ]])
end

T["problems"] = MiniTest.new_set()

T["problems"]["another file's diagnostics reach the header and the overview"] = function()
  child.cmd("OasGlance tests/fixtures/multi/to-damaged.yaml")
  expect.equality(list_lines()[3], "")
  list_goto("   Holder")
  detail_goto("ok")
  child.type_keys("<CR>")
  local header = list_lines()[3]
  local count = tonumber(header:match("^ ! (%d+) problems? so far$"))
  expect.equality(count ~= nil and count >= 1, true)
  expect.equality(overview_count(), "Problems so far " .. count)
  expect.equality(table.concat(detail_lines(), "\n"):find("(damaged.yaml)", 1, true) ~= nil, true)
end

T["problems"]["a note never counts, and the list is not redrawn for it"] = function()
  child.cmd("OasGlance tests/fixtures/notes-30.yaml")
  record_list_changes()
  list_goto("   Pet")
  expect.equality(list_lines()[3], "")
  expect.equality(child.lua_get("_G.list_changes"), {})
  list_goto(" Notes")
  local shown = detail_lines()
  local at = row_of(shown, "No problems so far.")
  expect.equality(vim.list_slice(shown, at), {
    "No problems so far.",
    "References are checked when opened.",
    "",
    "Notes 1",
    "  line 12  $ref siblings are ignored in OpenAPI 3.0",
  })
end

T["problems"]["a note beside a problem leaves the count alone"] = function()
  local text = child.fn.readfile("tests/fixtures/notes-30.yaml")
  table.remove(text, 5)
  local path = temp_path("one-problem.yaml")
  write_file(path, text)
  child.cmd("OasGlance " .. path)
  expect.equality(list_lines()[3], " ! 1 problem so far")
  list_goto("   Pet")
  expect.equality(list_lines()[3], " ! 1 problem so far")
  expect.equality(overview_count(), "Problems so far 1")
  expect.equality(row_of(detail_lines(), "Notes 1") > 0, true)
end

T["expansion"] = MiniTest.new_set()

T["expansion"]["<CR> and za expand and collapse a ref in place, and none opens by itself"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /pets/{petId}")
  expect.equality(table.concat(detail_lines(), "\n"):find("▾ →", 1, true), nil)
  local closed = detail_lines()
  detail_goto("▸ → Pet")
  child.type_keys("<CR>")
  expect.equality(detail_line("→ Pet"), "  ▾ → Pet")
  expect.equality(detail_line("parent"), "      parent    ↻ Pet  cycle")
  expect.equality(current_filetype(), "oasglance-detail")
  child.type_keys("za")
  expect.equality(detail_lines(), closed)
end

T["expansion"]["a closed local ref to a missing pointer is checked only when opened"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Missing")
  expect.equality(detail_line("gone"), "▸ gone  → Nope")
  expect.equality(list_lines()[3], "")
  local list_before = list_lines()
  local list_cursor = child.api.nvim_win_get_cursor(pane("oasglance-list").win)
  record_list_changes()

  detail_goto("gone")
  child.type_keys("<CR>")
  expect.equality(detail_line("gone"), "  gone  ✗ #/components/schemas/Nope  no such pointer")
  local after = detail_lines()
  child.type_keys("<CR>")
  expect.equality(detail_lines(), after)

  expect.equality(list_lines()[3], " ! 1 problem so far")
  expect.equality(child.lua_get("_G.list_changes"), { { 2, 3, 3 } })
  local list_after = list_lines()
  list_before[3] = list_after[3]
  expect.equality(list_after, list_before)
  expect.equality(child.api.nvim_win_get_cursor(pane("oasglance-list").win), list_cursor)
  expect.equality(row_of({ overview_count() }, "Problems so far 1"), 1)
  expect.equality(table.concat(detail_lines(), "\n"):find("no such pointer", 1, true) ~= nil, true)
end

T["expansion"]["gd on that closed ref checks it, breaks the row and does not jump"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Missing")
  detail_goto("gone")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Missing  object")
  expect.equality(detail_line("gone"), "  gone  ✗ #/components/schemas/Nope  no such pointer")
  local state = view_state()
  child.type_keys("<BS>")
  expect.equality(view_state(), state)
end

T["expansion"]["gs on a closed ref goes to the $ref and checks nothing"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Missing")
  detail_goto("gone")
  child.type_keys("gs")
  expect.equality(child.fn.tabpagenr(), 1)
  expect.equality(child.fn.expand("%:t"), "cycles.yaml")
  local cursor = child.api.nvim_win_get_cursor(0)
  local line = child.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1]
  expect.equality(line, '          $ref: "#/components/schemas/Nope"')
  child.cmd("tabnext 2")
  expect.equality(detail_line("gone"), "▸ gone  → Nope")
  expect.equality(list_lines()[3], "")
end

T["expansion"]["a self cycle and a mutual cycle end at the cycle row"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Node")
  expect.equality(detail_line("next"), "  next   ↻ Node  cycle")
  local before = detail_lines()
  detail_goto("next")
  child.type_keys("<CR>")
  expect.equality(detail_lines(), before)

  list_goto("   A")
  detail_goto("→ B")
  child.type_keys("<CR>")
  expect.equality(vim.list_slice(detail_lines(), 3), { "▾ b  → B", "    a  ↻ A  cycle" })
  detail_goto("↻ A")
  child.type_keys("za")
  expect.equality(vim.list_slice(detail_lines(), 3), { "▾ b  → B", "    a  ↻ A  cycle" })
end

T["expansion"]["gd and gs still work on a cycle row"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   A")
  detail_goto("→ B")
  child.type_keys("<CR>")
  detail_goto("↻ A")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "A  object")
  expect.equality(list_lines()[child.api.nvim_win_get_cursor(pane("oasglance-list").win)[1]], "   A")
  detail_goto("→ B")
  child.type_keys("gs")
  local cursor = child.api.nvim_win_get_cursor(0)
  expect.equality(
    child.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1],
    '          $ref: "#/components/schemas/B"'
  )
end

T["expansion"]["an unnamed buffer document shows the same cycle rows"] = function()
  child.cmd("enew")
  child.api.nvim_buf_set_lines(0, 0, -1, false, child.fn.readfile(CYCLES))
  child.cmd("OasGlance")
  list_goto("   Node")
  expect.equality(detail_line("next"), "  next   ↻ Node  cycle")
  list_goto("   A")
  detail_goto("→ B")
  child.type_keys("<CR>")
  expect.equality(detail_line("↻ A"), "    a  ↻ A  cycle")
end

T["expansion"]["the same schema expands in sibling branches"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Twice")
  detail_goto("first")
  child.type_keys("<CR>")
  detail_goto("second")
  child.type_keys("<CR>")
  expect.equality(vim.list_slice(detail_lines(), 3), {
    "▾ first   → Leaf",
    "    x  string",
    "▾ second  → Leaf",
    "    x  string",
  })
end

T["definition"] = MiniTest.new_set()

local function open_pet_operation()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /pets/{petId}")
  detail_goto("▸ → Pet")
end

T["definition"]["gd onto a listed schema moves the list cursor, and the view counts as an ancestor"] = function()
  open_pet_operation()
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Pet  object")
  expect.equality(detail_line("parent"), "  parent    ↻ Pet  cycle")
  expect.equality(list_lines()[child.api.nvim_win_get_cursor(pane("oasglance-list").win)[1]], "   Pet")
  expect.equality(current_filetype(), "oasglance-detail")
end

T["definition"]["gd onto a schema that is not listed leaves the list cursor"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("   Pet")
  local list_cursor = child.api.nvim_win_get_cursor(pane("oasglance-list").win)
  detail_goto("→ Cat")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Cat  object")
  expect.equality(child.api.nvim_win_get_cursor(pane("oasglance-list").win), list_cursor)
end

T["definition"]["a list selection that changes the target clears the history"] = function()
  open_pet_operation()
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Pet  object")
  list_goto("POST    /pets")
  expect.equality(detail_lines()[1], "POST /pets")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.lua("_G.notes = {}")
  local before = view_state()
  child.type_keys("<BS>")
  expect.equality(view_state(), before)
end

T["definition"]["entering the list without changing the target keeps the history"] = function()
  open_pet_operation()
  child.type_keys("gd")
  list_goto("   Pet")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "GET /pets/{petId}")
end

T["definition"]["<BS> returns with the expansion and cursor intact"] = function()
  open_pet_operation()
  child.type_keys("<CR>")
  detail_goto("parent")
  local before = detail_lines()
  local cursor = child.api.nvim_win_get_cursor(0)
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Pet  object")
  child.type_keys("<BS>")
  expect.equality(detail_lines(), before)
  expect.equality(child.api.nvim_win_get_cursor(0), cursor)
  child.type_keys("<BS>")
  expect.equality(detail_lines(), before)
end

T["definition"]["expanding counts towards the row limit, and collapsing removes the limit row"] = function()
  setup({ max_detail_rows = 15 })
  open_pet_operation()
  local closed = detail_lines()
  expect.equality(#closed, 14)
  child.type_keys("<CR>")
  local opened = detail_lines()
  expect.equality(#opened, 16)
  expect.equality(opened[16], "! stopped at 15 rows (max_detail_rows)")
  detail_goto("▾ → Pet")
  child.type_keys("<CR>")
  expect.equality(detail_lines(), closed)
end

T["no target"] = MiniTest.new_set()

--- Runs keys and expects nothing to change and nothing to be said.
local function expect_nothing(keys)
  local before = view_state()
  child.type_keys(keys)
  expect.equality(view_state(), before)
  expect.equality(child.lua_get("_G.notes"), {})
end

T["no target"]["definition on a row with no ref, and on a broken row"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Missing")
  detail_goto("Missing  object")
  expect_nothing("gd")
  detail_goto("gone")
  child.type_keys("<CR>")
  child.lua("_G.notes = {}")
  expect_nothing("gd")
end

T["no target"]["source on a help row"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  child.type_keys("?")
  detail_goto("Detail pane")
  expect_nothing("gs")
end

T["no target"]["toggle, definition and source on the limit row"] = function()
  setup({ max_detail_rows = 3 })
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("   Pet")
  detail_goto("stopped at 3 rows")
  expect_nothing("<CR>")
  expect_nothing("za")
  expect_nothing("gd")
  expect_nothing("gs")
end

T["no target"]["back with no history"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("   Pet")
  detail_goto("parent")
  expect_nothing("<BS>")
end

T["source"] = MiniTest.new_set()

--- The 1-based row and 0-based byte column of the `nth` line holding `needle`, in raw file lines.
local function find_in(text_lines, needle, nth)
  local seen = 0
  for index, line in ipairs(text_lines) do
    local col = line:find(needle, 1, true)
    if col then
      seen = seen + 1
      if seen == (nth or 1) then
        return { index, col - 1 }
      end
    end
  end
  error("no line with " .. needle, 0)
end

local function raw_lines(path)
  return vim.split(table.concat(vim.fn.readfile(path, "b"), "\n"), "\n", { plain = true })
end

local function gs_on_list_row(text)
  list_goto(text)
  child.type_keys("gs")
  return child.api.nvim_win_get_cursor(0)
end

T["source"]["lands on the exact byte position"] = function()
  local odd = temp_path("odd x%y#z.yaml")
  child.fn.writefile(child.fn.readfile(PETSTORE), odd)
  for _, case in ipairs({
    { PETSTORE, PETSTORE, "GET     /pets/{petId}", "    get:", 2 },
    { "tests/fixtures/petstore.json", "tests/fixtures/petstore.json", "GET     /pets/{petId}", '"get"', 2 },
    { "tests/fixtures/json/minified.json", "tests/fixtures/json/minified.json", "GET     /pets", '"get"', 1 },
    { "tests/fixtures/json/crlf.json", "tests/fixtures/json/crlf.json", "POST    /stores", '"post"', 1 },
    { child.fn.fnameescape(odd), odd, "GET     /pets/{petId}", "    get:", 2 },
  }) do
    child.cmd("tabonly")
    child.cmd("enew")
    child.cmd("OasGlance " .. case[1])
    local cursor = gs_on_list_row(case[3])
    local expected = find_in(raw_lines(case[2]), case[4], case[5])
    if case[4] == "    get:" then
      expected[2] = 4
    end
    expect.equality({ file = case[2], cursor = cursor }, { file = case[2], cursor = expected })
    expect.equality(child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ":p"), child.fn.fnamemodify(case[2], ":p"))
  end
end

T["source"]["a broken row jumps to its $ref"] = function()
  child.cmd("OasGlance " .. CYCLES)
  list_goto("   Missing")
  detail_goto("gone")
  child.type_keys("<CR>")
  child.type_keys("gs")
  local cursor = child.api.nvim_win_get_cursor(0)
  -- The broken row's position is the `$ref` value, the same as the closed row's.
  local expected = find_in(raw_lines(CYCLES), '"#/components/schemas/Nope"')
  expect.equality(cursor, expected)
  expect.equality(child.fn.expand("%:t"), "cycles.yaml")
end

--- A directory under /tmp holding a document and a file whose name has a newline and a Lua line.
local function newline_name_files()
  local dir = temp_path("newline-dir")
  child.fn.mkdir(dir, "p")
  -- No character here is one `fnameescape()` escapes, so the Lua line would run as written.
  local name = "x\nlua_G.oas_glance_pwned=1--\nlua--y.yaml"
  local target = dir .. "/" .. name
  child.fn.writefile({ "Target:", "  type: object", "  properties:", "    p:", "      type: string" }, target)
  child.fn.writefile({
    "openapi: 3.1.0",
    "info: { title: Newline, version: '1' }",
    "paths:",
    "  /a:",
    "    get: {}",
    "components:",
    "  schemas:",
    "    S:",
    "      properties:",
    "        t:",
    '          $ref: "./x\\nlua_G.oas_glance_pwned=1--\\nlua--y.yaml#/Target"',
  }, dir .. "/root.yaml")
  return dir, target
end

T["source"]["a file name with a newline runs nothing"] = MiniTest.new_set()

-- Spec 7 refuses a control character in a `$ref`, so the file is never reached through one, and `gs` goes to the `$ref`.
T["source"]["a file name with a newline runs nothing"]["a $ref to it is not allowed"] = function()
  local dir = newline_name_files()
  child.cmd("OasGlance " .. child.fn.fnameescape(dir .. "/root.yaml"))
  list_goto("   S")
  expect.equality(detail_line("not allowed"), "  lua--y.yaml#/Target  not allowed")
  expect.equality(detail_line("t  ✗"), "  t  ✗ ./x")
  detail_goto("not allowed")
  child.type_keys("<CR>")
  child.type_keys("gd")
  child.type_keys("gs")
  expect.equality(child.lua_get("_G.oas_glance_pwned"), vim.NIL)
  expect.equality(child.api.nvim_buf_get_name(0), dir .. "/root.yaml")
  expect.equality(child.api.nvim_win_get_cursor(0), { 11, 16 })
  expect.equality(child.lua_get("_G.notes"), {})
end

T["source"]["a file name with a newline runs nothing"]["reached by a hop the text checks cannot see"] = function()
  local dir, target = newline_name_files()
  -- The decoded `%0A` is refused too, so only a file opened by name holds such a path.
  child.fn.writefile({
    "openapi: 3.1.0",
    "info: { title: Encoded, version: '1' }",
    "paths: {}",
    "components:",
    "  schemas:",
    "    S:",
    "      properties:",
    "        t:",
    '          $ref: "./x%0Alua_G.oas_glance_pwned=1--%0Alua--y.yaml#/Target"',
  }, dir .. "/encoded.yaml")
  child.cmd("OasGlance " .. child.fn.fnameescape(dir .. "/encoded.yaml"))
  list_goto("   S")
  expect.equality(table.concat(detail_lines(), "\n"):find("not allowed", 1, true) ~= nil, true)
  expect.equality(child.fn.filereadable(target), 1)
  expect.equality(child.lua_get("_G.oas_glance_pwned"), vim.NIL)
end

T["source"]["a file name with a newline runs nothing"]["opened by name and left by gs"] = function()
  local _, target = newline_name_files()
  child.fn.writefile(
    { "openapi: 3.1.0", "info: { title: Odd, version: '1' }", "paths:", "  /a:", "    get: {}" },
    target
  )
  child.lua("require('oas-glance').open(...)", { target })
  expect.equality(list_lines()[1], " Odd 1")
  list_goto("GET     /a")
  child.type_keys("gs")
  expect.equality(child.lua_get("_G.oas_glance_pwned"), vim.NIL)
  expect.equality(child.api.nvim_buf_get_name(0), target)
  expect.equality(child.api.nvim_win_get_cursor(0), { 5, 4 })
end

T["source"]["never lands in a pane of another viewer"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local first =
    { list = pane("oasglance-list"), detail = pane("oasglance-detail"), tab = child.api.nvim_get_current_tabpage() }
  child.cmd("OasGlance tests/fixtures/types.yaml")
  local tabs = child.fn.tabpagenr("$")
  list_goto("   TypesA")
  child.type_keys("gs")
  expect.equality(child.fn.tabpagenr("$"), tabs + 1)
  expect.equality(child.fn.expand("%:t"), "types.yaml")
  for _, side in ipairs({ "list", "detail" }) do
    local item = first[side]
    expect.equality(child.api.nvim_buf_is_valid(item.buf), true)
    expect.equality(child.api.nvim_win_get_buf(item.win), item.buf)
  end
  child.api.nvim_set_current_tabpage(first.tab)
  expect.equality(list_lines()[1], " Petstore 1.0.0")
end

T["source"]["opens in the start window, or a new tabpage when it is gone"] = function()
  local start = child.api.nvim_get_current_win()
  child.cmd("OasGlance " .. PETSTORE)
  gs_on_list_row("POST    /pets")
  expect.equality(child.api.nvim_get_current_win(), start)
  expect.equality(child.fn.tabpagenr("$"), 2)

  child.cmd("tabnext 2")
  child.cmd("tabclose 1")
  expect.equality(child.fn.tabpagenr("$"), 1)
  gs_on_list_row("GET     /health")
  expect.equality(child.fn.tabpagenr("$"), 2)
  expect.equality(child.fn.expand("%:t"), "petstore-31.yaml")
  expect.equality(child.api.nvim_win_get_cursor(0)[1], find_in(raw_lines(PETSTORE), "/health:")[1] + 1)
end

T["source"]["a BOM file read from disk: 3 bytes off the first row only"] = function()
  local path = "tests/fixtures/json/bom.json"
  local raw = raw_lines(path)
  child.cmd("OasGlance " .. path)
  local first = gs_on_list_row("GET     /first")
  expect.equality(child.lua_get("vim.bo.bomb"), true)
  expect.equality(first, { 1, raw[1]:find('"get"', 1, true) - 1 - 3 })
  child.cmd("tabnext 2")
  local later = gs_on_list_row("GET     /later")
  expect.equality(later, { 2, raw[2]:find('"get"', 1, true) - 1 })
end

T["source"]["a BOM file viewed from its buffer: nothing subtracted"] = function()
  child.cmd("edit tests/fixtures/json/bom.json")
  expect.equality(child.lua_get("vim.bo.bomb"), true)
  local buffer_line = child.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  child.cmd("OasGlance")
  local first = gs_on_list_row("GET     /first")
  expect.equality(first, { 1, buffer_line:find('"get"', 1, true) - 1 })
end

T["source"]["a buffer document returns to its buffer"] = MiniTest.new_set()

T["source"]["a buffer document returns to its buffer"]["named, with unsaved edits"] = function()
  child.cmd("edit " .. PETSTORE)
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(buf, 0, 0, false, { "# one", "# two" })
  child.cmd("OasGlance")
  local cursor = gs_on_list_row("GET     /health")
  expect.equality(child.api.nvim_get_current_buf(), buf)
  expect.equality(cursor, { find_in(raw_lines(PETSTORE), "/health:")[1] + 3, 4 })
end

T["source"]["a buffer document returns to its buffer"]["unnamed"] = function()
  child.cmd("enew")
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(buf, 0, -1, false, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance")
  local cursor = gs_on_list_row("GET     /health")
  expect.equality(child.api.nvim_get_current_buf(), buf)
  expect.equality(cursor, { find_in(raw_lines(PETSTORE), "/health:")[1] + 1, 4 })
end

T["source"]["a buffer document returns to its buffer"]["in a new tabpage when the start window is gone"] = function()
  child.cmd("enew")
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(buf, 0, -1, false, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance")
  child.cmd("tabclose 1")
  gs_on_list_row("GET     /health")
  expect.equality(child.fn.tabpagenr("$"), 2)
  expect.equality(child.api.nvim_get_current_buf(), buf)
end

T["source"]["a buffer document returns to its buffer"]["wiped, named or unnamed"] = function()
  for _, named in ipairs({ true, false }) do
    child.cmd("tabonly")
    child.cmd(named and ("edit " .. PETSTORE) or "enew")
    local buf = child.api.nvim_get_current_buf()
    if not named then
      child.api.nvim_buf_set_lines(buf, 0, -1, false, child.fn.readfile(PETSTORE))
    end
    child.cmd("OasGlance")
    child.cmd("bwipeout! " .. buf)
    child.lua("_G.notes = {}")
    list_goto("GET     /health")
    local before = view_state()
    child.type_keys("gs")
    expect.equality(view_state(), before)
    expect.equality(child.lua_get("_G.notes"), {
      { message = "oas-glance: the source buffer no longer exists", level = WARN },
    })
  end
end

T["source"]["a buffer document returns to its buffer"]["clamps when the text got shorter"] = function()
  child.cmd("enew")
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(buf, 0, -1, false, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance")
  child.api.nvim_buf_set_lines(buf, 0, -1, false, { "ab" })
  local cursor = gs_on_list_row("GET     /health")
  expect.equality(cursor, { 1, 1 })
  expect.equality(child.lua_get("_G.notes"), {})
end

-- Filtering, with `vim.ui.input` stubbed

T["filter"] = MiniTest.new_set()

--- Answers the next prompts with `answer`, or cancels when it is nil, and records each prompt's options.
local function answer_prompt(answer)
  child.lua(
    [[
    local answer = ...
    _G.prompts = _G.prompts or {}
    vim.ui.input = function(opts, on_confirm)
      table.insert(_G.prompts, opts)
      on_confirm(answer)
    end
  ]],
    { answer }
  )
end

local function filter_by(text)
  answer_prompt(text)
  child.api.nvim_set_current_win(pane("oasglance-list").win)
  child.type_keys("f")
end

local function list_cursor()
  return child.api.nvim_win_get_cursor(pane("oasglance-list").win)[1]
end

T["filter"]["f applies terms and F clears them"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local before = list_lines()
  filter_by("tag:pets {petid}")
  expect.equality(list_lines(), {
    " Filter: tag:pets {petid}",
    "",
    "▾ pets 2",
    "   GET     /pets/{petId}",
    " ~ DELETE  /pets/{petId}",
  })
  expect.equality(child.lua_get("_G.prompts[1].prompt"), "Filter: ")
  child.type_keys("F")
  expect.equality(list_lines(), before)
end

T["filter"]["the prompt starts from the active filter"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  filter_by("store")
  filter_by("store")
  expect.equality(child.lua_get("_G.prompts[1].default"), vim.NIL)
  expect.equality(child.lua_get("_G.prompts[2].default"), "store")
end

T["filter"]["cancelling changes nothing, and an empty or blank answer clears"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local before = list_lines()
  filter_by("store")
  local filtered = list_lines()
  filter_by(nil)
  expect.equality(list_lines(), filtered)
  filter_by("")
  expect.equality(list_lines(), before)
  filter_by("store")
  filter_by("   ")
  expect.equality(list_lines(), before)
end

T["filter"]["groups open while filtering, and the fold state returns"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("▾ pets 4")
  child.type_keys("za")
  list_goto("▾ Schemas 3")
  child.type_keys("za")
  local folded = list_lines()
  filter_by("pet")
  expect.equality(row_of(list_lines(), "▾ pets 4") > 0, true)
  expect.equality(row_of(list_lines(), "▾ Schemas 2") > 0, true)
  list_goto("▾ pets 4")
  child.type_keys("za")
  child.type_keys("<CR>")
  expect.equality(row_of(list_lines(), "▾ pets 4") > 0, true)
  child.type_keys("F")
  expect.equality(list_lines(), folded)
end

T["filter"]["counts show matches, and matches are highlighted"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  filter_by("path:{petId}")
  expect.equality(list_lines()[3], "▾ pets 2")
  local marks = child.lua(
    [[
    local found = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(..., -1, 0, -1, { details = true })) do
      if mark[4].hl_group == "OasGlanceMatch" then
        found[#found + 1] = { mark[2], mark[3], mark[4].end_col }
      end
    end
    table.sort(found, function(a, b) return a[1] < b[1] end)
    return found
  ]],
    { pane("oasglance-list").buf }
  )
  -- `   GET     /pets/` and ` ~ DELETE  /pets/` are both 17 bytes.
  expect.equality(marks, { { 3, 17, 24 }, { 4, 17, 24 } })
end

T["filter"]["a term with {, % and # is literal"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  filter_by("{petId}")
  expect.equality(list_lines()[3], "▾ pets 2")
  filter_by("{petId}%#")
  expect.equality(list_lines(), { " Filter: {petId}%#", "", " No matches" })
  expect.equality(child.lua_get("_G.notes"), {})
end

T["filter"]["a hidden selection moves to the first match, as a new selection"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /pets/{petId}")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  detail_goto("→ Pet")
  child.type_keys("gd")
  expect.equality(detail_lines()[1]:find("^Pet") ~= nil, true)
  filter_by("store")
  expect.equality(list_lines()[list_cursor()], "   GET     /store/inventory")
  expect.equality(detail_lines()[1], "GET /store/inventory")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "GET /store/inventory")
end

T["filter"]["a visible selection stays, with its detail view and history"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /pets/{petId}")
  detail_goto("→ Pet")
  -- `gd` onto a listed schema moves the list cursor to it.
  child.type_keys("gd")
  expect.equality(list_lines()[list_cursor()], "   Pet")
  local shown = detail_lines()
  local tick = child.api.nvim_buf_get_changedtick(pane("oasglance-detail").buf)
  filter_by("pet")
  expect.equality(list_lines()[list_cursor()], "   Pet")
  child.type_keys("F")
  expect.equality(list_lines()[list_cursor()], "   Pet")
  expect.equality(detail_lines(), shown)
  expect.equality(child.api.nvim_buf_get_changedtick(pane("oasglance-detail").buf), tick)
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "GET /pets/{petId}")
end

T["filter"]["the filter line shows the overview, and clearing brings back the header rows"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local before = list_lines()
  list_goto("GET     /health")
  filter_by("nothing-like-this")
  expect.equality(list_lines(), { " Filter: nothing-like-this", "", " No matches" })
  expect.equality(list_cursor(), 1)
  expect.equality(detail_lines()[1], "Petstore 1.0.0")
  child.type_keys("F")
  expect.equality(list_lines(), before)
  expect.equality(list_lines()[3], "")
  expect.equality(list_cursor(), 1)
end

T["filter"]["the header count waits while filtering and appears after F"] = function()
  child.cmd("OasGlance " .. CYCLES)
  local before = list_lines()
  filter_by("Missing")
  expect.equality(list_lines(), { " Filter: Missing", "", "▾ Schemas 1", "   Missing" })
  list_goto("   Missing")
  record_list_changes()
  detail_goto("gone")
  child.type_keys("<CR>")
  expect.equality(detail_line("gone"), "  gone  ✗ #/components/schemas/Nope  no such pointer")
  expect.equality(child.lua_get("_G.list_changes"), {})
  expect.equality(list_lines()[3], "▾ Schemas 1")

  child.api.nvim_set_current_win(pane("oasglance-list").win)
  child.type_keys("F")
  local after = list_lines()
  expect.equality(after[3], " ! 1 problem so far")
  before[3] = after[3]
  expect.equality(after, before)
end

T["filter"]["gs on the filter line does nothing"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  filter_by("pets")
  list_goto(" Filter:")
  local before = view_state()
  child.type_keys("gs")
  expect.equality(view_state(), before)
  expect.equality(child.lua_get("_G.notes"), {})
end

T["filter"]["/ still searches in both panes"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  filter_by("pets")
  child.type_keys("/DELETE<CR>")
  expect.equality(list_lines()[list_cursor()], " ~ DELETE  /pets/{petId}")
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("gg", "/petId<CR>")
  expect.equality(child.api.nvim_get_current_line():find("petId", 1, true) ~= nil, true)
end

T["filter"]["filter and clear_filter follow the keymap config"] = function()
  setup({ keymaps = { list = { filter = "s", clear_filter = "S" } } })
  child.cmd("OasGlance " .. PETSTORE)
  local before = list_lines()
  local keys = keys_of("oasglance-list")
  expect.equality({ keys.f, keys.F }, { nil, nil })
  answer_prompt("store")
  child.type_keys("s")
  expect.equality(list_lines()[1], " Filter: store")
  child.type_keys("S")
  expect.equality(list_lines(), before)
end

-- External refs, broken rows and Problems

local MULTI_DIR = "tests/fixtures/multi"

local function real(path)
  return child.lua_get("vim.uv.fs_realpath(...)", { path })
end

--- Opens a file under `multi/` with that directory as the ref root, so the boundary does not depend on `/work`.
local function open_multi(file, opts)
  setup(vim.tbl_deep_extend("force", { refs = { root = real(MULTI_DIR) } }, opts or {}))
  child.cmd("OasGlance " .. MULTI_DIR .. "/" .. file)
end

--- Records the base name of every file read from now on, and counts filesystem probes.
local function spy_reads()
  child.lua([[
    _G.reads, _G.fs_calls = {}, 0
    local open = io.open
    io.open = function(path, mode)
      table.insert(_G.reads, vim.fs.basename(path))
      return open(path, mode)
    end
    for _, name in ipairs({ "fs_stat", "fs_lstat", "fs_realpath" }) do
      local original = vim.uv[name]
      vim.uv[name] = function(...)
        _G.fs_calls = _G.fs_calls + 1
        return original(...)
      end
    end
  ]])
end

local function reads()
  return child.lua_get("_G.reads")
end

local function header()
  return list_lines()[3]
end

--- Writes files into a new directory under `/tmp` and returns that directory.
local function temp_tree(files)
  local dir = temp_path("tree")
  child.fn.mkdir(dir, "p")
  local names = vim.tbl_keys(files)
  table.sort(names)
  for _, name in ipairs(names) do
    child.fn.mkdir(vim.fs.dirname(dir .. "/" .. name), "p")
    write_file(dir .. "/" .. name, files[name])
  end
  return dir
end

local function open_tree(dir, file, opts)
  setup(vim.tbl_deep_extend("force", { refs = { root = real(dir) } }, opts or {}))
  child.cmd("OasGlance " .. child.fn.fnameescape(dir .. "/" .. file))
end

local function schema_doc(properties)
  local out = {
    "openapi: 3.1.0",
    "info: { title: T, version: '1' }",
    "paths: {}",
    "components:",
    "  schemas:",
    "    S:",
    "      properties:",
  }
  for _, line in ipairs(properties) do
    out[#out + 1] = "        " .. line
  end
  return out
end

T["external refs"] = MiniTest.new_set()

T["external refs"]["the multi fixture has no gone.yaml"] = function()
  expect.equality(vim.uv.fs_stat(MULTI_DIR .. "/gone.yaml"), nil)
  expect.equality(vim.uv.fs_stat(MULTI_DIR .. "/paths/gone.yaml"), nil)
end

T["external refs"]["one expands in place, and gs lands in its file"] = function()
  open_multi("root.yaml")
  list_goto("   Pet")
  detail_goto("owner")
  child.type_keys("<CR>")
  expect.equality(detail_line("owner"), "▾ owner  → Owner (owner.yaml)")
  expect.equality(detail_line("name"), "    name  string")
  detail_goto("name")
  child.type_keys("gs")
  expect.equality(child.api.nvim_buf_get_name(0), real(MULTI_DIR .. "/schemas/owner.yaml"))
  expect.equality(child.api.nvim_win_get_cursor(0), find_in(raw_lines(MULTI_DIR .. "/schemas/owner.yaml"), "name:"))
end

T["external refs"]["selecting loads no closed ref, and a missing target looks like any other"] = function()
  open_multi("root.yaml")
  spy_reads()
  list_goto("   Pet")
  list_goto("   Outside")
  list_goto("   Listed")
  list_goto("   Pet")
  expect.equality(reads(), {})
  expect.equality(detail_line("owner"), "▸ owner  → Owner (owner.yaml)")
  expect.equality(detail_line("gone"), "▸ gone   → gone (gone.yaml)")
  list_goto("   Outside")
  expect.equality(detail_line("far"), "▸ far  → outside (outside.yaml)")
  list_goto("GET     /pets")
  expect.equality(reads(), { "shared.yaml" })
  expect.equality(header(), "")
end

T["external refs"]["toggle on a missing target breaks the row for good"] = function()
  open_multi("root.yaml")
  list_goto("   Pet")
  detail_goto("gone")
  child.type_keys("<CR>")
  expect.equality(detail_line("gone"), "  gone   ✗ ./gone.yaml  not found")
  local after = detail_lines()
  child.type_keys("<CR>", "za")
  expect.equality(detail_lines(), after)
  expect.equality(header(), " ! 1 problem so far")
end

T["external refs"]["toggle outside the root gives outside root"] = function()
  open_multi("root.yaml")
  list_goto("   Outside")
  detail_goto("far")
  child.type_keys("<CR>")
  expect.equality(detail_line("far"), "  far  ✗ ../outside.yaml  outside root")
end

T["external refs"]["gd on a closed external ref follows it once the checks pass"] = function()
  open_multi("root.yaml")
  list_goto("   Pet")
  spy_reads()
  detail_goto("owner")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Owner  object")
  expect.equality(reads(), { "owner.yaml" })
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "Pet  object")
  expect.equality(detail_line("owner"), "▸ owner  → Owner (owner.yaml)")
end

T["external refs"]["gd on a failing one breaks the row, with no jump and the history kept"] = function()
  open_multi("root.yaml")
  list_goto("   Local")
  detail_goto("pet")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Pet  object")
  local before = detail_lines()
  detail_goto("gone")
  child.type_keys("gd")
  local after = detail_lines()
  expect.equality(after[1], "Pet  object")
  local row = row_of(before, "gone")
  expect.equality(after[row], "  gone   ✗ ./gone.yaml  not found")
  before[row] = after[row]
  expect.equality(after, before)
  expect.equality(header(), " ! 1 problem so far")

  child.type_keys("gd")
  expect.equality(detail_lines(), after)
  expect.equality(child.lua_get("_G.notes"), {})
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "Local  object")
end

T["external refs"]["gs on a closed external ref goes to the $ref and loads nothing"] = function()
  open_multi("root.yaml")
  list_goto("   Pet")
  spy_reads()
  detail_goto("gone")
  child.type_keys("gs")
  expect.equality(child.api.nvim_buf_get_name(0), real(MULTI_DIR .. "/root.yaml"))
  expect.equality(child.api.nvim_win_get_cursor(0), find_in(raw_lines(MULTI_DIR .. "/root.yaml"), "./gone.yaml"))
  expect.equality(vim.tbl_contains(reads(), "gone.yaml"), false)
end

T["broken from the start"] = MiniTest.new_set()

T["broken from the start"]["remote, other schemes and #name render broken, read nothing, and count"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({
      "a:",
      "  $ref: http://example.com/a.yaml",
      "b:",
      "  $ref: HTTP://example.com/b.yaml",
      "c:",
      "  $ref: file:///etc/passwd",
      "d:",
      '  $ref: "#name"',
    }),
  })
  open_tree(dir, "root.yaml")
  spy_reads()
  list_goto("   S")
  expect.equality(vim.list_slice(detail_lines(), 3), {
    "  a  ✗ http://example.com/a.yaml  remote not loaded",
    "  b  ✗ HTTP://example.com/b.yaml  remote not loaded",
    "  c  ✗ file:///etc/passwd  not allowed",
    "  d  ✗ #name  unsupported ref",
  })
  expect.equality({ reads(), child.lua_get("_G.fs_calls") }, { {}, 0 })
  expect.equality(header(), " ! 4 problems so far")
end

T["broken from the start"]["one in a closed response counts only when that response opens"] = function()
  local dir = temp_tree({
    ["root.yaml"] = {
      "openapi: 3.1.0",
      "info: { title: T, version: '1' }",
      "paths:",
      "  /a:",
      "    get:",
      "      responses:",
      '        "200":',
      "          description: OK",
      '        "404":',
      "          description: Missing",
      "          content:",
      "            application/json:",
      "              schema:",
      "                $ref: https://example.com/e.yaml",
    },
  })
  open_tree(dir, "root.yaml")
  list_goto("GET     /a")
  expect.equality(detail_line("404"), "▸ 404 Missing")
  expect.equality(header(), "")
  detail_goto("404")
  child.type_keys("<CR>")
  expect.equality(detail_line("https"), "    ✗ https://example.com/e.yaml  remote not loaded")
  expect.equality(header(), " ! 1 problem so far")
end

T["external cycles"] = MiniTest.new_set()

T["external cycles"]["a closed external ref to a schema above stays closed, and opens as the cycle row"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({ "b:", "  $ref: ./b.yaml#/B", "c:", "  $ref: ./b.yaml#/B" }),
    ["b.yaml"] = { "B:", "  properties:", "    s:", "      $ref: ./root.yaml#/components/schemas/S" },
  })
  open_tree(dir, "root.yaml")
  list_goto("   S")
  detail_goto("▸ b ")
  child.type_keys("<CR>")
  -- root.yaml is loaded, as the document itself, and b.yaml now too.
  expect.equality(detail_line(" s "), "  ▸ s  → S (root.yaml)")
  expect.equality(detail_line(" c "), "▸ c  → B (b.yaml)")
  detail_goto(" s ")
  child.type_keys("<CR>")
  -- An external ref's name carries its file, as spec 7's display name says.
  expect.equality(detail_line(" s "), "    s  ↻ S (root.yaml)  cycle")
end

T["other loads"] = MiniTest.new_set()

T["other loads"]["a path-item ref loads at open, and schema refs do not"] = function()
  spy_reads()
  open_multi("root.yaml")
  expect.equality(reads(), { "root.yaml", "pets.yaml" })
  expect.equality(
    vim.list_slice(list_lines(), 5, 8),
    { "▾ pets 3", "   GET     /pets", "   POST    /pets", "   DELETE  /pets" }
  )
end

T["other loads"]["a non-schema ref loads on selection, and a broken one counts then"] = function()
  open_multi("root.yaml")
  spy_reads()
  list_goto("GET     /pets")
  expect.equality(reads(), { "shared.yaml" })
  expect.equality(detail_line("→"), "  ▸ → pet (pet.yaml)")
  expect.equality(header(), "")
  list_goto("DELETE  /pets")
  expect.equality(detail_line("gone"), "  id  ✗ ../gone.yaml#/parameters/id  not found")
  expect.equality(header(), " ! 1 problem so far")
end

T["broken path item"] = MiniTest.new_set()

T["broken path item"]["its row is listed at open, counts, and its view and gs go to the $ref"] = function()
  open_multi("broken-path-item.yaml")
  expect.equality(header(), " ! 1 problem so far")
  expect.equality(list_lines()[#list_lines()], " ! ✗       /pets  not found")
  list_goto("/pets  not found")
  expect.equality(detail_lines(), { "/pets", "✗ ./paths/gone.yaml  not found" })
  local at_ref = find_in(raw_lines(MULTI_DIR .. "/broken-path-item.yaml"), "./paths/gone.yaml")
  child.type_keys("gs")
  expect.equality(child.api.nvim_win_get_cursor(0), at_ref)
  child.cmd("tabnext 2")
  detail_goto("✗")
  child.type_keys("gs")
  expect.equality(child.api.nvim_win_get_cursor(0), at_ref)
end

T["problems"]["the row limit stops a remote ref from counting until it is drawn"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({
      "big:",
      "  properties:",
      "    p1: { type: string }",
      "    p2: { type: string }",
      "    p3: { type: string }",
      "    p4: { type: string }",
      "r:",
      "  $ref: https://example.com/r.yaml",
    }),
  })
  open_tree(dir, "root.yaml", { max_detail_rows = 5 })
  list_goto("   S")
  expect.equality(detail_lines()[#detail_lines()], "! stopped at 5 rows (max_detail_rows)")
  expect.equality(header(), "")
  detail_goto("big")
  child.type_keys("<CR>")
  expect.equality(detail_line("https"), "  r    ✗ https://example.com/r.yaml  remote not loaded")
  expect.equality(header(), " ! 1 problem so far")
end

T["problems"]["each reason a file can give is a row once opened"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({
      "missing:",
      "  $ref: ./nothing.yaml",
      "pointer:",
      "  $ref: ./ok.yaml#/nope",
      "outside:",
      "  $ref: ../outside.yaml",
      "type:",
      "  $ref: ./notes.txt",
      "large:",
      "  $ref: ./large.yaml",
      "loop:",
      '  $ref: "#/x-loop/a"',
      "deep:",
      '  $ref: "#/x-deep/a"',
      "garbage:",
      "  $ref: ./garbage.yaml",
      "damaged:",
      "  $ref: ./damaged.yaml#/bad/y",
    }),
    ["ok.yaml"] = { "x: 1" },
    ["notes.txt"] = { "x" },
    ["large.yaml"] = { "x: " .. string.rep("a", 200) },
  })
  -- Cycle and depth chains are appended below the schemas, as extensions.
  local root = dir .. "/root.yaml"
  local text = child.fn.readfile(root)
  vim.list_extend(text, {
    "x-loop:",
    '  a: { $ref: "#/x-loop/b" }',
    '  b: { $ref: "#/x-loop/a" }',
    "x-deep:",
    '  a: { $ref: "#/x-deep/b" }',
    '  b: { $ref: "#/x-deep/c" }',
    '  c: { $ref: "#/x-deep/d" }',
    "  d: { type: string }",
  })
  write_file(root, text)
  for _, name in ipairs({ "garbage.yaml", "damaged.yaml" }) do
    child.fn.writefile(child.fn.readblob(MULTI_DIR .. "/" .. name), dir .. "/" .. name)
  end
  open_tree(dir, "root.yaml", { refs = { max_file_bytes = 100, max_depth = 2 } })
  list_goto("   S")

  local expected = {
    missing = "./nothing.yaml  not found",
    pointer = "./ok.yaml#/nope  no such pointer",
    outside = "../outside.yaml  outside root",
    type = "./notes.txt  bad file type",
    large = "./large.yaml  too large",
    loop = "#/x-loop/a  ref cycle",
    deep = "#/x-deep/a  too deep",
    garbage = "./garbage.yaml  parse failed",
    damaged = "./damaged.yaml#/bad/y  parse failed",
  }
  local names = vim.tbl_keys(expected)
  table.sort(names)
  for _, name in ipairs(names) do
    detail_goto(" " .. name .. " ")
    child.type_keys("<CR>")
    local line = detail_line(" " .. name .. " ")
    expect.equality({ name, line:match("✗ (.*)$") }, { name, expected[name] })
  end
  -- The damaged files add their own syntax diagnostics, so the broken rows are counted on their own.
  list_goto(" OpenAPI")
  local broken = vim.tbl_filter(function(line)
    return line:find("^✗ line") ~= nil
  end, detail_lines())
  expect.equality(#broken, 9)
  local count = tonumber(header():match("(%d+) problems"))
  expect.equality(count > 9, true)
  expect.equality(overview_count(), "Problems so far " .. count)
end

T["problems"]["too many files once the limit is reached"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({ "a:", "  $ref: ./a.yaml", "b:", "  $ref: ./b.yaml" }),
    ["a.yaml"] = { "type: string" },
    ["b.yaml"] = { "type: string" },
  })
  open_tree(dir, "root.yaml", { refs = { max_files = 1 } })
  list_goto("   S")
  detail_goto("a ")
  child.type_keys("<CR>")
  detail_goto("b ")
  child.type_keys("<CR>")
  expect.equality(detail_line("b "), "  b  ✗ ./b.yaml  too many files")
end

T["problems"]["no base path for an unnamed buffer"] = function()
  child.cmd("enew")
  child.api.nvim_buf_set_lines(0, 0, -1, false, schema_doc({ "a:", "  $ref: ./a.yaml" }))
  child.cmd("OasGlance")
  list_goto("   S")
  detail_goto("a ")
  child.type_keys("<CR>")
  expect.equality(detail_line("a "), "  a  ✗ ./a.yaml  no base path")
end

T["problems"]["the count grows with what is drawn, once per source position"] = function()
  open_multi("root.yaml")
  expect.equality(header(), "")
  list_goto("   Pet")
  expect.equality(header(), "")
  local cursor = child.api.nvim_win_get_cursor(pane("oasglance-list").win)
  local list_before = list_lines()
  record_list_changes()

  detail_goto("gone")
  child.type_keys("<CR>")
  expect.equality(header(), " ! 1 problem so far")
  list_goto("   Remote")
  expect.equality(header(), " ! 2 problems so far")
  list_goto("DELETE  /pets")
  expect.equality(header(), " ! 3 problems so far")

  -- The same broken refs drawn again add nothing.
  list_goto("   Remote")
  list_goto("   Pet")
  detail_goto("gone")
  child.type_keys("gd")
  list_goto("DELETE  /pets")
  expect.equality(header(), " ! 3 problems so far")
  expect.equality(overview_count(), "Problems so far 3")

  expect.equality(child.lua_get("_G.list_changes"), { { 2, 3, 3 }, { 2, 3, 3 }, { 2, 3, 3 } })
  local list_after = list_lines()
  list_before[3] = list_after[3]
  expect.equality(list_after, list_before)
  list_goto("   Pet")
  expect.equality(child.api.nvim_win_get_cursor(pane("oasglance-list").win), cursor)
end

T["problems"]["with a filter active, growth changes no list row"] = function()
  open_multi("root.yaml")
  filter_by("Remote")
  local filtered = list_lines()
  record_list_changes()
  list_goto("   Remote")
  expect.equality(detail_line("spec"), "  spec  ✗ https://example.com/pet.yaml  remote not loaded")
  expect.equality(list_lines(), filtered)
  expect.equality(child.lua_get("_G.list_changes"), {})
  child.type_keys("F")
  expect.equality(header(), " ! 1 problem so far")
end

T["problems"]["an element overlapping an error has the marker and says it may be incomplete"] = function()
  child.cmd("OasGlance tests/fixtures/broken-syntax.yaml")
  expect.equality(row_of(list_lines(), " ! GET     /bad") > 0, true)
  expect.equality(row_of(list_lines(), "   GET     /good") > 0, true)
  list_goto("GET     /bad")
  expect.equality(detail_lines()[#detail_lines()], "! This element may be incomplete.")
  list_goto("GET     /good")
  expect.equality(table.concat(detail_lines(), "\n"):find("incomplete", 1, true), nil)
end

T["problems"]["gs on a Problems line jumps to it"] = function()
  local path = "tests/fixtures/broken-syntax.yaml"
  child.cmd("OasGlance " .. path)
  detail_goto("✗ line")
  child.type_keys("gs")
  expect.equality(child.api.nvim_win_get_cursor(0), find_in(raw_lines(path), "./gone.yaml"))
  child.cmd("tabnext 2")
  local syntax_row = tonumber(detail_line("! line"):match("^! line (%d+)"))
  detail_goto("! line")
  child.type_keys("gs")
  expect.equality(child.api.nvim_win_get_cursor(0)[1], syntax_row)
end

T["problems"]["gs into an external BOM file from a buffer document subtracts 3"] = function()
  local dir = temp_tree({ ["root.yaml"] = schema_doc({ "a:", '  $ref: "./bom.yaml#"' }) })
  child.lua("vim.fn.writefile({ '\239\187\191properties: {inner: {type: string}}' }, ...)", { dir .. "/bom.yaml" })
  setup({ refs = { root = real(dir) } })
  child.cmd("edit " .. child.fn.fnameescape(dir .. "/root.yaml"))
  child.cmd("OasGlance")
  list_goto("   S")
  detail_goto("a ")
  child.type_keys("<CR>")
  detail_goto("inner")
  child.type_keys("gs")
  expect.equality(child.api.nvim_buf_get_name(0), real(dir .. "/bom.yaml"))
  expect.equality(child.lua_get("vim.bo.bomb"), true)
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, #"properties: {" })
end

T["problems"]["gs never goes below column 0"] = function()
  local dir = temp_tree({ ["root.yaml"] = schema_doc({ "a:", "  $ref: ./err.yaml" }) })
  write_file(dir .. "/err.yaml", { "]", "type: string" })
  setup({ refs = { root = real(dir) } })
  child.cmd("edit " .. child.fn.fnameescape(dir .. "/err.yaml"))
  child.cmd("setlocal bomb")
  child.cmd("OasGlance " .. child.fn.fnameescape(dir .. "/root.yaml"))
  list_goto("   S")
  detail_goto("a ")
  child.type_keys("<CR>")
  list_goto(" OpenAPI")
  detail_goto("(err.yaml)")
  expect.equality(detail_line("(err.yaml)"):find("^! line 1 ") ~= nil, true)
  child.type_keys("gs")
  expect.equality(child.api.nvim_buf_get_name(0), real(dir .. "/err.yaml"))
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 0 })
  expect.equality(child.lua_get("_G.notes"), {})
end

T["problems"]["gs into a file modified in the start window reuses its buffer"] = function()
  child.cmd("edit " .. PETSTORE)
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(buf, 2, 3, false, { "  title: Edited" })
  child.cmd("OasGlance " .. PETSTORE)
  gs_on_list_row("GET     /pets/{petId}")
  expect.equality(child.api.nvim_get_current_buf(), buf)
  expect.equality(child.api.nvim_buf_get_lines(buf, 2, 3, false), { "  title: Edited" })
  expect.equality(child.lua_get("_G.notes"), {})
end

T["reload"] = MiniTest.new_set()

T["reload"]["re-reads the file, resets the count and the history, and keeps what still exists"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({
      "a:",
      '  $ref: "#/components/schemas/T"',
      "b:",
      '  $ref: "#/components/schemas/Nope"',
    }),
  })
  local root = dir .. "/root.yaml"
  local text = child.fn.readfile(root)
  vim.list_extend(text, { "    T:", "      properties:", "        x: { type: string }" })
  write_file(root, text)
  open_tree(dir, "root.yaml")
  list_goto("   S")
  -- `gd` breaks the row without storing an open state, so after `R` it is closed again.
  detail_goto(" b ")
  child.type_keys("gd")
  expect.equality(header(), " ! 1 problem so far")
  detail_goto(" a ")
  child.type_keys("<CR>")
  expect.equality(detail_line("x "), "    x  string")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "T  object")

  text[2] = "info: { title: Reloaded, version: '1' }"
  write_file(root, text)
  child.type_keys("R")
  expect.equality(list_lines()[1], " Reloaded 1")
  expect.equality(header(), "")
  expect.equality(current_filetype(), "oasglance-detail")
  expect.equality(detail_lines()[1], "T  object")
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "T  object")

  list_goto("   S")
  expect.equality(detail_line(" a "), "▾ a  → T")
  expect.equality(detail_line(" b "), "▸ b  → Nope")
end

--- A root document whose schema S has the ref `a` with that `$ref` line, and a property `b`.
local function opened_ref_doc(ref_line, b_type, with_t)
  local text = schema_doc({ "a:", "  " .. ref_line, "b: { type: " .. b_type .. " }" })
  if with_t ~= false then
    vim.list_extend(text, { "    T:", "      properties:", "        x: { type: string }" })
  end
  return text
end

local function open_ref_a(ref_line)
  local dir = temp_tree({
    ["root.yaml"] = opened_ref_doc(ref_line, "string"),
    ["ext.yaml"] = { "type: string" },
  })
  open_tree(dir, "root.yaml")
  list_goto("   S")
  detail_goto(" a ")
  child.type_keys("<CR>")
  expect.equality(detail_line(" a "), "▾ a  → T")
  return dir .. "/root.yaml"
end

T["reload"]["an opened ref whose text is unchanged stays open and is checked again"] = function()
  local root = open_ref_a("$ref: '#/components/schemas/T'")
  write_file(root, opened_ref_doc("$ref: '#/components/schemas/T'", "integer"))
  child.type_keys("R")
  expect.equality(detail_line(" b "), "  b  integer")
  expect.equality(detail_line(" a "), "▾ a  → T")
  expect.equality(detail_line(" x "), "    x  string")

  write_file(root, opened_ref_doc("$ref: '#/components/schemas/T'", "integer", false))
  child.type_keys("R")
  expect.equality(detail_line(" a "), "  a  ✗ #/components/schemas/T  no such pointer")
end

T["reload"]["an opened ref whose text changed starts closed, and its new target is not read"] = function()
  local root = open_ref_a("$ref: '#/components/schemas/T'")
  write_file(root, opened_ref_doc("$ref: ./ext.yaml", "string"))
  spy_reads()
  child.type_keys("R")
  expect.equality(detail_line(" a "), "▸ a  → ext (ext.yaml)")
  expect.equality(vim.tbl_contains(reads(), "ext.yaml"), false)
end

T["reload"]["a re-quoted but equal ref text stays open"] = function()
  local root = open_ref_a("$ref: '#/components/schemas/T'")
  write_file(root, opened_ref_doc('$ref: "#/components/schemas/T"', "string"))
  child.type_keys("R")
  expect.equality(detail_line(" a "), "▾ a  → T")
end

T["reload"]["<BS> after R does nothing"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /pets/{petId}")
  detail_goto("→ Pet")
  child.type_keys("gd")
  local shown = detail_lines()
  child.type_keys("R", "<BS>")
  expect.equality(detail_lines(), shown)
end

T["reload"]["re-reads a buffer document"] = function()
  child.cmd("edit " .. PETSTORE)
  child.cmd("OasGlance")
  child.cmd("tabfirst")
  child.api.nvim_buf_set_lines(0, 2, 3, false, { "  title: Edited" })
  child.cmd("tabnext 2")
  child.type_keys("R")
  expect.equality(list_lines()[1], " Edited 1.0.0")
end

T["reload"]["an invalid file gives its fatal message, and the view stays"] = function()
  local dir = temp_tree({ ["root.yaml"] = schema_doc({ "a: { type: string }" }) })
  open_tree(dir, "root.yaml")
  local before = view_state()
  write_file(dir .. "/root.yaml", { "swagger: '2.0'" })
  child.type_keys("R")
  expect.equality(view_state(), before)
  local notes = child.lua_get("_G.notes")
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, vim.log.levels.ERROR)
  expect.equality(notes[1].message:find("^oas%-glance: OpenAPI 2%.0 %(Swagger%) is not supported yet: ") ~= nil, true)
end

T["reload"]["a later change of the cwd changes nothing"] = function()
  local dir = temp_tree({
    ["root.yaml"] = schema_doc({ "a:", "  $ref: ./ext.yaml" }),
    ["ext.yaml"] = { "type: string" },
  })
  child.cmd("cd " .. child.fn.fnameescape(dir))
  -- A relative ref root and a relative file name, both resolved against this cwd.
  setup({ refs = { root = "." } })
  child.cmd("OasGlance root.yaml")
  local names = pane_names()
  -- Another directory, so a root of "." read again now would leave ext.yaml outside it.
  local elsewhere = temp_tree({ ["root.yaml"] = { "openapi: 3.1.0", "info: { title: Other, version: '1' }" } })
  child.cmd("cd " .. child.fn.fnameescape(elsewhere))

  local text = child.fn.readfile(dir .. "/root.yaml")
  text[2] = "info: { title: Moved, version: '1' }"
  write_file(dir .. "/root.yaml", text)
  child.type_keys("R")
  expect.equality(child.lua_get("_G.notes"), {})
  expect.equality(list_lines()[1], " Moved 1")
  expect.equality(pane_names(), names)

  list_goto("   S")
  detail_goto(" a ")
  child.type_keys("<CR>")
  expect.equality(detail_line(" a "), "▾ a  → ext (ext.yaml)  string")

  child.cmd("tabfirst")
  child.cmd("OasGlance " .. child.fn.fnameescape(dir .. "/root.yaml"))
  expect.equality({ child.fn.tabpagenr("$"), child.fn.tabpagenr() }, { 2, 2 })

  list_goto("   S")
  child.type_keys("gs")
  expect.equality(child.api.nvim_buf_get_name(0), real(dir .. "/root.yaml"))
end

T["source"]["a file that became a FIFO is not read"] = function()
  local dir = temp_tree({ ["root.yaml"] = schema_doc({ "a: { type: string }" }) })
  local path = dir .. "/root.yaml"
  child.cmd("OasGlance " .. child.fn.fnameescape(path))
  child.fn.delete(path)
  child.fn.system({ "mkfifo", path })
  expect.equality(child.lua_get("vim.uv.fs_stat(...).type", { path }), "fifo")
  list_goto("   S")
  local before = view_state()
  child.type_keys("gs")
  expect.equality(view_state(), before)
  expect.equality(
    child.lua_get("_G.notes"),
    { { message = "oas-glance: the source file is no longer a regular file", level = WARN } }
  )
end

T["reload"]["a wiped buffer gives the ERROR message, and the view stays"] = function()
  child.cmd("enew")
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(buf, 0, -1, false, child.fn.readfile(PETSTORE))
  child.cmd("OasGlance")
  child.cmd("bwipeout! " .. buf)
  local before = view_state()
  child.type_keys("R")
  expect.equality(view_state(), before)
  expect.equality(
    child.lua_get("_G.notes"),
    { { message = "oas-glance: the source buffer no longer exists", level = vim.log.levels.ERROR } }
  )
end

-- Laziness in the UI (spec 8)

--- A generated document of `count` flow-style operations. The first is listed under two tags, `S` holds
--- closed external refs, and `GET /param` has a non-schema ref into its own file.
local function generated_tree(count)
  local root = { "openapi: 3.1.0", "info: { title: Generated, version: '1' }", "paths:" }
  root[#root + 1] = "  /both: { get: { tags: [a, b], summary: Both, responses: {} } }"
  root[#root + 1] = '  /param: { get: { tags: [a], parameters: [ { $ref: "./param.yaml#/P" } ], responses: {} } }'
  for i = 1, count do
    root[#root + 1] = string.format(
      "  /n%d: { get: { tags: [a], summary: Item %d, description: Long text %d, responses: {} } }",
      i,
      i,
      i
    )
  end
  vim.list_extend(root, {
    "components:",
    "  schemas:",
    "    S:",
    "      properties:",
    "        one: { $ref: ./one.yaml#/X }",
    "        two: { $ref: ./two.yaml#/X }",
    "        three: { $ref: ./three.yaml#/X }",
    "    Other: { type: string }",
  })
  local x = { "X: { type: string }" }
  return temp_tree({
    ["root.yaml"] = root,
    ["one.yaml"] = x,
    ["two.yaml"] = x,
    ["three.yaml"] = x,
    ["param.yaml"] = { "P: { name: p, in: query, schema: { type: string } }" },
  })
end

--- Counts Operation builds and detail renders by wrapping the modules' functions.
local function count_builds()
  child.lua([[
    _G.builds, _G.renders = 0, 0
    local model = require("oas-glance.internal.model")
    local build = model.operation
    model.operation = function(document, ref)
      if not document._operations[ref] then
        _G.builds = _G.builds + 1
      end
      return build(document, ref)
    end
    local detail = require("oas-glance.internal.render.detail")
    for _, name in ipairs({ "operation", "schema", "overview", "help" }) do
      local render = detail[name]
      detail[name] = function(...)
        _G.renders = _G.renders + 1
        return render(...)
      end
    end
  ]])
end

T["laziness"] = MiniTest.new_set()

T["laziness"]["selecting a row builds one Operation, and the same target is not rendered again"] = function()
  local dir = generated_tree(300)
  count_builds()
  open_tree(dir, "root.yaml")
  expect.equality(child.lua_get("{ _G.builds, _G.renders }"), { 0, 1 })
  child.type_keys("j", "j")
  expect.equality(child.lua_get("{ _G.builds, _G.renders }"), { 0, 1 })

  list_goto("GET     /n150")
  expect.equality(child.lua_get("{ _G.builds, _G.renders }"), { 1, 2 })

  -- `/both` is listed under `a` and under `b`: two rows, one target.
  local rows = {}
  for index, line in ipairs(list_lines()) do
    if line == "   GET     /both" then
      rows[#rows + 1] = index
    end
  end
  expect.equality(#rows, 2)
  child.type_keys(rows[1] .. "G")
  expect.equality(child.lua_get("{ _G.builds, _G.renders }"), { 2, 3 })
  child.type_keys(rows[2] .. "G")
  expect.equality(child.lua_get("{ _G.builds, _G.renders }"), { 2, 3 })
end

T["laziness"]["closed external refs load nothing until opened, and each action loads exactly its file"] = function()
  local dir = generated_tree(300)
  open_tree(dir, "root.yaml")
  spy_reads()
  list_goto("   S")
  list_goto("   Other")
  list_goto("   S")
  detail_goto(" one ")
  child.type_keys("j", "j", "k")
  expect.equality(reads(), {})

  detail_goto(" one ")
  child.type_keys("<CR>")
  expect.equality(reads(), { "one.yaml" })
  detail_goto(" two ")
  child.type_keys("gd")
  expect.equality(reads(), { "one.yaml", "two.yaml" })
  child.type_keys("<BS>")
  expect.equality(detail_line(" three "), "▸ three  → X (three.yaml)")

  list_goto("GET     /param")
  expect.equality(reads(), { "one.yaml", "two.yaml", "param.yaml" })
end

-- Health

T["health"] = MiniTest.new_set()

local function health_lines()
  child.cmd("checkhealth oas-glance")
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

T["health"]["reports the parser's path"] = function()
  local text = table.concat(health_lines(), "\n")
  local path = child.lua_get("vim.api.nvim_get_runtime_file('parser/yaml.*', false)[1]")
  expect.equality(text:find('OK tree-sitter "yaml" parser: ' .. path, 1, true) ~= nil, true)
  expect.equality(text:find("OK Neovim 0.12 or later", 1, true) ~= nil, true)
  expect.equality(text:find("ERROR", 1, true), nil)
end

T["health"]["reports an error without the parser"] = function()
  child.lua('vim.opt.runtimepath:remove("/opt/tree-sitter-yaml")')
  local text = table.concat(health_lines(), "\n")
  expect.equality(
    text:find("ERROR the tree-sitter \"yaml\" parser was not found on 'runtimepath' (parser/yaml.*)", 1, true) ~= nil,
    true
  )
  expect.equality(text:find("|oas-glance-parser|", 1, true) ~= nil, true)
end

T["health"]["reports a parser that fails to load, with its path"] = function()
  local dir = child.lua([[
    local dir = vim.fn.tempname() .. "-bad-parser"
    vim.fn.mkdir(dir .. "/parser", "p")
    vim.fn.writefile({ "not a shared object" }, dir .. "/parser/yaml.so")
    vim.opt.runtimepath:prepend(dir)
    return dir
  ]])
  local text = table.concat(health_lines(), "\n")
  expect.equality(text:find('ERROR cannot load the tree-sitter "yaml" parser: ', 1, true) ~= nil, true)
  expect.equality(text:find("Found: " .. dir .. "/parser/yaml.so", 1, true) ~= nil, true)
end

T["health"]["a load failure with no parser file left gives no path and no Lua error"] = function()
  -- The file going away between the status check and the path lookup, made exact by a stubbed check.
  child.lua([[
    vim.opt.runtimepath:remove("/opt/tree-sitter-yaml")
    require("oas-glance.internal.tree").parser_status = function()
      return false, "load", "gone"
    end
  ]])
  local text = table.concat(health_lines(), "\n")
  expect.equality(text:find('ERROR cannot load the tree-sitter "yaml" parser: gone', 1, true) ~= nil, true)
  expect.equality(text:find("Found:", 1, true), nil)
  expect.equality(text:find("attempt to", 1, true), nil)
end

-- cURL command

T["curl"] = MiniTest.new_set()

local CREATE_PET = {
  ": 'createPet: POST /pets'",
  "curl -X POST --url 'https://api.example.com/v1/pets' \\",
  "  -H 'Content-Type: application/json' \\",
  "  --data-raw '{",
  '    "name": "string"',
  "  }'",
}

local function curl_win()
  return child.lua([[
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "sh" then
        return win
      end
    end
    return false
  ]])
end

local function buf_lines(buf)
  return child.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function win_lines(win)
  return buf_lines(child.api.nvim_win_get_buf(win))
end

local function open_create_pet()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("POST    /pets")
end

local function expect_split_below_detail()
  local detail_win = pane("oasglance-detail").win
  local win = child.api.nvim_get_current_win()
  expect.equality(child.api.nvim_win_get_config(win).relative, "")
  expect.equality(child.api.nvim_win_get_tabpage(win), child.api.nvim_win_get_tabpage(detail_win))
  local position, detail_position = child.api.nvim_win_get_position(win), child.api.nvim_win_get_position(detail_win)
  expect.equality(position[1] > detail_position[1], true)
  expect.equality(position[2], detail_position[2])
  expect.equality(win, curl_win())
  expect.equality(child.api.nvim_win_get_cursor(win), { 1, 0 })
  expect.equality(win_lines(win), CREATE_PET)
end

T["curl"]["gc from the detail pane opens a split below it, focused, at row 1"] = function()
  open_create_pet()
  child.api.nvim_set_current_win(pane("oasglance-detail").win)
  child.type_keys("gc")
  expect_split_below_detail()
  expect.equality(child.lua_get("_G.notes"), {})
end

T["curl"]["gc from the list pane does the same"] = function()
  open_create_pet()
  child.type_keys("gc")
  expect_split_below_detail()
end

T["curl"]["buffer options and name"] = function()
  open_create_pet()
  child.type_keys("gc")
  local buf = child.api.nvim_win_get_buf(curl_win())
  expect.equality(
    child.lua(
      [[
      local buf = ...
      local bo = vim.bo[buf]
      return { bo.buftype, bo.filetype, bo.modifiable, bo.bufhidden, bo.swapfile, vim.b[buf].oas_glance_identity ~= nil }
    ]],
      { buf }
    ),
    { "nofile", "sh", true, "wipe", false, true }
  )
  expect.equality(child.api.nvim_buf_get_name(buf), "oas-glance://petstore-31.yaml:curl")
  expect.equality(child.api.nvim_buf_get_keymap(buf, "n"), {})
end

T["curl"]["window options"] = function()
  open_create_pet()
  child.type_keys("gc")
  local win = curl_win()
  expect.equality({
    child.api.nvim_get_option_value("winfixheight", { win = win }),
    child.api.nvim_get_option_value("statusline", { win = win }),
  }, { true, " oas-glance curl" })
end

T["curl"]["a long URL line wraps at 80 columns and the height still shows the last line"] = function()
  open_create_pet()
  child.type_keys("gc")
  local win = curl_win()
  expect.equality({ child.o.columns, child.api.nvim_get_option_value("wrap", { win = win }) }, { 80, true })
  expect.equality(#CREATE_PET[2] > child.api.nvim_win_get_width(win), true)
  expect.equality(child.api.nvim_win_get_height(win), #CREATE_PET + 1)
  expect.equality({ child.fn.line("w0"), child.fn.line("w$") }, { 1, child.fn.line("$") })
end

T["curl"]["a short command gets height 3"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("GET     /health")
  child.type_keys("gc")
  local win = curl_win()
  expect.equality(win_lines(win), { ": 'health: GET /health'", "curl --url 'https://api.example.com/v1/health'" })
  expect.equality(child.api.nvim_win_get_height(win), 3)
end

T["curl"]["a second viewer of the same file name takes the numbered :curl name"] = function()
  local a, b = unpack(petstore_copies(2))
  child.cmd("OasGlance " .. a)
  list_goto("POST    /pets")
  child.type_keys("gc")
  expect.equality(child.api.nvim_buf_get_name(0), "oas-glance://petstore.yaml:curl")
  child.cmd("OasGlance " .. b)
  expect_names("petstore.yaml (2)")
  list_goto("POST    /pets")
  child.type_keys("gc")
  expect.equality(child.api.nvim_buf_get_name(0), "oas-glance://petstore.yaml (2):curl")
end

T["curl"]["a taken :curl name moves the number"] = function()
  local a = petstore_copies(1)[1]
  child.lua("vim.api.nvim_buf_set_name(vim.api.nvim_create_buf(true, true), 'oas-glance://petstore.yaml:curl')")
  child.cmd("OasGlance " .. a)
  expect_names("petstore.yaml (2)")
  list_goto("POST    /pets")
  child.type_keys("gc")
  expect.equality(child.api.nvim_buf_get_name(0), "oas-glance://petstore.yaml (2):curl")
end

T["curl"]["a second gc on another operation reuses the window, keeps its height and replaces edits"] = function()
  open_create_pet()
  child.type_keys("gc")
  local win = curl_win()
  child.api.nvim_win_set_height(win, 10)
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
  child.api.nvim_win_set_cursor(win, { 1, 3 })
  local wins = #child.api.nvim_tabpage_list_wins(0)
  list_goto("GET     /pets/{petId}")
  child.type_keys("gc")
  expect.equality(child.api.nvim_get_current_win(), win)
  expect.equality(child.api.nvim_win_get_height(win), 10)
  expect.equality(#child.api.nvim_tabpage_list_wins(0), wins)
  expect.equality(win_lines(win), {
    ": 'showPetById: GET /pets/{petId}'",
    [[curl --url 'https://api.example.com/v1/pets/'"${PET_ID}"]],
  })
  expect.equality(child.api.nvim_win_get_cursor(win), { 1, 0 })
end

T["curl"]["after closing the cURL window, gc opens a new one"] = function()
  open_create_pet()
  child.type_keys("gc")
  local win = curl_win()
  local buf = child.api.nvim_win_get_buf(win)
  child.api.nvim_win_close(win, true)
  expect.equality(child.api.nvim_buf_is_valid(buf), false)
  list_goto("POST    /pets")
  child.type_keys("gc")
  local again = curl_win()
  expect.equality(again ~= win, true)
  expect.equality(child.api.nvim_get_current_win(), again)
  expect.equality(win_lines(again), CREATE_PET)
  expect.equality(child.api.nvim_buf_get_name(0), "oas-glance://petstore-31.yaml:curl")
end

T["curl"]["q closes it with the viewer in a multi-tabpage session and wipes the buffer"] = function()
  open_create_pet()
  child.type_keys("gc")
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_set_current_win(pane("oasglance-list").win)
  child.type_keys("q")
  expect.equality({ child.fn.tabpagenr("$"), child.api.nvim_buf_is_valid(buf), curl_win() }, { 1, false, false })
end

T["curl"]["q on the last tabpage closes it too"] = function()
  open_create_pet()
  child.cmd("tabonly")
  child.type_keys("gc")
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_set_current_win(pane("oasglance-list").win)
  child.type_keys("q")
  expect.equality(
    { #child.api.nvim_tabpage_list_wins(0), child.api.nvim_buf_is_valid(buf), curl_win() },
    { 1, false, false }
  )
end

T["curl"]["a cURL window moved to another tabpage is wiped by q"] = function()
  open_create_pet()
  child.type_keys("gc")
  local buf = child.api.nvim_get_current_buf()
  local tab = child.api.nvim_get_current_tabpage()
  child.cmd("wincmd T")
  expect.equality(child.api.nvim_get_current_tabpage() ~= tab, true)
  child.api.nvim_set_current_tabpage(tab)
  child.type_keys("q")
  expect.equality(child.api.nvim_buf_is_valid(buf), false)
end

T["curl"][":OasGlance in the cURL buffer focuses the session"] = function()
  open_create_pet()
  local tab = child.api.nvim_get_current_tabpage()
  child.type_keys("gc")
  child.cmd("wincmd T")
  local tabs = child.fn.tabpagenr("$")
  child.cmd("OasGlance")
  expect.equality({ child.fn.tabpagenr("$"), child.api.nvim_get_current_tabpage() }, { tabs, tab })
  expect.equality(child.lua_get("_G.notes"), {})
end

T["curl"]["gs from a pane never picks the cURL window as the source window"] = function()
  open_create_pet()
  child.type_keys("gc")
  local win = curl_win()
  local buf = child.api.nvim_win_get_buf(win)
  child.cmd("OasGlance tests/fixtures/types.yaml")
  local tabs = child.fn.tabpagenr("$")
  list_goto("   TypesA")
  child.type_keys("gs")
  expect.equality(child.fn.tabpagenr("$"), tabs + 1)
  expect.equality(child.fn.expand("%:t"), "types.yaml")
  expect.equality(child.api.nvim_win_get_buf(win), buf)
  expect.equality(win_lines(win), CREATE_PET)
end

local SHOW_PET = {
  ": 'showPetById: GET /pets/{petId}'",
  [[curl --url 'https://api.example.com/v1/pets/'"${PET_ID}"]],
}

--- `gc` on the list row holding `text` of the open viewer, then focus back on the list.
local function built_on(text)
  list_goto(text)
  child.type_keys("gc")
  local win = curl_win()
  child.api.nvim_set_current_win(pane("oasglance-list").win)
  return win, child.api.nvim_win_get_buf(win)
end

local function edit(buf)
  child.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
end

T["curl"]["R rebuilds the cURL text when the target is still an operation"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win, buf = built_on("POST    /pets")
  edit(buf)
  child.type_keys("R")
  expect.equality(win_lines(win), CREATE_PET)
  expect.equality(curl_win(), win)
  expect.equality(child.api.nvim_get_current_win(), pane("oasglance-list").win)
end

T["curl"]["R rebuilds from the changed file"] = function()
  local path = petstore_copies(1)[1]
  child.cmd("OasGlance " .. path)
  local win = built_on("POST    /pets")
  local text = child.fn.readfile(path)
  for index, line in ipairs(text) do
    text[index] = line:gsub("https://api%.example%.com/v1", "https://changed.example.com/v1")
  end
  write_file(path, text)
  child.type_keys("R")
  expect.equality(win_lines(win)[2], "curl -X POST --url 'https://changed.example.com/v1/pets' \\")
end

T["curl"]["R on the overview leaves edited text alone"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win, buf = built_on("POST    /pets")
  edit(buf)
  list_goto(" Petstore 1.0.0")
  child.type_keys("R")
  expect.equality(win_lines(win), { "edited" })
end

T["curl"]["moving the list cursor onto another operation rebuilds without moving focus or height"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("POST    /pets")
  local height = child.api.nvim_win_get_height(win)
  expect.equality(height, 7)
  child.api.nvim_win_set_cursor(win, { 6, 2 })
  child.lua("_G.notes = {}")
  list_goto("GET     /pets/{petId}")
  expect.equality(win_lines(win), SHOW_PET)
  expect.equality(child.api.nvim_get_current_win(), pane("oasglance-list").win)
  expect.equality(child.api.nvim_win_get_height(win), height)
  expect.equality(child.api.nvim_win_get_cursor(win), { 2, 0 })
  expect.equality(child.lua_get("_G.notes"), {})
end

T["curl"]["a row in range keeps it, at column 0"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("GET     /pets/{petId}")
  child.api.nvim_win_set_cursor(win, { 2, 5 })
  list_goto("POST    /pets")
  expect.equality(win_lines(win), CREATE_PET)
  expect.equality(child.api.nvim_win_get_cursor(win), { 2, 0 })
end

--- Deletes the first line in the cURL window, then runs `after` in the same Lua chunk. Neovim closes an
--- undo block only on its way back to the main loop, so this is the case the undo break exists for.
local function edit_then(win, after)
  child.lua(
    [[
    local win, list_win, list_row, after = ...
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, 1, false, {})
    if after == "move here" then
      vim.api.nvim_win_set_cursor(list_win, { list_row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(list_win) })
      return
    end
    vim.api.nvim_set_current_win(list_win)
    if after == "move" then
      vim.api.nvim_win_set_cursor(list_win, { list_row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(list_win) })
    else
      vim.cmd("normal gc")
    end
  ]],
    { win, pane("oasglance-list").win, row_of(list_lines(), "GET     /pets/{petId}"), after }
  )
end

T["curl"]["an edit is overwritten and one u brings it back"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("POST    /pets")
  edit_then(win, "move")
  expect.equality(win_lines(win), SHOW_PET)
  child.api.nvim_set_current_win(win)
  child.type_keys("u")
  expect.equality(win_lines(win), vim.list_slice(CREATE_PET, 2))
end

T["curl"]["a rebuild while the cURL buffer is current is its own undo step"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("POST    /pets")
  edit_then(win, "move here")
  expect.equality(win_lines(win), SHOW_PET)
  expect.equality(child.api.nvim_get_current_win(), win)
  child.type_keys("u")
  expect.equality(win_lines(win), vim.list_slice(CREATE_PET, 2))
end

T["curl"]["one u after gc brings back the edits"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("POST    /pets")
  edit_then(win, "gc")
  expect.equality(win_lines(win), CREATE_PET)
  child.type_keys("u")
  expect.equality(win_lines(win), vim.list_slice(CREATE_PET, 2))
end

T["curl"]["an edit typed as keys is overwritten by a move and one u brings it back"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("POST    /pets")
  child.api.nvim_set_current_win(win)
  child.type_keys("gg", "dd")
  list_goto("GET     /pets/{petId}")
  expect.equality(win_lines(win), SHOW_PET)
  child.api.nvim_set_current_win(win)
  child.type_keys("u")
  expect.equality(win_lines(win), vim.list_slice(CREATE_PET, 2))
end

T["curl"]["gc on the operation already built replaces edits"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win, buf = built_on("POST    /pets")
  edit(buf)
  child.type_keys("gc")
  expect.equality(win_lines(win), CREATE_PET)
end

T["curl"]["a schema, the overview, help, a webhook and a broken path item keep the text with no message"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win, buf = built_on("POST    /pets")
  edit(buf)
  child.lua("_G.notes = {}")
  local moves = {
    function()
      list_goto("   Pet")
    end,
    function()
      list_goto(" Petstore 1.0.0")
    end,
    function()
      child.type_keys("?")
    end,
    function()
      list_goto("newPet")
    end,
  }
  for index, move in ipairs(moves) do
    move()
    expect.equality({ index, win_lines(win), child.lua_get("_G.notes") }, { index, { "edited" }, {} })
  end
end

T["curl"]["a broken path item keeps the text with no message"] = function()
  open_multi("broken-path-item.yaml")
  local win, buf = built_on("GET     /health")
  edit(buf)
  child.lua("_G.notes = {}")
  list_goto("/pets  not found")
  expect.equality({ win_lines(win), child.lua_get("_G.notes") }, { { "edited" }, {} })
end

T["curl"]["gd into a schema and back keeps the text and the edits"] = function()
  open_pet_operation()
  child.type_keys("gc")
  local win = curl_win()
  edit(child.api.nvim_win_get_buf(win))
  detail_goto("▸ → Pet")
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Pet  object")
  expect.equality(win_lines(win), { "edited" })
  child.type_keys("<BS>")
  expect.equality(detail_lines()[1], "GET /pets/{petId}")
  expect.equality(win_lines(win), { "edited" })
end

T["curl"]["a group row and a detail toggle do not rebuild"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win, buf = built_on("POST    /pets")
  edit(buf)
  list_goto("▾ pets 4")
  expect.equality(win_lines(win), { "edited" })
  -- The group row selected nothing, so the target is still `POST /pets` and `show` returns early.
  list_goto("POST    /pets")
  expect.equality(win_lines(win), { "edited" })
  detail_goto("▸ → NewPet")
  child.type_keys("za")
  expect.equality(detail_line("→ NewPet"):find("▾", 1, true) ~= nil, true)
  expect.equality(win_lines(win), { "edited" })
end

T["curl"]["after the cURL window is closed, a move opens nothing"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win = built_on("POST    /pets")
  child.api.nvim_win_close(win, true)
  local wins = #child.api.nvim_tabpage_list_wins(0)
  list_goto("GET     /pets/{petId}")
  expect.equality(curl_win(), false)
  expect.equality(#child.api.nvim_tabpage_list_wins(0), wins)
  expect.equality(child.fn.bufnr("oas-glance://petstore-31.yaml:curl"), -1)
end

T["curl"]["a cURL window moved to another tabpage is not updated"] = function()
  open_create_pet()
  local tab = child.api.nvim_get_current_tabpage()
  child.type_keys("gc")
  child.cmd("wincmd T")
  local moved = child.api.nvim_get_current_win()
  child.api.nvim_set_current_tabpage(tab)
  list_goto("GET     /pets/{petId}")
  expect.equality(win_lines(moved), CREATE_PET)
  expect.equality(
    child.lua([[
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "sh" then
          return true
        end
      end
      return false
    ]]),
    false
  )
end

T["curl"]["a non-modifiable cURL buffer is skipped silently"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local win, buf = built_on("POST    /pets")
  child.api.nvim_set_option_value("modifiable", false, { buf = buf })
  child.lua("_G.notes = {}; vim.v.errmsg = ''")
  list_goto("GET     /pets/{petId}")
  expect.equality({ win_lines(win), child.lua_get("_G.notes"), child.lua_get("vim.v.errmsg") }, { CREATE_PET, {}, "" })
end

T["curl"]["a move onto an operation with a broken external body ref marks it broken"] = function()
  open_multi("curl.yaml")
  local win = built_on("POST    /pets")
  -- Building `POST /pets` already met the broken `./gone.yaml` behind `schemas/pet.yaml`.
  expect.equality(header(), " ! 1 problem so far")
  list_goto("POST    /gone")
  expect.equality(header(), " ! 2 problems so far")
  expect.equality(vim.tbl_contains(detail_lines(), "      gone  ✗ ./missing.yaml  not found"), true)
  expect.equality(win_lines(win)[5], '    "gone": null')
  expect.equality(child.api.nvim_get_current_win(), pane("oasglance-list").win)
  expect.equality(child.api.nvim_win_get_cursor(pane("oasglance-detail").win)[1], 1)
end

T["curl"]["gd then gc builds for the operation in the history"] = function()
  open_pet_operation()
  child.type_keys("gd")
  expect.equality(detail_lines()[1], "Pet  object")
  child.type_keys("gc")
  expect.equality(win_lines(curl_win()), {
    ": 'showPetById: GET /pets/{petId}'",
    [[curl --url 'https://api.example.com/v1/pets/'"${PET_ID}"]],
  })
  expect.equality(detail_lines()[1], "Pet  object")
end

T["curl"]["no operation gives a warning and opens nothing"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  local wins = #child.api.nvim_tabpage_list_wins(0)
  local message = { message = "oas-glance: show an operation to build a cURL command", level = WARN }
  local views = {
    overview = function()
      list_goto(" Petstore 1.0.0")
    end,
    help = function()
      child.type_keys("?")
    end,
    schema = function()
      list_goto("   Pet")
    end,
  }
  for _, name in ipairs({ "overview", "help", "schema" }) do
    views[name]()
    child.lua("_G.notes = {}")
    child.type_keys("gc")
    expect.equality(
      { name, child.lua_get("_G.notes"), #child.api.nvim_tabpage_list_wins(0) },
      { name, { message }, wins }
    )
  end
end

T["curl"]["a webhook gives its warning"] = function()
  child.cmd("OasGlance " .. PETSTORE)
  list_goto("newPet")
  child.lua("_G.notes = {}")
  child.type_keys("gc")
  expect.equality(child.lua_get("_G.notes"), {
    { message = "oas-glance: a webhook has no server URL, so no cURL command is built", level = WARN },
  })
  expect.equality(curl_win(), false)
end

T["curl"]["a broken path item gives its warning"] = function()
  open_multi("broken-path-item.yaml")
  list_goto("/pets  not found")
  child.lua("_G.notes = {}")
  child.type_keys("gc")
  expect.equality(child.lua_get("_G.notes"), {
    { message = "oas-glance: this path item did not load, so no cURL command is built", level = WARN },
  })
  expect.equality(curl_win(), false)
end

T["curl"]["a refused gc leaves an open cURL window untouched"] = function()
  open_create_pet()
  child.type_keys("gc")
  local win = curl_win()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
  local height = child.api.nvim_win_get_height(win)
  list_goto("   Pet")
  child.type_keys("gc")
  expect.equality(#child.lua_get("_G.notes"), 1)
  expect.equality({ child.api.nvim_win_is_valid(win), win_lines(win), child.api.nvim_win_get_height(win) }, {
    true,
    { "edited" },
    height,
  })
  expect.equality(current_filetype(), "oasglance-list")
end

T["curl"]["a broken external body ref turns broken in the detail pane and raises the count"] = function()
  open_multi("curl.yaml")
  list_goto("POST    /gone")
  expect.equality(header(), "")
  detail_goto("gone  ")
  local row = child.api.nvim_win_get_cursor(pane("oasglance-detail").win)[1]
  expect.equality(detail_lines()[row], "    ▸ gone  → missing (missing.yaml)")
  child.type_keys("gc")
  expect.equality(header(), " ! 1 problem so far")
  expect.equality(detail_lines()[row], "      gone  ✗ ./missing.yaml  not found")
  expect.equality(child.api.nvim_win_get_cursor(pane("oasglance-detail").win)[1], row)
  expect.equality(win_lines(curl_win())[5], '    "gone": null')
end

T["curl"]["keymaps.detail.curl = false removes gc, and a remapped key works"] = function()
  setup({ keymaps = { list = { curl = "gC" }, detail = { curl = false } } })
  open_create_pet()
  expect.equality(keys_of("oasglance-detail")["gc"], nil)
  local list = keys_of("oasglance-list")
  expect.equality({ list["gc"], list["gC"] }, { nil, "oas-glance list curl" })
  child.type_keys("gC")
  expect.equality(win_lines(curl_win()), CREATE_PET)
end

return T
