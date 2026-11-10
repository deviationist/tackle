# tackle

[![CI](https://github.com/deviationist/tackle/actions/workflows/ci.yml/badge.svg)](https://github.com/deviationist/tackle/actions/workflows/ci.yml)

Turn a branch or PR into a ready-to-work, isolated git worktree — dependencies
reused instead of reinstalled, unversioned `.env` files copied, and an AI agent
session launched already primed on what changed and why. The git plumbing, dep
setup, and context injection are all handled transparently. The GitHub PR view
gives you a diff; `tackle` gives you a conversation.

Also useful for parallel branch work: spin up a second checkout without stashing
or switching branches.

> **Layout:** `tackle.zsh` (the script), `tests/` (bats suite + zsh smoke test —
> run `tests/run.sh`), and `SELL.md` (a shareable write-up). Source it from your
> shell rc:
>
> ```bash
> source ~/code-private/tackle/tackle.zsh
> ```
>
> `gwt` is a kept alias for `tackle` (the tool's original name), so old muscle
> memory still works.

## Usage

```
tackle <branch>                      # create worktree, install deps, launch agent
tackle <PR-number>                   # resolve branch from PR number, then same
tackle <PR-url>                      # resolve branch from PR URL, then same
tackle <branch> --no-agent           # create worktree + install deps, no agent
tackle <branch> -na                  # same as --no-agent
tackle --new <branch>                # create a NEW branch off HEAD, then same
tackle -n <branch> --base <ref>      # create a new branch off <ref> (short: -n / -b)
tackle <branch> --install            # force isolated install even if lockfile unchanged
tackle <branch> --no-deps            # skip all dependency handling (no symlink, no install)
tackle <branch> --no-env             # skip copying unversioned .env files into the worktree
tackle <branch> --no-config          # ignore any project tackle.toml for this run
tackle <branch> --trust              # pre-approve the project config's hook commands
tackle <branch> --time               # prefix each step with a [HH:MM:SS] timestamp
tackle <PR-url> --repo-check remote  # verify the URL's repo vs this checkout via gh
tackle <branch> --review             # launch agent with built-in "what changed?" prompt
tackle <branch> --prompt "message"   # launch agent with a custom initial prompt
tackle <branch> --add "message"      # add to prompt at {additive_prompt}, or append (stackable)
tackle <branch> --before "message"   # always prepend to the active prompt (stackable)
tackle <branch> --after "message"    # always append to the active prompt (stackable)
tackle --done                        # (from inside worktree) cd back + remove worktree
tackle --close                       # alias for --done
```

**PR resolution** — `tackle` accepts a branch name, PR number, or PR URL. When a
plain branch name is given, it automatically queries `gh pr list --head <branch>`
for open PRs:

- **1 PR found** — auto-resolved silently; PR number, title, and description are
  available as template variables
- **Multiple PRs** — `fzf` picker if available; otherwise an error listing the
  first 10 with ready-to-run `tackle <number>` hints
- **0 PRs found** — continues silently in branch-only mode (no PR context)

If `TACKLE_DIR_TEMPLATE` references `{pr_number}` or `{pr_title}` and no PR could
be resolved, tackle errors early rather than creating a misleadingly-named
worktree.

**Cross-repo guard** (`--repo-check` / `TACKLE_REPO_CHECK`) — a PR *URL* carries
its own `owner/repo`. If it names a different GitHub repo than the current
checkout, tackle would resolve the PR from the URL's repo but check out its head
branch *here* — a fetch failure at best, a silent same-named-branch mismatch at
worst. tackle catches this up front. Modes:

- `local` *(default)* — string-compare the URL against `git remote get-url
  origin`, normalized so scp-form (`git@github.com:o/r.git`) and https-form
  compare equal. Zero network.
- `remote` — ask `gh` for this checkout's canonical identity (handles renamed
  repos / non-`origin` remotes); falls back to the local check when `gh` is
  unavailable, unauthenticated, or offline.
- `off` — skip the guard.

Bare PR *numbers* carry no repo info and always skip the guard. Select per-run
with `--repo-check=<mode>` or persistently with `TACKLE_REPO_CHECK`.

**Dependency behaviour (language-agnostic):** tackle detects **every** package
manager present in the worktree — so multilingual repos are handled, not just the
first ecosystem found. For each one it makes a per-ecosystem decision driven by the
**lockfile**, which is the reliable, cross-language signal for "did deps change on
this branch" (never a comparison of the installed tree):

- **Reuse (symlink) — instant, zero-copy** — used only when *all* hold: the
  ecosystem's install dir is safely shareable by a plain root symlink (flat trees:
  npm/yarn; an in-project Python `.venv`), the lockfile(s) are byte-identical
  between the main repo and the worktree, and the main tree exists and is non-empty.
  The symlink is added to `.git/info/exclude` so git doesn't show it as untracked. A
  warning notes that dep mutations here (e.g. adding a package) affect the shared
  main-repo tree.
- **Install** — used otherwise (lockfile differs, or the layout isn't safely
  root-symlinkable). tackle runs the ecosystem's own install command, which is fast
  off its warm global cache (pnpm hardlinks, cargo/go/pip caches — no re-download).

The registry (add a package manager = add a row):

| Ecosystem | Detected by | Reuse dir | Root-symlinkable? | Install |
|---|---|---|---|---|
| pnpm | `pnpm-lock.yaml` | `node_modules` | No¹ | `pnpm i` |
| yarn | `yarn.lock` | `node_modules` | Yes | `yarn` |
| npm | `package-lock.json` / `package.json` | `node_modules` | Yes | `npm i` |
| Rust (cargo) | `Cargo.lock` | `target` | No² | `cargo fetch` |
| Go | `go.sum` | — | No² | `go mod download` |
| Python (uv) | `uv.lock`, or `pyproject.toml` `[tool.uv]` | `.venv` | Yes³ | `uv sync` |
| Python (poetry) | `poetry.lock`, or `pyproject.toml` `[tool.poetry]` | `.venv` | Yes³ | `poetry install` (in-project) |
| Python (pip) | `requirements.txt`, or a bare `pyproject.toml` | `.venv` | Yes³ | `python -m venv .venv && pip install …` |

¹ pnpm's strict/nested `node_modules` (one root + one per workspace package) isn't
fully materialised by a single root symlink, so pnpm defaults to install. Opt in to
symlink-reuse for known-flat layouts with `TACKLE_PNPM_SYMLINK=true`, or a
`node-linker=hoisted` line in `.npmrc` / `nodeLinker: hoisted` in
`pnpm-workspace.yaml`. ² cargo/go materialise from a shared global cache, so a
build in the worktree is already fast; there's no in-tree tree worth symlinking.

³ **Python** is detected most-specific first: `uv.lock` / `poetry.lock` (unambiguous)
→ a `pyproject.toml` `[tool.uv]` / `[tool.poetry]` declaration → `requirements.txt`
→ a bare `pyproject.toml`. This reads what the project *declares* rather than
tripping on a stray `requirements.txt` a uv/poetry repo also ships. Each install
command builds an **in-project `.venv`** so a fresh worktree is runnable (VS Code
finds the interpreter). A `.venv` is **reused by symlink** when the lockfile is
unchanged — but **never copied**: its scripts hard-code absolute interpreter paths,
so a copy would point back at the main repo. Repos whose venv is built by a *wrapper*
(Bazel, `make`, `nox`, …) fall outside detection — declare it in `tackle.toml`
(`symlink = [".venv"]` or a `setup` hook). Only an in-project `.venv` is handled; a
`venv/`-named or out-of-tree (default poetry) virtualenv isn't symlinked.

**Bazel workspaces** (`MODULE.bazel` / `WORKSPACE` / `WORKSPACE.bazel`) skip in-tree
dependency handling entirely: Bazel owns out-of-tree caches (e.g.
`~/Library/Caches/bazel`) and the in-tree `node_modules`/`.venv`/`target` are empty
by design, so there's nothing to reuse or install.

Pass `--install` to force a fully isolated install even when a symlink would be
valid, or `--no-deps` (or `TACKLE_DEPS=off`) to skip dependency handling entirely.
*Known limitation:* only **root-level** lockfiles are compared; nested per-package
workspace lockfiles are out of scope.

**`.env` copy behaviour:** `git worktree add` only materialises *tracked* files,
so gitignored secrets like `.env` would be missing and the app couldn't build or
run. After creating the worktree, tackle walks the main repo for files named
`.env` or `.env.*` — pruning package-manager/VCS dirs (`node_modules`, `.git`,
`vendor`, `.venv`, `venv`, `__pycache__`, `.tox`, `.pnpm-store`) for speed — and
copies each to its twin path in the worktree, creating parent directories as
needed. A `.env` buried deep in the tree (e.g. `apps/web/.env.local`) lands at
the same relative path; this filesystem walk also catches env files inside
gitignored directories, which a `git ls-files` approach would miss. Two skip
conditions apply. First, **the twin path already exists**: a tracked file has
already been checked out, so its presence means "leave it alone" — the copy is
strictly additive and never overwrites (this alone handles committed templates,
which are almost always tracked). Second, **template files are excluded by
name** — anything ending in `example`, `sample`, `template`, or `.dist` (so
`.env.example`, `.env.local-example`, `.env.sample`, `.env.template`,
`.env.dist`) is never copied, even if it happens to be untracked; these carry no
secrets and are meant to be committed. Unlike `node_modules` (symlinked), env
files are *copied*, so per-worktree tweaks don't leak back into the main
checkout. Each copied file is logged with its full destination path (followed by
a summary count), so you can see exactly which secrets landed in the worktree.
Disable per-run with `--no-env`, or persistently with `TACKLE_COPY_ENV=false`.

The worktree is created at `../<template>` (default: `<repo>_<branch>`). If the
branch doesn't exist locally it's fetched from origin first.

**`--new` / `-n` — start a new branch.** By default tackle only works with
branches that already exist locally or on `origin`. Pass `--new` to *create* the
branch as part of spinning up the worktree — the equivalent of
`git worktree add -b <branch>`:

```bash
tackle --new feature/my-idea            # new branch off HEAD, worktree, deps, agent
tackle -n feature/my-idea --base main   # new branch off main instead of HEAD
```

`--base` / `-b <ref>` picks what to branch from (default: `HEAD`); it's only
valid together with `--new`. In `--new` mode tackle skips all PR resolution (a
brand-new branch has no PR) and errors early if the branch already exists (drop
`--new` to check it out instead) or if `--base` names an unknown ref.

## Project config (`tackle.toml`)

Everything above is *personal* config (env vars + a co-located `.env`). A
**`tackle.toml`** committed at the repo root lets **a project declare how to bring
a worktree up to "running"** — extra files to materialise and setup/teardown
commands — so a fresh worktree lands ready to work, not just checked out. tackle
walks from your cwd up to the repo root to find it (so a monorepo subdir works),
and a gitignored **`tackle.local.toml`** deep-merges on top for personal
overrides (any key you set there replaces the base). A `tackle.json` /
`tackle.local.json` with the same keys works too, if you'd rather not rely on a
TOML parser (tackle uses Python's `tomllib`, 3.11+).

```toml
# tackle.toml — committed at the repo root
agent        = "claude"                       # per-project TACKLE_* defaults
dir_template = "{repo}_{branch}"
prompt       = "/pr-review"
deps         = "off"                          # skip dependency handling for this repo

copy    = ["config/local.json", "certs/dev.pem"]   # copied  main repo → worktree
symlink = ["big-assets"]                            # symlinked main repo → worktree

[hooks]
pre_create = ["docker compose config -q"]              # in the MAIN repo, before create; failure aborts
setup      = ["pnpm build", "docker compose up -d db"]  # in the WORKTREE, after create; failure warns
on_done    = ["docker compose down"]                    # in the worktree on --done, before removal
```

- **Keys.** `agent` / `dir_template` / `prompt` / `deps` map to the `TACKLE_*`
  knobs. `copy` / `symlink` bring files the `.env` copy won't (paths are relative
  to the repo root and must stay inside it — no absolute or `..` paths). `[hooks]`
  are shell commands run with `$TACKLE_MAIN`, `$TACKLE_WORKTREE`, and
  `$TACKLE_BRANCH` exported.
- **Precedence** (high → low): CLI flag → caller env var → `tackle.local` → base
  `tackle` → personal `.env` → built-in default. So a project can set its own
  agent/prompt, and you can still override per-invocation.
- **Hook failures:** `pre_create` is fatal (aborts before the worktree is
  created); `setup` and `on_done` warn and continue (the worktree already exists —
  better to let you fix it than tear it down).
- **Trust.** Because a committed file that runs commands is a code-execution
  surface, hook execution is gated by a **trust-on-first-use** prompt (à la
  `direnv allow`). The first time a repo's hooks would run, tackle shows them and
  asks `[o]nce / [a]lways / [s]kip`; `always` remembers the config's fingerprint
  under `TACKLE_STATE_DIR` (default `~/.local/state/tackle`). If the config later
  changes — including via the `tackle.local` layer or a `git pull` — the
  fingerprint mismatches and tackle **re-prompts with a diff of what changed**, so
  a slipped-in command can't run silently. Non-interactive runs (no TTY / closed
  stdin) **skip** hooks rather than auto-run or hang. Config-only keys (agent,
  template, `copy`/`symlink`) always apply — only command execution is gated.
