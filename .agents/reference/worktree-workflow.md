# Reference: Git Worktree Workflow

## Repo Layout

```
~/projects/openbubbles-app/                          ← main repo (rustpush branch)
~/projects/worktrees/openbubbles-app/
  <slug>/openbubbles-app/                            ← worktree for project <slug>
  <slug2>/openbubbles-app/                           ← worktree for project <slug2>
```

Each directory under `~/projects/worktrees/openbubbles-app/` is an independent working tree sharing the same `.git` object store as the main repo. Branches are isolated — changes in one worktree do not appear in another until merged.

## Current Worktrees

Run from any repo path:
```bash
git --no-pager worktree list
```

Example output:
```
/Users/god/projects/openbubbles-app                                         eed1b6332 [rustpush]
/Users/god/projects/worktrees/openbubbles-app/poised-anvil/openbubbles-app  7df6d728d (detached HEAD)
```

## Lifecycle

### 1. Plan

Define the project under `.agents/projects/<slug>/` before creating the worktree. The README must include the goal, milestones, and expected outcomes (see `rules/project-planning.md`).

### 2. Create Worktree + Branch

```bash
# From main repo root
git worktree add ~/projects/worktrees/openbubbles-app/<slug>/openbubbles-app \
  -b project/<slug> rustpush
```

Open the new worktree path as a project in Zed.

### 3. Implement Task by Task

Each task gets **one branch and one commit**. The project docs branch tracks status separately.

#### Task branch pattern

```bash
# Create task branch from rustpush
git checkout -b project/perf-m12 rustpush

# Apply only the files changed by this task
git add rust/src/lib.rs
git commit -m "perf(rust): increase Tokio worker thread count

Task M1.2 — ..."
```

Branch naming: `project/<slug>-<task-id>` (e.g. `project/perf-m12`, `project/perf-m25`).

#### Docs branch pattern

The project docs branch (e.g. `project/agent-docs`) is the long-lived branch for `.agents/` files. After committing task branches, update milestone status here:

```bash
git checkout project/agent-docs

# Pull updated milestone files from task branches
git checkout project/perf-m12 -- .agents/projects/performance-optimization/M1-startup.md
git checkout project/perf-m25 -- .agents/projects/performance-optimization/M2-message-delivery.md

git commit -m "docs(perf): mark M1.2, M2.5 acceptance criteria complete

Tasks committed to dedicated branches:
- project/perf-m12: Tokio worker threads (M1.2)
- project/perf-m25: SocketIOForegroundService ANR fix (M2.5)"
```

#### Rules

- Never mix task code and `.agents/` doc updates in the same commit
- Never commit task code directly to the docs branch
- Milestone file changes (checkbox updates) belong on the docs branch only
- One task branch per task — do not batch multiple tasks into one branch

### 4. Validate

From inside the worktree:
```bash
# Flutter
flutter analyze
flutter test

# Rust
cargo check --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml
```

### 5. Push and PR

```bash
git push origin project/<slug>
# Open PR: project/<slug> → rustpush
```

### 6. Cleanup After Merge

```bash
git worktree remove ~/projects/worktrees/openbubbles-app/<slug>/openbubbles-app
git branch -d project/<slug>
```

## Parallel Worktrees

Two milestones from the same project can run in parallel if their file write sets are disjoint. Each gets its own worktree and branch:

```
project/perf-m1   ← Milestone 1 (startup, Rust backend)
project/perf-m2   ← Milestone 2 (UI, ObjectBox)
```

When M1 merges first, rebase M2 onto `rustpush` before opening its PR:
```bash
# Inside M2 worktree
git fetch origin
git rebase origin/rustpush
```

## Agent Context Rules

| Situation | Action |
|---|---|
| Agent starts session | Run `git --no-pager worktree list` to confirm current worktree path |
| Path ambiguity | Check first component of CWD — `worktrees/` = feature branch, `projects/openbubbles-app` = mainline |
| Editing files | Always use worktree-relative paths — never reference sibling worktree paths |
| Need mainline state | `git fetch origin && git log origin/rustpush --oneline -5` from worktree |

## Detached HEAD Warning

Worktrees created without `-b <branch>` land in detached HEAD state. Commits are reachable only by SHA — easily lost. Always create with a named branch. If already detached:

```bash
git checkout -b project/<slug>
```

## Stale Worktree Detection

```bash
git --no-pager worktree list --porcelain | grep "prunable"
git worktree prune
```

Run after any force-deleted worktree directory to clean up `.git/worktrees/` metadata.
