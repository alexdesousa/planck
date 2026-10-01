# Step 4 — Backend slash-command parsing + synthetic `load_skill` injection

Part of [v0.2.6-spec](../v0.2.6-spec.md). Depends on
[Step 1](step-1-frontmatter-field.md).

## Description

When a user submits a message starting with `/skill-name` (optionally
followed by extra text), the backend:

1. Parses the skill name (and optional extra instructions) from the
   leading `/...` token.
2. Reads the named skill's `SKILL.md` from `ResourceStore` — including
   disabled-invocation skills, which are filtered out of the agent's
   autonomous pool in [Step 2](step-2-pool-filtering.md) but must remain
   user-loadable by name.
3. Injects a **synthetic `load_skill` tool-call + tool-result** into the
   session conversation *before* the user's actual message:
   - an assistant message carrying a `tool_calls` entry
     (`load_skill`, `{"name": "skill-name"}`)
   - a `tool`-role message whose content is the skill's `SKILL.md`
     content (prefixed with `"Skill directory: <path>\n\n"` to match the
     real `load_skill` tool's return format at `skill.ex:236-239`).
4. Passes the user's text (the extra instructions, or the full original
   message if no extra was given) as the normal user message for the
   agent to process.

The user chose "tool-call simulation" as the injection style (see
[v0.2.6-spec.md](../v0.2.6-spec.md) plan). This makes the loaded skill
appear in the conversation exactly as if the model had invoked `load_skill`
itself, so the model treats the content the same way it already treats
self-loaded skills — no new instruction format, no special-casing in the
system prompt.

### Trigger rule

Per the user's decision: `/skill-name` triggers **only at the start of the
message**. The parser matches `^/([a-z0-9_-]+)(\s+(.*))?$` (case-insensitive
on the name). If the name doesn't match a known skill in `ResourceStore`,
the message is passed through verbatim as a normal user message (no error
— the user might genuinely be typing a literal `/path` or unknown command;
the dropdown in Steps 6-7 is the discovery mechanism, not a hard validation).

### Where the parsing happens

Two candidate locations, to be resolved during TDD pre-work:

- **`session_live.ex` `do_prompt_submit/2`** (line 447) — parses in the
  LiveView layer, threads an opt into `Headless.prompt/3`.
- **`Headless.prompt/3`** (line 169) — parses in the headless layer,
  threads an opt into `Agent.prompt/3`.

Either is acceptable; the headless-layer option keeps the UI dumb and
makes the same feature available to the HTTP API path
(`session_controller.ex:144`) for free. **Preferred: parse in
`Headless.prompt/3`** so both UI and external callers get slash-command
support. The UI layer still needs Step 6-7 for the dropdown, but the
*execution* of a typed slash command shouldn't be UI-only.

### Injection mechanism (the open question)

[v0.2.6-spec.md](../v0.2.6-spec.md) Open Question 1 flags that
`Planck.Agent.Session` may not expose a clean API for inserting synthetic
tool-call/tool-result message pairs. TDD pre-work must investigate
`Session`'s insertion API:

- If `Session` supports inserting arbitrary message entries (assistant
  with `tool_calls`, `tool`-role result), use it directly. This is the
  clean path and matches the chosen design.
- If no such API exists, **fall back** to injecting the skill content as a
  system-role message preamble before the user's text, with a note like
  `"[User loaded skill 'skill-name' via slash command. Skill content: ...]"`
  + the extra instructions in the user message. This diverges from the
  chosen "tool-call simulation" approach and **must be called out in this
  file's Definition of Done** if it happens, with a note that the
  tool-call simulation remains a future improvement.

### TDD order

1. Investigate `Planck.Agent.Session`'s API for inserting synthetic
   messages. Decide injection mechanism.
2. Write `agent_test.exs` (or `session_test.exs`) cases asserting a
   prompt with a leading `/skill-name` produces a conversation containing
   a `load_skill` tool-call + tool-result + the user's text.
3. Run — they fail.
4. Implement parsing in `Headless.prompt/3` + injection in `Agent.prompt/3`.
5. Run — tests pass.
6. Add the headless-layer test asserting the HTTP API path also resolves
   slash commands (since parsing moved to headless, both paths get it).

## Definition of Done

- [ ] `Headless.prompt/3` parses a leading `/skill-name` (with optional
      trailing extra text) from the prompt.
- [ ] The named skill is read from `ResourceStore.get().skills` (the full,
      unfiltered store — disabled-invocation skills are reachable this way
      even though they're filtered out of the agent's autonomous pool).
- [ ] A synthetic `load_skill` tool-call (assistant message with
      `tool_calls`) + tool-result (`tool`-role message with the skill
      content, prefixed with `"Skill directory: <path>\n\n"`) is inserted
      into the session conversation before the user's message — *or*, if
      the Session API doesn't support it, a documented system-message
      preamble fallback is used and noted here.
- [ ] The user's text (extra instructions if present, else the full
      original message) is passed as the normal user message after the
      injection.
- [ ] A `/skill-name` where `skill-name` is not in `ResourceStore` is
      passed through verbatim as a normal user message (no error, no
      injection).
