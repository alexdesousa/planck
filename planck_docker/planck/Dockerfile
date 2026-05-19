# ── Stage 1: builder ──────────────────────────────────────────────────────────
# Compiles planck_cli and pre-installs sidecar dependencies so the runtime
# container starts quickly without downloading packages.
FROM hexpm/elixir:1.19.5-erlang-28.5-ubuntu-noble-20260410 AS builder

# Required for Erlang to boot correctly under QEMU (cross-platform builds).
ENV ELIXIR_ERL_OPTIONS="+Bd -noinput"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    ca-certificates \
    git \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /build
COPY . .

# Build the planck_docker OTP release (no Burrito wrapper).
ENV MIX_ENV=prod
ENV PLANCK_LOCAL=true
RUN cd planck_cli \
    && mix deps.get \
    && MIX_ENV=dev mix deps.compile \
    && MIX_ENV=dev mix do assets.setup + assets.deploy \
    && mix release planck_docker

# Pre-install sidecar deps (Mix + npm) so the runtime sidecar setup is fast.
RUN cd planck_docker/sidecar \
    && mix do local.hex --force + local.rebar --force + setup + compile

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM hexpm/elixir:1.19.5-erlang-28.5-ubuntu-noble-20260410

# Required for Erlang to boot correctly under QEMU (cross-platform builds).
ENV ELIXIR_ERL_OPTIONS="+Bd -noinput"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gettext-base \
    inotify-tools \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Hex and rebar are needed by SidecarManager to (re)compile the sidecar.
RUN mix local.hex --force && mix local.rebar --force

# planck OTP release.
COPY --from=builder /build/planck_cli/_build/prod/rel/planck_docker /app/release

# Sidecar source + pre-installed deps (entrypoint copies to workspace on first run).
COPY --from=builder /build/planck_docker/sidecar /app/sidecar

COPY planck_docker/planck/default_config.json.template /app/default_config.json.template
COPY planck_docker/searxng/settings.yml.template /app/searxng_settings.yml.template
COPY planck_docker/planck/setup.sh /setup.sh
COPY planck_docker/planck/entrypoint.sh /entrypoint.sh
RUN chmod +x /setup.sh /entrypoint.sh \
    && chown -R ubuntu:ubuntu /app
USER ubuntu

# Bind to all interfaces so the container port is reachable from the host.
ENV SHELL=/bin/sh
ENV MIX_ENV=prod
ENV IP_ADDRESS=0.0.0.0
ENV PORT=4000

EXPOSE 4000

ENTRYPOINT ["/entrypoint.sh"]
