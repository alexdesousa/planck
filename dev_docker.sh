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

# ── Write deep-thought team config (init-config only) ────────────────────────
if [ "$INIT_CONFIG" = "1" ]; then
  echo "Writing deep-thought team config..."
  mkdir -p "$DEV_DIR/workspace/.planck/teams/deep-thought"

  cat >"$DEV_DIR/workspace/.planck/config.json" <<'EOF'
{
  "providers": {
    "marvin": {
      "type": "openai",
      "base_url": "https://ai.coroto.net/v1",
      "has_api_key": false
    }
  },
  "models": [
    {
      "id": "Qwen3.6 35B",
      "model": "Qwen3.6-35B-A3B-UD-Q8_K_XL",
      "provider": "marvin",
      "params": {
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "presence_penalty": 1.5,
        "repetition_penalty": 1.0
      }
    }
  ],
  "default_provider": "marvin",
  "default_model": "Qwen3.6 35B"
}
EOF

  cat >"$DEV_DIR/workspace/.planck/teams/deep-thought/TEAM.json" <<'EOF'
{
  "name": "deep-thought",
  "members": [
    {
      "type": "orchestrator",
      "name": "Marvin",
      "provider": "marvin",
      "model_id": "Qwen3.6 35B",
      "system_prompt": "You are Marvin, a helpful assistant.",
      "prompt_hook": "Sidecar.Memory",
      "turn_end_hook": "Sidecar.SkillReflector"
    }
  ]
}
EOF

  echo "  → deep-thought team written."
fi

# ── Build images ──────────────────────────────────────────────────────────────
echo "Building images..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" build

# ── Run setup container ───────────────────────────────────────────────────────
echo "Running setup..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" run --rm setup

# ── Start stack ───────────────────────────────────────────────────────────────
echo "Starting..."
dc -f planck_docker/compose.yml --env-file "$ENV_FILE" up
