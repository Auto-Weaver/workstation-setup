#!/usr/bin/env bash
# First-time + daily deploy, combined.
#
# Usage: bash deploy.sh
#
# Steps:
#   1. Load .env.
#   2. Check host prerequisites (docker, compose, nvidia runtime).
#   3. Clone the private repo if missing, otherwise pull --rebase --autostash.
#   4. Ensure data/cache dirs exist on the host.
#   5. docker compose build.
#   6. Smoke test via `autoweaver-train echo`.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# ── Load env ────────────────────────────────────────────────────
if [[ ! -f "$HERE/.env" ]]; then
  echo "[deploy] ERROR: $HERE/.env not found." >&2
  echo "          Copy env.example to .env and edit AUTOWEAVER_REPO." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$HERE/.env"
set +a

# ── Host prerequisite check ────────────────────────────────────
# shellcheck disable=SC1091
source "$HERE/../lib/common.sh"
check_host

# ── Clone or pull ──────────────────────────────────────────────
if [[ ! -d "$AUTOWEAVER_MAIN_DIR" ]]; then
  echo "[deploy] $AUTOWEAVER_MAIN_DIR not found — cloning from $AUTOWEAVER_REPO"
  mkdir -p "$(dirname "$AUTOWEAVER_MAIN_DIR")"

  DEPLOY_KEY="$HOME/.ssh/autoweaver_lab_deploy"
  if [[ -f "$DEPLOY_KEY" ]]; then
    echo "[deploy] using Deploy Key at $DEPLOY_KEY"
    GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes" \
      git clone "$AUTOWEAVER_REPO" "$AUTOWEAVER_MAIN_DIR"
  else
    git clone "$AUTOWEAVER_REPO" "$AUTOWEAVER_MAIN_DIR"
  fi
else
  echo "[deploy] updating $AUTOWEAVER_MAIN_DIR"
  git -C "$AUTOWEAVER_MAIN_DIR" pull --rebase --autostash
fi

# ── Host data / cache dirs ─────────────────────────────────────
# Pre-create with the current user so bind mounts don't get root-owned.
mkdir -p \
  "$AUTOWEAVER_DATA_DIR/datasets" \
  "$AUTOWEAVER_DATA_DIR/runs" \
  "$AUTOWEAVER_CACHE_DIR/uv" \
  "$AUTOWEAVER_CACHE_DIR/torch"

# ── Identity for compose ───────────────────────────────────────
HOST_UID=$(id -u); export HOST_UID
HOST_GID=$(id -g); export HOST_GID

# ── Build image ────────────────────────────────────────────────
COMPOSE_FILE="$AUTOWEAVER_WORKDIR/docker/compose.yaml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[deploy] ERROR: compose file not found at $COMPOSE_FILE" >&2
  echo "          The private repo should ship docker/compose.yaml." >&2
  exit 1
fi

echo "[deploy] docker compose build"
docker compose -f "$COMPOSE_FILE" build

# ── Smoke test ─────────────────────────────────────────────────
echo "[deploy] smoke test: python -m autoweaver_train.cli echo"
if echo '{"command":"echo","params":{"deploy":"ok"}}' \
     | docker compose -f "$COMPOSE_FILE" run --rm -T train python -m autoweaver_train.cli \
     | grep -q '"status": "success"'; then
  echo "[deploy] smoke test passed"
else
  echo "[deploy] smoke test FAILED — inspect the output above" >&2
  exit 1
fi

echo "[deploy] done."
