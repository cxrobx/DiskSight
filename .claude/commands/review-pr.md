---
description: Comprehensive PR review with parallel specialized agents
allowed-tools: Bash(gh:*), Bash(git:*), Read, Glob, Grep, Task
---

# Comprehensive PR Review

Run a thorough multi-agent review of a pull request covering security, code quality, architecture, and test coverage.

## Usage

```
/review-pr [PR_NUMBER or branch]
```

If no PR is specified, reviews the current branch against main.

## Review Process

This command spawns specialized review agents in parallel:

| Agent | Focus Areas |
|-------|-------------|
| **Security Reviewer** | Authentication, authorization, injection, input validation, secret exposure |
| **Code Quality Reviewer** | Logic errors, error handling, type safety, resource leaks, dead code |
| **Architecture Reviewer** | Patterns, conventions, performance, scalability |
| **Test Coverage Reviewer** | Coverage gaps, edge cases, mock quality, test isolation |

## Instructions

1. **Fetch PR metadata and diff:**
   ```bash
   gh pr view $ARGUMENTS --json title,body,additions,deletions,changedFiles,files,headRefName,baseRefName
   gh pr diff $ARGUMENTS
   ```

   If no PR number provided, use the diff against main:
   ```bash
   git diff main...HEAD --stat
   git diff main...HEAD
   ```

2. **Analyze the scope** to understand what features/changes are being introduced.

3. **Launch all review agents in parallel** using the Task tool. Each agent should:
   - Read the relevant changed files
   - Check against project conventions (see `.claude/rules/`)
   - Report only HIGH confidence issues (>80%)
   - Categorize findings as CRITICAL, HIGH, MEDIUM, or LOW priority

4. **Agent prompts should include:**
   - The specific files to review (from diff)
   - The feature context (from PR description or commit messages)
   - What to look for (agent-specific focus areas)
   - Instruction to report HIGH confidence issues only

5. **Compile findings** into a summary report.

## Agent Prompts

### Security Reviewer
```
Review for security vulnerabilities. Focus on:
1. Authentication/Authorization - Are endpoints properly protected?
2. Injection - Are queries parameterized? Is input sanitized?
3. Input Validation - Are all inputs validated?
4. Secret Exposure - Are API keys, tokens, or credentials exposed?
5. Session Handling - Are sessions properly validated?
6. Race Conditions - Could concurrent requests bypass limits?

Read each changed file and report HIGH confidence security issues only.
```

### Code Quality Reviewer
```
Review for bugs and code quality. Focus on:
1. Logic Errors - Incorrect conditionals, edge cases not handled
2. Error Handling - Are errors properly caught and handled?
3. Type Safety - Type errors, any types, missing null checks
4. Resource Leaks - Unclosed connections, missing cleanup
5. Dead Code - Unreachable code paths
6. Correctness - Does the code do what it's supposed to do?

Report only HIGH confidence issues that would cause real problems.
```

### Architecture Reviewer
```
Review for architectural concerns. Focus on:
1. Project patterns - Does the code follow established conventions?
2. Performance - Are there obvious performance issues?
3. Error handling and retry logic
4. Database query patterns (N+1, missing indexes)
5. API design consistency

Check .claude/rules/ for project conventions. Report architecture issues.
```

### Test Coverage Reviewer
```
Review test coverage. Focus on:
1. Coverage - Are all code paths tested?
2. Edge Cases - Are edge cases covered?
3. Mock Quality - Are mocks realistic?
4. Test Isolation - Do tests properly reset state?
5. Error Testing - Are error paths tested?
6. Missing Tests - What important scenarios are NOT tested?

Report test quality issues and coverage gaps.
```

## Output Format

```markdown
## PR Review Summary

### CRITICAL ISSUES (Must Fix)
1. **Issue Title**
   - **File:** `path/to/file:line`
   - **Confidence:** XX%
   - **Problem:** Description
   - **Fix:** Suggested solution

### HIGH PRIORITY ISSUES
...

### MEDIUM PRIORITY ISSUES
...

### LOW PRIORITY ISSUES
...

### POSITIVE FINDINGS
- Good patterns observed
- etc.

### Summary Table
| Category | Critical | High | Medium | Low |
|----------|----------|------|--------|-----|
| Security | X | X | X | X |
| Code Quality | X | X | X | X |
| Architecture | X | X | X | X |
| Test Coverage | X | X | X | X |

**Recommendation:** [Approve / Approve with fixes / Request changes]
```

## Related Documentation

- `.claude/rules/` - Project conventions and patterns
