# tackle test suite

Behavioral tests that lock down `tackle.zsh`. First tests in this repo — the
pattern here (temp git repo per test, stubbed `gh`/agent, assert on observable
effects) is reusable for other helpers.

## Run

```sh
./tests/run.sh          # bats suite (bash) + zsh smoke test
bats tests/tackle.bats     # just the bats suite
zsh  tests/tackle_zsh_smoke.sh   # just the cross-shell smoke test
```

## Requirements

- **bats-core** — `brew install bats-core` (macOS) / `apt install bats` (Ubuntu).
- **git**, **python3** — same as tackle itself.
- **zsh** — for the smoke test (skipped if absent).

No network or GitHub auth needed: `gh` is stubbed, the agent launch is stubbed
(`TACKLE_AGENT=true`), and `TACKLE_ENV_FILE` is pointed at a nonexistent file so the
real `~/.zsh/.env` is never sourced.

## Layout

| File | Purpose |
|---|---|
| `tackle.bats` | The suite — 102 cases across creation, guards, `.env` copy, the **dependency registry** (per-ecosystem symlink-vs-install decision: npm/yarn identical-lockfile symlink, differing-lockfile install, `--install` force, pnpm default-install + hoisted opt-in, JS family exclusivity, multilingual install, empty-`node_modules`/Bazel short-circuit, **Python content-aware detection** — uv/poetry via `pyproject.toml` sections even with a stray `requirements.txt`, `.venv` symlink-reuse when the lock is unchanged, isolated-venv create otherwise, `--no-deps`/`TACKLE_DEPS=off`) + non-JS skip, the kept `gwt` alias, new-branch mode (`--new`/`-n` + `--base`/`-b`), `--done`, PR resolution (number/URL/multi-PR fzf picker), the cross-repo guard for PR URLs (`--repo-check`/`TACKLE_REPO_CHECK` local/remote/off + normalization + gh fallback), the review + prefill-prompt flow (`TACKLE_PROMPT`/`--review`/`--prompt` precedence, `--add`/`--before`/`--after`, template vars, `--flag=value` forms), branch fetch-from-origin, env-file precedence, the `--time` prefix, and the **project config** (`tackle.toml`/`.json` + `tackle.local` merge, precedence vs caller env, `copy`/`symlink` materialization, unsafe-path rejection, `deps=off`, the `pre_create`/`setup`/`on_done` hooks incl. failure semantics, the three-state trust flow — first / persisted / changed-with-diff / EOF-skip, `--no-config`/`TACKLE_CONFIG=off`, and the gitignore advisory). |
| `helpers.bash` | Shared setup: hermetic stubs (incl. `write_install_stub` for package managers), `init_repo`, recording-agent helper, isolated `TACKLE_STATE_DIR` trust store. |
| `tackle_zsh_smoke.sh` | Runs a create + `--done` cycle, a dependency-registry symlink case, a project-config copy + `setup` hook, **and** Python `pyproject.toml [tool.uv]` content-aware detection under **zsh** (bats only covers bash) — guards the registry's array/`read`/`${//}` splitting, the `file@section` marker's `${%@}`/`${#@}` splitting, and the config path's process-substitution / dynamic-scope / python-heredoc against zsh differences. |
| `run.sh` | Runs both. |

## Why a separate zsh smoke test?

`tackle.zsh` is sourced into **zsh** in daily use, but bats runs tests under
**bash**. The bash suite covers the shell-agnostic logic; the zsh smoke test
guards the bits that could diverge between shells (the `BASH_SOURCE`/`ZSH_VERSION`
detection block, word splitting, `read`), so a zsh-only regression can't slip
through.

## How the tests work

Each test creates a throwaway repo under `$BATS_TEST_TMPDIR` (auto-removed),
runs `tackle`, and asserts on what actually happened on disk and in the output —
e.g. *was the worktree created beside the repo root, was the deep `.env` copied
but the `.env.example` skipped, did `--done` from a subfolder remove the
worktree*. That last one is the regression guard for the subfolder fix: `--done`
resolves the current worktree's top-level with `git rev-parse --show-toplevel`
rather than trusting `$PWD`.
