# Rule: Architecture Decision Records (ADRs)

## When to Write an ADR

Write an ADR for every change that:
- Modifies how components communicate (FFI, MethodChannel, isolate topology)
- Changes a data store, format, or persistence strategy
- Alters a background processing model (service type, worker lifecycle, isolate use)
- Introduces or removes a significant dependency
- Makes a tradeoff between performance, complexity, correctness, or security
- Could be questioned or reversed by a future engineer

Do **not** write an ADR for:
- Bug fixes where correct behavior is unambiguous
- Cosmetic or naming changes
- New screen or widget following existing patterns
- Dependency patch version bumps

## File Location and Naming

All ADRs live in `.agents/adrs/`.

Filename format: `ADR-NNN-short-hyphenated-title.md`

- NNN is zero-padded sequential number (001, 002, ...)
- Title summarizes decision in 3–6 words
- Examples: `ADR-001-parallel-icloud-init.md`, `ADR-005-batch-message-watcher.md`

To get next number: count existing files in `.agents/adrs/` and increment.

## ADR Template

```markdown
# ADR-NNN — Title

**Status:** Proposed | Accepted | Rejected | Deprecated | Superseded by ADR-XXX  
**Date:** YYYY-MM-DD  
**Project:** [Project Name](../projects/project-name/milestone-file.md)  ← optional

## Context

Describe the situation that makes this decision necessary. Include:
- What code or system is affected (file paths, function names)
- Why the current approach is problematic
- Any constraints or requirements that shape the decision

## Decision

State the decision clearly. Include:
- What will change
- Code snippets showing before/after if helpful
- Any configuration or tooling changes required

## Consequences

List both positive and negative consequences. Be honest about tradeoffs.

**Positive:**
- ...

**Negative:**
- ...

## Alternatives Considered

List at least 2 alternatives that were rejected, and explain why.

**A: Description**  
Reason for rejection.

**B: Description**  
Reason for rejection.
```

## Status Lifecycle

```
Proposed → Accepted   (change implemented and merged)
Proposed → Rejected   (decision made not to proceed; document why)
Accepted → Deprecated (approach still works but no longer preferred)
Accepted → Superseded by ADR-XXX (replaced by newer decision)
```

Always update **Status** field when implementation completes or decision changes. Do not delete ADRs — historical record.

## Linking

- ADRs should link to project milestone file(s) they support.
- Milestone task entries should link to corresponding ADR(s).
- If an ADR supersedes another, both files should reference each other.

## Writing Style

- Present tense for Decision section ("We use X" not "We will use X").
- Past tense for Context section when describing current (pre-change) state.
- Be specific: name files, functions, and line numbers where relevant.
- Keep each section focused. ADRs are meant to be read quickly.
