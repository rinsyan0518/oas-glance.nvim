#!/bin/sh
# Host-side entry point. The only place that holds docker run flags.
#
# Usage:
#   docker-run.sh tag
#   docker-run.sh docker-check
#   docker-run.sh image
#   docker-run.sh clean-image
#   docker-run.sh [--no-build] [--name NAME] TASK [ARGS...]
#   docker-run.sh [--no-build] [--name NAME] try [FILE]
#
# OAS_GLANCE_PLATFORM=linux/amd64 or linux/arm64 builds, tags and runs that platform instead of the native one.
#
# Own exit codes, distinct from a failed check (1) and from Docker's codes:
EXIT_NO_DOCKER=3
EXIT_NO_DAEMON=4
EXIT_NO_IMAGE=5

set -u

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd -P)"

# The value reaches a tag and a command line.
platform="${OAS_GLANCE_PLATFORM:-}"
case "$platform" in
  "" | linux/amd64 | linux/arm64) ;;
  *)
    echo "docker-run: OAS_GLANCE_PLATFORM must be linux/amd64 or linux/arm64" >&2
    exit 64
    ;;
esac

image_tag() {
  hash="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git hash-object Dockerfile)" || exit 1
  if [ -n "$platform" ]; then
    printf 'oas-glance-dev:%s-%s\n' "$hash" "${platform#linux/}"
  else
    printf 'oas-glance-dev:%s\n' "$hash"
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker-run: docker is not installed" >&2
    exit "$EXIT_NO_DOCKER"
  fi
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 </dev/null &
  pid=$!
  ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge 50 ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "docker-run: the Docker daemon did not answer within 5 seconds" >&2
      exit "$EXIT_NO_DAEMON"
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if ! wait "$pid" 2>/dev/null; then
    echo "docker-run: the Docker daemon is not answering" >&2
    exit "$EXIT_NO_DAEMON"
  fi
}

build_image() {
  if [ -n "$platform" ]; then
    docker build --platform "$platform" -t "$1" .
  else
    docker build -t "$1" .
  fi
}

refuse() {
  echo "docker-run: refusing to run: $1" >&2
  exit 1
}

# Docker would follow a symlink on the host, and mkdir -p would create a directory through one.
check_real_path() {
  rest="$1"
  walk="$ROOT"
  while [ -n "$rest" ]; do
    walk="$walk/${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    [ -L "$walk" ] && refuse "$1 goes through a symlink"
    [ -e "$walk" ] || return 0
    [ "$(cd "$walk" 2>/dev/null && pwd -P)" = "$walk" ] || refuse "$1 is not a directory at $walk"
  done
}

bad_outputs() {
  dir="$1"
  shift
  [ -d "$dir" ] || return 0
  LC_ALL=C find "$dir" -mindepth 1 ! \( -type f -name .DS_Store \) \
    \( ! -type f -o -perm -100 -o -perm -010 -o -perm -001 -o "$@" \) -print || echo "$dir, which could not be read"
}

# Tests can write these directories, and git or make on the host would obey what they left. This only looks, so no git runs there.
check_outputs() {
  found="$(
    bad_outputs tests/screenshots -name '*[!a-z0-9_-]*' -o -name config -o -name objects -o -name refs -o -name makefile -o -name gnumakefile
    bad_outputs tests/snapshots ! -name '*.txt' -o -name '.*' -o -name '*[!a-z0-9_.-]*'
    bad_outputs doc ! -name oas-glance.txt
  )"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" | while IFS= read -r path; do
      echo "docker-run: not a reference file: $path" >&2
    done
    echo "docker-run: nothing was deleted. Remove it by hand, and run no git or make in that directory until you have." >&2
    exit 1
  fi
}

try_refuse() {
  echo "docker-run: try: $1" >&2
  exit 1
}

has_control() {
  case "$1" in
    *[[:cntrl:]]*) return 0 ;;
  esac
  return 1
}

