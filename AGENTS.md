# Symphony

## Codex GitHub rules for this fork

- This repo's writable target is `moizghumann/symphony`.
- Do not open PRs against `openai/symphony` unless explicitly instructed.
- Trust `git remote -v` over `gh repo view`.
- Before new work, run:

```sh
git fetch origin main
git checkout -b agent/<task> origin/main
```

- Never branch from stale local `main`.
- Branch creation is setup, not completion.
- Before push/PR, run:

```sh
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
```

- Use `mise exec -- ...` for Elixir commands.
- Do not run plain `mix`.
- Prefer focused tests first.
- Run `cd elixir && mise exec -- mix test` before push when Elixir code changed.
- Do not repeatedly run `make all` if it only fails known coverage thresholds.
- Open draft PRs with:

```sh
gh pr create --repo moizghumann/symphony --base main --head <branch> --draft
```

- If GitHub permission fails:
  - Stop retrying variants.
  - Inspect `git remote -v`.
  - Retry once with explicit `--repo moizghumann/symphony`.
  - If it still fails, report the exact blocker.
