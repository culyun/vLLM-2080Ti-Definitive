#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/build_network_routes.sh"

usage() {
  echo "usage: $0 --repo <repo> --target <dir> --mode <commit|ref> --ref <value>" >&2
  exit 2
}

REPO=
TARGET=
MODE=
REF=
GIT_HTTP_VERSION=${GIT_HTTP_VERSION:-HTTP/1.1}
BUILD_GIT_ACTIVE_PREFIX=${BUILD_GIT_ACTIVE_PREFIX:-}
BUILD_GIT_FOREIGN_REPO_PREFIX=${BUILD_GIT_FOREIGN_REPO_PREFIX:-https://gh-proxy.com/}
BUILD_GIT_DOMESTIC_REPO_PREFIX=${BUILD_GIT_DOMESTIC_REPO_PREFIX:-https://ghfast.top/}
BUILD_GIT_MIRROR_PREFIXES=${BUILD_GIT_MIRROR_PREFIXES:-$BUILD_GIT_FOREIGN_REPO_PREFIX $BUILD_GIT_DOMESTIC_REPO_PREFIX}
BUILD_GIT_PRIMARY_TIMEOUT_SECONDS=${BUILD_GIT_PRIMARY_TIMEOUT_SECONDS:-120}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO=${2:-}
      shift 2
      ;;
    --target)
      TARGET=${2:-}
      shift 2
      ;;
    --mode)
      MODE=${2:-}
      shift 2
      ;;
    --ref)
      REF=${2:-}
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$REPO" && -n "$TARGET" && -n "$MODE" && -n "$REF" ]] || usage

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

validate_target_path() {
  local target=$1
  local parent
  local base

  case "$target" in
    ""|"/"|"."|"..")
      echo "Refusing unsafe git target path: $target" >&2
      exit 2
      ;;
  esac

  parent=$(dirname -- "$target")
  base=$(basename -- "$target")
  if [[ "$parent" == "/" || "$parent" == "." || "$base" == "." || "$base" == ".." ]]; then
    echo "Refusing unsafe git target path: $target" >&2
    exit 2
  fi
}

git_url_with_prefix() {
  local prefix=$1
  local repo=$2
  if [[ "$prefix" == *"{}"* ]]; then
    printf '%s\n' "${prefix//\{\}/$repo}"
  else
    printf '%s%s\n' "$prefix" "$repo"
  fi
}

run_git_network_cmd() {
  local timeout_seconds=${1:-}
  shift

  if [[ -n "$timeout_seconds" ]]; then
    timeout --preserve-status "$timeout_seconds" "$@"
  else
    "$@"
  fi
}

fetch_once() {
  local repo=$1
  local timeout_seconds=${2:-}

  rm -rf "$TARGET"
  mkdir -p "$(dirname -- "$TARGET")"

  case "$MODE" in
    commit)
      git init "$TARGET"
      git -c http.version="$GIT_HTTP_VERSION" -C "$TARGET" remote add origin "$repo"
      run_git_network_cmd "$timeout_seconds" \
        git -c http.version="$GIT_HTTP_VERSION" -C "$TARGET" fetch --depth=1 origin "$REF"
      git -C "$TARGET" checkout -q FETCH_HEAD
      ;;
    ref)
      run_git_network_cmd "$timeout_seconds" \
        git -c http.version="$GIT_HTTP_VERSION" clone --depth=1 --branch "$REF" --single-branch "$repo" "$TARGET"
      ;;
    *)
      usage
      ;;
  esac
}

if ! is_positive_integer "$BUILD_GIT_PRIMARY_TIMEOUT_SECONDS"; then
  echo "BUILD_GIT_PRIMARY_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi
validate_target_path "$TARGET"

if [[ -n "$BUILD_GIT_ACTIVE_PREFIX" ]]; then
  FETCH_REPO=$(git_url_with_prefix "$BUILD_GIT_ACTIVE_PREFIX" "$REPO")
else
  FETCH_REPO=$REPO
fi
echo "Git fetch attempt: $FETCH_REPO"
if fetch_once "$FETCH_REPO" "$BUILD_GIT_PRIMARY_TIMEOUT_SECONDS"; then
  exit 0
fi

declare -a MIRROR_PREFIXES=()
if [[ -n "$BUILD_GIT_ACTIVE_PREFIX" ]]; then
  MIRROR_PREFIXES+=("$BUILD_GIT_ACTIVE_PREFIX")
fi
for MIRROR_PREFIX in $BUILD_GIT_MIRROR_PREFIXES; do
  local_seen=0
  [[ -n "$MIRROR_PREFIX" ]] || continue
  for EXISTING_PREFIX in "${MIRROR_PREFIXES[@]}"; do
    if [[ "$EXISTING_PREFIX" == "$MIRROR_PREFIX" ]]; then
      local_seen=1
      break
    fi
  done
  (( local_seen == 0 )) && MIRROR_PREFIXES+=("$MIRROR_PREFIX")
done

for MIRROR_PREFIX in "${MIRROR_PREFIXES[@]}"; do
  [[ -n "$MIRROR_PREFIX" ]] || continue
  [[ -n "$BUILD_GIT_ACTIVE_PREFIX" && "$MIRROR_PREFIX" == "$BUILD_GIT_ACTIVE_PREFIX" ]] && continue
  FETCH_REPO=$(git_url_with_prefix "$MIRROR_PREFIX" "$REPO")
  echo "Git fetch attempt: $FETCH_REPO"
  if fetch_once "$FETCH_REPO" "$BUILD_GIT_PRIMARY_TIMEOUT_SECONDS"; then
    exit 0
  fi
done

echo "Git fetch failed after primary and mirror attempts: $REPO" >&2
exit 1
