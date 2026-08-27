#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT_RELEASE_FILE=${PROJECT_RELEASE_FILE:-"$ROOT_DIR/PROJECT_RELEASE.env"}
if [[ -f "$PROJECT_RELEASE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$PROJECT_RELEASE_FILE"
fi

COMPOSE_FILE=${COMPOSE_FILE:-"$ROOT_DIR/docker/docker-compose.yml"}
DOCKERFILE=${DOCKERFILE:-"$ROOT_DIR/docker/Dockerfile"}
COMPOSE_SERVICE=${COMPOSE_SERVICE:-vllm}
VLLM_IMAGE=${VLLM_IMAGE:-local/vllm-2080ti-definitive:v${FORK_RELEASE#v}}

FLASHQLA_REPO=${FLASHQLA_REPO:-https://github.com/weicj/FlashQLA-SM70-SM75.git}
FLASHQLA_REF=${FLASHQLA_REF:-3ab27d77d8ca01d7a4718903b726add1a8886c0e}
BUILD_PYPI_OFFICIAL_INDEX=${BUILD_PYPI_OFFICIAL_INDEX:-https://pypi.org/simple}
BUILD_PYPI_FOREIGN_INDEX=${BUILD_PYPI_FOREIGN_INDEX:-https://pypi.python.org/simple}
BUILD_PYPI_DOMESTIC_INDEX=${BUILD_PYPI_DOMESTIC_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}
BUILD_GIT_FOREIGN_REPO_PREFIX=${BUILD_GIT_FOREIGN_REPO_PREFIX:-https://gh-proxy.com/}
BUILD_GIT_DOMESTIC_REPO_PREFIX=${BUILD_GIT_DOMESTIC_REPO_PREFIX:-https://ghfast.top/}
BUILD_GIT_OFFICIAL_PROBE=${BUILD_GIT_OFFICIAL_PROBE:-${FLASHQLA_REPO}/info/refs?service=git-upload-pack}
BUILD_GIT_FOREIGN_PROBE=${BUILD_GIT_FOREIGN_PROBE:-${BUILD_GIT_FOREIGN_REPO_PREFIX}${BUILD_GIT_OFFICIAL_PROBE}}
BUILD_GIT_DOMESTIC_PROBE=${BUILD_GIT_DOMESTIC_PROBE:-${BUILD_GIT_DOMESTIC_REPO_PREFIX}${BUILD_GIT_OFFICIAL_PROBE}}
BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS=${BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS:-5}
BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS=${BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS:-60}
BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS=${BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS:-$BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS}
BUILD_PYPI_MIRROR_INDEX=${BUILD_PYPI_MIRROR_INDEX:-$BUILD_PYPI_DOMESTIC_INDEX}
BUILD_PYPI_MIRROR_FALLBACK=${BUILD_PYPI_MIRROR_FALLBACK:-1}
BUILD_WHEELHOUSE_DIR=${BUILD_WHEELHOUSE_DIR:-}
BUILD_NETWORK_PREFLIGHT=${BUILD_NETWORK_PREFLIGHT:-1}
BUILD_GIT_PRIMARY_TIMEOUT_SECONDS=${BUILD_GIT_PRIMARY_TIMEOUT_SECONDS:-120}
BUILD_GIT_MIRROR_PREFIXES=${BUILD_GIT_MIRROR_PREFIXES:-https://gh-proxy.com/ https://ghfast.top/}
CUTLASS_REPO=${CUTLASS_REPO:-https://github.com/nvidia/cutlass.git}
CUTLASS_REVISION=${CUTLASS_REVISION:-da5e086dab31d63815acafdac9a9c5893b1c69e2}
TRITON_REPO=${TRITON_REPO:-https://github.com/triton-lang/triton.git}
TRITON_TAG=${TRITON_TAG:-7c56a5e40f7fd928dfd5c72902d5def0097db73a}

ACTION=docker
DRY_RUN=0
declare -a EXTRA_ARGS=()

usage() {
  cat <<'EOF'
usage:
  docker/build.sh [docker] [--dry-run] [extra docker build args...]
  docker/build.sh compose [--dry-run] [extra docker compose build args...]
  docker/build.sh env

examples:
  ./docker/build.sh
  ./docker/build.sh --dry-run --progress=plain
  ./docker/build.sh compose --dry-run --no-cache
  ./docker/build.sh env
EOF
}

fail() {
  echo "$*" >&2
  exit 1
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

detect_cpu_threads() {
  local threads
  threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  if ! is_positive_integer "$threads"; then
    threads=$(nproc 2>/dev/null || true)
  fi
  if ! is_positive_integer "$threads"; then
    threads=4
  fi
  printf '%s\n' "$threads"
}

detect_memory_gb() {
  local mem_kb mem_gb
  mem_kb=$(awk '/MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
  mem_gb=$(( mem_kb / 1024 / 1024 ))
  if (( mem_gb < 1 )); then
    mem_gb=1
  fi
  printf '%s\n' "$mem_gb"
}

select_max_jobs() {
  local threads=$1
  local mem_gb=$2
  local reserve_gb=3
  local per_job_gb=3
  local mem_limited_jobs

  mem_limited_jobs=$(( (mem_gb - reserve_gb) / per_job_gb ))
  (( mem_limited_jobs >= 1 )) || mem_limited_jobs=1
  (( mem_limited_jobs <= threads )) || mem_limited_jobs=$threads

  printf '%s\n' "$mem_limited_jobs"
}

validate_max_jobs_range() {
  local jobs=$1
  local threads=$2
  is_positive_integer "$jobs" || fail "MAX_JOBS must be a positive integer."
  if (( jobs < 1 || jobs > threads )); then
    fail "MAX_JOBS must be between 1 and CPU_THREADS ($threads)."
  fi
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
  local timeout_seconds=${BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS:-5}
  local pypi_probe pypi_ms git_ms total_ms

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
  printf '%s\t%s\t%s\t%s\n' "$total_ms" "$mode" "$pypi_ms" "$git_ms"
}

prompt_yes_no_timeout() {
  local prompt=$1
  local timeout_seconds=${2:-10}
  local default_answer=${3:-y}
  local answer=""

  if [[ "${ASSUME_YES:-0}" == "1" || "${YES:-0}" == "1" ]]; then
    printf '%s\n' "$default_answer"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    printf '%s\n' "$default_answer"
    return 0
  fi

  if [[ "$default_answer" == "y" ]]; then
    printf '%s ' "$prompt"
    if ! read -r -t "$timeout_seconds" answer; then
      answer=""
    fi
    case "$answer" in
      n|N) printf 'n\n' ;;
      *) printf 'y\n' ;;
    esac
    return 0
  fi

  printf '%s ' "$prompt"
  if ! read -r -t "$timeout_seconds" answer; then
    answer=""
  fi
  case "$answer" in
    y|Y) printf 'y\n' ;;
    *) printf 'n\n' ;;
  esac
}

infer_selected_mode() {
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

choose_download_mode() {
  local measurements=()
  local line selected_line selected_mode selected_total selected_pypi selected_git
  local probe_tmp
  local -a probe_jobs=()
  local item pid mode answer

  if [[ "${BUILD_NETWORK_PREFLIGHT:-1}" != "1" ]]; then
    BUILD_DOWNLOAD_SELECTED_MODE=${BUILD_DOWNLOAD_SELECTED_MODE:-$(infer_selected_mode)}
    return 0
  fi

  if [[ -n "${BUILD_PYPI_ACTIVE_INDEX:-}" || -n "${BUILD_GIT_ACTIVE_PREFIX:-}" ]]; then
    BUILD_DOWNLOAD_SELECTED_MODE=${BUILD_DOWNLOAD_SELECTED_MODE:-$(infer_selected_mode)}
    echo "Preflight: using preselected ${BUILD_DOWNLOAD_SELECTED_MODE} download route."
    return 0
  fi

  echo "Preflight: benchmarking download routes..."
  echo "Preflight: sample timeout is ${BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS}s per URL probe."
  if ! is_positive_integer "$BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS"; then
    fail "BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS must be a positive integer."
  fi

  probe_tmp=$(mktemp -d)
  probe_download_route official "$BUILD_PYPI_OFFICIAL_INDEX" "$BUILD_GIT_OFFICIAL_PROBE" \
    >"$probe_tmp/official.out" 2>"$probe_tmp/official.err" &
  probe_jobs+=("$!:official")
  probe_download_route foreign "$BUILD_PYPI_FOREIGN_INDEX" "$BUILD_GIT_FOREIGN_PROBE" \
    >"$probe_tmp/foreign.out" 2>"$probe_tmp/foreign.err" &
  probe_jobs+=("$!:foreign")
  probe_download_route domestic "$BUILD_PYPI_DOMESTIC_INDEX" "$BUILD_GIT_DOMESTIC_PROBE" \
    >"$probe_tmp/domestic.out" 2>"$probe_tmp/domestic.err" &
  probe_jobs+=("$!:domestic")

  for item in "${probe_jobs[@]}"; do
    pid=${item%%:*}
    wait "$pid" || true
  done

  for mode in official foreign domestic; do
    [[ ! -s "$probe_tmp/$mode.err" ]] || cat "$probe_tmp/$mode.err" >&2
    if [[ -s "$probe_tmp/$mode.out" ]]; then
      line=$(head -n 1 "$probe_tmp/$mode.out")
      measurements+=("$line")
    fi
  done
  rm -rf "$probe_tmp"

  selected_mode=official
  selected_total=unknown
  selected_pypi=unknown
  selected_git=unknown

  if ((${#measurements[@]} == 0)); then
    echo "Preflight: network looks poor; no download route is currently reachable."
    answer=$(prompt_yes_no_timeout "Continue anyway? [y/N]:" 10 n)
    [[ "$answer" == "y" ]] || fail "Docker build cancelled because network preflight failed."
    BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_OFFICIAL_INDEX
    BUILD_GIT_ACTIVE_PREFIX=
  else
    selected_line=$(printf '%s\n' "${measurements[@]}" | sort -n -k1,1 | head -n 1)
    selected_mode=$(printf '%s\n' "$selected_line" | awk -F '\t' '{print $2}')
    selected_total=$(printf '%s\n' "$selected_line" | awk -F '\t' '{print $1}')
    selected_pypi=$(printf '%s\n' "$selected_line" | awk -F '\t' '{print $3}')
    selected_git=$(printf '%s\n' "$selected_line" | awk -F '\t' '{print $4}')

    case "$selected_mode" in
      official)
        BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_OFFICIAL_INDEX
        BUILD_GIT_ACTIVE_PREFIX=
        ;;
      foreign)
        BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_FOREIGN_INDEX
        BUILD_GIT_ACTIVE_PREFIX=$BUILD_GIT_FOREIGN_REPO_PREFIX
        answer=$(prompt_yes_no_timeout "Continue with mirror route? [Y/n]:" 10 y)
        [[ "$answer" != "n" ]] || fail "Docker build cancelled by user."
        ;;
      domestic)
        BUILD_PYPI_ACTIVE_INDEX=$BUILD_PYPI_DOMESTIC_INDEX
        BUILD_GIT_ACTIVE_PREFIX=$BUILD_GIT_DOMESTIC_REPO_PREFIX
        answer=$(prompt_yes_no_timeout "Continue with domestic mirror route? [Y/n]:" 10 y)
        [[ "$answer" != "n" ]] || fail "Docker build cancelled by user."
        ;;
    esac
  fi

  BUILD_DOWNLOAD_SELECTED_MODE=$selected_mode
  export BUILD_PYPI_ACTIVE_INDEX BUILD_GIT_ACTIVE_PREFIX BUILD_DOWNLOAD_SELECTED_MODE
  echo "Preflight: selected ${BUILD_DOWNLOAD_SELECTED_MODE} download route (${selected_total}ms sample total; PyPI=${selected_pypi}ms; Git=${selected_git}ms)."
}

configure_build_parallelism() {
  CPU_THREADS=${CPU_THREADS:-$(detect_cpu_threads)}
  MEMORY_GB=${MEMORY_GB:-$(detect_memory_gb)}

  is_positive_integer "$CPU_THREADS" || fail "CPU_THREADS must be a positive integer when set explicitly."
  is_positive_integer "$MEMORY_GB" || fail "MEMORY_GB must be a positive integer when set explicitly."

  if [[ -n "${BUILD_MAX_JOBS:-}" && -n "${MAX_JOBS:-}" && "${BUILD_MAX_JOBS}" != "${MAX_JOBS}" ]]; then
    fail "BUILD_MAX_JOBS and MAX_JOBS must match when both are set."
  fi

  if [[ -n "${BUILD_MAX_JOBS:-}" ]]; then
    MAX_JOBS=$BUILD_MAX_JOBS
    MAX_JOBS_SOURCE=env:BUILD_MAX_JOBS
  elif [[ -n "${MAX_JOBS:-}" ]]; then
    MAX_JOBS_SOURCE=env:MAX_JOBS
  else
    MAX_JOBS=$(select_max_jobs "$CPU_THREADS" "$MEMORY_GB")
    if (( MAX_JOBS < CPU_THREADS )); then
      MAX_JOBS_SOURCE=auto-memory
    else
      MAX_JOBS_SOURCE=auto
    fi
  fi

  validate_max_jobs_range "$MAX_JOBS" "$CPU_THREADS"
  BUILD_MAX_JOBS=${BUILD_MAX_JOBS:-$MAX_JOBS}
  export CPU_THREADS MEMORY_GB MAX_JOBS BUILD_MAX_JOBS MAX_JOBS_SOURCE
}

print_summary() {
  cat <<EOF
Docker build settings:
  Root: $ROOT_DIR
  Compose file: $COMPOSE_FILE
  Dockerfile: $DOCKERFILE
  Image: $VLLM_IMAGE
  CPU_THREADS: $CPU_THREADS
  MEMORY_GB: $MEMORY_GB
  MAX_JOBS: $MAX_JOBS ($MAX_JOBS_SOURCE)
  BUILD_MAX_JOBS: $BUILD_MAX_JOBS
  Route: ${BUILD_DOWNLOAD_SELECTED_MODE:-$(infer_selected_mode)}
  BUILD_PYPI_ACTIVE_INDEX: ${BUILD_PYPI_ACTIVE_INDEX:-$BUILD_PYPI_OFFICIAL_INDEX}
  BUILD_GIT_ACTIVE_PREFIX: ${BUILD_GIT_ACTIVE_PREFIX:-<official>}
  BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS: $BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS
  BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS: $BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS
  BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS: $BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS
  BUILD_GIT_PRIMARY_TIMEOUT_SECONDS: $BUILD_GIT_PRIMARY_TIMEOUT_SECONDS
EOF
}

print_cmd() {
  printf 'Command:'
  printf ' %q' "$@"
  printf '\n'
}

run_or_print() {
  if (( DRY_RUN == 1 )); then
    print_cmd "$@"
    return 0
  fi
  "$@"
}

compose_cli() {
  if docker compose version >/dev/null 2>&1; then
    printf '%s\n' "docker compose"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    printf '%s\n' "docker-compose"
    return 0
  fi
  fail "Neither 'docker compose' nor 'docker-compose' is available on PATH."
}

run_compose_build() {
  local compose_cmd
  local -a cmd=()

  compose_cmd=$(compose_cli)
  case "$compose_cmd" in
    "docker compose")
      cmd=(docker compose -f "$COMPOSE_FILE" build)
      ;;
    "docker-compose")
      cmd=(docker-compose -f "$COMPOSE_FILE" build)
      ;;
    *)
      fail "Unsupported compose command: $compose_cmd"
      ;;
  esac
  cmd+=("${EXTRA_ARGS[@]}")
  cmd+=("$COMPOSE_SERVICE")
  run_or_print "${cmd[@]}"
}

run_docker_build() {
  local -a build_arg_names=(
    MAX_JOBS
    FLASHQLA_REPO
    FLASHQLA_REF
    BUILD_NETWORK_PREFLIGHT
    BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS
    BUILD_PYPI_OFFICIAL_INDEX
    BUILD_PYPI_FOREIGN_INDEX
    BUILD_PYPI_DOMESTIC_INDEX
    BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS
    BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS
    BUILD_PYPI_MIRROR_INDEX
    BUILD_PYPI_MIRROR_FALLBACK
    BUILD_WHEELHOUSE_DIR
    BUILD_PYPI_ACTIVE_INDEX
    BUILD_DOWNLOAD_SELECTED_MODE
    BUILD_GIT_ACTIVE_PREFIX
    BUILD_GIT_FOREIGN_REPO_PREFIX
    BUILD_GIT_DOMESTIC_REPO_PREFIX
    BUILD_GIT_OFFICIAL_PROBE
    BUILD_GIT_FOREIGN_PROBE
    BUILD_GIT_DOMESTIC_PROBE
    BUILD_GIT_PRIMARY_TIMEOUT_SECONDS
    BUILD_GIT_MIRROR_PREFIXES
    CUTLASS_REPO
    CUTLASS_REVISION
    TRITON_REPO
    TRITON_TAG
  )
  local name value
  local -a cmd=(
    docker build
    -f "$DOCKERFILE"
    -t "$VLLM_IMAGE"
  )

  for name in "${build_arg_names[@]}"; do
    value=${!name-}
    cmd+=(--build-arg "$name=$value")
  done

  cmd+=("${EXTRA_ARGS[@]}")
  cmd+=("$ROOT_DIR")
  run_or_print "${cmd[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    compose|docker|env)
      ACTION=$1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

configure_build_parallelism
choose_download_mode
export VLLM_IMAGE
export FLASHQLA_REPO FLASHQLA_REF
export BUILD_NETWORK_PREFLIGHT BUILD_PREFLIGHT_SAMPLE_TIMEOUT_SECONDS
export BUILD_PYPI_OFFICIAL_INDEX BUILD_PYPI_FOREIGN_INDEX BUILD_PYPI_DOMESTIC_INDEX
export BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS BUILD_PYPI_FALLBACK_TIMEOUT_SECONDS
export BUILD_PYPI_MIRROR_INDEX BUILD_PYPI_MIRROR_FALLBACK BUILD_WHEELHOUSE_DIR
export BUILD_PYPI_ACTIVE_INDEX BUILD_DOWNLOAD_SELECTED_MODE
export BUILD_GIT_ACTIVE_PREFIX BUILD_GIT_FOREIGN_REPO_PREFIX BUILD_GIT_DOMESTIC_REPO_PREFIX
export BUILD_GIT_OFFICIAL_PROBE BUILD_GIT_FOREIGN_PROBE BUILD_GIT_DOMESTIC_PROBE
export BUILD_GIT_PRIMARY_TIMEOUT_SECONDS BUILD_GIT_MIRROR_PREFIXES
export CUTLASS_REPO CUTLASS_REVISION TRITON_REPO TRITON_TAG
print_summary

case "$ACTION" in
  compose)
    run_compose_build
    ;;
  docker)
    run_docker_build
    ;;
  env)
    ;;
  *)
    usage
    exit 2
    ;;
esac
