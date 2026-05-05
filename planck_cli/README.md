# planck_cli

The web UI and HTTP API for Planck — a Phoenix LiveView application that provides the
browser-based interface and a REST/SSE API for interacting with agents.

## Running

```bash
PLANCK_LOCAL=true mix run --no-halt -- --sname planck_cli
```

- `PLANCK_LOCAL=true` — resolves sibling packages as local path dependencies instead
  of fetching from Hex.
- `--sname planck_cli` — sets the Erlang node name for distribution (required for the
  optional sidecar). Passed after `--` so `System.argv()` delivers it to the app.

The web UI is then available at [http://localhost:4000](http://localhost:4000).

## Server options

All options can be passed as flags after `--` or set via environment variables:

| Flag | Env var | Default | Notes |
|---|---|---|---|
| `--port N` | `PORT` | `4000` | HTTP port |
| `--ip ADDR` | `IP_ADDRESS` | `127.0.0.1` | Bind address; use `0.0.0.0` to expose on the network |
| `--host NAME` | `HOST` | `localhost` | Hostname for URL generation |
| `--sname NAME` | `NODE_SNAME` | `planck_cli` | Erlang short node name |
| `--cookie VAL` | `NODE_COOKIE` | `planck` | Erlang magic cookie |

```bash
# Expose on all interfaces (e.g. for LAN access or Docker)
IP_ADDRESS=0.0.0.0 PLANCK_LOCAL=true mix run --no-halt

# Custom port and node name
PLANCK_LOCAL=true mix run --no-halt -- --port 8080 --sname my_planck
```

## Sidecar

If you have a sidecar configured (at `~/.planck/sidecar` by default), it will be built
and started automatically. The sidecar status is shown in the agents sidebar.
Erlang distribution (`--sname`) must be enabled for the sidecar to connect back.