- **Escape hatches:** `--no-config` (or `TACKLE_CONFIG=off`) ignores the file for
  a run; `--trust` pre-approves the hooks non-interactively (useful in scripts).
- **gitignore:** add `tackle.local.*` to your `.gitignore`. tackle never edits
  your git config, but it prints a one-line reminder if it loads a `tackle.local.*`
  that isn't ignored.

See [`tackle.example.toml`](tackle.example.toml) for a fully commented template.

**`--done` / `--close`** uses `git worktree list` to locate the main repo and cd
back to it. If there are uncommitted changes it lists them and prompts for
confirmation before discarding.

**`--review` flag** launches the agent with a built-in prompt that asks it to
summarise what changed, the goal of the changes, and anything worth a closer
look. PR description is injected as context when available — which includes plain
branch inputs that auto-resolve to a single PR. Degrades gracefully when no PR
context is found.

**`--prompt "message"` flag** sets a fully custom initial prompt, replacing
`--review` / `TACKLE_PROMPT`.

**`--add "message"` flag** places extra context at the `{additive_prompt}` marker
in the active prompt if one is present; otherwise appends to the end. Stackable —
pass multiple `--add` flags.

**`--before "message"` / `--after "message"` flags** wrap the fully-prepared
prompt from the outside — `--before` prepends, `--after` appends — regardless of
template markers. Stackable.

