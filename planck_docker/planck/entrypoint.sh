#!/bin/sh
set -e

PLANCK_DIR=/workspace/.planck

# Create .planck directory if needed
mkdir -p "$PLANCK_DIR"

# Copy bundled sidecar on first run (preserve user customisations afterwards)
if [ ! -d "$PLANCK_DIR/sidecar" ]; then
  echo "[planck] Installing bundled sidecar..."
  cp -r /app/sidecar "$PLANCK_DIR/sidecar"
fi

# Write default config on first run, substituting env vars (preserve existing config)
if [ ! -f "$PLANCK_DIR/config.json" ]; then
  echo "[planck] Writing default config..."
  envsubst < /app/default_config.json.template > "$PLANCK_DIR/config.json"
fi

# Write default Searxng settings on first run (preserve user customisations)
mkdir -p "$PLANCK_DIR/searxng"
if [ ! -f "$PLANCK_DIR/searxng/settings.yml" ]; then
  echo "[planck] Writing default Searxng settings..."
  envsubst < /app/searxng_settings.yml.template > "$PLANCK_DIR/searxng/settings.yml"
fi

# Run planck from the workspace directory so it picks up .planck/config.json
cd /workspace
exec /app/release/bin/planck_docker start
