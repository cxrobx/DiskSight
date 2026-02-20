---
description: Review changes since a ref, fix all issues, re-review until clean
allowed-tools: Bash(gh:*), Bash(git:*), Bash(npx tsc:*), Bash(python:*), Bash(xcodebuild:*), Read, Glob, Grep, Task, TaskCreate, TaskUpdate, TaskList, Skill, TeamCreate, TeamDelete, SendMessage
---

# /review-loop - Review & Fix Loop Until Clean

Runs a review on changes since a reference point, fixes all CRITICAL/HIGH/MEDIUM issues found, and re-reviews until no actionable issues remain.

## Usage

```
/review-loop [ref]           # Task-based (default, lightweight)
/review-loop [ref] --swarm   # Team Swarm (heavy, persistent agents)
```

- `ref` (optional): Git ref to compare against. Examples:
  - `main` - Changes on current branch vs main
  - `abc1234` - Changes since specific commit
  - `HEAD~5` - Last 5 commits
  - (no argument) - Defaults to `main`
- `--swarm` (optional): Use persistent Team Swarm coordination instead of lightweight Task agents. More expensive but provides persistent reviewers across cycles with shared context.

**Mode selection**: Check if `$ARGUMENTS` contains `--swarm`. Strip it from the ref before processing.

## Shared Steps

### Step 1: Determine Diff Range

If no ref provided, default to `main`:
```bash
git merge-base main HEAD
```

Otherwise use the provided ref directly.

### Step 2: Analyze Scope

```bash
git log <ref>..HEAD --oneline
git diff <ref>..HEAD --stat
git diff <ref>..HEAD --name-only
```

Report the number of commits, files changed, and lines added/removed. Save the list of changed files for reviewers.

---

## Default Mode (Task-Based)

Delegates review to `/review-pr` (6 parallel Task agents internally), then spawns parallel Task fix agents grouped by domain. Lightweight — no Team/SendMessage overhead.

### Step 3: Create Task Tracking

Create tasks using TaskCreate:
1. "Review all changes since <ref>" (review pass)
2. "Fix all issues from review pass N" (fix pass, blocked by review)
3. "Re-review until clean" (blocked by fix)

### Step 4: Run /review-pr

Use the Skill tool to invoke `/review-pr` against the diff range. If there's no open PR, create a temporary mental model of the diff as if it were a PR (use `git diff <ref>..HEAD` as the scope).

The `/review-pr` command will launch 6 specialized agents in parallel (Security, Code Quality, Backend, Frontend, Database, Test Coverage) and return a structured report with CRITICAL, HIGH, MEDIUM, and LOW findings.

### Step 5: Check Exit Condition

Parse the `/review-pr` output. Count issues at each severity level.

**If zero CRITICAL + HIGH + MEDIUM issues**: The loop is clean. Proceed to Step 7.
**If any CRITICAL, HIGH, or MEDIUM issues exist**: Continue to Step 6.

LOW-severity issues are reported but do NOT keep the loop running.

### Step 6: Fix Issues & Re-Review (Loop)

Group the CRITICAL/HIGH/MEDIUM issues by file/domain and launch fix agents in parallel using the Task tool:

| Domain | `subagent_type` |
|--------|-----------------|
| Security issues | `security-engineer` |
| Backend code | `backend-engineer` |
| Frontend/UI code | `frontend-engineer` |
| Database/migrations | `architecture-engineer` |
| General/mixed | `general-purpose` |

