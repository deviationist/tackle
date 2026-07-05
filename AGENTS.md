# tackle — agent guide

`tackle <branch|PR-number|PR-url>` — one command that turns a branch or PR into a
ready-to-work, isolated git worktree with an AI agent primed on the change.

- Resolves the branch, creates a git worktree, symlinks `node_modules` (instant),
  copies unversioned `.env` files into the worktree, and launches the agent primed
  with PR context. Plain branch names auto-resolve to their open PR via
  `gh pr list` (1 match → silent; multiple → `fzf` picker or listed error;
  0 → branch-only).
- `--review` starts with a built-in "what changed?" prompt that auto-injects the
  PR title and description when a PR is resolved. `--prompt "…"` sets a fully
  custom prompt; `--add` / `--before` / `--after` layer onto it (assembly order
  `[--before][base+--add][--after]`). `TACKLE_PROMPT` is the persistent default;
  it supports template variables `{branch}` `{pr_number}` `{pr_title}`
  `{pr_description}` `{additive_prompt}`.
- **Cross-repo guard**: a PR *URL* pointing at a different GitHub repo than the
  current checkout is caught up front — `--repo-check` / `TACKLE_REPO_CHECK`:
  `local` (default, string-compare vs `git remote get-url origin`), `remote`
  (ask `gh`, falls back to local), or `off`. Bare PR numbers always skip it.
- `tackle --done` / `--close` cd back to the main repo and remove the worktree
  (prompts before discarding uncommitted changes).
- `gwt` is a kept alias for `tackle` (the tool's original name).
- Config (`TACKLE_AGENT`, `TACKLE_DIR_TEMPLATE`, `TACKLE_PROMPT`,
  `TACKLE_REPO_CHECK`, `TACKLE_COPY_ENV`) lives in a `.env` co-located with the
  script (auto-sourced); override the path via `TACKLE_ENV_FILE`.
- Compatible with bash and zsh.

## Tests

`./tests/run.sh` runs the bats behavioral suite (bash) + a zsh smoke test.
Requires `bats-core`; `git` + `python3` (same as tackle itself); `zsh` for the
smoke test (skipped if absent). `gh` and `fzf` are stubbed, so no network or
GitHub auth is needed. See `tests/README.md`.
