#!/bin/sh
# Local development helper — builds images from source and starts the stack.
# Data lives in .planck-dev/ (gitignored) so it doesn't touch ~/planck.
#
# Usage:
#   ./dev_docker.sh              — fresh environment (default): tears down and rebuilds
#   ./dev_docker.sh preserve     — keep existing data, just rebuild images and restart
#   ./dev_docker.sh init-config  — fresh environment + write deep-thought team config
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
INIT_CONFIG=0
[ "$1" = "preserve" ] && PRESERVE=1
[ "$1" = "init-config" ] && INIT_CONFIG=1

# ── Tear down existing environment (default and init-config) ─────────────────
if [ "$PRESERVE" = "0" ] && [ -d "$DEV_DIR" ]; then
  dc -f planck_docker/compose.yml --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null || true
  # beads/dolt write root-owned files into bind mounts; rm -rf fails on Linux
  # without sudo. Run the removal inside a container to sidestep UID mismatch.
  docker run --rm -v "$(pwd):/host" alpine sh -c "rm -rf '/host/$DEV_DIR'"
  echo "  → $DEV_DIR removed."
fi

# ── Create directory layout ───────────────────────────────────────────────────
mkdir -p \
  "$DEV_DIR/typesense-data" \
  "$DEV_DIR/vault-data" \
  "$DEV_DIR/dolt-data" \
  "$DEV_DIR/beads-data" \
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
SEARXNG_SECRET=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)
SEARXNG_LANGUAGE=en
AGENT_VAULT_MASTER_PASSWORD=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)
AGENT_VAULT_EMAIL=admin@planck.local
AGENT_VAULT_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
BEADS_TOKEN=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)
EOF
  echo "  → $ENV_FILE created."
else
  echo "  → $ENV_FILE exists — adding any missing keys..."
  add_if_missing PLANCK_HOME "$PLANCK_HOME"
  add_if_missing TYPESENSE_API_KEY "planck-internal-key"
  add_if_missing PLANCK_BIND_ADDRESS "127.0.0.1"
  add_if_missing SEARXNG_SECRET "$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
  add_if_missing SEARXNG_LANGUAGE "en"
  add_if_missing AGENT_VAULT_MASTER_PASSWORD "$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
  add_if_missing AGENT_VAULT_EMAIL "admin@planck.local"
  add_if_missing AGENT_VAULT_PASSWORD "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  add_if_missing BEADS_TOKEN "$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
fi

# ── Install planck_setup skill (always — it's repo-managed, not user data) ───
echo "Installing planck_setup skill..."
rm -rf "$DEV_DIR/workspace/.planck/skills/planck_setup"
cp -r skills/planck_setup "$DEV_DIR/workspace/.planck/skills/"

# ── Write deep-thought team config (init-config only) ────────────────────────
# Loads config.json and TEAM.json from the repo root — copy the *.example
# files to get started. Both are gitignored so local endpoints stay local.
if [ "$INIT_CONFIG" = "1" ]; then
  echo "Writing deep-thought team config..."
  [ -f "config.json" ] || {
    echo "  !! config.json missing — copy config.json.example and adjust."
    exit 1
  }
  [ -f "TEAM.json" ] || {
    echo "  !! TEAM.json missing — copy TEAM.json.example and adjust."
    exit 1
  }
  mkdir -p "$DEV_DIR/workspace/.planck/teams/deep-thought"

  cp config.json "$DEV_DIR/workspace/.planck/config.json"
  cp TEAM.json "$DEV_DIR/workspace/.planck/teams/deep-thought/TEAM.json"

  echo "  → deep-thought team written from config.json + TEAM.json."
fi

# ── Build images ──────────────────────────────────────────────────────────────
echo "Building images..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" build

# ── Run setup container ───────────────────────────────────────────────────────
echo "Running setup..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" run --rm -T setup

# ── Start stack ───────────────────────────────────────────────────────────────
echo "Starting..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" up
