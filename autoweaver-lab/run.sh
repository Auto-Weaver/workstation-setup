#!/usr/bin/env bash
# Run the autoweaver-train CLI inside a one-shot Docker container.
#
# Usage:
#   bash run.sh echo                               # smoke test (no config)
#   bash run.sh train    <config.yaml> [args...]   # train experiment
#   bash run.sh evaluate <config.yaml> [args...]   # evaluate experiment
#   bash run.sh <subcommand> [args...]             # passthrough (prepare, list_experiments, ...)
#
# Reads .env from this script's directory; see env.example.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# ── Load env ────────────────────────────────────────────────────
if [[ ! -f "$HERE/.env" ]]; then
  echo "[run] ERROR: $HERE/.env not found." >&2
  echo "       Copy env.example to .env and edit AUTOWEAVER_REPO." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$HERE/.env"
set +a

# ── Identity for compose's user: ${HOST_UID}:${HOST_GID} ───────
HOST_UID=$(id -u); export HOST_UID
HOST_GID=$(id -g); export HOST_GID

# ── Pre-create bind-mount targets as the current user ──────────
# If we let docker create these paths, they'd end up root-owned and the
# non-root container wouldn't be able to write into them.
mkdir -p "$AUTOWEAVER_CACHE_DIR/uv" "$AUTOWEAVER_CACHE_DIR/torch"

# ── Locate compose file ────────────────────────────────────────
COMPOSE_FILE="$AUTOWEAVER_WORKDIR/docker/compose.yaml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[run] ERROR: compose file not found at $COMPOSE_FILE" >&2
  echo "       Have you run deploy.sh to clone/update the private repo?" >&2
  exit 1
fi

# ── Dispatch ───────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "Usage: bash run.sh <subcommand> [args...]" >&2
  echo "  echo | train <config> | evaluate <config> | prepare | list_experiments" >&2
  exit 1
fi

subcommand="$1"; shift

case "$subcommand" in
  echo)
    # CLI echo uses JSON stdin; -T disables the pseudo-TTY so the pipe survives.
    echo '{"command":"echo","params":{"hi":1}}' \
      | docker compose -f "$COMPOSE_FILE" run --rm -T train python -m autoweaver_train.cli
    ;;
  train|evaluate)
    if [[ $# -lt 1 ]]; then
      echo "[run] ERROR: $subcommand requires a config path" >&2
      exit 1
    fi
    config="$1"; shift
    docker compose -f "$COMPOSE_FILE" run --rm train \
      python -m autoweaver_train.cli "$subcommand" -c "$config" "$@"
    ;;
  *)
    docker compose -f "$COMPOSE_FILE" run --rm train \
      python -m autoweaver_train.cli "$subcommand" "$@"
    ;;
esac
