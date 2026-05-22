#!/bin/sh
# Local development helper — builds images from source and starts the stack.
# Data lives in .planck-dev/ (gitignored) so it doesn't touch ~/planck.
#
# Usage:
#   ./dev_docker.sh            — fresh environment (default): tears down and rebuilds
#   ./dev_docker.sh preserve   — keep existing data, just rebuild images and restart
set -e

cd "$(dirname "$0")"

# ── Detect compose command ────────────────────────────────────────────────────
if docker compose version >/dev/null 2>&1; then
  dc() { docker compose "$@"; }
else
  dc() { docker-compose "$@"; }
fi

DEV_DIR=".planck-dev"
PLANCK_HOME="$(pwd)/$DEV_DIR"
ENV_FILE="$DEV_DIR/.env"

PRESERVE=0
[ "$1" = "preserve" ] && PRESERVE=1

# ── Tear down existing environment (default) ─────────────────────────────────
if [ "$PRESERVE" = "0" ]; then
  rm -rf "$DEV_DIR"
  echo "  → $DEV_DIR removed."
fi

# ── Create directory layout ───────────────────────────────────────────────────
mkdir -p \
  "$DEV_DIR/typesense-data" \
  "$DEV_DIR/workspace/.planck/skills"

# ── Write .env (add missing keys if it exists) ────────────────────────────────
add_if_missing() {
  grep -q "^$1=" "$ENV_FILE" 2>/dev/null || echo "$1=$2" >>"$ENV_FILE"
}

if [ ! -f "$ENV_FILE" ]; then
  cat >"$ENV_FILE" <<EOF
PLANCK_HOME=$PLANCK_HOME
TYPESENSE_API_KEY=planck-internal-key
PLANCK_BIND_ADDRESS=127.0.0.1
SEARXNG_SECRET=test-secret-local
SEARXNG_LANGUAGE=en
EOF
  echo "  → $ENV_FILE created."
else
  echo "  → $ENV_FILE exists — adding any missing keys..."
  add_if_missing PLANCK_HOME "$PLANCK_HOME"
  add_if_missing TYPESENSE_API_KEY "planck-internal-key"
  add_if_missing PLANCK_BIND_ADDRESS "127.0.0.1"
  add_if_missing SEARXNG_SECRET "test-secret-local"
  add_if_missing SEARXNG_LANGUAGE "en"
fi

# ── Install planck_setup skill (always — it's repo-managed, not user data) ───
echo "Installing planck_setup skill..."
rm -rf "$DEV_DIR/workspace/.planck/skills/planck_setup"
cp -r skills/planck_setup "$DEV_DIR/workspace/.planck/skills/"

# ── Build images ──────────────────────────────────────────────────────────────
echo "Building images..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" build

# ── Run setup container ───────────────────────────────────────────────────────
echo "Running setup..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" run --rm setup

# ── Start stack ───────────────────────────────────────────────────────────────
echo "Starting..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" up
