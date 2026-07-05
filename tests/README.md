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
| `tackle.bats` | The suite — 57 cases across creation, guards, `.env` copy, `node_modules` symlink + non-JS skip, the kept `gwt` alias, `--done`, PR resolution (number/URL/multi-PR fzf picker), the cross-repo guard for PR URLs (`--repo-check`/`TACKLE_REPO_CHECK` local/remote/off + normalization + gh fallback), the review + prefill-prompt flow (`TACKLE_PROMPT`/`--review`/`--prompt` precedence, `--add`/`--before`/`--after`, template vars, `--flag=value` forms), branch fetch-from-origin, env-file precedence, and the `--time` prefix. |
| `helpers.bash` | Shared setup: hermetic stubs, `init_repo`, recording-agent helper. |
| `tackle_zsh_smoke.sh` | Runs a create + `--done` cycle under **zsh** (bats only covers bash). |
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
