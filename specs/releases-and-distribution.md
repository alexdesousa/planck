# Releases & Distribution

## Per-package strategy

| Package | Distribution | Notes |
|---|---|---|
| `planck_ai` | Hex.pm | Standalone LLM library, no agent dep |
| `planck_agent` | Hex.pm | Depends on `planck_ai` |
| `planck_headless` | Hex.pm | Depends on `planck_agent` |
| `planck_cli` | Burrito binary + GitHub Releases | Depends on all of the above; contains Web UI + HTTP API |

The Web UI and HTTP API are not separate Hex packages. They live inside `planck_cli`
as internal modules. Anyone wanting to build their own interface depends on
`planck_headless` directly.

## planck_cli — Burrito binary

Self-contained binary. Bundles the Erlang runtime. End users need no Elixir or Erlang.

```elixir
def releases do
  [
    planck: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [
          linux:      [os: :linux,   cpu: :x86_64],
          macos_arm:  [os: :darwin,  cpu: :aarch64],
          windows:    [os: :windows, cpu: :x86_64]
        ],
        debug: Mix.env() != :prod
      ]
    ]
  ]
end
```

## planck_cli — execution modes

```sh
planck                        # Start the web server (default)
planck --port 8080            # Custom port
planck --ip 0.0.0.0           # Bind to all interfaces (e.g. Docker)
planck --host planck.local    # Custom URL hostname
planck --sname my_node        # Custom Erlang node name
planck --cookie my_secret     # Custom Erlang cookie
planck --help                 # Print usage
planck --version              # Print version
```

All flags can also be set via environment variables — the flag overrides the
env var when both are provided:

| Flag | Env var | Default |
|---|---|---|
| `--port` | `PORT` | `4000` |
| `--ip` | `IP_ADDRESS` | `127.0.0.1` |
| `--host` | `HOST` | `localhost` |
| `--sname` | `NODE_SNAME` | `planck_cli` |
| `--cookie` | `NODE_COOKIE` | `planck` |

The web server binds to `127.0.0.1` by default so only the local machine can
reach it. Set `IP_ADDRESS=0.0.0.0` (or `--ip 0.0.0.0`) to expose on all
interfaces — for example inside a Docker container.

Erlang distribution (`--sname`/`--cookie`) is started automatically at boot
and is required for the optional sidecar to connect back.

`SECRET_KEY_BASE` signs cookies and LiveView connections. If not provided a random
key is generated at each startup (sessions do not survive restarts). Pin it with
`SECRET_KEY_BASE=$(openssl rand -base64 48) planck` for persistent sessions.

For CI pipelines and external integrations, use the HTTP API directly
(`GET /api/sessions`, `POST /api/sessions/:id/prompt`, etc.) — no separate
headless mode is needed.

## Hex library releases

Each library is versioned and published independently:

```sh
cd planck_ai && mix hex.publish
```

Users who want to build on top of Planck depend only on what they need:

```elixir
{:planck_ai, "~> 0.1"}          # LLM abstraction only
{:planck_agent, "~> 0.1"}       # agent runtime (pulls planck_ai transitively)
{:planck_headless, "~> 0.1"}    # full headless stack (pulls planck_agent transitively)
```

## Version policy

All packages share the same version number and are released simultaneously. Version is
defined once per `mix.exs` via a module attribute and kept in sync with `./bump`.

## Bump script

```sh
./bump X.Y.Z
```

Updates all files in the checklist below and prepends a `## vX.Y.Z` stub to
each CHANGELOG. Does not commit or tag — run `./check` and fill in the
CHANGELOGs before committing.

## Release checklist

Every file that must be updated when cutting a new version (`X.Y.Z`):

### Version numbers

