# Rule: Git Worktree Workflow for Large Projects

## When to Use Worktrees

Use a git worktree for any project that:
- Spans multiple milestones or sessions
- Requires changes that must not land on `rustpush` until reviewed
- Involves parallel streams of work (e.g., two milestones in flight simultaneously)
- Is risky enough that a clean rollback path is required

Do **not** use a worktree for:
- Single-file bug fixes
- Documentation-only changes
- Changes that can be reviewed and merged in one session

## Naming Convention

Worktree directories live under:
```
~/projects/worktrees/openbubbles-app/<slug>/openbubbles-app
```

- `<slug>` is a short unique identifier for the work (e.g., `perf-m1`, `desktop-keychain`)
- Each worktree checks out its own dedicated branch (see below)

## Branch Convention

| Purpose | Branch name format | Example |
|---|---|---|
| Feature project | `project/<slug>` | `project/perf-m1` |
| Experimental | `experiment/<slug>` | `experiment/lru-cache` |
| Hotfix from worktree | `fix/<slug>` | `fix/apns-crash` |

Branch from `rustpush` (the mainline) unless the work builds on another in-flight project branch.

## Creating a Worktree

```bash
# From the main repo root
git worktree add ~/projects/worktrees/openbubbles-app/<slug>/openbubbles-app -b project/<slug> rustpush
```

Then open the worktree path in Zed as a new project window.

## Agent Behavior Inside a Worktree

- All file reads and edits target the worktree path — never the main repo path.
- Never `cd` or reference `~/projects/openbubbles-app` from inside a worktree session.
- Commits made inside the worktree stay on the feature branch and do not touch `rustpush`.
- Use `git --no-pager worktree list` to confirm current context if uncertain.

## Committing Inside a Worktree

Follow standard commit conventions (Conventional Commits). Reference milestone task IDs in commit body when applicable:

```
feat(perf): batch ObjectBox message watcher

Task 1.2 — reduces watcher callback overhead on low-end devices.
```

## Merging Back to Mainline

1. Ensure all acceptance criteria in affected milestone files are checked off.
2. Run full build and relevant tests from within the worktree.
3. Push the feature branch: `git push origin project/<slug>`
4. Open a PR from `project/<slug>` into `rustpush`.
5. After merge, remove the worktree:

```bash
git worktree remove ~/projects/worktrees/openbubbles-app/<slug>/openbubbles-app
git branch -d project/<slug>
```

## Do Not

- Do not commit directly to `rustpush` from a worktree session
- Do not create a worktree without a dedicated branch (detached HEAD = no rollback)
- Do not leave stale worktrees after project merges — they consume disk and confuse `git worktree list`
- Do not share one worktree across two unrelated projects
- Do not open the main repo and the worktree in the same Zed window — separate windows prevent path confusion