- [ ] A message not starting with `/` is unaffected — passed through
      verbatim.
- [ ] The `on_skill_use` callback (wired in `headless.ex:908-910` to
      `SkillUsage.record_use/5`) fires for the synthetic load, so
      slash-command usage is tracked in `.planck/skills.db` the same way
      autonomous `load_skill` usage is.
- [ ] Both the LiveView prompt path and the HTTP API prompt path
      (`session_controller.ex:144`) resolve slash commands (because
      parsing lives in `Headless.prompt/3`).
- [ ] `mix test` in `planck_agent` and `planck_headless` passes.
- [ ] `./check planck_agent` and `./check planck_headless` pass.

## Use Cases

```gherkin
Feature: Slash commands load skills via synthetic tool-call simulation

  Background:
    Given ResourceStore is loaded with skill "grill-me" whose SKILL.md
      contains grilling instructions
    And "grill-me" has disable_model_invocation: true
    # disabled for autonomous invocation, but user-loadable by name

  Scenario: Slash command with extra instructions
    When the user submits the message "/grill-me give me five questions"
    Then the session conversation contains, in order:
      | role      | content                                          |
      | assistant | tool_calls: [load_skill {"name": "grill-me"}]   |
      | tool      | "Skill directory: <path>\n\n<SKILL.md content>" |
      | user      | "give me five questions"                        |
    And the agent processes the user message with the skill content in context

  Scenario: Slash command with no extra instructions
    When the user submits the message "/grill-me"
    Then the session conversation contains the synthetic tool-call + result
    And the user message is empty or a minimal placeholder

  Scenario: Unknown slash command passes through
    When the user submits the message "/not-a-skill hello there"
    Then no synthetic tool-call is injected
    And the user message is "/not-a-skill hello there" verbatim

  Scenario: Non-slash message is unaffected
    When the user submits the message "hello there"
    Then no synthetic tool-call is injected
    And the user message is "hello there"

  Scenario: Disabled-invocation skill is loadable via slash command
    Given "grill-me" has disable_model_invocation: true
    When the user submits "/grill-me"
    Then the synthetic load_skill succeeds (the skill is read from the full
      ResourceStore, not the agent's filtered pool)
    And the agent receives the skill content

  Scenario: Slash-command usage is recorded in SkillUsage
    When the user submits "/grill-me"
    Then SkillUsage.record_use/5 is called for "grill-me"
    And a row exists in .planck/skills.db for this session/agent/skill

  Scenario: HTTP API path also resolves slash commands
    Given an external script POSTs to /api/sessions/:id/prompt with body
      "/grill-me via CI"
    Then the synthetic tool-call + result are injected
    And the agent receives "via CI" as the user message
```

## Test Cases

In `planck_agent/test/planck/agent/agent_test.exs` (or a new
`slash_command_test.exs`):

- `describe "slash command parsing"`:
  - `/skill-name extra text` → tool-call + result + "extra text"
  - `/skill-name` (no extra) → tool-call + result + empty/placeholder user
    message
  - `/Unknown` → no injection, message passed verbatim
  - `normal message` → no injection, message passed verbatim
  - disabled-invocation skill is loadable by name (reads from full store)
  - `on_skill_use` fires for the synthetic load
- `describe "slash command injection format"`:
  - the tool-result content is prefixed with
    `"Skill directory: <path>\n\n"` matching the real `load_skill` return
  - the assistant message's `tool_calls` entry has `name: "load_skill"`
    and `arguments: %{"name" => "skill-name"}`

In `planck_headless/test/planck/headless_test.exs`:

- `describe "Headless.prompt/3 slash command"`:
  - resolves `/skill-name` against `ResourceStore.get().skills`
  - threads the injection opt into `Agent.prompt/3`
  - passes non-slash messages through unchanged

In `planck_cli/test/.../session_controller_test.exs` (if HTTP API tests
exist there):

- `describe "POST /api/sessions/:id/prompt with slash command"`:
  - the HTTP path resolves the slash command (because parsing is in
    `Headless.prompt/3`, not the LiveView)

## Open question (must resolve during TDD pre-work)

**Session insertion API.** Before writing tests, read
`planck_agent/lib/planck/agent/session.ex` and find (or determine the
absence of) an API for inserting arbitrary message entries (assistant +
tool pair). If absent, document the system-message-preamble fallback in
this file's Definition of Done and proceed with that. The fallback is
acceptable for v0.2.6; tool-call simulation can be revisited when
`Session` grows the API.

## Files touched

| File | Change |
|---|---|
| `planck_headless/lib/planck/headless.ex` | parse `/skill-name [extra]` in `prompt/3`, read skill from `ResourceStore`, thread injection opt |
| `planck_agent/lib/planck/agent.ex` | handle the injection opt in `prompt/3`, insert synthetic tool-call + result via `Session` (or preamble fallback) |
| `planck_agent/lib/planck/agent/session.ex` | (possibly) add insertion API if missing |
| `planck_headless/test/planck/headless_test.exs` | slash-command parsing tests |
| `planck_agent/test/planck/agent/agent_test.exs` | injection + pass-through tests |