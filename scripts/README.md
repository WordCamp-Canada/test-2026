# WCEH issue template

`copy-issues.sh` replays the issue list of a WordCamp planning repo into a new repo.
GitHub's "template repository" feature copies files, not issues, and this repo's value *is* its issues.

## Usage

```bash
# Preview (reads source only, writes nothing)
./copy-issues.sh --source WordCamp-Canada/2024-WCEH-Planning --dest WordCamp-Canada/test-2026 \
  --author kierahowe --exclude-title test --dry-run

# For real
./copy-issues.sh --source WordCamp-Canada/2024-WCEH-Planning --dest WordCamp-Canada/test-2026 \
  --author kierahowe --exclude-title test
```

Requires `gh` and `jq`. Auth is via `GH_TOKEN`/`GITHUB_TOKEN`; set `SOURCE_GH_TOKEN` / `DEST_GH_TOKEN`
if the two repos need different tokens. Tokens are never printed.

## What it does (in order)

1. **Labels**: created; if a label already exists (new repos ship defaults like `bug`), its colour/description is updated.
2. **Milestones**: created without due dates (the source dates belong to last year's event).
3. **Issues**: oldest first, always **open**, with labels and milestone.
4. **Fix-up pass**: `#N` cross-references are rewritten to the new issue numbers.

## Deliberate behaviours (the non-obvious *why*)

- **Assignees are not copied.** They'd notify people and may not be collaborators on the new repo.
- **`@mentions` are wrapped in backticks** so the copy doesn't ping people.
- **`#N` references to issues that weren't copied** become `` `#N` (not copied) `` — otherwise they'd link to an unrelated issue in the new repo.
- **Aborts if the destination already has issues** (override: `--allow-existing`). A second run would duplicate everything.
- **`--delay` (default 2s)** between creations avoids GitHub's secondary rate limit; rate-limit responses are retried with back-off.
- Not copied: comments, reactions, projects, closed state.

## Turning this into a workflow_dispatch Action

- The default `GITHUB_TOKEN` in Actions is scoped to the running repo only. Reading a private template and writing to a *different*
  new repo needs a PAT (or GitHub App token) with Issues: read/write on both, passed as `GH_TOKEN`.
- Inputs to expose: `dest` (required), plus `source`, `author`, `exclude-title`. Run with `--dry-run` first if you want a preview job.
- `ubuntu-latest` already has `gh` and `jq`; nothing to install.

## Testing

No live test suite. The destination write path was exercised against a stubbed `gh`
(source = real API, destination = canned responses) and checked for payload correctness.
