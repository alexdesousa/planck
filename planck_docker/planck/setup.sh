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

# ── Agent-vault bootstrap ──────────────────────────────────────────────────────
# Registers the owner account, creates the planck vault, and generates a scoped
# agent token. The token is written to /planck-home/.env so docker compose can
# inject it into the planck container on the next (or current) `up` invocation.
# Skipped if the token is already present or if vault vars are not set.
if [ -n "$AGENT_VAULT_URL" ] && [ -n "$AGENT_VAULT_EMAIL" ] && [ -n "$AGENT_VAULT_PASSWORD" ]; then
  PLANCK_ENV=/planck-home/.env

  if grep -q "^AGENT_VAULT_TOKEN=" "$PLANCK_ENV" 2>/dev/null; then
    echo "[setup] Vault token already present."
  else
    echo "[setup] Bootstrapping agent-vault..."

    # Wait up to 60 s for vault to accept connections
    i=0
    until curl -s "$AGENT_VAULT_URL/health" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 60 ]; then
        echo "[setup] Vault not reachable after 60 s — skipping bootstrap."
        break
      fi
      sleep 1
    done

    if curl -s "$AGENT_VAULT_URL/health" >/dev/null 2>&1; then
      # Register owner account — succeeds on first run, returns error on subsequent
      # runs (already registered). Ignore the exit code either way.
      curl -s -X POST "$AGENT_VAULT_URL/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$AGENT_VAULT_EMAIL\",\"password\":\"$AGENT_VAULT_PASSWORD\"}" \
        >/dev/null 2>&1 || true

      # Login and obtain a session token. Use -s (not -sf) so a non-200
      # response body is still captured rather than causing a script exit.
      RESP=$(curl -s -X POST "$AGENT_VAULT_URL/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$AGENT_VAULT_EMAIL\",\"password\":\"$AGENT_VAULT_PASSWORD\"}" \
        2>/dev/null) || true
      SESSION=$(echo "$RESP" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)

      if [ -z "$SESSION" ]; then
        echo "[setup] Could not login to vault — skipping bootstrap."
        echo "[setup] Login response: $RESP"
      else
        # Create vault (idempotent — ignore 409 conflict on re-runs)
        curl -s -X POST "$AGENT_VAULT_URL/v1/vaults" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $SESSION" \
          -d '{"name":"planck","credential_store":{"kind":"builtin"}}' \
          >/dev/null 2>&1 || true

        # Create scoped agent (proxy role on the planck vault)
        RESP=$(curl -s -X POST "$AGENT_VAULT_URL/v1/agents" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $SESSION" \
          -d '{"name":"planck-sidecar","role":"no-access","vaults":[{"vault_name":"planck","vault_role":"proxy"}]}' \
          2>/dev/null) || true
        TOKEN=$(echo "$RESP" | grep -o '"av_agent_token":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -n "$TOKEN" ]; then
          echo "AGENT_VAULT_TOKEN=$TOKEN" >> "$PLANCK_ENV"
          echo "[setup] Vault agent token written."
        else
          echo "[setup] Could not create agent token — skipping bootstrap."
          echo "[setup] Agent response: $RESP"
        fi
      fi
    fi
  fi
fi

echo "[setup] Done."
