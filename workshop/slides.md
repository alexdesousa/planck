---
marp: true
theme: default
paginate: true
html: true
style: |
  @import url('https://fonts.googleapis.com/css2?family=Press+Start+2P&family=Space+Mono:ital,wght@0,400;0,700;1,400&display=swap');

  :root {
    --bg: #f5f5f5;
    --fg: #1a1a1a;
    --card: #ffffff;
    --primary: #5F4FE6;
    --accent: #FED13B;
    --border: #1a1a1a;
    --shadow: #1a1a1a;
    --muted: #CFCCEA;
    --muted-fg: #5B5686;
  }

  section {
    background: var(--bg);
    color: var(--fg);
    font-family: 'Space Mono', monospace;
    font-size: 1.05rem;
    padding: 2.5rem 3rem;
    line-height: 1.8;
  }

  /* Pagination */
  section::after {
    font-family: 'Space Mono', monospace;
    font-size: 0.7rem;
    color: var(--muted-fg);
  }

  /* ── Headings ── */
  h1 {
    font-family: 'Press Start 2P', monospace;
    font-size: 1.35rem;
    line-height: 1.6;
    color: var(--fg);
    margin-bottom: 1.5rem;
    letter-spacing: -0.02em;
  }

  h2 {
    font-family: 'Press Start 2P', monospace;
    font-size: 0.9rem;
    color: var(--primary);
    margin-bottom: 1rem;
    line-height: 1.6;
  }

  h3 {
    font-family: 'Space Mono', monospace;
    font-weight: 700;
    font-size: 1rem;
    color: var(--fg);
    margin-bottom: 0.5rem;
    border-bottom: 2px solid var(--border);
    padding-bottom: 0.25rem;
  }

  /* ── Lists ── */
  ul, ol {
    padding-left: 1.5rem;
    line-height: 2;
  }

  li::marker {
    color: var(--primary);
    font-weight: 700;
  }

  /* ── Blockquote ── */
  blockquote {
    background: var(--card);
    border: 2px solid var(--border);
    box-shadow: 4px 4px 0 var(--shadow);
    padding: 1rem 1.5rem;
    margin: 1.5rem 0;
    font-style: italic;
    color: var(--fg);
    border-radius: 0;
  }

  blockquote p {
    margin: 0;
  }

  /* ── Code ── */
  code {
    background: var(--muted);
    color: var(--primary);
    font-family: 'Space Mono', monospace;
    font-size: 0.85em;
    padding: 0.1em 0.4em;
    border: 1px solid var(--border);
    border-radius: 0;
  }

  pre {
    background: var(--card);
    border: 2px solid var(--border);
    box-shadow: 4px 4px 0 var(--shadow);
    padding: 1rem 1.5rem;
    border-radius: 0;
    font-size: 0.8rem;
    line-height: 1.6;
  }

  pre code {
    background: none;
    border: none;
    padding: 0;
    color: var(--fg);
    font-size: 1em;
  }

  /* ── Prompt box ── */
  .prompt-box {
    border: 2px solid var(--border);
    box-shadow: 4px 4px 0 var(--shadow);
    font-family: 'Space Mono', monospace;
    font-size: 0.8rem;
    overflow: hidden;
    margin: 0.5rem 0;
  }
  .prompt-box strong { background: none; padding: 0; }
  .hl-line {
    display: block;
    padding: 0.5rem 0.75rem;
    border-left: 4px solid;
    margin-bottom: 1px;
    line-height: 1.6;
  }
  .hl-line.r { background: rgba(95,79,230,0.1); border-color: #5F4FE6; }
  .hl-line.b { background: rgba(254,209,59,0.3); border-color: #c9a400; }
  .hl-line.i { background: rgba(207,204,234,0.5); border-color: #5B5686; }
  .hl-line.e { background: rgba(170,252,61,0.2); border-color: #4a8a00; }
  .tag {
    display: inline-block;
    font-weight: 700;
    font-size: 0.7rem;
    padding: 0.05em 0.35em;
    margin-right: 0.5rem;
    vertical-align: middle;
  }
  .tag.r { background: #5F4FE6; color: white; }
  .tag.b { background: #FED13B; color: #1a1a1a; }
  .tag.i { background: #CFCCEA; color: #1a1a1a; }
  .tag.e { background: #AAFC3D; color: #1a1a1a; }

  /* ── Grid tables ── */
  .tbl {
    display: grid;
    width: 100%;
    border: 2px solid var(--border);
    box-shadow: 4px 4px 0 var(--shadow);
    font-size: 0.9rem;
    margin: 1rem 0;
    font-family: 'Space Mono', monospace;
  }
  .tbl-3col { grid-template-columns: 10fr 22fr 68fr; }
  .tbl-3col-b { grid-template-columns: 20fr 40fr 40fr; }
  .tbl-2col { grid-template-columns: 25fr 75fr; }
  .tbl-2col-30 { grid-template-columns: 30fr 70fr; }
  .tbl > div {
    padding: 0.5rem 0.85rem;
    border-right: 1px solid var(--border);
    border-bottom: 1px solid var(--border);
    line-height: 1.4;
  }
  .tbl-3col > div:nth-child(3n),
  .tbl-3col-b > div:nth-child(3n) { border-right: none; }
  .tbl-2col > div:nth-child(2n),
  .tbl-2col-30 > div:nth-child(2n) { border-right: none; }
  .tbl-3col > div:nth-last-child(-n+3),
  .tbl-3col-b > div:nth-last-child(-n+3) { border-bottom: none; }
  .tbl-2col > div:nth-last-child(-n+2),
  .tbl-2col-30 > div:nth-last-child(-n+2) { border-bottom: none; }
  .th {
    background: var(--primary);
    color: white;
    font-weight: 700;
  }
  .alt { background: var(--muted); }

  /* ── Columns helper ── */
  .columns {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 2rem;
    align-items: start;
  }

  /* ── Lead slides ── */
  section.lead {
    background: var(--accent);
    display: flex;
    flex-direction: column;
    justify-content: center;
  }

  section.lead h1 {
    font-size: 1.5rem;
    color: var(--fg);
    margin-bottom: 0.75rem;
  }

  section.lead h2 {
    font-size: 0.8rem;
    color: var(--fg);
    opacity: 0.7;
  }

  section.lead p {
    font-size: 0.95rem;
    color: var(--fg);
    opacity: 0.75;
    margin: 0.25rem 0 0;
  }

  section.lead::after {
    color: var(--fg);
    opacity: 0.5;
  }

  /* ── Title slide ── */
  section.title {
    background: var(--fg);
    color: var(--bg);
    display: flex;
    flex-direction: column;
    justify-content: center;
  }

  section.title h1 {
    font-size: 1.4rem;
    color: var(--accent);
    margin-bottom: 0.5rem;
  }

  section.title p {
    font-family: 'Space Mono', monospace;
    color: var(--muted);
    margin: 0;
    font-size: 0.9rem;
  }

  section.title::after {
    display: none;
  }

  /* ── Accent card ── */
  .card {
    background: var(--card);
    border: 2px solid var(--border);
    box-shadow: 4px 4px 0 var(--shadow);
    padding: 1rem 1.5rem;
    margin: 0.75rem 0;
  }

  /* ── Highlight tag ── */
  strong {
    background: var(--accent);
    padding: 0 0.2em;
    font-weight: 700;
  }
---

<!-- _class: title -->

# Think strategically. Delegate everything else.

How to turn your workflows into a team of specialists

---

# What we're doing today

By the end of this workshop you will:

- Know how to **brief a specialist** so it does exactly what you need
- Identify which parts of your work **only you can do** — and which to hand off
- Design a **team of specialists** around your actual workflow
- Walk away with a structure you can start using today, with any tool

> This is not about a specific product. Everything here works with Claude Code, Codex, OpenCode, Hermes, or whichever tool you prefer.

---

<!-- _class: lead -->

# How we got here
## The evolution of working with AI

---

# LEVEL 1: It started with chat

2022\. ChatGPT launches.

You type a question. You get an answer. It feels like magic.

Most people are amazed — and stop right there.

> The model becomes a smarter search engine. Ask something. Get something back. Move on.

That's Level 1. Useful. But nowhere near the ceiling.

---

# LEVEL 2: Then came "prompting"

People started realizing that **how** you asked mattered.

And so began the era of prompt engineering:
- Prompt libraries and marketplaces
- "Magic phrases" shared like recipes
- Courses on how to talk to AI
- Prompts traded like spells: *"use these exact words and it will do X"*

The model was treated like a vending machine with a secret code.

Some people got remarkable results. Everyone else wondered what they were doing wrong.

---

# LEVEL 3: The truth about prompts

Here's what the "prompt engineers" actually figured out:

> There is no magic. Prompts that work are just **good briefs**.

Clear task. Relevant context. Specific role. Defined boundaries.

The people getting great results weren't casting spells — they were communicating precisely. The same way you'd brief a skilled colleague before handing off important work.

**Prompting is communication. Precise communication.**

---

# LEVEL 4: The next step

Once you understand that — the obvious question follows:

> Why do this manually, for every task, every time?

You don't have to.

Instead of prompting on the fly, you **describe your team once** — what each specialist does, what they need, what they're responsible for. Then you focus on the work only you can do.

That's what this workshop is about.

---

<!-- _class: lead -->

# Part 1
## Why your brief matters

---

# Your specialist only knows what you tell them

A model doesn't look up answers. It generates them — based entirely on what you've given it to work with.

There's no memory between conversations. No background knowledge about your project. No assumptions about your preferences.

> Every time you open a conversation, you're meeting a brilliant specialist for the first time. What you put in front of them determines everything that comes out.

This is why **briefing well** is the most important skill.

---

# The contractor analogy

Imagine hiring a brilliant freelance contractor.

- They are **extremely skilled** across many domains
- They show up to every meeting having read **nothing** from before
- Everything they know about your project comes from **what you tell them in the room**
- When the meeting ends, they forget everything

This is your specialist.

**The meeting is the brief.**

---

# What goes into a brief?

Think of it as **a meeting room with two things in it**.

<div class="columns">
<div>

### The whiteboard
What you bring to the meeting — documents, references, history, instructions. Whatever is on it, the specialist can use. Whatever isn't — doesn't exist.

</div>
<div>

### The job description
Who they are in this room — their role, their style, their boundaries. A writer doesn't plan. An editor doesn't rewrite. This keeps specialists from stepping on each other.

</div>
</div>

**Both together make a complete brief.**

---

# Google has a name for this: TCREI

<div class="tbl tbl-3col">
  <div class="th">Letter</div><div class="th">Stands for</div><div class="th">Maps to</div>
  <div><strong>T</strong></div><div>Task</div><div>Job description — role, output, boundaries</div>
  <div class="alt"><strong>C</strong></div><div class="alt">Context</div><div class="alt">Whiteboard — what they need to know</div>
  <div><strong>R</strong></div><div>References</div><div>Whiteboard — examples, style guides, prior work</div>
  <div class="alt"><strong>E</strong></div><div class="alt">Evaluate</div><div class="alt">How you'll judge if the output is good</div>
  <div><strong>I</strong></div><div>Iterate</div><div>Expect to refine — first output is rarely final</div>
</div>

> A "prompt" is just a brief structured around these five things. No magic, no spells — just clear communication.

---

# We call it BRIEF

Same five elements — a name that remembers itself.

<div class="tbl tbl-2col">
  <div class="th">Letter</div><div class="th">Means</div>
  <div><strong>B</strong></div><div>Brief — what you want done and what good looks like</div>
  <div class="alt"><strong>R</strong></div><div class="alt">Role — who the specialist is in this context</div>
  <div><strong>I</strong></div><div>Information — the context they need to do the job</div>
  <div class="alt"><strong>E</strong></div><div class="alt">Examples — references, style guides, prior work</div>
  <div><strong>F</strong></div><div>Feedback — evaluate the output and refine</div>
</div>

> Google calls it TCREI. We call it what it is: a **BRIEF**.

---

# What a BRIEF looks like in practice

<div class="columns">
<div>

<div class="prompt-box">
  <div class="hl-line r"><span class="tag r">R</span>You are an editor.</div>
  <div class="hl-line b"><span class="tag b">B</span>Your job: review drafts for clarity and tone. Flag problems. Do not rewrite unless asked.</div>
  <div class="hl-line i"><span class="tag i">I</span>The reader is non-technical. Prefer plain language over jargon.</div>
  <div class="hl-line e"><span class="tag e">E</span>Good: "The system failed." — Not: "The system experienced an unexpected termination event."</div>
</div>

</div>
<div>

<span class="tag r">R</span> Role
<span class="tag b">B</span> Brief
<span class="tag i">I</span> Information
<span class="tag e">E</span> Examples

This is the system prompt — loaded before the conversation starts. Always pinned.

### First message (F)

> "Here's the draft.
> Please review it."

</div>
</div>

---

# The whiteboard has limited space

Every specialist has a limit on how much they can hold in mind at once.

When you hit that limit, older content falls off — like erasing the top of the whiteboard to make room at the bottom.

Early tools had a limit roughly the length of *The Hobbit*.
Today's models hold entire libraries.

**The principle doesn't change.**

---

# What falls off — and what doesn't

Not everything degrades equally.

- **Before the conversation** — your brief (role, task, information, examples) — is always pinned. The specialist always knows who they are and what they're doing.
- **During the conversation** — the back-and-forth, the feedback, the decisions made three hours ago — is what falls off.

The F in BRIEF (Feedback) happens in the conversation. Everything else belongs in the brief — written once, always there.

> Put the important things in the brief, not the chat. **What you include matters as much as what you ask.**

---

# How big is the whiteboard?

Today's frontier models have enormous whiteboards — but they're not infinite.

<div class="tbl tbl-3col-b">
  <div class="th">Model</div><div class="th">Context</div><div class="th">That's roughly...</div>
  <div>Claude Sonnet 4.6</div><div>200k → 1M tokens</div><div>Project Hail Mary → all 7 Harry Potter books</div>
  <div class="alt">Claude Opus 4.7</div><div class="alt">200k → 1M tokens</div><div class="alt">Project Hail Mary → all 7 Harry Potter books</div>
  <div>GPT-5.5</div><div>1M tokens</div><div>All 7 Harry Potter books</div>
  <div class="alt">Gemini 2.5 Pro</div><div class="alt">1M → 2M tokens</div><div class="alt">All 7 Harry Potter books — read twice</div>
</div>

> A bigger whiteboard still needs a clear brief. More context doesn't replace focus — it just means more room to get unfocused.

---

# A crowded whiteboard isn't a good whiteboard

Same size. Completely different quality.

<div class="columns">
<div>

**Focused context:**
> "After all this time? Always."
> — Snape, *Harry Potter and the Deathly Hallows*

</div>
<div>

**Noisy context:**
> "May the Force be with you, Harry!"
> — Gandalf, *Star Wars: A New Hope* (1977, probably)

</div>
</div>

The specialist can only work with what's on the whiteboard. Fill it with noise — from three different universes — and the output will match.

---

# The insight

Your specialist isn't limited by intelligence.

They're limited by **what's on the whiteboard**.

That's what BRIEF is for. Now let's talk about teams.

---

<!-- _class: lead -->

# Part 2
## From one specialist to a team

---

# What is an agent?

Every agent has two parts:

<div class="columns">
<div>

### The mind
The language model — it reads the brief, reasons through the task, and generates a response. This is where intelligence lives.

It doesn't act on its own. It only thinks.

</div>
<div>

### The body
The harness — it gives the mind its tools, loads the right brief, routes work to the right specialist, and acts in the world on its behalf.

It doesn't think on its own. It only acts.

</div>
</div>

Together: a **specialist that can think and act**. That's an agent.

The mind knows. The body does. The brief tells both what they're here for.

---

# What makes a specialist a specialist?

Not the model. The brief.

> "You are an editor. Your job is to review drafts for clarity and tone. You flag problems. You do not rewrite unless asked."

Load a different brief into the same mind and you have a completely different specialist — a writer, a researcher, a strategist.

**The model doesn't change. The brief does.**

---

# Why teams?

A single specialist trying to do everything at once produces mediocre results.

It's the same reason you wouldn't ask one person to simultaneously:
- Plan a project
- Write the deliverable
- Review their own work

Roles create **focus**. Focus creates quality.

When you split work across specialized agents, each one operates at full capacity on a narrow task — and the results compound.

---

# A team in practice: writing

<div class="columns">
<div>

### Planner
Reads your brief. Produces an outline and key arguments. Doesn't write prose.

### Writer
Takes the outline. Writes a full draft. Doesn't plan, doesn't edit.

### Editor
Reads the draft. Flags clarity, structure, tone. Returns notes or a revised version.

</div>
<div>

```
You → Planner
       ↓
     outline
       ↓
     Writer
       ↓
      draft
       ↓
     Editor
       ↓
  final → You
```

</div>
</div>

---

# A team in practice: research

### Scout
Searches for sources, summarizes what exists on a topic

### Analyst
Reads the summaries, identifies patterns, contradictions, gaps

### Synthesizer
Writes a coherent narrative from the analyst's findings

### Fact-checker
Challenges claims, flags unsupported assertions

Each specialist sees only what they need. The tool routes the work.

---

# Teams are not fixed

You compose a team around the job.

<div class="tbl tbl-2col">
  <div class="th">Job</div><div class="th">Team</div>
  <div>Writing</div><div>Planner → Writer → Editor</div>
  <div class="alt">Research</div><div class="alt">Scout → Analyst → Synthesizer</div>
  <div>Software</div><div>Planner → Developer → Reviewer</div>
  <div class="alt">Strategy</div><div class="alt">Researcher → Strategist → Devil's Advocate</div>
  <div>Content</div><div>Briefer → Creator → Distributor</div>
</div>

The pattern is always the same: **diverge → produce → converge**.

---

<!-- _class: lead -->

# Part 3
## Organizing your workspace

---

# Your workspace is your office

Think of your workspace as an office building.

Each project or area of work has its own room:

- A writing room — with your drafts, notes, and style guides
- A research room — with your sources, findings, and summaries
- A client room — with briefs, deliverables, and history

When you organize your work this way, **specialists always know which room to walk into**.

---

# The directory: your receptionist

At the entrance of your workspace sits a single index file.

This file is **maintained by a specialist**. It's the routing layer:

> "When you ask about the novel → go to the writing room"
> "When you ask about competitors → go to the research room"

When you start a new conversation, the specialist reads the index first — like a receptionist who knows where every office is and what each team does.

**You don't manage this manually. A specialist keeps it current.**

---

# Job descriptions for each room

Each room holds two things: the work itself, and a description of **how specialists should work in that room**.

<div class="columns">
<div>

**Writing room**
- Your drafts and notes
- Writer brief: voice, pace, format
- Editor brief: what to flag, what to leave alone

</div>
<div>

**Research room**
- Your sources and findings
- Scout brief: where to search, what to summarize
- Analyst brief: what patterns to look for

</div>
</div>

The specialist picks up the right brief automatically when they enter the room.

---

# What this looks like in practice

<div class="tbl tbl-3col-b">
  <div class="th">Room</div><div class="th">Work inside</div><div class="th">Specialists</div>
  <div>Writing</div><div>Drafts, notes, style guide</div><div>Planner, Writer, Editor</div>
  <div class="alt">Research</div><div class="alt">Sources, summaries, findings</div><div class="alt">Scout, Analyst, Synthesizer</div>
  <div>Client work</div><div>Briefs, deliverables, feedback</div><div>Briefer, Deliverer, Reviewer</div>
</div>

One workspace. Multiple rooms. Each with its own team.

The index at the entrance routes every conversation to the right room — automatically.

---

<!-- _class: lead -->

# Part 4
## Designing your first team

---

# Start with the job, not the tools

Before opening any tool, ask:

1. **What is the output?** (a document, a decision, a piece of code)
2. **What are the stages?** (research, draft, review, publish)
3. **What does each stage need to know?** (sources, style guide, constraints)
4. **Where does that information live?** (a room, a file, a reference)

Once you can answer these, you can describe your team.

---

# Writing your first specialist brief

A brief doesn't have to be long. It needs to be **specific**.

<div class="tbl tbl-2col">
  <div class="th">Field</div><div class="th">Example</div>
  <div><strong>Name</strong></div><div>Writer</div>
  <div class="alt"><strong>Job</strong></div><div class="alt">Turn outlines into first drafts</div>
  <div><strong>Style</strong></div><div>Conversational, direct, no jargon</div>
  <div class="alt"><strong>Avoid</strong></div><div class="alt">Bullet points, passive voice</div>
  <div><strong>Output</strong></div><div>Plain text, one section at a time</div>
  <div class="alt"><strong>Boundary</strong></div><div class="alt">Does not plan. Does not edit. Writes.</div>
</div>

> The boundary line matters most. It's what keeps specialists from stepping on each other.

---

# Choosing your tool

Any of these will support this pattern:

<div class="tbl tbl-2col-30">
  <div class="th">Tool</div><div class="th">Good for</div>
  <div><strong>Claude Code</strong></div><div>Terminal-native, strong file access</div>
  <div class="alt"><strong>Codex</strong></div><div class="alt">GitHub-integrated workflows</div>
  <div><strong>OpenCode</strong></div><div>Open source, self-hostable</div>
  <div class="alt"><strong>Hermes</strong></div><div class="alt">Multi-model routing</div>
</div>

The structure you learned today works with all of them.
Pick the one that fits your environment — not the one with the most hype.

---

# What to do after today

**This week:**
- Pick one repeatable task you do regularly
- Map out its stages (2–4 is enough)
- Create a room for it in your workspace
- Write one brief for the stage that costs you the most time

**Then:**
- Add more rooms as your work grows
- Let a specialist maintain the index
- Grow the team as the work demands

---

<!-- _class: title -->

# The core idea

You don't configure specialists.

You organize your work.

The structure does the routing.

---

<!-- _class: lead -->

# Questions?

---
