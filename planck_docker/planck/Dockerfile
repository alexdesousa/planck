# ── Stage 1: builder ──────────────────────────────────────────────────────────
# Compiles planck_cli and pre-installs sidecar dependencies so the runtime
# container starts quickly without downloading packages.
FROM hexpm/elixir:1.20.4-erlang-29.1-ubuntu-noble-20260911 AS builder

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
# erlexec's C build shells out to bare `erl` to detect the system architecture
# and erl_interface include/lib paths. That `erl` invocation crashes on boot
# on this image (prim_tty's NIF-based terminal handling fails with `undef`,
# independent of arch or QEMU — a real, reproducible failure, not emulation
# noise). CROSS_COMPILE routes architecture detection through `$(CXX)
# -dumpmachine` instead; ERL_CXXFLAGS/ERL_LDFLAGS are computed from the
# filesystem so the other two `erl` calls are never made either.
RUN cd planck_cli \
    && ERL_ROOT_DIR=/usr/local/lib/erlang \
    && ERTS_VSN=$(basename $(ls -d ${ERL_ROOT_DIR}/erts-*) | sed 's/erts-//') \
    && EI_DIR=$(ls -d ${ERL_ROOT_DIR}/lib/erl_interface-* | sort -V | tail -1) \
    && export CROSS_COMPILE=1 \
    && export ERL_CXXFLAGS="-I${ERL_ROOT_DIR}/erts-${ERTS_VSN}/include -I${EI_DIR}/include" \
    && export ERL_LDFLAGS="-L${EI_DIR}/lib" \
    && mix deps.get \
    && MIX_ENV=dev mix deps.compile \
    && MIX_ENV=dev mix do assets.setup + assets.deploy \
    && mix release planck_docker

# Pre-install sidecar deps (Mix + npm) so the runtime sidecar setup is fast.
# planck_agent is resolved as a local path dep via File.dir? auto-detection in
# mix.exs — no env var needed. The path ../../planck_agent exists here (COPY . .)
# so mix.lock does not lock it to Hex, and SidecarManager picks it up at runtime.
# See the erlexec/CROSS_COMPILE comment above — same fix needed here since
# erlexec is also a transitive dep of the sidecar.
RUN cd planck_docker/sidecar \
    && ERL_ROOT_DIR=/usr/local/lib/erlang \
    && ERTS_VSN=$(basename $(ls -d ${ERL_ROOT_DIR}/erts-*) | sed 's/erts-//') \
    && EI_DIR=$(ls -d ${ERL_ROOT_DIR}/lib/erl_interface-* | sort -V | tail -1) \
    && export CROSS_COMPILE=1 \
    && export ERL_CXXFLAGS="-I${ERL_ROOT_DIR}/erts-${ERTS_VSN}/include -I${EI_DIR}/include" \
    && export ERL_LDFLAGS="-L${EI_DIR}/lib" \
    && mix do local.hex --force + local.rebar --force + setup + compile

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM hexpm/elixir:1.20.4-erlang-29.1-ubuntu-noble-20260911

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
# planck_agent + planck_ai sources outside the workspace so Typesense doesn't index them.
# PLANCK_AGENT_SRC is forwarded by SidecarManager. planck_agent's local_or_hex then
# auto-detects planck_ai via File.dir?("../planck_ai") = /app/planck_ai.
COPY --from=builder /build/planck_agent /app/planck_agent
COPY --from=builder /build/planck_ai /app/planck_ai

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
ENV PLANCK_AGENT_SRC=/app/planck_agent

EXPOSE 4000

ENTRYPOINT ["/entrypoint.sh"]
