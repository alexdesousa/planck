# Planck Commands

A command is a reusable slash prompt stored on the filesystem. Typing
`/<name> [args]` in the prompt input renders the command's EEx template with
the trailing arguments and enqueues the result as a user message — the agent
then responds to it like any other prompt.

Commands are useful for boilerplate prompts you invoke repeatedly: review
checklists, refactoring playbooks, test-generation instructions, or any
multi-line prompt you don't want to retype.

## File layout

```
.planck/commands/<name>/
  COMMAND.md
  resources/          (optional — files the agent may reference)
    checklist.md
```

Each command lives in its own subdirectory containing a `COMMAND.md` file.
Directories without `COMMAND.md` are silently skipped.

## COMMAND.md format

```markdown
---
name: review-checklist
description: Runs the project's review checklist against recent changes.
disable-model-invocation: true
help: "/review-checklist [scope]"
---

# Review Checklist

You are reviewing: <%= Enum.join(args, " ") %>

- Check for correctness first — does it do what it claims?
- Flag style issues only if they impact readability
- Suggest performance improvements only when material
```

Frontmatter fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | ✅ | — | Identifier used in `/name` dispatch and the UI dropdown |
| `description` | ✅ | — | One-line summary shown in the dropdown |
| `disable-model-invocation` | | `true` | Excludes the command from the agent's autonomous `run_command` pool. No effect in the user slash path |
| `help` | | `nil` | Usage string shown as the dropdown row subtitle |

Everything after the closing `---` is an EEx template stored raw and rendered
on demand when the command is invoked.

## Template rendering

The body is an EEx template. The binding `args` holds the user's trailing
text — a **list of strings**, or `[]` when no trailing text was given:

| Input | `args` value |
|---|---|
| `/review-checklist` | `[]` |
| `/review-checklist src/auth` | `["src/auth"]` |
| `/review-checklist src/auth lib/` | `["src/auth", "lib/"]` |

To interpolate args as a readable string, join them:

```elixir
You are reviewing: <%= Enum.join(args, " ") %>
```

Bare `<%= args %>` renders the Elixir term (`["src/auth"]`), which is usually
not what you want for display. Guard against the empty case when the
argument is optional:

```elixir
<%= if Enum.any?(args), do: "Focus on #{Enum.join(args, ", ")}." %>
```

The rendered body is what the agent sees — it is persisted as a
`{:custom, :command}` message with `invoked_by: :user` and shown as a
command card in the chat.

## Dispatch precedence

`/<name>` is resolved in three tiers (first match wins):

1. **Built-in primitives** — `/clear` and `/compact` are intercepted before
   custom commands. A command named `clear` or `compact` can never be invoked
   via the slash path; the built-in always shadows it.
2. **Custom commands** — matched by `name` against `ResourceStore.commands`.
3. **Skills** — matched by `name` against `ResourceStore.skills`, triggering
   the `load_skill` tool.

An unknown `/<name>` that matches no tier is passed through verbatim as a
regular user message.

## Global vs project commands

- `~/.planck/commands/` — available across all projects
- `.planck/commands/` — project-local; overrides global on name collision

Command names are resolved from the configured `commands_dirs`
(default: `.planck/commands` and `~/.planck/commands`).

## Dynamic loading — live updates without restart

When you edit a `COMMAND.md` file on disk, the running `Watcher` GenServer
detects the change (300 ms debounce) and calls `ResourceStore.reload/0`.
Edited command templates are available immediately on the next
`/<name>` invocation — no restart needed.

## Example use cases

- **Review checklists** — structured review criteria for a reviewer agent
- **Refactoring playbooks** — step-by-step instructions for a specific refactor
- **Test generation** — prompt scaffolding for generating test suites
- **Onboarding prompts** — project context and conventions for new sessions

For skill configuration (separate from commands), see:
https://raw.githubusercontent.com/alexdesousa/planck/main/skills/planck_setup/references/skills.md
