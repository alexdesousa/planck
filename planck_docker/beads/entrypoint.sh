#!/bin/sh
set -e

mkdir -p /data/.beads
export BEADS_DIR=/data/.beads

# Every bd invocation below resolves things — the init-time prefix default,
# and (it turns out) a git repository root it needs even just to serve —
# relative to the process's actual working directory, not $BEADS_DIR. This
# script never cd'd anywhere, so that directory was "/" the whole time:
# confirmed as the cause of both bd init's "directory name '/' produces an
# invalid database name" (worked around below with --prefix) and bd serve's
# "cannot resolve workspace context: cannot determine repository root" (a
# `git init /data` alone did NOT fix this — git searches *upward* from cwd,
# and /data is not an ancestor of /, so a repo living there is invisible to
# a process still running from /). Fixing the actual cwd fixes both at the
# root instead of patching each symptom separately.
cd /data

# bd unconditionally resolves its "workspace context" via a git repository
# root, even for bd serve, which otherwise has nothing to do with git — see
# above. No flag disables this (checked --global, --shared-server,
# --stealth — all real, none of them is it); every bd_* tool talks to this
# over HTTP and none of them ever touch git themselves, so this repo is
# never committed to, pushed, or otherwise used beyond satisfying that one
# check. `git init` on an already-initialized directory is safe to repeat
# (git's own documented behavior), so no extra guard is needed here on
# restart. `safe.directory` heads off a related, common container gotcha
# (git refusing to operate when the process's UID doesn't own the
# directory) before it has a chance to bite.
git config --global --add safe.directory /data
git init --quiet

# bd init --server is not idempotent — a second call against an
# already-initialized workspace exits 1 with "This workspace is already
# initialized" — so only run it the first time.
#
# --prefix planck: without it, bd derives the issue id prefix from the
# current directory's name — "data" now that cwd is fixed, not something
# recognizable. Explicit and required, not just tidiness. Nothing in this
# codebase parses or validates the prefix itself (the bd_* tools just pass
# whatever id string the API hands back), so this is safe to change on its
# own — but it only takes effect on a fresh `bd init`; an already-initialized
# workspace keeps its existing prefix (originally "bd") until its data
# volume is wiped and reinitialized, same as any other bd init change.
if [ ! -f "$BEADS_DIR/config.yaml" ]; then
  bd init --server --server-host dolt --server-port 3306 --quiet --skip-agents --prefix planck
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
