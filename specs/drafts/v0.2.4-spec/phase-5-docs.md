# Phase 5 — Docs

Part of [v0.2.4-spec](../v0.2.4-spec.md). Depends on
[Phase 1](phase-1-planck-ai.md) (the config shape being documented) and
[Phase 2](phase-2-planck-agent.md) (`classify`'s availability model).

## Objective

Update the user-facing setup guides so a person — or an agent configuring a
Planck environment on someone's behalf, per `AGENTS.md`'s "read the relevant
guide before implementing" instruction — can find the `typesafe` provider
type and understand `classify`'s automatic availability without reading
`planck_ai`/`planck_agent` source.

## Plan

- `skills/planck_setup/references/configuration.md` — document
  `"type": "typesafe"` alongside `"anthropic"/"openai"/"google"`, including
  the cloud vs `base_url`-override split (mirroring however `"openai"` vs
  a `base_url`-carrying `"openai"` entry is currently documented there).
- `skills/planck_setup/references/teams.md` — `classify` isn't an
  inter-agent tool in the same sense as `call_agent`/`spawn_agent`, but
  it's automatically granted the same way; note it in whatever section
  already documents automatic vs opt-in (`TEAM.json`-declared) tool
  availability.

## Use Cases

- Someone following `configuration.md` to hand-write `config.json` finds
  the `typesafe` provider type documented at the same level of detail as
  `anthropic`/`openai`/`google`, without needing to read
  `Planck.AI.Config` source to guess the shape.
- An agent configuring a new Planck environment (the `planck-setup` skill's
  own use case) correctly writes a `typesafe` provider entry and knows not
  to add `classify` to a worker's `TEAM.json` `"tools"` list, because
  `teams.md` says it's automatic.

## Test Cases

None — this phase is documentation only, no code changes to verify with
automated tests. Correctness here is checked by cross-referencing the
finished Phase 1/2/3/4 implementation against what's written, not by a test
suite.
