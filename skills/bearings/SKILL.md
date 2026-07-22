---
name: bearings
description: Generate a concise "where did I leave off" status report for the current conversation and workspace, using explicit user instructions, existing local project conventions, and observable local state. Use when the user invokes bearings or $bearings, asks for a status report, catch-up, morning brief, "where did I leave off", or "what's in the works".
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no private firstmate paths, tools, task vocabulary, or environment branching. -->

# bearings

Generate a compact current-status report so the user can resume work quickly after a break, context reset, or handoff.
This public skill is deliberately generic: it does not assume a firstmate home, fleet state, task ids, or firstmate helper scripts.
If this skill is installed in Codex, invoke it as `$bearings`; native `/bearings` is not a repo-provided Codex slash command.

## What it does

1. **Gather the current state from the conversation and local workspace.**
   Read the current chat context, recent explicit user decisions, visible open work, and any local files the user or repository convention already makes relevant.
   Prefer existing local status sources such as `README.md`, `AGENTS.md`, `CLAUDE.md`, `TODO`, `BACKLOG`, `NOTES`, issue templates, or project-specific status files when they are present and readable.
   Do not invent a remote tracker scan or external-system lookup from a git remote alone.
   Use external systems only when the user explicitly asks for them or a local instruction already requires them.

2. **Separate the report into four fixed buckets.**
   Render each bucket even when it is empty.
   Keep items mutually exclusive, so each fact appears in exactly one place:
   - **Needs You** - decisions, credentials, approvals, missing requirements, or blockers only the user can clear.
   - **Recently Done** - work completed in this conversation or in a local status source that clearly says it is complete.
   - **Underway** - active work, pending local changes, tests or reviews still in progress, and work the agent can continue without the user's action.
   - **Next** - queued or not-yet-started work, including items blocked on another task rather than on the user.

3. **Write a local report only when it adds value or the user asked for one.**
   If the report is more than a short chat digest, or the user asked for a durable brief, write it to `.bearings.md` in the current directory.
   Before writing in a git worktree, check whether `.bearings.md` is tracked.
   If it is tracked, update it only when that appears to be the project's established convention; otherwise ask before writing.
   If it is untracked or absent, write the report there and add `.bearings.md` to a current-directory `.gitignore` when practical so the private pickup note does not accidentally enter version control.
   Never stage, commit, push, merge, delete branches, or mutate external systems as part of bearings.

4. **Respond with a concise pickup summary.**
   Start with the four fixed buckets in order: Needs You, Recently Done, Underway, Next.
   Each section should be short enough to scan, with one line per material item.
   If a section has nothing to report, say so plainly.
   If a `.bearings.md` file was written, mention it and keep the chat digest shorter than the file.
   If a needed source could not be read or a status is uncertain, state the uncertainty rather than guessing.

## What this skill does not do

It does not replace a project manager, issue tracker, or firstmate fleet report.
It does not treat a git remote, package metadata, or repository name as permission to query or write an external system.
It does not store credentials, secrets, private tokens, or sensitive personal data in the report.
It does not make project changes beyond the optional local `.bearings.md` pickup note and its optional current-directory `.gitignore` protection.
