# Bundled Sidecar Tools

`specs/sidecar.md` documents the sidecar *mechanism* — the `Planck.Agent.Sidecar`
behaviour, hooks, RPC plumbing. `specs/planck-docker.md` documents how the
bundled sidecar gets *deployed*. Neither says *why* the bundled sidecar has the
specific tools it has, or what each one is actually for. This does.

## What "opinionated" means here

The sidecar mechanism is deliberately unopinionated: a sidecar can be a single
module or a whole Phoenix app, and nothing about `Planck.Agent.Sidecar` assumes
what capabilities it should add. `planck_docker`'s bundled sidecar is the
opposite — a specific, curated set of tools Planck ships by default, backed by
three internal services (Typesense, Searxng, Tika) that come up automatically
with the Docker stack. A user who never writes a line of sidecar code still
gets web research, workspace/session search, persistent memory, and a
self-writing skill system, on day one.

The point of being opinionated is that "install Planck" should mean something
more useful than "install a chat window in front of an LLM with bash access."
Every tool below exists because the core coding tools (`read`, `write`, `edit`,
`bash` — not sidecar tools, always available) leave a specific, recurring gap
unaddressed.

## The tools, at a glance

| Tool | Fills the gap | Backed by |
|---|---|---|
| `read` (shadowed) | Binary documents (PDF/DOCX/XLSX/...) are opaque to a plain-text reader | Tika |
| `web_fetch` | Raw HTML is noisy; the same page shouldn't cost a fetch twice | Node.js (`@mozilla/readability`) + Typesense |
| `search_web` | The agent needs to find things it doesn't already have a URL for | Searxng |
| `search_workspace` | A large workspace can't be read file-by-file | Typesense |
| `session_search` | Decisions made in a past session are otherwise gone once that session ends | Typesense |
| `update_memory` | Facts an agent should just *know* next time, without being asked to look them up | Typesense |
| `list_skills` / `write_skill` | Procedures an agent has already worked out shouldn't have to be re-derived every time | filesystem + `SkillReflector` |
| `bd_ready` / `bd_get` / `bd_list` / `bd_claim` / `bd_create` / `bd_done` / `bd_delete` | Work spanning multiple agents/turns needs a shared, structured tracker — not just ad-hoc `update_memory` facts | `beads` + `dolt` |

Three services do almost all of the load-bearing work: **Typesense** (search
and memory storage), **Searxng** (private web search), **Tika** (document text
extraction). A fourth pair, **`beads`** (task API) + **`dolt`** (its storage
backend), backs the shared task tracker specifically. All are internal-only
Docker services — see `specs/planck-docker.md` for the deployment side.

---

## Document reading — `read` (shadowed)

**Motivation.** The built-in `read` tool (`planck_agent`) is a plain-text
reader. Real workspaces accumulate PDFs, spreadsheets, and slide decks —
requirements docs, exported data, a client's brief — and a plain-text reader
can only fail on them, or worse, silently return binary garbage the model then
hallucinates about.

**How it works.** `Sidecar.Tools.Read` registers under the same name as the
built-in tool, so declaring it in a sidecar's `tools/0` shadows the original —
agents don't need to know two different tools exist. For plain text it behaves
identically to the built-in. For a recognized binary format it sends the file
to Apache Tika for extraction, caches the result in `doc_cache/` inside the
workspace (invalidated automatically when the source file's mtime moves past
the cache's), and prepends a header noting the original format and that the
file can only be `write`-replaced, not `edit`-patched — the model is reading
extracted text, not the file's real bytes, so incremental edits to it would be
meaningless.

## Web research — `web_fetch` and `search_web`

**Motivation, `web_fetch`.** A raw HTML fetch is mostly noise for an LLM —
navigation chrome, ads, tracking scripts. `web_fetch` exists so an agent gets
the same clean-reading-view experience a human gets from a browser's reader
mode, and so that reading the same page twice (across turns, across sessions)
doesn't repeat the network round-trip or the noise-stripping cost.

**How it works.** Fetches the URL, pipes it through `@mozilla/readability` +
`turndown` (a Node.js script invoked via `erlexec`) to get clean markdown,
caches the result to `web_cache/` keyed by a hash of the URL, and — because the
cache lives inside the watched workspace — the workspace indexer picks it up
automatically, so `search_workspace` can later find content across every page
ever fetched without re-fetching any of them. `refresh: true` forces a
re-fetch past the cache; `offset`/`limit` paginate long pages.

**Motivation, `search_web`.** An agent needs to find things it doesn't already
have a URL for. Searxng specifically (rather than a commercial search API) was
chosen for two reasons: it's privacy-respecting (no query logging to a
third-party, no per-query cost), and it avoids locking Planck's core research
capability to one vendor's API and pricing.

