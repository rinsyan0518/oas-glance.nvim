#!/bin/sh
# Container-side entry point. Any failed step exits 1.
set -u

mkdir -p /tmp/home /tmp/xdg/config /tmp/xdg/data /tmp/xdg/state /tmp/xdg/cache /tmp/xdg/run || exit 1

# Zero collected cases and start-up errors must fail, not quit with 0 or leave Neovim waiting.
TEST_RUNNER='
local file = vim.env.OAS_GLANCE_TEST_FILE or ""
local collect = { find_files = file ~= "" and function() return { file } end or nil }
local ok, err = pcall(function()
  if #MiniTest.collect(collect) == 0 then
    error("no test cases collected")
  end
  local stdout = MiniTest.gen_reporter.stdout()
  local cases = {}
  local reporter = {
    start = function(all_cases)
      cases = all_cases
      stdout.start(all_cases)
    end,
    update = stdout.update,
    finish = function()
      local all_ran = true
      for _, case in ipairs(cases) do
        local state = type(case.exec) == "table" and case.exec.state or ""
        all_ran = all_ran and (state:find("^Pass") ~= nil or state:find("^Fail") ~= nil)
      end
      if all_ran then
        vim.fn.writefile({}, vim.env.OAS_GLANCE_TESTS_DONE)
      end
      stdout.finish()
    end,
  }
  MiniTest.run({ collect = collect, execute = { reporter = reporter } })
end)
if not ok then
  io.stderr:write(tostring(err), "\n")
  vim.cmd("cquit 1")
end
'

# A test that quits Neovim or stops the run ends it with 0 before later failures count, so every case must have run.
run_tests() {
  done_file="/tmp/oas-glance-tests-done.$$"
  rm -f "$done_file"
  OAS_GLANCE_TESTS_DONE="$done_file" OAS_GLANCE_TEST_FILE="${1:-}" timeout 120 nvim --headless -u scripts/minimal_init.lua -c "lua $TEST_RUNNER"
  run_status=$?
  [ "$run_status" -eq 0 ] || return "$run_status"
  if [ ! -e "$done_file" ]; then
    echo "tasks: the test run ended before every case ran, so it did not pass" >&2
    return 1
  fi
}

# mini.test only collects test_*.lua, so another name would silently never run.
check_test_names() {
  bad=0
  for file in tests/*.lua; do
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      continue
    fi
    case "$file" in
      tests/helpers.lua | tests/test_*.lua) ;;
      *)
        echo "tasks: $file is not run by the tests, name it tests/test_*.lua" >&2
        bad=1
        ;;
    esac
  done
  return "$bad"
}

task_test() {
  check_test_names || return 1
  run_tests
}

task_test_file() {
  if [ ! -f "${1:-}" ]; then
    echo "tasks: no such test file: ${1:-}" >&2
    return 1
  fi
  run_tests "$1"
}

task_update_screenshots() {
  check_test_names || return 1
  OAS_GLANCE_UPDATE_REFERENCES=1 run_tests
}

existing_lua_dirs() {
  while IFS= read -r dir || [ -n "$dir" ]; do
    if [ -d "$dir" ]; then
      printf '%s\n' "$dir"
    fi
  done <scripts/lua-dirs
}

# LuaLS cannot take a directory list, so no Lua file may sit outside the list.
check_stray_lua() {
  set --
  while IFS= read -r dir || [ -n "$dir" ]; do
    set -- "$@" -path "./$dir" -prune -o
  done <scripts/lua-dirs || return 1
  stray="$(find . -path ./tmp -prune -o -path ./.hook-state -prune -o "$@" -name '*.lua' ! -type d -print)" || return 1
  if [ -n "$stray" ]; then
    printf '%s\n' "$stray" | while IFS= read -r file; do
      echo "tasks: $file is outside the Lua directories, add its directory to scripts/lua-dirs" >&2
    done
    return 1
  fi
}

task_format() {
  check_stray_lua || return 1
  dirs="$(existing_lua_dirs)" || return 1
  stylua --allow-hidden $dirs
}

task_format_check() {
  check_stray_lua || return 1
  dirs="$(existing_lua_dirs)" || return 1
  stylua --allow-hidden --check $dirs
}

# selene can report a config or feature error and still exit 0.
task_lint() {
  check_stray_lua || return 1
  dirs="$(existing_lua_dirs)" || return 1
  selene $dirs >/tmp/selene.out 2>&1
  status=$?
  cat /tmp/selene.out
  if grep -q '^ERROR' /tmp/selene.out; then
    return 1
  fi
  return "$status"
}

task_typecheck() {
  check_stray_lua || return 1
  mkdir -p /tmp/luals || return 1
  if ! lua-language-server --check=/work --configpath=/work/.luarc.json \
    --check_format=json --check_out_path=/tmp/luals/check.json \
    --logpath=/tmp/luals/log --metapath=/tmp/luals/meta; then
    cat /tmp/luals/check.json
    echo
    return 1
  fi
}

generate_doc() {
  OAS_GLANCE_DOC_OUTPUT="$1" timeout 120 nvim --headless -u scripts/minimal_init.lua -l scripts/minidoc.lua
}

task_doc() {
  generate_doc doc/oas-glance.txt
}

task_doc_check() {
  mkdir -p /tmp/doc || return 1
  generate_doc /tmp/doc/oas-glance.txt || return 1
  diff -u doc/oas-glance.txt /tmp/doc/oas-glance.txt
}

# Interactive, so no timeout.
task_try() {
  nvim -u scripts/try_init.lua
}

task_check() {
  summary=""
  failed=""
  for step in format-check lint typecheck test doc-check; do
    echo "==> $step"
    case "$step" in
      format-check) task_format_check ;;
      lint) task_lint ;;
      typecheck) task_typecheck ;;
      test) task_test ;;
      doc-check) task_doc_check ;;
    esac
    if [ $? -eq 0 ]; then
      summary="$summary
PASS $step"
    else
      summary="$summary
FAIL $step"
      failed="$failed $step"
    fi
    echo
  done
  echo "==> summary$summary"
  if [ -n "$failed" ]; then
    echo "check failed:$failed"
    return 1
  fi
  echo "check passed"
}

task="${1:-}"
[ $# -gt 0 ] && shift

case "$task" in
  check) task_check || exit 1 ;;
  doc) task_doc || exit 1 ;;
  doc-check) task_doc_check || exit 1 ;;
  format) task_format || exit 1 ;;
  format-check) task_format_check || exit 1 ;;
  lint) task_lint || exit 1 ;;
  typecheck) task_typecheck || exit 1 ;;
  test) task_test || exit 1 ;;
  test-file) task_test_file "$@" || exit 1 ;;
  try) task_try || exit 1 ;;
  update-screenshots) task_update_screenshots || exit 1 ;;
  *)
    echo "tasks: unknown task: $task" >&2
    exit 1
    ;;
esac