Each fix agent receives:
- The specific issues to fix (with file paths, line numbers, descriptions)
- Instruction to read each file before editing
- Instruction to be surgical (only change what's needed)
- Reference to `.claude/rules/` for project conventions (if present)

After all fixes are applied, **go back to Step 4** (run `/review-pr` again on the updated diff).

**Max iterations: 3 review-fix cycles.** If CRITICAL/HIGH/MEDIUM issues persist after 3 passes, stop and report remaining issues for manual review.

### Step 7: Verify Build

Auto-detect build system and run verification:
- TypeScript/Node: `npx tsc --noEmit`
- Python: `python -m py_compile` on changed `.py` files
- Swift: `xcodebuild -scheme <scheme> build`

If build fails, fix compilation errors and re-check.

### Step 8: Report Summary

Output a summary:

```markdown
## Review Loop Complete

**Scope**: N commits, M files, +X/-Y lines since <ref>
**Passes**: K review passes until clean

### Issues Found & Fixed

| # | Severity | Category | Issue | File | Pass |
|---|----------|----------|-------|------|------|
| 1 | CRITICAL | Security | Description | file.ts:42 | 1 |
| 2 | HIGH | Backend | Description | worker.py:88 | 1 |
...

### Not Auto-Fixed (Requires Design Decision)
- Issue description (reason it wasn't auto-fixed)

### Positive Findings
- Good patterns found during review

### Build Status
- Build: PASS/FAIL

### Summary Table
| Category | Critical | High | Medium | Fixed | Remaining |
|----------|----------|------|--------|-------|-----------|
| Security | X | X | X | X | X |
| Code Quality | X | X | X | X | X |
| Backend | X | X | X | X | X |
| Frontend | X | X | X | X | X |
| Database | X | X | X | X | X |
| Test Coverage | X | X | X | X | X |

**Recommendation:** [All clear / Issues remaining for manual review]
```

---

## Swarm Mode (`--swarm`)

Creates a persistent team with 6 reviewer teammates and on-demand fixer teammates. Full Team coordination via SendMessage/TaskList. More expensive but reviewers persist across cycles with shared context.

### Step 3: Create Team & Spawn Reviewers

Create the team:
```
TeamCreate: team_name = "review-loop-{timestamp}", description = "Review-fix loop for changes since <ref>"
```

Then spawn **6 reviewer teammates in parallel** using the Task tool with `team_name` parameter. All reviewers use `subagent_type: "feature-dev:code-reviewer"`.

| Teammate Name | Focus Areas |
|---------------|-------------|
| `security-reviewer` | Authentication, authorization, SQL injection, rate limiting, input validation, session handling, race conditions |
| `quality-reviewer` | Logic errors, error handling, code duplication, type safety, resource leaks, dead code, correctness |
| `backend-reviewer` | Backend patterns, async patterns, timeout handling, retry logic, project conventions |
| `frontend-reviewer` | React hooks, state management, error handling, loading states, TypeScript safety, UX issues |
| `database-reviewer` | Migration idempotency, schema changes, indexes, constraints, type choices |
| `test-reviewer` | Coverage gaps, edge cases, mock quality, test isolation, error testing, missing tests |

**Each reviewer's prompt MUST include:**
1. The complete list of changed files (from Step 2)
2. The feature context (from git log)
3. Domain-specific focus areas (from table above)
4. The structured findings format (see below)
5. Instruction to read each file before reviewing
6. Instruction to check `.claude/rules/` for project conventions (if they exist)
7. Instruction: report only findings with **self-assessed confidence >= 80%**
8. Instruction: when done, send findings to team lead via SendMessage

**Reviewer prompt template:**
```
You are the {DOMAIN} reviewer on a review-fix team. Your job is to review the following changed files for {FOCUS_AREAS}.

CHANGED FILES:
{file_list}

FEATURE CONTEXT:
{git_log_summary}

REVIEW CYCLE: {N} of max 3

INSTRUCTIONS:
1. Read each changed file that falls in your domain
2. Check against project conventions in .claude/rules/ (if present)
3. Report ONLY issues where you are >= 80% confident it's a real problem
4. Categorize each finding as CRITICAL, HIGH, MEDIUM, or LOW
5. When done, send your findings to the team lead using SendMessage

FORMAT YOUR FINDINGS EXACTLY AS:

REVIEW COMPLETE: {domain}
CYCLE: {N}
FILES REVIEWED: {count}

FINDINGS:
- {SEVERITY} | {file_path}:{line} | {confidence}% | {title} | {description} | {suggested_fix}

POSITIVE:
- {good_pattern_description}

NO ISSUES: {true|false}
```

### Step 4: Review Phase (Per Cycle)

1. **Create review tasks** via TaskCreate — one per reviewer (e.g., "Security review cycle N")
2. **Assign tasks** to reviewers via TaskUpdate (set `owner`)
3. **Send each reviewer a message** via SendMessage with the cycle number and any additional context (e.g., "This is cycle 2 — focus on files that were modified in the fix phase")
4. **Wait for findings** — reviewer messages arrive automatically. Wait for all 6 reviewers to respond.
5. **Aggregate findings:**
   - Parse each reviewer's structured findings
   - Deduplicate: if two reviewers flag the same file:line, keep the higher severity
   - Filter: only keep findings with >= 80% confidence
   - Categorize: group by CRITICAL, HIGH, MEDIUM, LOW
6. **Check exit condition:**
   - **Zero CRITICAL + HIGH + MEDIUM findings** → Loop is clean, proceed to Step 6
   - **Any CRITICAL, HIGH, or MEDIUM findings** → Continue to Step 5

### Step 5: Fix Phase (Per Cycle)

Group findings by domain and spawn **fix teammates only for domains that have CRITICAL/HIGH/MEDIUM findings**.

| Domain Pattern | Teammate Name | `subagent_type` |
|----------------|---------------|-----------------|
| Security issues (any file) | `security-fixer` | `security-engineer` |
| Backend code | `backend-fixer` | `backend-engineer` |
| Frontend/UI code | `frontend-fixer` | `frontend-engineer` |
| Database/migrations | `database-fixer` | `architecture-engineer` |
| General/mixed | Use the most relevant fixer above, or `frontend-engineer` as default |

**Each fix agent's prompt MUST include:**
1. The specific issues to fix (file paths, line numbers, descriptions, suggested fixes)
2. Instruction to read each file BEFORE editing
3. Instruction to be surgical — only change what's needed to fix the reported issue
4. Reference to `.claude/rules/` for project conventions (if present)
5. Instruction: when done, mark task as completed and send confirmation to team lead

**Fix agent prompt template:**
```
You are the {DOMAIN} fixer on a review-fix team. Fix the following issues that were found during code review cycle {N}.

ISSUES TO FIX:
{numbered_list_of_issues_with_file_paths_lines_descriptions_and_suggested_fixes}

INSTRUCTIONS:
1. Read each file BEFORE making changes
2. Be surgical — only change what's needed to fix each issue
3. Follow project conventions in .claude/rules/ (if present)
4. After fixing all issues, send a summary to the team lead via SendMessage listing what you fixed
5. Mark your task as completed via TaskUpdate

DO NOT:
- Refactor surrounding code
- Add features or improvements beyond the fix
- Change code style or formatting of untouched lines
```

After all fix agents complete, **loop back to Step 4** (re-review). On the re-review cycle, tell reviewers to focus on files modified during the fix phase.

**Max iterations: 3 review-fix cycles.** If CRITICAL/HIGH/MEDIUM issues persist after 3 passes, stop and report remaining issues for manual review.

### Step 6: Verify Build

Auto-detect build system and run verification:
- TypeScript/Node: `npx tsc --noEmit`
- Python: `python -m py_compile` on changed `.py` files
- Swift: `xcodebuild -scheme <scheme> build`

If build fails, fix compilation errors and re-check.

### Step 7: Shutdown Team

1. Send `shutdown_request` to ALL teammates via SendMessage (reviewers + any active fixers)
2. Wait for shutdown confirmations
3. Call TeamDelete to clean up the team and task list

### Step 8: Report Summary

Output a summary:

```markdown
## Review Loop Complete

**Scope**: N commits, M files, +X/-Y lines since <ref>
**Passes**: K review passes until clean
**Team**: 6 reviewers + N fix agents across K cycles

### Issues Found & Fixed

| # | Severity | Category | Issue | File | Pass | Fixed By |
|---|----------|----------|-------|------|------|----------|
| 1 | CRITICAL | Security | Description | file.ts:42 | 1 | security-fixer |
| 2 | HIGH | Backend | Description | worker.py:88 | 1 | backend-fixer |
...

### Not Auto-Fixed (Requires Design Decision)
- Issue description (reason it wasn't auto-fixed)

### Positive Findings
- Good patterns found during review

### Build Status
- Build: PASS/FAIL

### Summary Table
| Category | Critical | High | Medium | Fixed | Remaining |
|----------|----------|------|--------|-------|-----------|
| Security | X | X | X | X | X |
| Code Quality | X | X | X | X | X |
| Backend | X | X | X | X | X |
| Frontend | X | X | X | X | X |
| Database | X | X | X | X | X |
| Test Coverage | X | X | X | X | X |

**Recommendation:** [All clear / Issues remaining for manual review]
```

---

## Swarm Mode Team Roster

### Persistent Reviewers (all cycles)

| Teammate | `subagent_type` | Domain |
|----------|-----------------|--------|
| `security-reviewer` | `feature-dev:code-reviewer` | Auth, injection, rate limiting, sessions |
| `quality-reviewer` | `feature-dev:code-reviewer` | Logic errors, types, resource leaks, dead code |
| `backend-reviewer` | `feature-dev:code-reviewer` | Backend patterns, async, retries |
| `frontend-reviewer` | `feature-dev:code-reviewer` | React hooks, state, loading states, TypeScript |
| `database-reviewer` | `feature-dev:code-reviewer` | Schema, indexes, constraints, migrations |
| `test-reviewer` | `feature-dev:code-reviewer` | Coverage gaps, edge cases, test isolation |

### On-Demand Fixers (spawned only when needed)

| Teammate | `subagent_type` | When Spawned |
|----------|-----------------|--------------|
| `security-fixer` | `security-engineer` | Security findings exist |
| `backend-fixer` | `backend-engineer` | Backend findings exist |
| `frontend-fixer` | `frontend-engineer` | Frontend/UI findings exist |
| `database-fixer` | `architecture-engineer` | Database/migration findings exist |

## Configuration

### Max Iterations
The loop runs a maximum of **3 review-fix cycles** to prevent infinite loops. If CRITICAL/HIGH/MEDIUM issues persist after 3 passes, report remaining issues for manual review.

### Confidence Threshold
Reviewers self-assess confidence for each finding. Only findings with **>= 80% confidence** are included in the actionable report.

### Loop Exit Condition
The loop exits when all reviewers return **zero CRITICAL, HIGH, or MEDIUM issues**. LOW-severity findings are included in the final report but do not keep the loop running.

## Examples

```
# Review current branch vs main (Task-based, default)
/review-loop main

# Review last 5 commits
/review-loop HEAD~5

# Review since specific commit with Team Swarm
/review-loop abc1234 --swarm

# Auto-detect (defaults to main)
/review-loop

# Auto-detect with Team Swarm
/review-loop --swarm
```
