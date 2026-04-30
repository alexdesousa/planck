# planck_cli

The web UI for Planck — a Phoenix LiveView application that provides the browser-based
interface for interacting with agents.

## Running

Planck requires a distributed Erlang node so the optional sidecar can connect back.
Use `elixir --sname` instead of plain `mix run`:

```bash
PLANCK_LOCAL=true elixir --sname planck_cli -S mix run --no-halt
```

- `PLANCK_LOCAL=true` — resolves sibling packages (`planck_agent`, `planck_headless`, etc.)
  as local path dependencies instead of fetching from Hex.
- `--sname planck_cli` — enables Erlang distribution with a short node name, required
  for the sidecar to connect back.

The web UI is then available at [http://localhost:4000](http://localhost:4000).

## Sidecar

If you have a sidecar configured (at `~/.planck/sidecar` by default), it will be built
and started automatically. The sidecar status is shown in the agents sidebar. If it
shows "starting" and never connects, make sure the app is running with `--sname` as
shown above.
