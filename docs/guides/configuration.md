# Planck Configuration

Planck reads config from multiple sources. Priority order (highest first):

1. CLI flags (`--port`, `--ip`, etc.) — binary only
2. Environment variables
3. `.env` files — `~/.planck/.env` (global) then `./.planck/.env` (project)
4. JSON config files — `~/.planck/config.json` (global) then `.planck/config.json` (project)
5. Hardcoded defaults

## Web server

These control the web server and are only meaningful when running the `planck` binary
or `mix run`. They are **not** stored in `config.json`.

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--port` | `PORT` | `4000` | HTTP listening port |
| `--ip` | `IP_ADDRESS` | `127.0.0.1` | Bind address. Use `0.0.0.0` for Docker/server |
| `--host` | `HOST` | `localhost` | Hostname for generated URLs |
| `--sname` | `NODE_SNAME` | `planck_cli` | Erlang short node name (required for sidecar) |
| `--cookie` | `NODE_COOKIE` | `planck` | Erlang magic cookie |

`SECRET_KEY_BASE` signs cookies and LiveView connections. If not set a random key is
generated at each startup — active sessions will not survive a restart. Pin it for
persistent sessions:

```sh
SECRET_KEY_BASE=$(openssl rand -base64 48) planck
```

**Security note:** `IP_ADDRESS` defaults to `127.0.0.1` so the server is only reachable
from the local machine. Planck has no authentication — only expose it on the network
when you control access at the infrastructure level.

## Keys

```json
{
  "default_model":  "sonnet",
  "sessions_dir":   ".planck/sessions",
  "skills_dirs":    [".planck/skills", "~/.planck/skills"],
  "teams_dirs":     [".planck/teams", "~/.planck/teams"],
  "sidecar":        ".planck/sidecar",
  "locale":         "en",
  "providers":      {},
  "models":         []
}
```

| Key | Env var | Description |
|---|---|---|
| `default_model` | `PLANCK_DEFAULT_MODEL` | Alias of the model used when no team template is specified |
| `sessions_dir` | `PLANCK_SESSIONS_DIR` | Where SQLite session files are stored |
| `skills_dirs` | `PLANCK_SKILLS_DIRS` (colon-separated) | Directories scanned for skills |
| `teams_dirs` | `PLANCK_TEAMS_DIRS` (colon-separated) | Directories scanned for team templates |
| `sidecar` | `PLANCK_SIDECAR` | Path to a sidecar Mix project; omit or set to non-existent path to disable |
| `locale` | `PLANCK_LOCALE` | UI language (`en`, `es`). Overrides browser language. Set globally in `~/.planck/config.json` or per-project in `.planck/config.json` |
| `providers` | — | Map of named provider entries (see below) |
| `models` | — | List of model declarations (see below) |

## Image proxy

The image proxy (`GET /api/proxy`) is configured via environment variables only — these
are not read from `config.json`.

| Env var | Separator | Description |
|---|---|---|
| `PLANCK_PROXY_IMAGE_DOMAINS` | comma | HTTP/HTTPS `host` (with optional `:port`) allowed for proxying. Default: empty (deny all). |
| `PLANCK_PROXY_IMAGE_PATHS` | colon | Local filesystem path prefixes from which files may be served. Default: empty (deny all). |

```sh
PLANCK_PROXY_IMAGE_DOMAINS=image.coroto.net,cdn.example.com:8080
PLANCK_PROXY_IMAGE_PATHS=/home/user/comfyui/output:/tmp/planck-images
```

See the [images guide](images.md) for the full security model.

## Providers and models

Models are declared in two parts: a `providers` map that defines backends, and a
`models` list that assigns user-facing aliases.

### Provider entry fields

| Field | Required | Description |
|---|---|---|
| `type` | yes | `"anthropic"`, `"openai"`, or `"google"` |
| `base_url` | no | Override the default endpoint — required for OpenAI-compatible local servers |
| `identifier` | no | Uppercase tag for env var derivation (`"NVIDIA"` → `NVIDIA_API_KEY`). Defaults to `"OPENAI"` when omitted on openai-type providers |
| `has_api_key` | no | Set to `false` for local servers that need no authentication (Ollama, llama.cpp). Default: `true` |

### Model entry fields

| Field | Required | Description |
|---|---|---|
| `id` | yes | User-defined alias used throughout the UI (e.g. `"sonnet"`) |
| `model` | yes | Provider's model identifier (e.g. `"claude-sonnet-4-6"`) |
| `provider` | yes | Key referencing an entry in the `providers` map |
| `params` | no | Inference parameters (`temperature`, `max_tokens`, etc.) |

### Example

```json
{
  "default_model": "sonnet",
  "providers": {
    "anthropic": { "type": "anthropic" },
    "openai":    { "type": "openai" },
    "google":    { "type": "google" },
    "nvidia": {
      "type":       "openai",
      "base_url":   "https://integrate.api.nvidia.com/v1",
      "identifier": "NVIDIA"
    },
    "groq": {
      "type":       "openai",
      "base_url":   "https://api.groq.com/openai/v1",
      "identifier": "GROQ"
    },
    "local-ollama": {
      "type":        "openai",
      "base_url":    "http://localhost:11434",
      "has_api_key": false
    }
  },
  "models": [
    { "id": "sonnet",   "model": "claude-sonnet-4-6",           "provider": "anthropic" },
    { "id": "gpt-4o",   "model": "gpt-4o",                     "provider": "openai" },
    { "id": "flash",    "model": "gemini-2.5-flash",            "provider": "google" },
    { "id": "llama70b", "model": "meta/llama-3.3-70b-instruct", "provider": "nvidia",
      "params": { "temperature": 0.6, "receive_timeout": 600000 } },
    { "id": "llama3.2", "model": "llama3.2",                    "provider": "local-ollama" }
  ]
}
```

When multiple config files are loaded, `providers` maps are **merged** (project-local
wins on key collision). `models` lists are **concatenated** — entries from
`~/.planck/config.json` and `.planck/config.json` are combined so globally configured
models are not shadowed by project-local ones.

## Minimal setup

```sh
mkdir -p .planck/teams .planck/skills .planck/sessions

cat > .planck/config.json <<'EOF'
{
  "default_model": "sonnet",
  "providers": {
    "anthropic": { "type": "anthropic" }
  },
  "models": [
    { "id": "sonnet", "model": "claude-sonnet-4-6", "provider": "anthropic" }
  ]
}
EOF
```

## API keys

API keys can be set in three ways (higher entries win):

1. **Shell environment variables** — always take precedence:
   ```sh
   export ANTHROPIC_API_KEY="sk-ant-..."
   export OPENAI_API_KEY="sk-..."
   export GOOGLE_API_KEY="..."
   export NVIDIA_API_KEY="nvapi-..."
   ```

2. **`.planck/.env`** — project-local, applies only in this directory:
   ```sh
   # .planck/.env
   ANTHROPIC_API_KEY=sk-ant-...
   ```

3. **`~/.planck/.env`** — global, applies to all projects:
   ```sh
   # ~/.planck/.env
   OPENAI_API_KEY=sk-...
   ```

Standard dotenv format: `KEY=value`, one per line, `#` for comments.
These files are loaded at startup — add them to `.gitignore` to avoid
accidentally committing credentials.

The env var name for a custom OpenAI-compatible provider is derived from its
`identifier` field: `"NVIDIA"` → `NVIDIA_API_KEY`, `"GROQ"` → `GROQ_API_KEY`.
Providers with `has_api_key: false` need no key at all.

The Web UI's setup modal (⚙ in the status bar) writes the API key to the
appropriate `.env` file automatically when you configure a new provider.
