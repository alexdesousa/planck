# Travel Agent Demo

A companion to a Building Planck post on embedding `Planck.Agent` directly
into your own app — no `planck_headless`, no session/config-file baggage,
just one agent, your own tools, and a Phoenix LiveView front end.

It's a single AI agent with four custom tools (`get_weather`,
`get_country_facts`, `search_flights`, `reserve_flight`) that interviews a
visitor about their trip and books a mock flight. No coding tools
(`read`/`write`/`edit`/`bash`), no delegation tools (`spawn_agent`,
`call_agent`, etc.) — because we never asked `Planck.Agent` for any. It gets
exactly the tools we pass it.

The whole app is one file: `travel_agent.exs`. No mix project, no asset
pipeline — Phoenix + LiveView (loaded from CDN, no build step) for the web
layer, Tailwind via CDN plus hand-written CSS for the RetroUI look (matching
`planck_cli`'s own theme).

## Running it

Requires Elixir 1.19+.

```bash
elixir travel_agent.exs
```

Then open <http://localhost:8000>. You'll be asked to pick a provider
(Anthropic, OpenAI, Gemini, or a local OpenAI-compatible server like Ollama)
and, unless it's keyless, an API key — this demo doesn't ship with one.

## What's demonstrated

- One `Planck.Agent` GenServer, started directly via
  `DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent, ...})`
  with `tools:`, `system_prompt:`, and `model:` — no team, no TEAM.json, no
  `.planck/` config files anywhere on disk.
- A `%Planck.AI.Model{}` built directly from the config form. Provider API
  keys are read fresh per-request via plain `System.get_env/1`
  (`Planck.AI.Adapter.resolve_api_key/1`) — no caching, no reload step, just
  `System.put_env/2` at configure time.
- `Planck.Agent.subscribe/1` + `handle_info({:agent_event, type, payload}, socket)`
  for streaming — no hand-written SSE endpoint, no client-side JS beyond the
  two CDN `<script>` tags LiveView itself needs. Agent events arrive as plain
  Elixir messages; no JSON-encoding boundary exists between the agent and
  the UI at all.
- The whole three-step flow (provider setup → trip details → chat) lives in
  one LiveView's socket assigns, not separate pages/cookies/a visitor store.
- Two tools backed by real, keyless public APIs (Open-Meteo, REST
  Countries); two simulated (`search_flights`/`reserve_flight` — no free
  public flight-pricing API exists).

## Known limitations

- Each browser tab gets its own LiveView process and its own `Planck.Agent`
  — closing the tab (or hitting "Start over") terminates that agent.
  Nothing persists across a page reload; this demo trades that away
  deliberately for minimalism.
- Flight prices and airlines are entirely fictional, seeded deterministically
  from the search parameters — not real fares.
- Setting a provider API key sets a process-wide OS environment variable
  (`ANTHROPIC_API_KEY`, etc.) — fine for one person testing locally, not
  safe for multiple concurrent visitors picking different keys for the same
  provider.
