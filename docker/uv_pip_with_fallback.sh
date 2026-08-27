#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/build_network_routes.sh"

BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS=${BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS:-60}
BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS=${BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS:-$BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS}
BUILD_PYPI_MIRROR_INDEX=${BUILD_PYPI_MIRROR_INDEX:-${BUILD_PYPI_DOMESTIC_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}}
BUILD_WHEELHOUSE_DIR=${BUILD_WHEELHOUSE_DIR:-}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

WHEELHOUSE_DIR=$BUILD_WHEELHOUSE_DIR
if [[ -z "$WHEELHOUSE_DIR" && -d /data/wheelhouse/cu128 ]]; then
  WHEELHOUSE_DIR=/data/wheelhouse/cu128
fi

declare -a UV_ENV=(env)
if [[ -n "$WHEELHOUSE_DIR" ]]; then
  if [[ -d "$WHEELHOUSE_DIR" ]]; then
    UV_ENV+=("UV_FIND_LINKS=$WHEELHOUSE_DIR")
  else
    echo "BUILD_WHEELHOUSE_DIR does not exist: $WHEELHOUSE_DIR" >&2
    exit 2
  fi
fi

if [[ "${BUILD_PYPI_MIRROR_FALLBACK:-1}" != "1" ]]; then
  if [[ -n "${BUILD_PYPI_ACTIVE_INDEX:-}" ]]; then
    exec "${UV_ENV[@]}" UV_DEFAULT_INDEX="$BUILD_PYPI_ACTIVE_INDEX" uv pip "$@"
  fi
  exec "${UV_ENV[@]}" uv pip "$@"
fi

if ! is_positive_integer "$BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS"; then
  echo "BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi
if ! is_positive_integer "$BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS"; then
  echo "BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi

if [[ -n "${BUILD_PYPI_ACTIVE_INDEX:-}" ]]; then
  if "${UV_ENV[@]}" UV_DEFAULT_INDEX="$BUILD_PYPI_ACTIVE_INDEX" \
      timeout --preserve-status "$BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS" uv pip "$@"; then
    exit 0
  fi
else
  if "${UV_ENV[@]}" timeout --preserve-status "$BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS" uv pip "$@"; then
    exit 0
  fi
fi

echo "Selected-route Python package install failed; retrying with mirror index." >&2
exec "${UV_ENV[@]}" UV_DEFAULT_INDEX="$BUILD_PYPI_MIRROR_INDEX" \
  timeout --preserve-status "$BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS" uv pip "$@"
