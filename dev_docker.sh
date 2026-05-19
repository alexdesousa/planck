#!/bin/sh
# Local development helper — builds images from source and starts the stack.
# Data lives in .planck-dev/ (gitignored) so it doesn't touch ~/planck.
set -e

cd "$(dirname "$0")"

# ── Detect compose command ────────────────────────────────────────────────────
if docker compose version >/dev/null 2>&1; then
  dc() { docker compose "$@"; }
else
  dc() { docker-compose "$@"; }
fi

DEV_DIR=".planck-dev"
export PLANCK_HOME="$(pwd)/$DEV_DIR"

mkdir -p \
  "$DEV_DIR/models" \
  "$DEV_DIR/typesense-data" \
  "$DEV_DIR/workspace/.planck"

# ── Write .env (skip if present) ─────────────────────────────────────────────
ENV_FILE="$DEV_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" << 'EOF'
TYPESENSE_API_KEY=planck-internal-key
PLANCK_BIND_ADDRESS=127.0.0.1
SEARXNG_SECRET=test-secret-local
SEARXNG_LANGUAGE=en
EOF
  echo "  → $ENV_FILE created."
else
  echo "  → $ENV_FILE already exists, skipping."
fi

# ── Download model ────────────────────────────────────────────────────────────
MODEL="Bonsai-8B-Q1_0.gguf"
MODEL_PATH="$DEV_DIR/models/$MODEL"
MODEL_URL="https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/main/$MODEL"

if [ ! -f "$MODEL_PATH" ]; then
  echo "Downloading Bonsai model (1.16 GB)..."
  curl -L --progress-bar -o "$MODEL_PATH" "$MODEL_URL"
else
  echo "  → Model already downloaded, skipping."
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
