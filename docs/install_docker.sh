#!/bin/sh
set -e

REPO="alexdesousa/planck"
VERSION="0.2.2"
PLANCK_HOME="$HOME/planck"
COMPOSE_URL="https://raw.githubusercontent.com/$REPO/v${VERSION}/planck_docker/compose.yml"

# ── Parse flags ───────────────────────────────────────────────────────────────
BIND_ADDRESS="127.0.0.1"
for arg in "$@"; do
  case "$arg" in
  --bind=*) BIND_ADDRESS="${arg#--bind=}" ;;
  --bind)
    shift
    BIND_ADDRESS="$1"
    ;;
  esac
done

# ── Detect OS ─────────────────────────────────────────────────────────────────
os="$(uname -s)"
case "$os" in
Linux) : ;;
Darwin) : ;;
*)
  echo "Unsupported OS: $os"
  echo "Download manually from https://github.com/$REPO/releases"
  exit 1
  ;;
esac

# ── Check Docker ──────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed."
  case "$os" in
  Linux) echo "Install it from https://docs.docker.com/engine/install/" ;;
  Darwin) echo "Install OrbStack (recommended): https://orbstack.dev" ;;
  esac
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running. Start Docker and try again."
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "Neither 'docker compose' nor 'docker-compose' found."
  echo "Install Docker Compose: https://docs.docker.com/compose/install/"
  exit 1
fi

# ── Create directory layout ───────────────────────────────────────────────────
echo "Setting up $PLANCK_HOME..."
mkdir -p \
  "$PLANCK_HOME/typesense-data" \
  "$PLANCK_HOME/vault-data" \
  "$PLANCK_HOME/dolt-data" \
  "$PLANCK_HOME/beads-data" \
  "$PLANCK_HOME/workspace/.planck"

# ── Write .env — create if absent, add missing keys if it exists ──────────────
ENV_FILE="$PLANCK_HOME/.env"

add_if_missing() {
  grep -q "^$1=" "$ENV_FILE" || echo "$1=$2" >>"$ENV_FILE"
}

rand32() { LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32; }
rand24() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

SEARXNG_SECRET="$(rand32)"
VAULT_MASTER="$(rand32)"
VAULT_PASSWORD="$(rand24)"
BEADS_TOKEN="$(rand32)"

if [ ! -f "$ENV_FILE" ]; then
  echo "Writing $ENV_FILE..."
  cat >"$ENV_FILE" <<EOF
PLANCK_HOME=$PLANCK_HOME
TYPESENSE_API_KEY=planck-internal-key
PLANCK_BIND_ADDRESS=$BIND_ADDRESS
SEARXNG_SECRET=$SEARXNG_SECRET
SEARXNG_LANGUAGE=en
AGENT_VAULT_MASTER_PASSWORD=$VAULT_MASTER
AGENT_VAULT_EMAIL=admin@planck.local
AGENT_VAULT_PASSWORD=$VAULT_PASSWORD
BEADS_TOKEN=$BEADS_TOKEN
EOF
  echo "  → $ENV_FILE created. Edit SEARXNG_LANGUAGE to change the search language."
else
  echo "  → $ENV_FILE exists — adding any missing keys..."
  add_if_missing PLANCK_HOME "$PLANCK_HOME"
  add_if_missing TYPESENSE_API_KEY "planck-internal-key"
  add_if_missing PLANCK_BIND_ADDRESS "$BIND_ADDRESS"
  add_if_missing SEARXNG_SECRET "$SEARXNG_SECRET"
  add_if_missing SEARXNG_LANGUAGE "en"
  add_if_missing AGENT_VAULT_MASTER_PASSWORD "$VAULT_MASTER"
  add_if_missing AGENT_VAULT_EMAIL "admin@planck.local"
  add_if_missing AGENT_VAULT_PASSWORD "$VAULT_PASSWORD"
  add_if_missing BEADS_TOKEN "$BEADS_TOKEN"
fi

# ── Download compose.yml ──────────────────────────────────────────────────────
COMPOSE_FILE="$PLANCK_HOME/compose.yml"
echo "Downloading compose.yml..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$COMPOSE_FILE" "$COMPOSE_URL"
else
  wget -qO "$COMPOSE_FILE" "$COMPOSE_URL"
fi

# ── Download release tarball (skill + dolt/beads build contexts) ─────────────
# dolt and beads are built locally, not published as per-version images (see
# specs/planck-docker.md) — compose.yml's build context for both is relative
# to compose.yml's own directory, so their Dockerfile + entrypoint.sh have to
# be sitting right next to it here, not just present in the monorepo checkout
# this script doesn't have.
TARBALL_URL="https://github.com/$REPO/archive/refs/tags/v${VERSION}.tar.gz"
TARBALL_FILE="$(mktemp)"
trap 'rm -f "$TARBALL_FILE"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$TARBALL_FILE" "$TARBALL_URL"
else
  wget -qO "$TARBALL_FILE" "$TARBALL_URL"
fi

SKILL_BASE="$PLANCK_HOME/workspace/.planck/skills"
echo "Installing planck_setup skill..."
mkdir -p "$SKILL_BASE"
tar -xzf "$TARBALL_FILE" --strip-components=2 \
  -C "$SKILL_BASE" "planck-${VERSION}/skills/planck_setup" ||
  echo "Warning: could not install planck_setup skill"

echo "Installing dolt/beads build contexts..."
for svc in dolt beads; do
  mkdir -p "$PLANCK_HOME/$svc"
  tar -xzf "$TARBALL_FILE" --strip-components=3 \
    -C "$PLANCK_HOME/$svc" "planck-${VERSION}/planck_docker/$svc" ||
    echo "Warning: could not install $svc build context"
done

# ── Pull images ───────────────────────────────────────────────────────────────
echo "Pulling Docker images..."
$COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

# ── Run setup container (renders templates, copies sidecar) ──────────────────
# -T: setup's entrypoint is a plain script, not interactive — and when this
# install script itself runs via `curl | sh`, stdin is the pipe, not a real
# terminal, so TTY allocation fails outright ("the input device is not a TTY")
# and aborts the whole install before services ever start.
# < /dev/null: -T alone isn't enough — `docker compose run` still attaches to
# stdin regardless of TTY allocation, and while piped through `sh` that stdin
# IS the rest of this very script. Without this redirect, the command reads
# and silently discards everything after it, so `sh` sees the script end here
# and drops back to a prompt — services never start, with no error at all.
echo "Running first-run setup..."
$COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" run --rm -T setup < /dev/null

# ── Start services ────────────────────────────────────────────────────────────
echo "Starting Planck..."
$COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

echo ""
echo "Planck is running at http://localhost:4000"
echo "Open it in your browser and follow the setup wizard to configure a provider."