Assembly order: `[--before] [base + --add] [--after]`

```bash
# Built-in review with extra focus (--add becomes part of the base):
tackle 1234 --review --add "Focus on the authentication changes"

# Strict framing — preamble before, instruction after:
tackle 1234 --review --before "You are a senior security reviewer." --after "Keep it concise."

# Use {additive_prompt} in TACKLE_PROMPT to control where --add lands within the base:
export TACKLE_PROMPT="Review this PR.\n\n{additive_prompt}\n\n{pr_description}"
tackle 1234 --add "Flag anything security-related"
```

**Prompt template variables** — usable in `--prompt`, `--add`, `--before`,
`--after`, `--review`, and `TACKLE_PROMPT`:

| Variable | Value |
|---|---|
| `{branch}` | Resolved branch name |
| `{pr_number}` | PR number (PR input only, else empty) |
| `{pr_title}` | PR title (PR input only, else empty) |
| `{pr_description}` | PR body wrapped in `<pr_description>` XML tags (PR input only; only fetched when this variable is present in the prompt) |
| `{additive_prompt}` | Insertion point for `--add` content; if absent, `--add` appends to end |

The XML wrapping on `{pr_description}` signals to the model that it is external
data, not instructions — a basic prompt-injection defence.

Variables that resolve to empty (e.g. `{pr_description}` on a branch-only input)
are removed along with any surrounding lines that become blank or
punctuation-only, so the prompt stays clean regardless of input type.

