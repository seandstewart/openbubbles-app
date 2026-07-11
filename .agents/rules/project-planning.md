# Rule: Project Planning

## Project Folder Structure

Each project lives in its own subdirectory under `.agents/projects/`:

```
.agents/projects/
  <project-slug>/
    README.md          ← Project overview (required)
    M1-<theme>.md      ← Milestone 1 (one file per milestone)
    M2-<theme>.md
    ...
```

Project slug is a short hyphenated name (e.g., `performance-optimization`).

## README.md (Project Overview)

Every project README must include:

| Section | Content |
|---|---|
| **Goal** | One-sentence description of what success looks like |
| **Problem Statement** | Why project exists; what user-visible pain it addresses |
| **Milestones table** | ID, name, primary files, status, link to milestone file |
| **ADR links** | Link to `.agents/adrs/` |
| **Expected Outcomes** | Measurable before/after metrics where possible |
| **Implementation Order** | Recommended sequencing with rough time estimates |

## Milestone Files

Each milestone file covers one theme (e.g., startup performance, memory, sync).

### Required Sections

**File header:**
```markdown
# M{N} — {Theme Name}

**Theme:** One-line description  
**Status:** Proposed | In Progress | Complete  
**ADRs:** Links to relevant ADRs  
```

**Per-task block:**
```markdown
## Task {N}.{M} — {Task Name}

**Severity:** 🔴 Critical | 🟠 High | 🟡 Medium | 🟢 Low  
**Effort:** Trivial | Low | Medium | High  
**ADR:** Link (if applicable)  

**Files:**
- `path/to/file.dart` — relevant function or class

**Problem:** Clear description of what is wrong and why it matters.

**Solution:** Code snippet or step-by-step description of the fix.

**Acceptance Criteria:**
- [ ] Checkbox items that define "done"
- [ ] Each item is independently verifiable
```

## Task Severity Definitions

| Level | Meaning |
|---|---|
| 🔴 Critical | Causes crashes, ANRs, data loss, or makes app unusable |
| 🟠 High | Significant user-visible performance degradation or security issue |
| 🟡 Medium | Noticeable but tolerable; correctness or efficiency concern |
| 🟢 Low | Minor cleanup; cosmetic; nice-to-have |

## Effort Definitions

| Level | Engineering time (rough) |
|---|---|
| Trivial | < 30 minutes; change 1–5 lines |
| Low | 1–4 hours; well-understood change with clear solution |
| Medium | 1–3 days; requires design thought or touches multiple files |
| High | 1–2 weeks; significant architecture change |

## Status Tracking

Update `Status` in milestone file header and milestones table in `README.md` as work progresses:

- **Proposed** — Planned but not started
- **In Progress** — Actively being worked on (include assignee or date started)
- **Complete** — All acceptance criteria met and verified

Mark individual acceptance criteria checkboxes as work is verified:
```markdown
- [x] Completed criterion
- [ ] Pending criterion
```

## Linking Tasks to ADRs

If a task requires an architectural decision:
1. Write the ADR first (see `rules/adr.md`)
2. Link to it in task's **ADR** field
3. Link back to milestone task from ADR's **Project** field

If a task is a straightforward bug fix or trivial change, no ADR needed.

## Naming Conventions

| Item | Format | Example |
|---|---|---|
| Project slug | lowercase-hyphenated | `performance-optimization` |
| Milestone file | `M{N}-{theme}.md` | `M1-startup.md` |
| Task ID | `{milestone}.{index}` | Task 3.1, Task 3.2 |
| ADR file | `ADR-{NNN}-{title}.md` | `ADR-005-batch-message-watcher.md` |

## Do Not

- Do not embed implementation code in `README.md` — keep in milestone files
- Do not add tasks to milestone files without Problem and at least one Acceptance Criterion
- Do not mark task Complete without verifying all acceptance criteria
- Do not create project without linking from top-level `AGENTS.md`
