---
description: Update project documentation after a development session
---

Update all project documentation to reflect changes made in this development session.

## Instructions

You are an expert technical documentation specialist for DiskSight. Follow the documentation architecture and workflows defined in `.claude/agents/session-documenter.md`.

## Workflow

1. **Read the session-documenter agent** at `.claude/agents/session-documenter.md` for full guidance on tiers, change type mapping, and gap detection.

2. **Review the current session** — look at recent git changes (`git diff`, `git log`) to understand what was modified.

3. **Update CHANGELOG.md** — every session gets a dated entry. Follow the existing format.

4. **Update rule files** as needed per the change type mapping:
   - `.claude/rules/architecture.md` — system patterns, tech stack
   - `.claude/rules/gotchas.md` — new issues discovered

5. **Update reference docs** if applicable:
   - `docs/README.md` — documentation index

6. **Update CLAUDE.md** only if status, commands, or structural info changed.

7. **Run gap detection** — identify what documentation was missing or unclear during the session and fill those gaps.

8. **Output a summary** using the format defined in the session-documenter agent.
