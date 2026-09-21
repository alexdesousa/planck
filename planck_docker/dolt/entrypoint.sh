#!/bin/sh
set -e

dolt sql-server --host 0.0.0.0 --port 3306 &
SERVER_PID=$!

# Forward shutdown to the actual server process — it runs as this script's
# background child now, not tini's direct child.
trap 'kill -TERM "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID"' TERM INT

# `dolt sql -q` against a repo with no server yet would open the data
# directory directly instead of talking to the server just started above —
# wait until it actually answers as a client before granting anything.
until dolt sql -q "SELECT 1" >/dev/null 2>&1; do
  sleep 0.5
done

# The root user dolt auto-creates on first launch is scoped to 'localhost'
# only — confirmed via `SHOW GRANTS FOR 'root'@'%'` failing outright with
# "no such grant defined for user 'root' on host '%'". Refused for any
# other container connecting over the compose network, which is exactly
# how `beads` reaches this service — surfaced as `bd`'s own "Access denied
# for user 'root'" the first time this stack actually ran, not caught by
# the original design (the healthcheck below only confirms the TCP port is
# open, not that a *remote* client can authenticate). Both statements are
# naturally idempotent, so no extra "already done" guard is needed here.
dolt sql -q "CREATE USER IF NOT EXISTS 'root'@'%'; GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"

wait "$SERVER_PID"
