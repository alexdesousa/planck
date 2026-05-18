#!/bin/sh
# First-run workspace setup. Idempotent — safe to run on every start.
set -e

PLANCK_DIR=/workspace/.planck

mkdir -p "$PLANCK_DIR/searxng"

if [ ! -d "$PLANCK_DIR/sidecar" ]; then
  echo "[setup] Installing bundled sidecar..."
  cp -r /app/sidecar "$PLANCK_DIR/sidecar"
fi

if [ ! -f "$PLANCK_DIR/config.json" ]; then
  echo "[setup] Writing default config..."
  envsubst < /app/default_config.json.template > "$PLANCK_DIR/config.json"
fi

if [ ! -f "$PLANCK_DIR/searxng/settings.yml" ]; then
  echo "[setup] Writing default Searxng settings..."
  envsubst < /app/searxng_settings.yml.template > "$PLANCK_DIR/searxng/settings.yml"
fi

echo "[setup] Done."
