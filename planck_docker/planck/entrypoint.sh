#!/bin/sh
set -e

/setup.sh

cd /workspace
exec /app/release/bin/planck_docker start