**Note:** if `TACKLE_DIR_TEMPLATE` references `{pr_number}` or `{pr_title}`,
passing a plain branch name is an error — those placeholders would silently
produce a misleading directory name. Pass a PR number/URL instead, or update the
template.

```bash
export TACKLE_PROMPT="PR #{pr_number}: {pr_title}
{pr_description}
Summarize what changed and flag anything risky."
```

**`TACKLE_PROMPT` env var** sets a persistent default prompt used on every run.
`--prompt` and `--review` override it; `--add` always appends regardless of
source. For agents that support slash commands (e.g. Claude Code), you can invoke
a skill directly:

```bash
export TACKLE_PROMPT="/pr-review"
```

**`--time` flag** prefixes every output line with a `[HH:MM:SS]` wall-clock
timestamp.

**Output colours** (TTY only — stripped when piped): cyan for steps (`→`), green
for success (`✓`), yellow for warnings (`⚠`), red for errors (`✗`) on stderr.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `TACKLE_AGENT` | `claude` | Agent binary to launch |
| `TACKLE_DIR_TEMPLATE` | `{repo}_{branch}` | Worktree directory name template; placeholders: `{repo}` `{branch}` `{input}` |
| `TACKLE_PROMPT` | _(none)_ | Default prompt; overridden by `--prompt` / `--review`; extended by `--add` |
| `TACKLE_REPO_CHECK` | `local` | Cross-repo guard for PR URLs: `local` / `remote` / `off` |
| `TACKLE_DEPS` | `on` | Set `off` to skip all dependency handling (same as `--no-deps` on every run) |
| `TACKLE_PNPM_SYMLINK` | _(unset)_ | Set `true` to allow symlink-reuse of a pnpm `node_modules` (only safe for flat/hoisted pnpm layouts) |
| `TACKLE_ENV_FILE` | _(script dir)/.env_ | Path to an env file to source at startup; see below |
| `TACKLE_COPY_ENV` | `true` | Copy unversioned `.env`/`.env.*` files into the worktree; set `false` (or pass `--no-env`) to skip |
| `TACKLE_CONFIG` | `on` | Set `off` to ignore any project `tackle.toml` (same as `--no-config` on every run) |
| `TACKLE_STATE_DIR` | `~/.local/state/tackle` | Where the project-config trust store lives |

