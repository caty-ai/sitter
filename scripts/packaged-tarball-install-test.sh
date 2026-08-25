#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH_ROOT=''

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  exit 1
}

cleanup() {
  if [[ -n $SCRATCH_ROOT && -d $SCRATCH_ROOT ]]; then
    rm -rf "$SCRATCH_ROOT"
  fi
}

require_npm() {
  if command -v npm >/dev/null 2>&1; then
    pass 'npm available'
    return
  fi
  printf 'missing-dep: npm\n' >&2
  exit 127
}

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
    return
  fi
  printf 'FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
  exit 1
}

assert_file() {
  local label=$1 path=$2
  if [[ -e $path ]]; then
    pass "$label"
    return
  fi
  printf 'FAIL %s (%s)\n' "$label" "$path"
  exit 1
}

assert_cmp() {
  local label=$1 left=$2 right=$3
  if cmp "$left" "$right" >/dev/null 2>&1; then
    pass "$label"
    return
  fi
  printf 'FAIL %s (%s vs %s)\n' "$label" "$left" "$right"
  exit 1
}

read_repo_version() {
  sed -n "s/^SITTER_VERSION='\\(.*\\)'$/\\1/p" "$ROOT/sitter"
}

read_package_version() {
  (
    cd "$1"
    npm pkg get version
  ) | tr -d '"'
}

resolve_path() {
  local path=$1 dir target
  while [[ -L $path ]]; do
    dir=$(cd "$(dirname "$path")" && pwd -P)
    target=$(readlink "$path") || return 1
    case $target in
      /*) path=$target ;;
      *) path=$dir/$target ;;
    esac
  done
  dir=$(cd "$(dirname "$path")" && pwd -P)
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

find_installed_bin() {
  local prefix=$1 candidate=$1/bin/sitter fallback=''
  if [[ -e $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  fallback=$(find "$prefix" \( -type f -o -type l \) -path '*/bin/sitter' -print -quit)
  if [[ -n $fallback ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

main() {
  local stage_dir pack_dir install_prefix sitter_home smoke_ledger repo_version staged_version
  local expected_tarball tarball_path tarball_name installed_bin installed_target installed_version

  require_npm

  SCRATCH_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sitter-packaged-install.XXXXXX") || fail 'mktemp scratch root'
  trap cleanup EXIT HUP INT TERM

  stage_dir=$SCRATCH_ROOT/stage
  pack_dir=$SCRATCH_ROOT/pack
  install_prefix=$SCRATCH_ROOT/prefix
  sitter_home=$SCRATCH_ROOT/sitter-home
  smoke_ledger=$SCRATCH_ROOT/sitter-test.jsonl

  mkdir -p "$stage_dir" "$pack_dir" "$install_prefix" "$sitter_home" "$SCRATCH_ROOT/npm-cache"
  export npm_config_cache=$SCRATCH_ROOT/npm-cache
  cp -R "$ROOT/packages/npm/." "$stage_dir"
  cp -p "$ROOT/sitter" "$ROOT/LICENSE" "$stage_dir/"
  assert_cmp 'staged sitter matches repo' "$ROOT/sitter" "$stage_dir/sitter"
  assert_cmp 'staged LICENSE matches repo' "$ROOT/LICENSE" "$stage_dir/LICENSE"

  repo_version=$(read_repo_version)
  [[ -n $repo_version ]] || fail 'repo version detected'
  pass 'repo version detected'

  staged_version=$(read_package_version "$stage_dir")
  [[ -n $staged_version ]] || fail 'staged package version detected'
  pass 'staged package version detected'
  assert_eq 'repo and staged versions agree' "$repo_version" "$staged_version"

  if (
    cd "$stage_dir"
    npm pack --pack-destination "$pack_dir" --silent >/dev/null
  ); then
    pass 'npm pack succeeded'
  else
    fail 'npm pack succeeded'
  fi

  shopt -s nullglob
  set -- "$pack_dir"/*.tgz
  shopt -u nullglob
  [[ $# -eq 1 ]] || fail 'exactly one tarball created'
  pass 'exactly one tarball created'
  tarball_path=$1
  tarball_name=$(basename "$tarball_path")
  expected_tarball=caty-ai-sitter-"$staged_version".tgz
  assert_eq 'tarball filename matches version' "$expected_tarball" "$tarball_name"

  if npm install --global --prefix "$install_prefix" --offline --no-audit --no-fund --silent "$tarball_path" >/dev/null; then
    pass 'local tarball install succeeded'
  else
    fail 'local tarball install succeeded'
  fi

  installed_bin=$(find_installed_bin "$install_prefix") || fail 'installed sitter binary found'
  assert_file 'installed sitter binary found' "$installed_bin"
  installed_target=$(resolve_path "$installed_bin") || fail 'installed sitter target resolved'
  assert_cmp 'installed sitter matches repo script' "$ROOT/sitter" "$installed_target"

  installed_version=$("$installed_bin" --version)
  assert_eq 'repo, package, and installed versions agree' "sitter $repo_version" "$installed_version"

  if SITTER_HOME=$sitter_home "$installed_bin" run --ledger "$smoke_ledger" --on-fail 'cat >&2' -- sh -c 'sleep 3; echo test'; then
    pass 'README smoke command succeeded'
  else
    fail 'README smoke command succeeded'
  fi
  if grep -o '"status":"success"' "$smoke_ledger" >/dev/null 2>&1; then
    pass 'README smoke ledger records success'
    return
  fi
  fail 'README smoke ledger records success'
}

main "$@"