| File | What to change |
|---|---|
| `VERSION` | Bare version string, read by CI scripts |
| `planck_ai/mix.exs` | `@version` |
| `planck_agent/mix.exs` | `@version` |
| `planck_headless/mix.exs` | `@version` |
| `planck_cli/mix.exs` | `@version` |
| `planck_docker/sidecar/mix.exs` | `version:` |
| `planck_docker/compose.yml` | `image: ghcr.io/alexdesousa/planck:X.Y.Z` (both service entries) |
| `skills/planck_setup/SKILL.md` | `planck_version:` frontmatter field |
| `docs/install.sh` | `VERSION="X.Y.Z"` |
| `docs/install.ps1` | `$Version = "X.Y.Z"` |
| `docs/install_docker.sh` | `VERSION="X.Y.Z"` |
| `docs/install_docker.ps1` | `$Version = "X.Y.Z"` |

### CHANGELOGs

Add a `## vX.Y.Z` section to each of:

- `planck_ai/CHANGELOG.md`
- `planck_agent/CHANGELOG.md`
- `planck_headless/CHANGELOG.md`
- `planck_cli/CHANGELOG.md`
- `planck_docker/CHANGELOG.md`

### CI — OTP version pins

`release.yml` has two sets of `otp-version`:

- **Publish jobs** (`publish-ai`, `publish-agent`, `publish-headless`): float on `"29.1"` — no pin needed, since these jobs only compile and never fetch a portable ERTS.
- **Build jobs** (`build-linux`, `build-macos-arm`, `build-windows`): each downloads a portable ERTS to bundle into the binary. Burrito reads the *build host's own installed* OTP_VERSION file to pick which one to fetch (`Burrito.Util.get_otp_version/0`) — it does not use the `otp-version:` string you gave `erlef/setup-beam` directly, only whatever that action actually installed.
  - **A two-component pin (e.g. `"29.1"`) is unsafe for `build-linux` and `build-macos-arm`.** `erlef/setup-beam` resolves it to the *newest patch* in that line, not the bare GA release — and that resolution can change between one workflow run and the next as new patches are published upstream, with no change to the pin itself. Both platforms fetch their portable ERTS from a third-party mirror (beam-machine-universal.b-cdn.net) that lags behind official OTP patch releases. If the newest patch isn't built there yet, the job 404s deep inside Burrito. This isn't hypothetical: on 2026-09-22, `"29.1"` drifted to `29.1.1` on *both* `build-linux` and `build-macos-arm` overnight — even though bare `OTP-29.1` was confirmed mirrored for both platforms the day before — and broke both jobs simultaneously. `build-macos-arm` was previously assumed exempt ("macOS's package already resolves to a clean, mirrored patch"); that assumption was wrong. `build-windows` fetches straight from GitHub's official OTP releases, not this mirror, so it hasn't shown this failure mode — but treat that as unconfirmed safety, not a guarantee.
  - The fix is to pin `build-linux` and `build-macos-arm` to a full, exact three-component patch version confirmed mirrored on **both** platforms — never a bare `"X.Y"` line — so there is no newer patch for `erlef/setup-beam` to drift to. Confirm before pinning:
    ```sh
    curl -o /dev/null -sw '%{http_code}\n' \
      "https://beam-machine-universal.b-cdn.net/OTP-X.Y.Z/linux/x86_64/any/otp_X.Y.Z_linux_any_x86_64.tar.gz?please-respect-my-bandwidth-costs=thank-you&openssl=3.5.1&musl=1.2.5"
    curl -o /dev/null -sw '%{http_code}\n' \
      "https://beam-machine-universal.b-cdn.net/OTP-X.Y.Z/macos/universal/otp_X.Y.Z_macos_universal.tar.gz?please-respect-my-bandwidth-costs=thank-you&openssl=3.5.1&musl=1.2.5"
    ```
    200 on both means it's safe to pin both jobs to that exact version; 404 on either means fall back to the last exact patch confirmed mirrored on both (currently `"29.0.6"`, confirmed 2026-09-22) until the newer one catches up.

### Git tag

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

Pushing the tag triggers the release workflow.