**Env file** — tackle auto-sources a `.env` in the same directory as
`tackle.zsh` if one exists. This is where you keep your personal defaults without
cluttering your shell rc. Copy `.env.example` to get started. Override the path
by setting `TACKLE_ENV_FILE` before sourcing the script:

```bash
# ~/.zshrc — point to a custom location (optional; omit to use the auto-detected default):
export TACKLE_ENV_FILE="$HOME/.config/tackle.env"
source ~/code-private/tackle/tackle.zsh
```

Caller-set env vars always win over the file, so one-shot overrides still work:

```bash
# In your .zshrc / .bashrc (or in the co-located .env):
export TACKLE_AGENT="cursor"
export TACKLE_DIR_TEMPLATE="{repo}-wt_{input}"
export TACKLE_PROMPT="/pr-review"

# One-shot override — wins over both shell rc and .env:
TACKLE_DIR_TEMPLATE="{repo}-wt_{input}" tackle 1234
```

## Example workflow

```bash
# Review a PR — agent starts with full PR context and "what changed?" prompt
tackle 1234 --review

# Tailor the review focus with --add:
tackle 1234 --review --add "Pay close attention to the API surface changes"

# When done, from inside the worktree:
tackle --close   # or tackle --done

# Work on a second ticket in parallel without leaving your current branch:
tackle feature/my-branch --no-agent
```

## Requirements

Compatible with bash and zsh — source from `.bashrc` or `.zshrc`. Requires `git`,
`python3`, and the configured agent binary in `PATH`. Dependency handling is
language-agnostic: the registry covers JS (pnpm/yarn/npm), Rust, Go, and Python,
plus Bazel-awareness (see *Dependency behaviour* above); whichever package
managers a repo uses must be on `PATH` for the install path to run. `gh` unlocks PR
resolution and the `remote` cross-repo check; `fzf` unlocks the multi-PR picker.

## Tests

```sh
./tests/run.sh          # bats suite (bash) + zsh smoke test
```

See `tests/README.md` for the suite layout and how the hermetic `gh`/agent stubs
work.

## License

[MIT](LICENSE) © Robert S.
