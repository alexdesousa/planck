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

Project config lives in `.planck/config.json` at the working directory root.

## Keys

```json
{
  "default_provider": "anthropic",
  "default_model":    "claude-sonnet-4-6",
  "sessions_dir":     ".planck/sessions",
  "skills_dirs":      [".planck/skills", "~/.planck/skills"],
  "teams_dirs":       [".planck/teams", "~/.planck/teams"],
  "sidecar":          ".planck/sidecar",
  "locale":           "en",
  "models":           []
}
```

| Key | Env var | Description |
|---|---|---|
| `default_provider` | `PLANCK_DEFAULT_PROVIDER` | Provider used when no team template is specified |
| `default_model` | `PLANCK_DEFAULT_MODEL` | Model id used when no team template is specified |
| `sessions_dir` | `PLANCK_SESSIONS_DIR` | Where SQLite session files are stored |
| `skills_dirs` | `PLANCK_SKILLS_DIRS` (colon-separated) | Directories scanned for skills |
| `teams_dirs` | `PLANCK_TEAMS_DIRS` (colon-separated) | Directories scanned for team templates |
| `sidecar` | `PLANCK_SIDECAR` | Path to a sidecar Mix project; omit or set to non-existent path to disable |
| `locale` | `PLANCK_LOCALE` | UI language (`en`, `es`). Overrides browser language. Set globally in `~/.planck/config.json` or per-project in `.planck/config.json` |

## Local model declarations

The `models` key declares local or custom models not in the built-in catalog:

```json
{
  "models": [
    {
      "id":             "llama3.2",
      "provider":       "ollama",
      "base_url":       "http://localhost:11434",
      "context_window": 128000
    },
    {
      "id":             "mistral",
      "provider":       "llama_cpp",
      "base_url":       "http://localhost:8080",
      "context_window": 32768,
      "default_opts":   { "temperature": 0.5 }
    }
  ]
}
```

Valid providers: `anthropic`, `openai`, `google`, `ollama`, `llama_cpp`.

## Minimal setup for a project

```sh
mkdir -p .planck/teams .planck/skills .planck/sessions

cat > .planck/config.json <<'EOF'
{
  "default_provider": "anthropic",
  "default_model":    "claude-sonnet-4-6"
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

The Web UI's setup modal (⚙ in the status bar) writes the API key to the
appropriate `.env` file automatically when you configure a new provider.