# Sets try_resolved to the real path of $1, following symlinks in every component.
# The trailing x keeps command substitution from dropping trailing newlines.
resolve_try_file() {
  # cd treats a bare `-` as $OLDPWD, even after `--`.
  case "$1" in
    /*) path="$1" ;;
    *) path="./$1" ;;
  esac
  hops=0
  while :; do
    dir="$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd -P && echo x)" || try_refuse "no such file: $given"
    dir="${dir%x}"
    dir="${dir%?}"
    has_control "$dir" && try_refuse "unsupported character in $given"
    path="$dir/$(basename -- "$path")"
    [ -L "$path" ] || break
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || try_refuse "no such file: $given"
    target="$(readlink "$path" && echo x)" || try_refuse "no such file: $given"
    target="${target%x}"
    target="${target%?}"
    has_control "$target" && try_refuse "unsupported character in $given"
    case "$target" in
      /*) path="$target" ;;
      *) path="$dir/$target" ;;
    esac
  done
  try_resolved="$path"
}

# The file name reaches the container only as an environment variable.
prepare_try() {
  if ! { [ -t 0 ] && [ -t 1 ]; }; then
    echo "docker-run: try needs a terminal; run it from an interactive shell" >&2
    exit 1
  fi
  given="${1:-}"
  [ -n "$given" ] || given=tests/fixtures/petstore-31.yaml
  has_control "$given" && try_refuse "unsupported character in $given"
  { [ -f "$given" ] && [ -r "$given" ]; } || try_refuse "no such file: $given"
  unset CDPATH
  resolve_try_file "$given"
  has_control "$try_resolved" && try_refuse "unsupported character in $given"
  case "$try_resolved" in
    "$ROOT"/*) ;;
    *) try_refuse "$given is outside this repository; copy it into tmp/ to try it" ;;
  esac
  try_file="/work/${try_resolved#"$ROOT"/}"
}

case "${1:-}" in
  tag)
    image_tag
    exit 0
    ;;
  docker-check)
    require_docker
    exit 0
    ;;
  image)
    require_docker
    IMAGE="$(image_tag)" || exit 1
    build_image "$IMAGE"
    exit $?
    ;;
  clean-image)
    require_docker
    for image in $(docker images oas-glance-dev --format '{{.Repository}}:{{.Tag}}'); do
      docker image rm "$image" >/dev/null || exit 1
      echo "removed $image"
    done
    exit 0
    ;;
esac

no_build=0
name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)
      no_build=1
      shift
      ;;
    --name)
      name="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "docker-run: no task given" >&2
  exit 64
fi

task="$1"

if [ "$task" = try ]; then
  prepare_try "${2:-}"
  set -- try
fi

LC_ALL=C grep -Evq '^[a-z]+$' scripts/lua-dirs
[ $? -eq 1 ] || refuse "scripts/lua-dirs must hold one [a-z]+ name per line"

case "$task" in
  update-screenshots) write_dirs="tests/screenshots tests/snapshots" ;;
  doc) write_dirs="doc" ;;
  format)
    write_dirs=""
    while IFS= read -r dir || [ -n "$dir" ]; do
      if [ "$dir" != scripts ] && { [ -d "$dir" ] || [ -L "$dir" ]; }; then
        write_dirs="$write_dirs $dir"
      fi
    done <scripts/lua-dirs
    ;;
  *) write_dirs="" ;;
esac

for path in .hook-state tests/screenshots tests/snapshots doc $write_dirs; do
  check_real_path "$path"
done
if [ "$task" = format ]; then
  check_real_path scripts
  for file in scripts/*.lua scripts/.*.lua; do
    [ -L "$file" ] && refuse "$file is a symlink"
  done
fi
check_outputs

mkdir -p .hook-state $write_dirs || exit 1

require_docker
IMAGE="$(image_tag)" || exit 1

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [ "$no_build" -eq 1 ]; then
    echo "docker-run: image $IMAGE is missing, run: make image" >&2
    exit "$EXIT_NO_IMAGE"
  fi
  build_image "$IMAGE" || exit $?
fi

if [ -n "$name" ]; then
  set -- --name "$name" "$IMAGE" scripts/tasks.sh "$@"
else
  set -- "$IMAGE" scripts/tasks.sh "$@"
fi

# Tools would otherwise read .git/info/exclude, so a local rule could hide files from the check.
if [ -d .git ]; then
  set -- --tmpfs /work/.git:ro "$@"
elif [ -e .git ]; then
  set -- -v /dev/null:/work/.git:ro "$@"
fi

for path in $write_dirs; do
  set -- -v "$ROOT/$path:/work/$path:rw" "$@"
done
[ -n "$platform" ] && set -- --platform "$platform" "$@"
if [ "$task" = try ]; then
  [ -n "${TERM:-}" ] && set -- -e TERM "$@"
  set -- -it -e "OAS_GLANCE_TRY_FILE=$try_file" "$@"
fi
if [ "$task" = format ]; then
  for file in scripts/*.lua scripts/.*.lua; do
    [ -f "$file" ] && set -- -v "$ROOT/$file:/work/$file:rw" "$@"
  done
fi

set -- docker run --rm --init --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 --memory 4g \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT:/work:ro" -w /work \
  --tmpfs /work/.hook-state:ro \
  --tmpfs /tmp:rw,exec,mode=1777 \
  -e HOME=/tmp/home -e TMPDIR=/tmp \
  -e XDG_CONFIG_HOME=/tmp/xdg/config -e XDG_DATA_HOME=/tmp/xdg/data \
  -e XDG_STATE_HOME=/tmp/xdg/state -e XDG_CACHE_HOME=/tmp/xdg/cache \
  -e XDG_RUNTIME_DIR=/tmp/xdg/run \
  "$@"

# Only these tasks run repo code with write access. format runs StyLua alone, from the image, on files it cannot execute.
case "$task" in
  update-screenshots | doc)
    "$@"
    status=$?
    check_outputs
    exit "$status"
    ;;
esac

exec "$@"
