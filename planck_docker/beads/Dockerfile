# Installs the pinned `bd` binary (from beads' own GitHub releases, not the
# Homebrew formula — this needs to run on Linux inside the container) and
# fronts the `dolt` service with `bd serve`. See entrypoint.sh.
FROM debian:bookworm-slim

ARG BEADS_VERSION=1.3.0
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Checksums pinned from the release's own checksums.txt — verified before
# extracting, not just downloaded and trusted.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) SHA256=2f92b904ecf35b607e44dc5c39229173af69c54f1183e8d709f1773540cdcf3b ;; \
      arm64) SHA256=4ce9446a68edc13202b76c84a47d66fb3dad2787b6464c9522a108faf9c1c608 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/beads.tar.gz \
      "https://github.com/gastownhall/beads/releases/download/v${BEADS_VERSION}/beads_${BEADS_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    echo "${SHA256}  /tmp/beads.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/beads.tar.gz -C /usr/local/bin bd; \
    chmod +x /usr/local/bin/bd; \
    rm /tmp/beads.tar.gz

COPY planck_docker/beads/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8377

ENTRYPOINT ["/entrypoint.sh"]
