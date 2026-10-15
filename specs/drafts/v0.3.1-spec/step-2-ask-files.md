# Step 2 — `ask_files` core tool + live-`read` resolution

Part of [v0.3.1-spec](../v0.3.1-spec.md). Depends on
[Step 1](step-1-rename-ask.md).

## Description

New `Tools.ask_files/1` in `planck_agent`, appended next to `ask` in
`orchestrator_tools/6` under the identical RLCD predicate. Params:
`provider, model_id, base_url, paths: [string]` (max 255 after
expansion; explicit paths plus glob patterns `*`/`?`/`[...]` expanded
against the agent's cwd — glob support was added after this draft's
original "explicit paths only" plan), `questions` (same
`choice|score|boolean` shape as `ask`). Per file: resolve
(absolute or workspace/cwd-relative, same rule as `read`), skip with
reason (not-found, not-a-file, empty, over char budget with headroom
for the questions, binary via null-byte sniff) into
`skipped: [{path, reason}]`; else one `evaluate(model, %{path:,
content:}, questions, [])`. Concurrency cap 16 (`Task.async_stream`,
order-restored). Returns `{results: [{path, answers}], skipped,
calls}` JSON — same envelope as upstream L9 so a follow-up `ask`
choice keyed by path can pick-first.

**Live-`read` resolution.** `execute_fn` runs headless-side, so at
call time it queries `ResourceStore.get().tools` for the current
`"read"` wrapper (which RPCs to whatever sidecar is connected *now*)
and delegates per file; if absent, falls back to builtin `read`
semantics. Never recurses into `ask_files`. This handles late sidecar
arrival per-call with no `execute_fn` arity change.

**Worker-grant fix.** The documented-but-unwired worker grant
(`TEAM.json` `tools` / `spawn_agent` `tools:`) must actually resolve:
include `ask`/`ask_files` in the headless grantable pool when RLCD is
configured (the `phase-2-planck-agent.md` design says this; it was
never implemented — `grep classify planck_headless/lib` is empty).

Prompt sections: `tool_section("ask_files")` documents the envelope
plus the gating recipe (`ask_files` boolean → act where `noul > Y`,
Y chosen by the agent; re-`read` only hits). Document `boolean` ≡
upstream `noul`.

### TDD order

1. `ask_files` with injected reader (pure tests: mixed ok/skipped,
   cap, order, envelope).
2. Live-resolution + fallback; worker-grant pool; prompt sections.

## Definition of Done

- `ask` and `ask_files` share one RLCD predicate; both grantable to
  workers; `mix test` green in `planck_agent`, `planck_headless`.
- Sessions started before sidecar connect still get sidecar-`read`
  content inside `ask_files` once the sidecar lands.

## Use Cases

```gherkin
Feature: ask_files triages many files with one question block

  Scenario: Bug triage over explicit paths
    Given paths ["a.ex", "b.ex", "missing.ex"] and a boolean question "Is this file related to <bug>?"
    When ask_files executes with an RLCD model
    Then results contains "a.ex" and "b.ex" with answers
    And skipped contains "missing.ex" with reason "not found"
    And calls equals 2

  Scenario: Oversize and binary files are skipped with reasons
    Given one file over the char budget and one binary file
    When ask_files executes
    Then both appear in skipped with reasons and neither consumes an RLCD call

  Scenario: Over the file cap
    Given 256 paths
    When ask_files executes
    Then it returns an error before reading any file

  Scenario: Sidecar read wins when present
    Given the sidecar connected after session start with a shadowing "read"
    When ask_files executes
    Then file content comes through the sidecar reader (e.g. Tika-extracted text)

  Scenario: No sidecar means builtin fallback
    Given no sidecar connected
    When ask_files executes
    Then file content comes from local reads with identical path semantics

  Scenario: Worker can be granted ask_files
    Given an RLCD model configured and a worker granted ["ask_files"]
    When the worker starts
    Then its tool set contains "ask_files"
```

## Test Cases

- Envelope shape, skip reasons, 255 cap, concurrency bound,
  order-stability, per-file RLCD failure → `skipped` (not whole-call
  failure).
- Live-resolution prefers sidecar `read`; fallback without sidecar;
  no self-recursion.
- Grantable-pool inclusion iff RLCD present (orchestrator + worker).

## Files touched

- `planck_agent/lib/planck/agent/tools.ex` (new `ask_files/1`)
- `planck_agent/lib/planck/agent/system_prompt.ex`
- `planck_headless/lib/planck/headless.ex` (grantable pool)
- Tests in both packages
