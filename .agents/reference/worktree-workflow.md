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

### 3. Implement by Milestone

Work milestone-by-milestone. After each task:
- Check off acceptance criteria in the milestone file
- Commit with a message referencing the task ID

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
