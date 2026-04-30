# Planck Configuration

Planck reads config from three sources in priority order (highest first):

1. Environment variables (`PLANCK_*`)
2. JSON config files — `~/.planck/config.json` (global) then `.planck/config.json` (project)
3. Hardcoded defaults

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

API keys are set via environment variables and are never stored in config files:

```sh
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="..."
```
