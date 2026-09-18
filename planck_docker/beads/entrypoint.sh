#!/bin/sh
set -e

mkdir -p /data/.beads
export BEADS_DIR=/data/.beads

# bd init --server is not idempotent — a second call against an
# already-initialized workspace exits 1 with "This workspace is already
# initialized" — so only run it the first time.
if [ ! -f "$BEADS_DIR/config.yaml" ]; then
  bd init --server --server-host dolt --server-port 3306 --quiet --skip-agents
fi

echo "$BEADS_TOKEN" > /run/beads-token

# --allow-non-loopback: traffic from the planck container over the Docker
# bridge network isn't loopback traffic from bd serve's point of view, even
# though it's internal to the stack — requires --auth-token-file.
# --allowed-host beads: the DNS-rebinding check only answers to loopback
# spellings and the bind address by default; a client dialing the service
# name "beads" needs to be enumerated explicitly, or every request 400s.
exec bd serve --addr 0.0.0.0:8377 --allow-non-loopback --allowed-host beads \
  --auth-token-file /run/beads-token
