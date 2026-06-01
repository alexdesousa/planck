# Docker Stack

The Planck Docker stack (`planck_docker/compose.yml`) bundles several services
that are automatically available when self-hosting. No extra configuration is
needed to use them — they are active as long as the stack is running.

## Services

### Planck (web UI + sidecar)

The main container runs the Planck web UI, the HTTP API, and the bundled sidecar
OTP application. The sidecar connects back to the planck node over distributed
Erlang on startup.

### Agent-vault (credential proxy)

[Infisical agent-vault](https://github.com/infisical/agent-vault) is an HTTPS
MITM proxy that injects credentials into outbound HTTP requests based on
host-matching service rules. Agents make plain HTTP calls — the proxy handles
authentication transparently.

- Port 14322: MITM proxy (used by all outbound LLM and tool calls)
- Port 14321: management API (internal only, not published)

Credentials and service rules are managed via Planck's **Setup modal** →
"Manage secrets" and "Configure a service rule".

**Security**: Agents never see API keys. The bash tool runs with a minimal
environment (`PATH`, `HOME`, proxy vars only — no secrets). Credential injection
is host-scoped: a rule for `api.n8n.com` only fires for requests to that host,
preventing prompt-injection exfiltration.

### Typesense (workspace indexing)

Full-text search over workspace files. The sidecar automatically indexes new and
changed files. Agents use `search_workspace` to find relevant files before
reading them, reducing context usage.

Data directory: `$PLANCK_HOME/typesense-data`

### Searxng (private web search)

Privacy-respecting meta-search. Agents use `search_web` to query the web without
sending queries to third-party search APIs. Results are returned as structured
snippets.

Language: set `SEARXNG_LANGUAGE` in your `.env` (default: `en`).

### Apache Tika (document extraction)

Extracts plain text from binary documents: PDF, DOCX, XLSX, PPTX, ODT, and
more. Agents use the `read` tool on document files; Tika handles extraction
transparently when the file extension is recognised.

## Sidecar features (Docker only)

The bundled sidecar enables additional capabilities beyond the base planck
packages:

### Long-term memory

Session turns are indexed in Typesense after each conversation. On session
resume, relevant past turns are retrieved and injected into the agent prompt,
giving the agent context about previous conversations.

Implemented in: `Sidecar.Memory`

### Short-term memory

A per-agent in-memory store (ETS) for the current session. The sidecar writes
summaries or key facts that survive compaction and are injected at the start of
each turn via the `Prompt` hook.

Implemented in: `Sidecar.Memory` (ETS layer)

### Skill reflector

After each turn, the sidecar evaluates whether the agent's work could be
captured as a reusable skill and writes one if appropriate. Skills accumulate
over time, making the agent progressively more efficient on familiar tasks.

Implemented in: `Sidecar.SkillReflector`

### Markdown web fetch

The `fetch_web` tool fetches URLs and converts HTML to clean Markdown using
[Readability](https://github.com/mozilla/readability)-style extraction. Fetched
pages are cached in Typesense; repeated requests within a session return the
cached version instantly.

Implemented in: `Sidecar.Tools.WebFetch`

## Data directories

| Directory | Contents |
|---|---|
| `$PLANCK_HOME/workspace/` | Agent workspace (files, sessions, teams, skills, sidecar) |
| `$PLANCK_HOME/typesense-data/` | Workspace search index |
| `$PLANCK_HOME/vault-data/` | Agent-vault credentials and service rules |

To reset a service's data, stop the stack and delete the corresponding directory.
