# Wraps the official dolthub/dolt image to self-grant remote root access on
# first boot — see entrypoint.sh for why that's needed at all.
FROM dolthub/dolt:2.2.0

COPY planck_docker/dolt/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# tini (already the base image's own PID 1) still reaps zombies and forwards
# signals — just to this entrypoint script now instead of directly to dolt.
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
