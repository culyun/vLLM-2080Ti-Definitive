#!/usr/bin/env bash
set -euo pipefail

FLASHQLA_REPO=${FLASHQLA_REPO:-https://github.com/weicj/FlashQLA-SM70-SM75.git}
BUILD_PYPI_OFFICIAL_INDEX=${BUILD_PYPI_OFFICIAL_INDEX:-https://pypi.org/simple}
BUILD_PYPI_FOREIGN_INDEX=${BUILD_PYPI_FOREIGN_INDEX:-https://pypi.python.org/simple}
BUILD_PYPI_DOMESTIC_INDEX=${BUILD_PYPI_DOMESTIC_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}
BUILD_GIT_FOREIGN_REPO_PREFIX=${BUILD_GIT_FOREIGN_REPO_PREFIX:-https://gh-proxy.com/}
BUILD_GIT_DOMESTIC_REPO_PREFIX=${BUILD_GIT_DOMESTIC_REPO_PREFIX:-https://ghfast.top/}
BUILD_GIT_OFFICIAL_PROBE=${BUILD_GIT_OFFICIAL_PROBE:-${FLASHQLA_REPO}/info/refs?service=git-upload-pack}
BUILD_GIT_FOREIGN_PROBE=${BUILD_GIT_FOREIGN_PROBE:-${BUILD_GIT_FOREIGN_REPO_PREFIX}${BUILD_GIT_OFFICIAL_PROBE}}
BUILD_GIT_DOMESTIC_PROBE=${BUILD_GIT_DOMESTIC_PROBE:-${BUILD_GIT_DOMESTIC_REPO_PREFIX}${BUILD_GIT_OFFICIAL_PROBE}}
BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS=${BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS:-5}
BUILD_ROUTE_CACHE_FILE=${BUILD_ROUTE_CACHE_FILE:-/tmp/docker-build-network-routes.env}
BUILD_DOWNLOAD_SELECTED_MODE=${BUILD_DOWNLOAD_SELECTED_MODE:-}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

measure_network_url_ms() {
  local url=$1
  local timeout_seconds=${2:-6}
  local start end elapsed

  start=$(date +%s%3N)
  if command -v curl >/dev/null 2>&1; then
    curl -L --max-time "$timeout_seconds" --connect-timeout "$timeout_seconds" \
      --fail --silent --show-error --output /dev/null "$url" >/dev/null 2>&1 || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout="$timeout_seconds" -O /dev/null "$url" >/dev/null 2>&1 || return 1
  else
    return 1
  fi

  end=$(date +%s%3N)
  elapsed=$((end - start))
  (( elapsed > 0 )) || elapsed=1
  printf '%s\n' "$elapsed"
}

pypi_probe_url() {
  local index_url=$1
  printf '%s/\n' "${index_url%/}"
}

probe_download_route() {
  local mode=$1
  local pypi_url=$2
  local git_url=$3
  local git_prefix=$4
  local timeout_seconds=${BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS:-5}
  local pypi_probe
  local pypi_ms git_ms total_ms

  pypi_probe=$(pypi_probe_url "$pypi_url")
  if ! pypi_ms=$(measure_network_url_ms "$pypi_probe" "$timeout_seconds"); then
    printf 'Preflight: %-8s unavailable at Python index %s\n' "$mode" "$pypi_probe" >&2
    return 1
  fi
  if ! git_ms=$(measure_network_url_ms "$git_url" "$timeout_seconds"); then
    printf 'Preflight: %-8s unavailable at Git probe %s\n' "$mode" "$git_url" >&2
    return 1
  fi

  total_ms=$((pypi_ms + git_ms))
  printf 'Preflight: %-8s route %5sms total  PyPI=%sms  Git=%sms\n' \
    "$mode" "$total_ms" "$pypi_ms" "$git_ms" >&2
  printf '%s\t%s\t%s\t%s\t%s\n' "$total_ms" "$mode" "$pypi_ms" "$git_ms" "$git_prefix"
}

cache_selected_route() {
  mkdir -p "$(dirname -- "$BUILD_ROUTE_CACHE_FILE")"
  {
    printf 'BUILD_DOWNLOAD_SELECTED_MODE=%q\n' "${BUILD_DOWNLOAD_SELECTED_MODE:-official}"
    printf 'BUILD_PYPI_ACTIVE_INDEX=%q\n' "${BUILD_PYPI_ACTIVE_INDEX:-$BUILD_PYPI_OFFICIAL_INDEX}"
    printf 'BUILD_GIT_ACTIVE_PREFIX=%q\n' "${BUILD_GIT_ACTIVE_PREFIX:-}"
  } > "$BUILD_ROUTE_CACHE_FILE"
}

load_selected_route() {
  [[ -f "$BUILD_ROUTE_CACHE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$BUILD_ROUTE_CACHE_FILE"
  [[ -n "${BUILD_DOWNLOAD_SELECTED_MODE:-}" ]] || return 1
  echo "Preflight: reusing cached ${BUILD_DOWNLOAD_SELECTED_MODE} download route." >&2
}

infer_selected_route() {
  if [[ "${BUILD_PYPI_ACTIVE_INDEX:-}" == "$BUILD_PYPI_FOREIGN_INDEX" || \
        "${BUILD_GIT_ACTIVE_PREFIX:-}" == "$BUILD_GIT_FOREIGN_REPO_PREFIX" ]]; then
    printf '%s\n' "foreign"
  elif [[ "${BUILD_PYPI_ACTIVE_INDEX:-}" == "$BUILD_PYPI_DOMESTIC_INDEX" || \
          "${BUILD_GIT_ACTIVE_PREFIX:-}" == "$BUILD_GIT_DOMESTIC_REPO_PREFIX" ]]; then
    printf '%s\n' "domestic"
  elif [[ -n "${BUILD_PYPI_ACTIVE_INDEX:-}" || -n "${BUILD_GIT_ACTIVE_PREFIX:-}" ]]; then
    printf '%s\n' "custom"
  else
    printf '%s\n' "official"
  fi
}

choose_download_route() {
  local measurements=()
  local line
  local mode
  local probe_tmp
  local selected_line
  local selected_mode=official

  if [[ "${BUILD_NETWORK_PREFLIGHT:-1}" != "1" ]]; then
    return 0
  fi
  if [[ -n "${BUILD_PYPI_ACTIVE_INDEX:-}" || -n "${BUILD_GIT_ACTIVE_PREFIX:-}" ]]; then
    BUILD_DOWNLOAD_SELECTED_MODE=${BUILD_DOWNLOAD_SELECTED_MODE:-$(infer_selected_route)}
    echo "Preflight: using preselected ${BUILD_DOWNLOAD_SELECTED_MODE} download route." >&2
    export BUILD_DOWNLOAD_SELECTED_MODE BUILD_PYPI_ACTIVE_INDEX BUILD_GIT_ACTIVE_PREFIX
    return 0
  fi
  if load_selected_route; then
    export BUILD_DOWNLOAD_SELECTED_MODE BUILD_PYPI_ACTIVE_INDEX BUILD_GIT_ACTIVE_PREFIX
    return 0
  fi

  if ! is_positive_integer "$BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS"; then
    echo "BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS must be a positive integer." >&2
    exit 2
  fi

  echo "Preflight: benchmarking download routes..." >&2
  echo "Preflight: sample timeout is ${BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS}s per URL probe." >&2

  probe_tmp=$(mktemp -d)
  probe_download_route official "$BUILD_PYPI_OFFICIAL_INDEX" "$BUILD_GIT_OFFICIAL_PROBE" "" \
    >"$probe_tmp/official.out" 2>"$probe_tmp/official.err" &
  probe_download_route foreign "$BUILD_PYPI_FOREIGN_INDEX" "$BUILD_GIT_FOREIGN_PROBE" "$BUILD_GIT_FOREIGN_REPO_PREFIX" \
    >"$probe_tmp/foreign.out" 2>"$probe_tmp/foreign.err" &
  probe_download_route domestic "$BUILD_PYPI_DOMESTIC_INDEX" "$BUILD_GIT_DOMESTIC_PROBE" "$BUILD_GIT_DOMESTIC_REPO_PREFIX" \
    >"$probe_tmp/domestic.out" 2>"$probe_tmp/domestic.err" &
  wait || true

  for mode in official foreign domestic; do
    [[ ! -s "$probe_tmp/$mode.err" ]] || cat "$probe_tmp/$mode.err" >&2
    if [[ -s "$probe_tmp/$mode.out" ]]; then
      line=$(head -n 1 "$probe_tmp/$mode.out")
      measurements+=("$line")
    fi
  done
  rm -rf "$probe_tmp"

  if ((${#measurements[@]} > 0)); then
    selected_line=$(printf '%s\n' "${measurements[@]}" | sort -n -k1,1 | head -n 1)
    selected_mode=$(printf '%s\n' "$selected_line" | awk -F '\t' '{print $2}')
  else
    echo "Preflight: no download route probe succeeded; falling back to official-first retry order." >&2
  fi

  case "$selected_mode" in
    official)
      BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_OFFICIAL_INDEX
      BUILD_GIT_ACTIVE_PREFIX=
      ;;
    foreign)
      BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_FOREIGN_INDEX
      BUILD_GIT_ACTIVE_PREFIX=$BUILD_GIT_FOREIGN_REPO_PREFIX
      ;;
    domestic)
      BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_DOMESTIC_INDEX
      BUILD_GIT_ACTIVE_PREFIX=$BUILD_GIT_DOMESTIC_REPO_PREFIX
      ;;
  esac

  BUILD_DOWNLOAD_SELECTED_MODE=$selected_mode
  echo "Preflight: selected ${BUILD_DOWNLOAD_SELECTED_MODE} download route." >&2
  cache_selected_route
  export BUILD_DOWNLOAD_SELECTED_MODE BUILD_PYPI_ACTIVE_INDEX BUILD_GIT_ACTIVE_PREFIX
}

choose_download_route
