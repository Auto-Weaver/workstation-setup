#!/usr/bin/env bash
# Reusable shell functions for workstation operations.
# Source this file from project-specific ops scripts:
#   source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

# ── Tool checks ────────────────────────────────────────────

need_tools() {
  local ok=1
  if ! command -v git >/dev/null 2>&1; then
    echo "[check] FAIL: git not found" >&2
    ok=0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "[check] FAIL: docker not found" >&2
    ok=0
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "[check] FAIL: docker compose plugin not found" >&2
    ok=0
  fi
  if [[ "${ok}" -eq 0 ]]; then
    exit 1
  fi
}

# ── Host prerequisite checks ──────────────────────────────

check_host() {
  echo "[check] Verifying host prerequisites..."
  local ok=1

  # Docker
  if command -v docker >/dev/null 2>&1; then
    echo "[check] OK: docker $(docker --version | awk '{print $3}' | tr -d ',')"
  else
    echo "[check] FAIL: docker not found"
    ok=0
  fi

  # Docker Compose
  if docker compose version >/dev/null 2>&1; then
    echo "[check] OK: $(docker compose version)"
  else
    echo "[check] FAIL: docker compose plugin not found"
    ok=0
  fi

  # NVIDIA driver
  if command -v nvidia-smi >/dev/null 2>&1; then
    local gpu_name
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
    echo "[check] OK: GPU ${gpu_name}"
  else
    echo "[check] FAIL: nvidia-smi not found (run bootstrap phase1)"
    ok=0
  fi

  # NVIDIA container runtime
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
    echo "[check] OK: nvidia docker runtime"
  else
    echo "[check] FAIL: nvidia docker runtime not found (run bootstrap phase2)"
    ok=0
  fi

  # Daheng camera udev rules
  if [[ -f /etc/udev/rules.d/99-daheng-camera.rules ]]; then
    echo "[check] OK: daheng udev rules"
  else
    echo "[check] WARN: daheng udev rules not found (camera may not be accessible)"
  fi

  # Daheng SDK libraries
  for lib in libgxiapi.so liblog4cplus_gx.so GxU3VTL.cti GxGVTL.cti; do
    if [[ -f "/usr/lib/${lib}" ]]; then
      echo "[check] OK: /usr/lib/${lib}"
    else
      echo "[check] WARN: /usr/lib/${lib} not found (run bootstrap phase2)"
    fi
  done

  # Galaxy config
  if [[ -d /etc/Galaxy ]]; then
    echo "[check] OK: /etc/Galaxy config"
  else
    echo "[check] WARN: /etc/Galaxy not found (run bootstrap phase2)"
  fi

  if [[ "${ok}" -eq 1 ]]; then
    echo "[check] All prerequisites met."
  else
    echo "[check] Some checks failed. Fix issues before proceeding." >&2
    exit 1
  fi
}

# ── X11 access ─────────────────────────────────────────────

ensure_x11_access() {
  if ! command -v xhost >/dev/null 2>&1; then
    echo "[dev] WARN: xhost not found, skip X11 authorization setup."
    return
  fi

  export DISPLAY="${DISPLAY:-:0}"

  if [[ -z "${XAUTHORITY:-}" ]]; then
    if [[ -f "/run/user/$(id -u)/gdm/Xauthority" ]]; then
      export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
    elif [[ -f "${HOME}/.Xauthority" ]]; then
      export XAUTHORITY="${HOME}/.Xauthority"
    fi
  fi

  if xhost +SI:localuser:root >/dev/null 2>&1; then
    echo "[dev] X11 access ready via SI:localuser:root (DISPLAY=${DISPLAY})."
    return
  fi

  if xhost +local: >/dev/null 2>&1; then
    echo "[dev] X11 access ready via local fallback (DISPLAY=${DISPLAY})."
    return
  fi

  echo "[dev] WARN: failed to authorize X11 (DISPLAY=${DISPLAY}, XAUTHORITY=${XAUTHORITY:-unset})."
}

# ── GitHub token ───────────────────────────────────────────

ensure_github_token() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    read -rsp "Enter GitHub Fine-grained PAT (read access to private repos): " GITHUB_TOKEN
    echo
  fi

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "GITHUB_TOKEN is empty." >&2
    exit 1
  fi

  export GITHUB_TOKEN
}

# ── Docker health wait ─────────────────────────────────────

# Usage: wait_healthy <container1> <container2> ...
wait_healthy() {
  local services=("$@")
  local timeout=60
  local elapsed=0

  echo "[dev] Waiting for services to be healthy..."
  for svc in "${services[@]}"; do
    while true; do
      local health
      health="$(docker inspect --format='{{.State.Health.Status}}' "${svc}" 2>/dev/null || echo "missing")"
      if [[ "${health}" == "healthy" ]]; then
        echo "[dev] OK: ${svc} is healthy"
        break
      fi
      if [[ "${elapsed}" -ge "${timeout}" ]]; then
        echo "[dev] WARN: ${svc} not healthy after ${timeout}s (status: ${health})" >&2
        break
      fi
      sleep 2
      elapsed=$((elapsed + 2))
    done
  done
}

# ── Base image management ──────────────────────────────────

# Usage: ensure_base_image <image_name> <build_func>
ensure_base_image() {
  local image_name="$1"
  local build_func="$2"

  if ! docker image inspect "${image_name}" >/dev/null 2>&1; then
    echo "[dev] Base image not found: ${image_name}"
    "${build_func}"
  fi
}

# Usage: ensure_base_image_fresh <image_name> <build_func> <repo_root> <dep_files...>
# Rebuilds if dependency files changed after image was built.
ensure_base_image_fresh() {
  local image_name="$1"
  local build_func="$2"
  local repo_root="$3"
  shift 3
  local dep_files=("$@")

  if ! docker image inspect "${image_name}" >/dev/null 2>&1; then
    echo "[deploy] Base image not found: ${image_name}"
    "${build_func}"
    return
  fi

  local deps_ts=0
  for f in "${dep_files[@]}"; do
    local ts
    ts="$(git -C "${repo_root}" log -1 --format=%ct -- "${f}" 2>/dev/null || echo 0)"
    if [[ -n "${ts}" ]] && (( ts > deps_ts )); then
      deps_ts="${ts}"
    fi
  done

  local image_created
  local image_ts
  image_created="$(docker image inspect "${image_name}" --format '{{.Created}}' 2>/dev/null || true)"
  image_ts="$(date -d "${image_created}" +%s 2>/dev/null || echo 0)"

  if (( deps_ts > image_ts )); then
    echo "[deploy] Dependency files changed after base image build; rebuilding..."
    "${build_func}"
  else
    echo "[deploy] Base image is up to date."
  fi
}
