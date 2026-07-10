# tackle — agent guide

`tackle <branch|PR-number|PR-url>` — one command that turns a branch or PR into a
ready-to-work, isolated git worktree with an AI agent primed on the change.

- Resolves the branch, creates a git worktree, sets up dependencies per detected
  ecosystem, copies unversioned `.env` files into the worktree, and launches the
  agent primed with PR context. Plain branch names auto-resolve to their open PR
  via `gh pr list` (1 match → silent; multiple → `fzf` picker or listed error;
  0 → branch-only).
- **Dependency handling is language-agnostic** (registry: JS pnpm/yarn/npm, Rust,
  Go, Python). Per ecosystem it byte-compares the lockfile main-vs-worktree and
  symlinks the shared install dir (flat `node_modules`; an in-project Python
  `.venv`) only when it's safe *and* the lockfile matches; otherwise it runs a
  cache-backed install. pnpm defaults to install (opt into symlink with
  `TACKLE_PNPM_SYMLINK=true` / `node-linker=hoisted`). **Python** is detected
  most-specific first — `uv.lock`/`poetry.lock`, then a `pyproject.toml`
  `[tool.uv]`/`[tool.poetry]` declaration, then `requirements.txt`, then a bare
  `pyproject.toml` — and each install command builds an in-project `.venv`; venvs
  are reused by symlink only (never copied — they bake absolute interpreter paths).
  Bazel workspaces (`MODULE.bazel`/`WORKSPACE`) skip in-tree reuse (use a
  `tackle.toml` hook/symlink for their venv). `--install` forces an isolated
  install; `--no-deps` (or `TACKLE_DEPS=off`) skips dependency handling. Only
  root-level lockfiles are compared.
- **New branches**: `--new` / `-n <branch>` creates the branch as part of the
  worktree (`git worktree add -b`) instead of requiring it to exist; `--base` /
  `-b <ref>` picks what to branch from (default `HEAD`, only valid with `--new`).
- **Project config** (`tackle.toml` / `tackle.json` at the repo root or a monorepo
  subdir, with an optional gitignored `tackle.local.*` that deep-merges on top):
  declares per-project `agent` / `dir_template` / `prompt` / `deps`, `copy` /
  `symlink` paths brought into the worktree, and `[hooks] pre_create` / `setup`
  (in the worktree) / `on_done` commands. Hooks get `$TACKLE_MAIN` /
  `$TACKLE_WORKTREE` / `$TACKLE_BRANCH`. Precedence: CLI > caller env >
  `tackle.local` > base config > `.env` > default. Hook execution is gated by a
  trust-on-first-use prompt (per repo; re-prompts with a diff if the config
  changes). `--no-config` / `TACKLE_CONFIG=off` ignores it; `--trust` pre-approves.
  See `tackle.example.toml`.
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
  `TACKLE_REPO_CHECK`, `TACKLE_DEPS`, `TACKLE_PNPM_SYMLINK`, `TACKLE_COPY_ENV`,
  `TACKLE_CONFIG`) lives in a `.env` co-located with the script (auto-sourced);
  override the path via `TACKLE_ENV_FILE`. Per-project settings go in a
  `tackle.toml` (see above); the trust store lives in `TACKLE_STATE_DIR`
  (default `~/.local/state/tackle`).
- Compatible with bash and zsh.

## Tests

`./tests/run.sh` runs the bats behavioral suite (bash) + a zsh smoke test.
Requires `bats-core`; `git` + `python3` (same as tackle itself); `zsh` for the
smoke test (skipped if absent). `gh` and `fzf` are stubbed, so no network or
GitHub auth is needed. See `tests/README.md`.