**How it works.** Queries the internal Searxng instance and formats the top
five results as `**title**\nurl\ncontent` per result. Searxng itself is
user-configurable (via the bundled `configure-searxng` skill, editing
`.planck/searxng/settings.yml` — see `specs/planck-docker.md`), so which
underlying search engines actually get queried is not hardcoded into the tool
at all.

## Retrieval over what already exists — `search_workspace` and `session_search`

These two are the same *idea* — ranked full-text search instead of needing to
already know where to look — applied to two different corpora that would
otherwise be invisible to each other.

**Motivation, `search_workspace`.** Once a workspace grows past a handful of
files, reading them one at a time to find something stops working, and an
agent has no equivalent of a human's "grep the codebase" instinct without a
tool for it. Full-text ranking also means an agent doesn't need to guess exact
filenames or exact strings — just describe what it's looking for.

**How it works.** `Sidecar.Watcher` performs a full index of `/workspace` on
sidecar startup, then watches for changes and re-indexes incrementally
(`file_system`-based), skipping `.planck/sessions`, `.planck/sidecar`, `.git`,
`node_modules`, `_build`, `deps` — anything that isn't a human- or
agent-authored workspace file. `search_workspace` just queries that index via
`Sidecar.Typesense.search/2` and formats the top ten hits as
`**path**\nexcerpt`.

**Motivation, `session_search`.** A session, once it ends (or once its context
gets compacted), stops existing as far as the model's context window is
concerned — but the decisions made and problems solved in it are often exactly
what a *later* session needs. Without this, Planck's institutional memory of a
project resets every time a conversation does.

**How it works.** Every turn gets indexed into a `long_term_memory` Typesense
collection (role, agent name, content, timestamp) as the session runs.
`session_search` queries that collection, optionally filtered to one agent by
name, ranked by text-match relevance and then recency, returning
`**[agent / role]** content` per hit. This is deliberately a *search* tool the
model has to decide to call — contrast with `update_memory` below, which is
injected passively into every prompt without the model asking.

## Self-maintained state — `update_memory`

**Motivation.** `session_search` requires the model to think to search for
something. Some things an agent should just already know at the start of every
turn without having to go looking — an ongoing task's current state, a
established preference, a fact worth not re-deriving. `update_memory` is that:
curated, agent-maintained, and passively injected, not searched.

