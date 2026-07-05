# tackle

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
tackle <branch> -n                   # same as --no-agent
tackle <branch> --install            # force full install even if lockfile unchanged
tackle <branch> --no-env             # skip copying unversioned .env files into the worktree
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

**Dependency install behaviour:** if the main repo has a `node_modules`
directory, it is symlinked into the worktree — near-instant regardless of whether
the lockfiles match. Two warnings are printed: one that dep mutations here affect
the main repo, and (if lockfiles differ) one that some deps may be missing. Pass
`--install` to force a full isolated install instead. The symlink is also
silently added to `.git/info/exclude` so git doesn't show it as an untracked
file.

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
| `TACKLE_ENV_FILE` | _(script dir)/.env_ | Path to an env file to source at startup; see below |
| `TACKLE_COPY_ENV` | `true` | Copy unversioned `.env`/`.env.*` files into the worktree; set `false` (or pass `--no-env`) to skip |

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
`python3`, and the configured agent binary in `PATH`; the package manager is
auto-detected (pnpm/yarn/npm, skipped in non-JS repos). `gh` unlocks PR
resolution and the `remote` cross-repo check; `fzf` unlocks the multi-PR picker.

## Tests

```sh
./tests/run.sh          # bats suite (bash) + zsh smoke test
```

See `tests/README.md` for the suite layout and how the hermetic `gh`/agent stubs
work.

## License

[MIT](LICENSE) © Robert S.
