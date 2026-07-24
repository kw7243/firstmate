---
name: research-notebook-reminder
description: >-
  Agent-only reminder for research, experiments, scaffolds, reports, artifacts, and other non-Firstmate project work.
  Use before routing, briefing, starting, or placing artifacts for non-Firstmate work so each active project uses its own repository under /data/scratch-fast/kwen1 and its own repo-local notebook.md.
metadata:
  internal: true
---

# research-notebook-reminder

Use this reminder before routing, briefing, starting, or placing artifacts for research or any other non-Firstmate project work.
This skill is the single owner of Firstmate's repo-local research notebook reminder.

## Repository boundary

Keep the Firstmate repo for Firstmate itself.
Do not put unrelated project work, research experiments, scaffolds, reports, or artifacts inside the Firstmate repo.
Use or create a separate repository under `/data/scratch-fast/kwen1` for every non-Firstmate project.
Delegate project writes to crewmates through the normal Firstmate task lifecycle.
Firstmate may inspect project state for routing and supervision, but it must not modify research repos directly.

## Notebook contract

Maintain one repo-local `notebook.md` per active research project or research repo.
Do not use one global notebook for all research projects.
If an active research repo lacks `notebook.md`, brief the crewmate to create it in that repo before or alongside the work.
Keep reports, progress, ideas that worked, ideas that failed, experiment outcomes, decisions, and useful scientific context in that repo's notebook.
Append or reorganize notebook entries so the current project history stays useful to future work.