**How it works.** Backed by `Sidecar.Memory` (an ETS-backed GenServer, see
`specs/sidecar.md`'s Per-agent memory section), keyed one record per agent as
`"team_name:agent_name"` in a `short_term_memory` Typesense collection, and
injected into every prompt via the `Planck.Agent.Hooks.Prompt` `prompt_hook`.
The tool itself has two actions: `"append"` (default) adds a fact and checks
the combined length against a 2,200-character cap — if it's over, the tool
returns the *full* combined content and asks the model to summarize and
resubmit with `"overwrite"`. The size cap is deliberate: it forces periodic
self-consolidation instead of unbounded, ever-noisier growth, and it's the
model doing the summarizing (not the tool), since deciding what's still worth
keeping is a judgment call the tool has no basis to make.

## Compounding procedural knowledge — `list_skills` and `write_skill`

**Motivation.** Memory (above) captures *facts*. Skills capture *procedures* —
"here's how to do X in this project" — the kind of thing worth writing down
once a pattern has proven itself, so a future agent doesn't have to
rediscover it turn by turn. Without this, every session starts from the same
base capability with no way for Planck to get better at a specific project's
own recurring tasks over time.

**How it works.** `write_skill` writes `.planck/skills/<name>/SKILL.md` with
`creator: agent` frontmatter, preserving any user-set `always_present: true`
across rewrites; `list_skills`, in its ordinary top-level registration, lists
every skill regardless of who authored it. But agents don't call `write_skill`
directly on their own initiative — it's driven by
`Sidecar.SkillReflector`, a `Planck.Agent.Hooks.TurnEnd` hook that counts tool
calls in a turn and, past a threshold, spins up an ephemeral "reflection"
mini-agent with exactly three tools: `list_skills` (here, restricted to
`creator: "agent"` only — a reflection agent shouldn't rewrite a human's
hand-curated skill), `load_skill`, and `write_skill`. The mini-agent decides
whether the turn's work was repeatable enough to be worth capturing, writes or
updates a skill if so, and its result is injected back into the *parent*
agent's history as a passive, non-callable entry — the parent never sees
`write_skill` as a tool it could call itself. Full lifecycle detail (the
`@max_tool_calls` safety cap, the create/update injection format) is in
`specs/sidecar.md`.

## Shared task tracking — the beads tools

**Motivation.** Memory (above) is per-agent and ad-hoc — a fact one agent
jots down for its own future turns. Work that spans *multiple* agents (an
orchestrator delegating to workers, or a human tracking what a team is doing)
needs a shared, structured primitive instead: a task with an id, a status,
and an owner, visible to everyone, not a scattered set of private notes.

**How it works.** Backed by `beads` (an HTTP task-tracking API) with `dolt`
as its storage engine, both dedicated Docker services — one shared instance
per Planck installation, not per-project or per-session. Seven tools cover
the LLM-facing side: `bd_ready` (open, unblocked work — what an agent should
pick up next), `bd_get` (a single bead's current state, including anything a
human edited since it was claimed), `bd_list` (whole-board overview,
including closed/done — orchestrator-only, for triage), `bd_claim`,
`bd_create` (optional `description`/`priority`), `bd_done`, and `bd_delete`.
Every successful call attaches a `ui:` button opening a shared kanban-style
board widget, so a turn that only claims or closes a bead still leaves a
human a way to see the board, not just the agent that acted on it.

**Human vs. agent actions.** The board widget lets a human create and delete
beads directly; it deliberately has no assign or mark-done control of its
own. Workers are spawned and torn down by the orchestrator at its own
discretion, so a human picking a specific worker to hand a bead to would
bypass the orchestrator's own delegation — and marking a bead done is the
same problem one level up, since the orchestrator (or whichever agent it
delegated to) is the one that actually knows whether the work is finished.
Claiming and closing stay LLM-only actions, resolved through the calling
agent's own durable `team_name:agent_name` identity (`Sidecar.Tools.Beads.require_actor/1`),
not a live picker or free text — a human's own actions on the board are
recorded as a fixed, well-known actor, `"user"`.

---

## What's deliberately not here

The restraint is as much a design choice as the tools themselves:

- **No browser/computer-use tool.** `web_fetch` covers "read a page";
  anything requiring interaction (clicking, forms, JS-rendered content) is a
  much bigger trust and complexity surface and isn't part of the opinionated
  default.
- **No credential-aware tools beyond what agent-vault already handles
  transparently** — see `specs/sidecar.md`'s and the v0.1.10 draft's coverage
  of `Planck.Agent.Secrets` / agent-vault; tools don't need their own
  credential-handling logic because outbound requests are proxied.
