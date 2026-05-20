#!/bin/sh
set -e

REPO="alexdesousa/planck"
VERSION="0.1.6"
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
  "$PLANCK_HOME/workspace/.planck"

# ── Write .env (skip if present) ─────────────────────────────────────────────
ENV_FILE="$PLANCK_HOME/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Writing $ENV_FILE..."
  SEARXNG_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 32)"
  cat >"$ENV_FILE" <<EOF
PLANCK_HOME=$PLANCK_HOME
TYPESENSE_API_KEY=planck-internal-key
PLANCK_BIND_ADDRESS=$BIND_ADDRESS
SEARXNG_SECRET=$SEARXNG_SECRET
SEARXNG_LANGUAGE=en
EOF
  echo "  → $ENV_FILE created. Edit SEARXNG_LANGUAGE to change the search language."
else
  echo "  → $ENV_FILE already exists, skipping."
fi

# ── Download compose.yml ──────────────────────────────────────────────────────
COMPOSE_FILE="$PLANCK_HOME/compose.yml"
echo "Downloading compose.yml..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$COMPOSE_FILE" "$COMPOSE_URL"
else
  wget -qO "$COMPOSE_FILE" "$COMPOSE_URL"
fi

# ── Pull images ───────────────────────────────────────────────────────────────
echo "Pulling Docker images..."
$COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

# ── Run setup container (renders templates, copies sidecar) ──────────────────
echo "Running first-run setup..."
$COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" run --rm setup

# ── Start services ────────────────────────────────────────────────────────────
echo "Starting Planck..."
$COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

echo ""
echo "Planck is running at http://localhost:4000"
echo "Open it in your browser and follow the setup wizard to configure a provider."
