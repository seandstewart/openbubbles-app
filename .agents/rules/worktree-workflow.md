# Rule: Git Branch Workflow

## Branch Convention

One branch per task. One commit per task.

```
project/<project-slug>/<milestone>/<task>-<slug>
```

Examples:
- `project/perf-opt/m1/1-parallel-icloud-init`
- `project/perf-opt/m5/3-lru-image-cache`
- `project/desktop-keychain/m2/1-platform-keychain`

Branch from `rustpush` unless work builds on an in-flight project branch.

```bash
git checkout rustpush
git pull
git checkout -b project/<project-slug>/<milestone>/<task>-<slug>
```

## Committing

One commit per task. Task branches contain only code files changed by that task — no `.agents/` updates.

Commit format:
```
<type>(<scope>): <summary>

Task <milestone>.<task> — <brief rationale>
```

Example:
```
perf(rust): increase Tokio worker thread count

Task M1.2 — replaces worker_threads(1) with available_parallelism().min(4).
```

## Project Docs Branch

A long-lived docs branch (e.g. `project/agent-docs`) tracks all `.agents/` project files. After committing a task branch, check off acceptance criteria on the docs branch:

```bash
git checkout project/agent-docs
git checkout project/perf-opt/m1/2-tokio-threads -- .agents/projects/performance-optimization/M1-startup.md
git commit -m "docs(perf): mark M1.2 acceptance criteria complete"
```

Never commit task code to the docs branch. Never commit `.agents/` updates to a task branch.

## Merging

1. Ensure acceptance criteria in affected milestone files are checked off.
2. Run full build and relevant tests.
3. Push: `git push origin project/<project-slug>/<milestone>/<task>-<slug>`
4. Open PR into `rustpush`.
5. After merge, delete branch: `git branch -d project/<project-slug>/<milestone>/<task>-<slug>`

## Do Not

- Commit directly to `rustpush`
- Batch multiple tasks into one branch or commit
- Commit `.agents/` doc updates to a task branch
- Commit task code to the docs branch
