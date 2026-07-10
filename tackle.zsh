#!/usr/bin/env bash
# tackle — git worktree add + install deps + optional AI agent session.
# Creates a sibling directory named by TACKLE_DIR_TEMPLATE, installs deps,
# and drops you into an agent session (pass -na/--no-agent to skip).
#
# Usage:
#   tackle <branch>                      # create worktree, install deps, launch agent
#   tackle <PR-number>                   # resolve branch from PR number, then same
#   tackle <PR-url>                      # resolve branch from PR URL, then same
#   tackle <branch> --no-agent           # create worktree + install deps, no agent
#   tackle <branch> -na                  # same as --no-agent
#   tackle --new <branch>                # create a NEW branch (off HEAD) + worktree
#   tackle -n <branch> --base <ref>      # create a new branch off <ref> (short forms)
#   tackle <branch> --install            # force isolated install even if lockfile unchanged
#   tackle <branch> --no-deps            # skip all dependency handling (no symlink, no install)
#   tackle <branch> --no-env             # skip copying unversioned .env files into the worktree
#   tackle <branch> --no-config          # ignore any project tackle.toml for this run
#   tackle <branch> --trust              # pre-approve the project config's hook commands
#   tackle <branch> --time               # prefix each step with a [HH:MM:SS] timestamp
#   tackle <PR-url> --repo-check remote  # verify the URL's repo vs this checkout via gh (see below)
#   tackle <branch> --review             # launch agent with built-in "what changed?" prompt
#   tackle <branch> --prompt "message"   # launch agent with a custom initial prompt
#   tackle <branch> --add "message"       # append to prompt, or substitute at {additive_prompt} (stackable)
#   tackle <branch> --before "message"   # always prepend to the active prompt (stackable)
#   tackle <branch> --after "message"    # always append to the active prompt (stackable)
#   tackle --done                        # cd back to main repo and remove this worktree
#   tackle --close                       # alias for --done
#   tackle --exit                        # alias for --done
#
# Dependency handling is per-ecosystem and language-agnostic (see the registry in
# _tackle_setup_deps). For each package manager detected in the worktree, tackle
# byte-compares the lockfile(s) against the main repo. It symlinks the main repo's
# install dir into the worktree ONLY when that dir is safely shareable by a plain
# root symlink (flat trees: npm/yarn; an in-project Python .venv) AND the lockfiles
# are identical AND the main tree is non-empty — instant, zero-copy. Otherwise it
# runs that ecosystem's own install command (fast off the warm global cache).
# pnpm defaults to install (its strict/nested node_modules isn't safely
# root-symlinkable); opt in with TACKLE_PNPM_SYMLINK=true or a node-linker=hoisted
# config. Python is detected most-specific first (uv.lock / poetry.lock, then a
# pyproject.toml [tool.uv]/[tool.poetry] declaration, then requirements.txt, then a
# bare pyproject); each install command builds an in-project .venv so a fresh
# worktree is runnable. A .venv is only ever reused by SYMLINK, never copied — its
# scripts bake in absolute interpreter paths, so a copy would point back at main.
# Bazel workspaces (MODULE.bazel/WORKSPACE) skip in-tree reuse entirely (Bazel owns
# out-of-tree caches; use a tackle.toml hook/symlink there). Pass --install to
# force an isolated install; --no-deps to skip entirely.
#
# Unversioned .env files in the main repo are copied into the worktree (git only
# checks out tracked files, so gitignored secrets would otherwise be missing).
# Template files (.env.example/.sample/.template/.dist) are never copied.
# Disable per-run with --no-env, or persistently with TACKLE_COPY_ENV=false.
#
# Configuration (env vars — set in your .zshrc / .bashrc, or in the .env file):
#   TACKLE_AGENT        — agent binary to launch (default: claude)
#   TACKLE_DIR_TEMPLATE — naming template for the worktree directory.
#                      Placeholders: {repo} {branch} {input}
#                      Default: {repo}_{branch}
#   TACKLE_PROMPT       — default initial prompt passed to the agent on every run.
#                      Supports the same template variables as --prompt (see below).
#                      Overridden by --prompt / --review flags.
#                      Tip: agents with slash commands can use a skill name:
#                        export TACKLE_PROMPT="/pr-review"
#   TACKLE_DEPS         — set to "off" to skip all dependency handling (default: on).
#                      Same as passing --no-deps on every run.
#   TACKLE_PNPM_SYMLINK — set to "true" to allow symlink-reuse of a pnpm node_modules
#                      (only safe for flat/hoisted pnpm layouts; default: install).
#   TACKLE_REPO_CHECK   — cross-repo guard for PR *URLs* (default: local).
#                      A PR URL carries its own owner/repo; if it names a
#                      different GitHub repo than the current checkout, tackle would
#                      resolve the PR from the URL's repo but check out its head
#                      branch here — a fetch failure at best, a silent same-named
#                      branch mismatch at worst. Modes (also via --repo-check):
#                        local  — string-compare the URL against `git remote
#                                 get-url origin`. Zero network. Default.
#                        remote — ask gh for this repo's canonical identity
#                                 (network round-trip); falls back to the local
#                                 check if gh is unavailable/unauthed/offline.
#                        off    — skip the guard.
#                      Bare PR numbers carry no repo info and always skip it.
#
# Env file (optional — keeps personal config out of your shell rc):
#   A .env file in the same directory as this script is auto-loaded if present.
#   Override the path with TACKLE_ENV_FILE=/path/to/your.env in your shell rc.
#   Caller-set env vars always win over the env file (one-shot overrides work).
#
# Project config (optional — travels with the repo; how to bring a worktree up):
#   A tackle.toml (or tackle.json) at the repo root — or a monorepo subdir; tackle
#   walks cwd up to the repo root to find it — declares per-project defaults and
#   setup steps. A gitignored tackle.local.toml deep-merges on top (local keys
#   replace base keys). Recognized keys:
#     agent / dir_template / prompt / deps   — per-project TACKLE_* defaults
#     copy    = ["path", ...]                — copy    main repo → worktree
#     symlink = ["path", ...]                — symlink main repo → worktree (git-excluded)
#     [hooks] pre_create / setup / on_done   — commands run before create / after
#                                               create (in the worktree) / on --done
#   Hooks get $TACKLE_MAIN, $TACKLE_WORKTREE, $TACKLE_BRANCH in their env.
#   Precedence: CLI flag > caller env > tackle.local > tackle (base) > .env > default.
#   Because a committed config runs commands, hook execution is gated by a
#   trust-on-first-use prompt (per repo; re-prompts if the config later changes).
#   Skip it with --no-config / TACKLE_CONFIG=off; pre-approve with --trust.
#   See tackle.example.toml for a fully commented template.
#
# Prompt template variables (usable in --prompt, --review, TACKLE_PROMPT):
#   {branch}            — resolved branch name
#   {pr_number}         — PR number (only when input is a PR number or URL)
#   {pr_title}          — PR title  (only when input is a PR number or URL)
#   {pr_description}    — PR body wrapped in <pr_description> tags, for injection
#                         safety. Only fetched from gh when this variable is present
#                         in the prompt. Empty when input is a branch name.
#   {additive_prompt}   — insertion point for --add content. If the template
#                         contains this variable, --add text is placed here;
#                         otherwise --add appends to the end.
#
# Example TACKLE_PROMPT using variables:
#   export TACKLE_PROMPT="PR #{pr_number}: {pr_title}
#   {pr_description}
#   Please summarize what changed and flag anything risky."
#
# Installation — save this file anywhere, then add one line to your shell rc:
#   source /path/to/tackle.zsh   # works in both .bashrc and .zshrc
#
# Compatible with bash and zsh.

# Capture the directory this script was sourced from — used to auto-detect a
# co-located .env file. Must run at the top level (not inside the function,
# where $0/$BASH_SOURCE would give different values).
_TACKLE_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]-}" ]]; then
  _TACKLE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
elif [[ -n "${ZSH_VERSION-}" ]]; then
  _TACKLE_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
fi

_tackle_impl() {
  local input=""
  local launch_agent=true
  local done_mode=false
  local new_mode=false     # --new: create the branch instead of resolving an existing one
  local base_ref=""        # --base: ref to branch from in --new mode (default HEAD)
  local force_install=false
  local no_deps=false      # --no-deps forces true; TACKLE_DEPS / config resolved later
  local no_config=false    # --no-config: ignore any project tackle.toml this run
  local force_trust=false  # --trust: pre-approve the project config's hooks
  local show_time=false
  # Copy unversioned .env files into the worktree by default; TACKLE_COPY_ENV=false
  # (env) or --no-env (per-run) disables it.
  local copy_env=true
  [[ "${TACKLE_COPY_ENV:-true}" == "true" ]] || copy_env=false
  local repo_check_flag=""  # --repo-check: local|remote|off (overrides TACKLE_REPO_CHECK)
  local prompt=""
  local prompt_cli_set=false  # true once --prompt/--review sets the base prompt
  local prompt_extra=""   # --add   : placed at {additive_prompt} or appended
  local prompt_before=""  # --before: always prepended
  local prompt_after=""   # --after : always appended
  # Project-config state, populated after arg-parse + git verification.
  local _cfg_json="" _cfg_dir="" _cfg_run_hooks=false

  # Logging helpers — colors only when the fd is a TTY.
  _tackle_ts() { $show_time && printf '[%s] ' "$(date '+%H:%M:%S')"; }

  _tackle_log() {  # cyan  — progress step
    if [ -t 1 ]; then printf '%s\033[36mtackle:\033[0m → %s\n' "$(_tackle_ts)" "$*"
    else printf '%stackle: → %s\n' "$(_tackle_ts)" "$*"; fi
  }
  _tackle_ok() {   # green — success / completion
    if [ -t 1 ]; then printf '%s\033[32mtackle:\033[0m ✓ %s\n' "$(_tackle_ts)" "$*"
    else printf '%stackle: ✓ %s\n' "$(_tackle_ts)" "$*"; fi
  }
  _tackle_warn() { # yellow — non-fatal warning
    if [ -t 1 ]; then printf '%s\033[33mtackle:\033[0m ⚠  %s\n' "$(_tackle_ts)" "$*"
    else printf '%stackle: ⚠  %s\n' "$(_tackle_ts)" "$*"; fi
  }
  _tackle_err() {  # red   — error (stderr)
    if [ -t 2 ]; then printf '%s\033[31mtackle:\033[0m ✗ %s\n' "$(_tackle_ts)" "$*" >&2
    else printf '%stackle: ✗ %s\n' "$(_tackle_ts)" "$*" >&2; fi
  }

  # ── dependency setup (registry-driven, language-agnostic) ───────────────────
  # Nested like the log helpers above so these close over $force_install /
  # $no_deps / the log helpers with no parameter plumbing. Called once, from the
  # worktree root, with the main worktree path as $1.
  #
  # The reliable, cross-language signal for "did deps change on this branch" is the
  # LOCKFILE (the resolved dependency graph) — never a comparison of the installed
  # tree. We symlink the main repo's install dir only when it's provably safe AND
  # free (flat tree + identical lockfile); otherwise we defer to the ecosystem's
  # own installer, which is fast off its warm global cache.

  # True when the pnpm layout is flat/hoisted, so a single root-symlink is safe.
  # Default (strict/nested pnpm) is install — see the header comment.
  _tackle_pnpm_is_hoisted() {
    [[ "${TACKLE_PNPM_SYMLINK:-}" == "true" ]] && return 0
    grep -qs 'node-linker[[:space:]]*=[[:space:]]*hoisted' .npmrc 2>/dev/null && return 0
    grep -qs 'nodeLinker:[[:space:]]*hoisted' pnpm-workspace.yaml 2>/dev/null && return 0
    return 1
  }

  # Decide whether symlink-reuse is valid for one ecosystem. All must hold:
  #   main, root_symlinkable(yes/no), reuse_dir, lockfiles(comma-separated)
  _tackle_can_symlink_reuse() {
    local main="$1" sym="$2" dir="$3" lfs="$4" lf
    $force_install                && return 1   # --install forces isolation
    [[ "$sym" == yes ]]           || return 1   # ecosystem must be root-symlinkable
    [[ -n "$dir" ]]               || return 1
    [[ ! -e "./$dir" ]]           || return 1   # never clobber a checked-out tree
    # reuse dir must exist AND be non-empty in main (an empty node_modules — the
    # Bazel/infrastructure case — is worthless to symlink; -d alone isn't enough).
    [[ -d "$main/$dir" && -n "$(ls -A "$main/$dir" 2>/dev/null)" ]] || return 1
    # every comparison lockfile must exist both sides and be byte-identical.
    while IFS= read -r lf; do
      [[ -z "$lf" ]] && continue
      [[ -f "$main/$lf" && -f "./$lf" ]] || return 1
      cmp -s "$main/$lf" "./$lf"         || return 1
    done <<< "${lfs//,/$'\n'}"
    return 0
  }

  # Symlink the main repo's install dir into the worktree and git-exclude it.
  # .gitignore patterns like `node_modules/` (trailing slash) match real dirs but
  # not symlinks, so we add the name to the common gitdir's info/exclude.
  _tackle_symlink_reuse() {
    local main="$1" dir="$2" common_gitdir
    ln -s "$main/$dir" "./$dir"
    common_gitdir=$(git rev-parse --git-common-dir)
    mkdir -p "$common_gitdir/info"
    grep -qxF "$dir" "$common_gitdir/info/exclude" 2>/dev/null \
      || echo "$dir" >> "$common_gitdir/info/exclude"
    _tackle_ok "$dir symlinked from main repo (lockfiles match)"
    _tackle_warn "dep changes here (e.g. adding packages) will affect the main repo — use --install to isolate"
  }

  # Registry marker test. A plain marker is a filename (does it exist?). A
  # "file@section" marker ALSO requires a TOML table header — e.g.
  # `pyproject.toml@tool\.uv` matches only when pyproject.toml declares [tool.uv]
  # (or a [tool.uv.*] subtable). This is what lets Python detection tell uv from
  # poetry from pip by what pyproject.toml actually declares, not merely which
  # files happen to exist (a uv/poetry repo often also ships a requirements.txt).
  _tackle_dep_marker_present() {
    local spec="$1" f sec
    case "$spec" in
      *@*) f="${spec%@*}"; sec="${spec#*@}"
           [[ -f "$f" ]] && grep -qE "^[[:space:]]*\[${sec}[].]" "$f" 2>/dev/null ;;
      *)   [[ -f "$spec" ]] ;;
    esac
  }

  _tackle_setup_deps() {              # $1 = main worktree path; cwd = new worktree
    local main_repo="$1"

    # Bazel owns out-of-tree caches (~/Library/Caches/bazel); the in-tree
    # node_modules/.venv/target are empty by design, so reuse/install here is
    # pointless or wrong. Short-circuit before touching the registry.
    if [[ -f MODULE.bazel || -f WORKSPACE || -f WORKSPACE.bazel ]]; then
      _tackle_log "Bazel workspace detected — skipping in-tree dependency reuse (Bazel manages caches out of tree)"
      return 0
    fi

    if $no_deps; then
      _tackle_log "dependency handling disabled (--no-deps / TACKLE_DEPS=off)"
      return 0
    fi

    # Registry: one '|'-delimited row per package-manager ecosystem. Fields:
    #   name | family | marker | lockfiles(comma) | reuse_dir | root_symlinkable | install_cmd
    # Rows scan top-to-bottom; the first match within a `family` wins (pnpm>yarn>npm
    # — they share node_modules), while different families are all handled so
    # multilingual repos install every ecosystem present. Add a manager = add a row.
    #
    # Python is detected most-specific first: uv.lock / poetry.lock (unambiguous),
    # then a pyproject.toml [tool.uv] / [tool.poetry] declaration (a "file@section"
    # marker), then requirements.txt, then a bare pyproject. A venv is reused by
    # SYMLINK (never copy — its scripts bake in absolute interpreter paths, so a
    # copy would point back at the main repo); the install commands each produce an
    # in-project .venv so a fresh worktree is actually runnable (VS Code, etc.).
    local _rows=(
      'pnpm|js|pnpm-lock.yaml|pnpm-lock.yaml|node_modules|no|pnpm i'
      'yarn|js|yarn.lock|yarn.lock|node_modules|yes|yarn'
      'npm|js|package-lock.json|package-lock.json|node_modules|yes|npm i'
      'npm|js|package.json|package.json|node_modules|yes|npm i'
      'cargo|rust|Cargo.lock|Cargo.lock|target|no|cargo fetch'
      'go|go|go.sum|go.sum||no|go mod download'
      'uv|python|uv.lock|uv.lock|.venv|yes|uv sync'
      'poetry|python|poetry.lock|poetry.lock|.venv|yes|POETRY_VIRTUALENVS_IN_PROJECT=true poetry install'
      'uv|python|pyproject.toml@tool\.uv|uv.lock|.venv|yes|uv sync'
      'poetry|python|pyproject.toml@tool\.poetry|poetry.lock|.venv|yes|POETRY_VIRTUALENVS_IN_PROJECT=true poetry install'
      'pip|python|requirements.txt|requirements.txt|.venv|yes|python3 -m venv .venv && .venv/bin/pip install -r requirements.txt'
      'pip|python|pyproject.toml|pyproject.toml|.venv|yes|python3 -m venv .venv && .venv/bin/pip install .'
    )

    local _handled=" " _row name family marker lockfiles reuse_dir symlinkable install_cmd
    for _row in "${_rows[@]}"; do
      IFS='|' read -r name family marker lockfiles reuse_dir symlinkable install_cmd <<< "$_row"
      _tackle_dep_marker_present "$marker" || continue      # not this ecosystem
      case "$_handled" in *" $family "*) continue ;; esac    # family already handled
      _handled="$_handled$family "

      # A flat/hoisted pnpm layout is safe to root-symlink; strict pnpm is not.
      [[ "$name" == pnpm ]] && _tackle_pnpm_is_hoisted && symlinkable=yes

      if _tackle_can_symlink_reuse "$main_repo" "$symlinkable" "$reuse_dir" "$lockfiles"; then
        _tackle_symlink_reuse "$main_repo" "$reuse_dir"
      else
        _tackle_log "installing $name dependencies ($install_cmd) ..."
        eval "$install_cmd" || return 1
      fi
    done
    return 0
  }

  # ── project config (tackle.toml / tackle.local.toml) ────────────────────────
  # A per-project file, committed at the repo root (or a monorepo subdir), that
  # declares how to bring a worktree up to "running": TACKLE_* defaults, extra
  # files to copy/symlink, and setup/teardown hook commands. A gitignored
  # tackle.local.{toml,json} deep-merges on top (local keys replace base keys).
  # All parsing/merging/validation lives in one python helper (python3 is already
  # a hard dep); the shell just consumes the normalized JSON it prints.
  _tackle_cfg_run() { python3 - "$@" <<'PY'
import sys, os, json

def _load_file(path):
    if path.endswith('.toml'):
        try:
            import tomllib as T
        except ModuleNotFoundError:
            try:
                import tomli as T
            except ModuleNotFoundError:
                sys.stderr.write("tackle: %s needs a TOML parser (Python 3.11+ tomllib or 'pip install tomli') — or use a tackle.json instead\n" % os.path.basename(path))
                sys.exit(3)
        with open(path, 'rb') as f:
            return T.load(f)
    with open(path) as f:
        return json.load(f)

def _deep_merge(b, o):
    if isinstance(b, dict) and isinstance(o, dict):
        r = dict(b)
        for k, v in o.items():
            r[k] = _deep_merge(b[k], v) if k in b else v
        return r
    return o

def _as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return [str(x) for x in v]
    return [str(v)]

_NAMES_BASE  = ('tackle.toml', 'tackle.json')
_NAMES_LOCAL = ('tackle.local.toml', 'tackle.local.json')

def _first_existing(cfgdir, names):
    for n in names:
        p = os.path.join(cfgdir, n)
        if os.path.isfile(p):
            return n, p
    return None, None

def _normalize(cfgdir):
    files = []
    bn, bp = _first_existing(cfgdir, _NAMES_BASE)
    base = {}
    if bp:
        base = _load_file(bp); files.append(bn)
    ln, lp = _first_existing(cfgdir, _NAMES_LOCAL)
    local = {}
    if lp:
        local = _load_file(lp); files.append(ln)
    merged = _deep_merge(base, local) if local else base
    if not isinstance(merged, dict):
        sys.stderr.write("tackle: config root must be a table/object\n"); sys.exit(4)
    hooks = merged.get('hooks') or {}
    if not isinstance(hooks, dict):
        sys.stderr.write("tackle: config [hooks] must be a table\n"); sys.exit(4)
    out = {
        'agent':        merged.get('agent'),
        'dir_template': merged.get('dir_template'),
        'prompt':       merged.get('prompt'),
        'deps':         merged.get('deps'),
        'copy':         _as_list(merged.get('copy')),
        'symlink':      _as_list(merged.get('symlink')),
        'hooks':        {k: _as_list(hooks.get(k)) for k in ('pre_create', 'setup', 'on_done')},
        'files':        files,
    }
    for key in ('copy', 'symlink'):
        for p in out[key]:
            if p.startswith('/') or p == '..' or p.startswith('../') or '/../' in p or p.endswith('/..'):
                sys.stderr.write("tackle: unsafe %s path %r in config (no absolute or parent-dir paths)\n" % (key, p)); sys.exit(4)
    if out['deps'] not in (None, 'on', 'off'):
        sys.stderr.write("tackle: config 'deps' must be \"on\" or \"off\"\n"); sys.exit(4)
    for s in ('agent', 'dir_template', 'prompt'):
        if out[s] is not None and not isinstance(out[s], str):
            sys.stderr.write("tackle: config '%s' must be a string\n" % s); sys.exit(4)
    return out

def _dig(d, key):
    for part in key.split('.'):
        d = d.get(part) if isinstance(d, dict) else None
    return d

mode = sys.argv[1]
if mode == 'discover':
    start = os.path.abspath(sys.argv[2])
    ceiling = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
    d = start
    while True:
        for n in _NAMES_BASE + _NAMES_LOCAL:
            if os.path.isfile(os.path.join(d, n)):
                print(d); sys.exit(0)
        if ceiling and d == ceiling:
            break
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    sys.exit(0)
elif mode == 'load':
    print(json.dumps(_normalize(sys.argv[2]), sort_keys=True))
elif mode == 'scalar':
    v = _dig(json.loads(sys.argv[2]), sys.argv[3])
    print('' if v is None else v)
elif mode == 'list':
    for x in (_dig(json.loads(sys.argv[2]), sys.argv[3]) or []):
        print(x)
elif mode == 'fingerprint':
    import hashlib
    print(hashlib.sha256(sys.argv[2].encode()).hexdigest())
elif mode == 'diff':
    import difflib
    a = json.dumps(json.loads(sys.argv[2]), indent=2, sort_keys=True).splitlines()
    b = json.dumps(json.loads(sys.argv[3]), indent=2, sort_keys=True).splitlines()
    for line in difflib.unified_diff(a, b, fromfile='last-trusted', tofile='current', lineterm=''):
        print(line)
else:
    sys.stderr.write("tackle: internal: unknown config mode %r\n" % mode); sys.exit(2)
PY
  }

  _tackle_cfg_scalar() { _tackle_cfg_run scalar "$_cfg_json" "$1"; }
  _tackle_cfg_list()   { _tackle_cfg_run list   "$_cfg_json" "$1"; }

  # True when the merged config declares any hook command.
  _tackle_cfg_has_hooks() {
    local n
    n=$( { _tackle_cfg_list hooks.pre_create
           _tackle_cfg_list hooks.setup
           _tackle_cfg_list hooks.on_done; } | grep -c . )
    [[ "$n" -gt 0 ]]
  }

  # Pretty-print the hook commands for the first-trust prompt.
  _tackle_cfg_show_hooks() {
    local ph cmd first
    for ph in pre_create setup on_done; do
      first=true
      while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        $first && { printf '    [%s]\n' "$ph"; first=false; }
        printf '      %s\n' "$cmd"
      done < <(_tackle_cfg_list "hooks.$ph")
    done
  }

  # Trust gate for command execution (TOFU with change detection, à la ssh known
  # hosts / direnv allow). Sets $_cfg_run_hooks in the caller's scope. The stored
  # baseline is the full normalized merged config, so a change in EITHER the base
  # or the local file re-triggers the prompt. Config-only keys always apply — only
  # command execution is gated here.
  _tackle_cfg_trust() {
    _cfg_run_hooks=false
    local statedir="${TACKLE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tackle}/trust"
    local key tf stored
    key=$(_tackle_cfg_run fingerprint "$_cfg_dir")
    tf="$statedir/$key"

    if $force_trust; then
      mkdir -p "$statedir" && printf '%s' "$_cfg_json" > "$tf"
      _cfg_run_hooks=true; return 0
    fi

    stored=""
    [[ -f "$tf" ]] && stored=$(cat "$tf")
    if [[ -n "$stored" && "$stored" == "$_cfg_json" ]]; then
      _cfg_run_hooks=true; return 0                    # already trusted, unchanged
    fi

    # Distinguish first-trust (neutral) from a changed-since-trusted config
    # (cautionary + a diff of what changed — this is what catches a command
    # slipped in via a git pull or the tackle.local layer).
    if [[ -z "$stored" ]]; then
      _tackle_warn "this project defines tackle setup commands — first time here. Review before trusting:"
      _tackle_cfg_show_hooks >&2
    else
      _tackle_warn "this project's tackle config CHANGED since you trusted it. What changed:"
      _tackle_cfg_run diff "$stored" "$_cfg_json" | sed 's/^/    /' >&2
    fi
    # read unconditionally: interactively this prompts; non-interactively (CI,
    # closed stdin) read hits EOF, ans stays empty, and we fall through to skip —
    # so hooks never auto-run and tackle never hangs. Pre-approve with --trust.
    printf 'tackle: trust these commands for %s? [o]nce / [a]lways / [s]kip (default: skip) ' "$_cfg_dir" >&2
    local ans=""; read -r ans || true
    case "$ans" in
      o|O|once)   _cfg_run_hooks=true ;;
      a|A|always) _cfg_run_hooks=true
                  mkdir -p "$statedir" && printf '%s' "$_cfg_json" > "$tf"
                  _tackle_ok "trusted — remembered for next time" ;;
      *)          _tackle_warn "skipped hooks (config-only settings still apply — approve with --trust)" ;;
    esac
    return 0
  }

  # Run one hook phase. Each command is eval'd in a subshell cd'd to $2 with
  # $TACKLE_MAIN / $TACKLE_WORKTREE / $TACKLE_BRANCH exported. pre_create failure
  # is fatal (abort before creating the worktree); setup/on_done failures warn and
  # continue (the worktree exists; better to let the user fix it than tear down).
  _tackle_run_hooks() {              # $1=phase  $2=rundir  $3=worktree-or-empty
    local phase="$1" rundir="$2" wt="$3" cmd
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      _tackle_log "hook[$phase] $cmd"
      ( cd "$rundir" && TACKLE_MAIN="$main_repo" TACKLE_WORKTREE="$wt" TACKLE_BRANCH="$branch" eval "$cmd" )
      if [[ $? -ne 0 ]]; then
        if [[ "$phase" == pre_create ]]; then
          _tackle_err "pre_create hook failed: $cmd"; return 1
        fi
        _tackle_warn "hook[$phase] failed (continuing): $cmd"
      fi
    done < <(_tackle_cfg_list "hooks.$phase")
    return 0
  }

  # Copy / symlink the config-declared paths from the main repo into the worktree.
  # Runs with cwd = worktree root. copy overwrites (explicit intent); symlink skips
  # a destination that already exists. Paths are validated (no absolute / no ..) by
  # the python loader, so they can only land inside the worktree.
  _tackle_cfg_materialize() {        # $1 = main repo path; cwd = worktree
    local main="$1" p src n=0
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      src="$main/$p"
      if [[ ! -e "$src" ]]; then _tackle_warn "config copy: '$p' not found in main repo — skipping"; continue; fi
      mkdir -p "$(dirname "$p")"
      if cp -Rp "$src" "$p" 2>/dev/null; then _tackle_log "copied $p from main repo"; n=$((n + 1)); fi
    done < <(_tackle_cfg_list copy)
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      src="$main/$p"
      if [[ ! -e "$src" ]]; then _tackle_warn "config symlink: '$p' not found in main repo — skipping"; continue; fi
      [[ -e "./$p" ]] && continue
      mkdir -p "$(dirname "$p")"
      if ln -s "$src" "./$p"; then _tackle_log "symlinked $p → main repo"; n=$((n + 1)); fi
    done < <(_tackle_cfg_list symlink)
    [[ "$n" -gt 0 ]] && _tackle_ok "materialized $n path(s) declared in config"
    return 0
  }

  # Capture caller-set env NOW, before the .env file or the project config can
  # touch it — a one-shot `TACKLE_AGENT=cursor tackle ...` must win over both.
  # The full precedence (caller env > project config > .env file > default) is
  # resolved after arg-parse + git verification, because it depends on
  # --no-config and on discovering the repo root. See "resolve effective config".
  local _env_agent="$TACKLE_AGENT"
  local _env_template="$TACKLE_DIR_TEMPLATE"
  local _env_prompt="$TACKLE_PROMPT"
  local _env_deps="$TACKLE_DEPS"
  local _env_deps_set=false; [[ -n "${TACKLE_DEPS+x}" ]] && _env_deps_set=true
  local agent template

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-agent|--no-claude|-na) launch_agent=false; shift ;;
      --new|-n)                  new_mode=true;       shift ;;
      --base|-b)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--base requires a value (a ref to branch from)"; return 2
        fi
        base_ref="$2"; shift 2 ;;
      --base=*)                  base_ref="${1#--base=}"; shift ;;
      --done|--close|--exit)     done_mode=true;      shift ;;
      --install)                 force_install=true;  shift ;;
      --no-deps)                 no_deps=true;        shift ;;
      --no-config)               no_config=true;      shift ;;
      --trust)                   force_trust=true;    shift ;;
      --no-env)                  copy_env=false;      shift ;;
      --time)                    show_time=true;      shift ;;
      --repo-check)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--repo-check requires a value (local|remote|off)"; return 2
        fi
        repo_check_flag="$2"; shift 2 ;;
      --repo-check=*)            repo_check_flag="${1#--repo-check=}"; shift ;;
      --review)
        prompt="Please summarize what has changed in this branch compared to the base branch. What is the goal of these changes, and are there any areas that look risky or worth a closer look?

{pr_description}"
        prompt_cli_set=true; shift ;;
      --prompt)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--prompt requires a value"; return 2
        fi
        prompt="$2"; prompt_cli_set=true; shift 2 ;;
      --prompt=*) prompt="${1#--prompt=}"; prompt_cli_set=true; shift ;;
      --add)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--add requires a value"; return 2
        fi
        [[ -n "$prompt_extra" ]] && prompt_extra="${prompt_extra}
"
        prompt_extra="${prompt_extra}$2"; shift 2 ;;
      --add=*)
        local _add_val="${1#--add=}"
        [[ -n "$prompt_extra" ]] && prompt_extra="${prompt_extra}
"
        prompt_extra="${prompt_extra}${_add_val}"; shift ;;
      --before)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--before requires a value"; return 2
        fi
        [[ -n "$prompt_before" ]] && prompt_before="${prompt_before}
"
        prompt_before="${prompt_before}$2"; shift 2 ;;
      --before=*)
        local _before_val="${1#--before=}"
        [[ -n "$prompt_before" ]] && prompt_before="${prompt_before}
"
        prompt_before="${prompt_before}${_before_val}"; shift ;;
      --after)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--after requires a value"; return 2
        fi
        [[ -n "$prompt_after" ]] && prompt_after="${prompt_after}
"
        prompt_after="${prompt_after}$2"; shift 2 ;;
      --after=*)
        local _after_val="${1#--after=}"
        [[ -n "$prompt_after" ]] && prompt_after="${prompt_after}
"
        prompt_after="${prompt_after}${_after_val}"; shift ;;
      -*)  _tackle_err "unknown option: $1"; return 2 ;;
      *)   input="$1"; shift ;;
    esac
  done

  # --done: find main worktree via git, cd back, and remove this worktree.
  # Resolve the *current worktree's* top-level (not $PWD) so --done works from
  # any subfolder: `git worktree remove` only accepts a worktree's root path,
  # and git rev-parse traverses up to it for us.
  if $done_mode; then
    local worktree_path
    worktree_path=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$worktree_path" ]]; then
      _tackle_err "--done: not inside a git repository"
      return 1
    fi
    local main_repo
    main_repo=$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
    if [[ -z "$main_repo" || "$main_repo" == "$worktree_path" ]]; then
      _tackle_err "--done: not inside a linked worktree (already at main?)"
      return 1
    fi
    # Use --untracked-files=no to skip the slow untracked scan on large repos.
    local uncommitted
    uncommitted=$(git -C "$worktree_path" status --porcelain --untracked-files=no 2>/dev/null)
    if [[ -n "$uncommitted" ]]; then
      _tackle_err "worktree has uncommitted changes:"
      echo "$uncommitted" | sed 's/^/  /' >&2
      printf "tackle: discard and remove anyway? [y/N] "
      local answer
      read -r answer
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        _tackle_err "aborted — worktree kept at $worktree_path"
        return 1
      fi
    fi

    # Project config: run the on_done teardown hook (in the worktree) before
    # removal — e.g. `docker compose down` to free ports. Honors --no-config and
    # the trust gate; a config load error never blocks teardown.
    if ! $no_config && [[ "${TACKLE_CONFIG:-on}" != "off" ]]; then
      local branch
      branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
      _cfg_dir=$(_tackle_cfg_run discover "$PWD" "$worktree_path")
      if [[ -n "$_cfg_dir" ]]; then
        _cfg_json=$(_tackle_cfg_run load "$_cfg_dir") || _cfg_json=""
        if [[ -n "$_cfg_json" ]] && [[ "$(_tackle_cfg_list hooks.on_done | grep -c .)" -gt 0 ]]; then
          _tackle_cfg_trust
          $_cfg_run_hooks && _tackle_run_hooks on_done "$worktree_path" "$worktree_path"
        fi
      fi
    fi

    cd "$main_repo" || return 1
    git worktree remove --force "$worktree_path" || {
      _tackle_err "failed to remove worktree at $worktree_path"
      return 1
    }
    _tackle_ok "back in $main_repo"
    return 0
  fi

  # Create mode
  if [[ -z "$input" ]]; then
    echo "usage: tackle <branch|PR-number|PR-url> [--no-agent|-na] [--install] [--time]" >&2
    echo "       tackle --new|-n <branch> [--base|-b <ref>]  (create a new branch)" >&2
    echo "       tackle ... [--no-config] [--trust]          (project tackle.toml)" >&2
    echo "       tackle --done (inside a worktree)" >&2
    return 2
  fi

  # --base only makes sense when creating a branch.
  if [[ -n "$base_ref" ]] && ! $new_mode; then
    _tackle_err "--base is only valid with --new"
    return 2
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    _tackle_err "not inside a git repository"
    return 1
  fi

  # ── resolve effective config: caller env > project config > .env file > default
  # Personal .env file first (lowest project-agnostic layer) — it may set TACKLE_*.
  local _env_file="${TACKLE_ENV_FILE:-${_TACKLE_SCRIPT_DIR:+${_TACKLE_SCRIPT_DIR}/.env}}"
  if [[ -n "${_env_file:-}" && -f "$_env_file" ]]; then
    # shellcheck source=/dev/null
    source "$_env_file"
  fi

  # Project config: discover tackle.{toml,json} (+ .local) walking cwd → repo root,
  # then load + merge. Skipped by --no-config / TACKLE_CONFIG=off.
  if ! $no_config && [[ "${TACKLE_CONFIG:-on}" != "off" ]]; then
    local _cfg_ceiling; _cfg_ceiling=$(git rev-parse --show-toplevel 2>/dev/null)
    _cfg_dir=$(_tackle_cfg_run discover "$PWD" "$_cfg_ceiling")
    if [[ -n "$_cfg_dir" ]]; then
      _cfg_json=$(_tackle_cfg_run load "$_cfg_dir") || return 1
      _tackle_log "loaded project config from $_cfg_dir"
      # Advisory only (never mutate git): nudge if a tackle.local.* isn't ignored.
      local _lf
      for _lf in tackle.local.toml tackle.local.json; do
        if [[ -f "$_cfg_dir/$_lf" ]] && ! git -C "$_cfg_dir" check-ignore -q "$_lf" 2>/dev/null; then
          _tackle_warn "$_lf isn't gitignored — add 'tackle.local.*' to .gitignore to keep it out of commits"
        fi
      done
    fi
  fi

  # Apply TACKLE_* precedence now that .env + project config are both known.
  local _cfg_agent="" _cfg_template="" _cfg_prompt="" _cfg_deps=""
  if [[ -n "$_cfg_json" ]]; then
    _cfg_agent=$(_tackle_cfg_scalar agent)
    _cfg_template=$(_tackle_cfg_scalar dir_template)
    _cfg_prompt=$(_tackle_cfg_scalar prompt)
    _cfg_deps=$(_tackle_cfg_scalar deps)
  fi
  agent="${_env_agent:-${_cfg_agent:-${TACKLE_AGENT:-claude}}}"
  template="${_env_template:-${_cfg_template:-${TACKLE_DIR_TEMPLATE:-}}}"
  [[ -z "$template" ]] && template='{repo}_{branch}'
  if ! $prompt_cli_set; then
    prompt="${_env_prompt:-${_cfg_prompt:-${TACKLE_PROMPT:-}}}"
  fi
  # deps: --no-deps (already forced) > caller TACKLE_DEPS > config.deps > .env > on
  if ! $no_deps; then
    if $_env_deps_set; then
      [[ "$_env_deps" == off ]] && no_deps=true
    elif [[ -n "$_cfg_deps" ]]; then
      [[ "$_cfg_deps" == off ]] && no_deps=true
    elif [[ "${TACKLE_DEPS:-on}" == off ]]; then
      no_deps=true
    fi
  fi

  local branch="$input"
  local pr_number="" pr_title="" pr_body=""

  # --new: validate up front so we fail before building the worktree path.
  if $new_mode; then
    if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
      _tackle_err "branch '$branch' already exists — drop --new to check it out"
      return 1
    fi
    if [[ -n "$base_ref" ]] && ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
      _tackle_err "--base '$base_ref' is not a valid ref"
      return 1
    fi
  fi

  # Resolve PR number or URL → branch name via gh CLI.
  # Always fetch number + title (cheap). Only add body to the request when
  # {pr_description} is actually referenced in the prompt — avoids fetching
  # potentially large PR bodies that won't be used.
  if ! $new_mode && { [[ "$branch" =~ ^[0-9]+$ ]] || [[ "$branch" == *"/pull/"* ]]; }; then
    # A PR *URL* carries its own owner/repo. If it points at a different GitHub
    # repo than this checkout, resolving it here is wrong: we'd pull the PR's
    # metadata from the URL's repo but then try to check out its head branch in
    # *this* repo — which fails on the fetch, or (worse) silently grabs a
    # same-named local branch and pairs it with the other repo's PR context.
    # Catch the mismatch up front. Bare PR *numbers* carry no repo info, so
    # they're inherently "this repo" and skip the guard. Three modes:
    #   local  (default) — string-compare the URL against `git remote get-url
    #                      origin`. Zero network.
    #   remote           — ask gh for this repo's canonical identity (a network
    #                      round-trip), falling back to the local check when gh
    #                      is unavailable / unauthenticated / offline.
    #   off              — skip the guard entirely.
    # Select via --repo-check=<mode> or TACKLE_REPO_CHECK; default is local.
    if [[ "$input" == *"/pull/"* ]]; then
      local _repo_check="${repo_check_flag:-${TACKLE_REPO_CHECK:-local}}"
      case "$_repo_check" in
        local|remote|off) ;;
        *) _tackle_err "invalid repo-check mode '$_repo_check' (want: local|remote|off)"; return 2 ;;
      esac
      if [[ "$_repo_check" != "off" ]]; then
        # Resolve this checkout's identity URL. remote mode asks gh (authoritative,
        # handles renamed repos / non-origin remotes); it falls back to the local
        # origin string if gh can't answer.
        local _current_url=""
        if [[ "$_repo_check" == "remote" ]] && command -v gh &>/dev/null; then
          _current_url=$(gh repo view --json url -q .url 2>/dev/null)
        fi
        if [[ -z "$_current_url" ]]; then
          [[ "$_repo_check" == "remote" ]] && \
            _tackle_warn "repo-check=remote: gh lookup unavailable — falling back to local origin check"
          _current_url=$(git remote get-url origin 2>/dev/null)
        fi
        if [[ -n "$_current_url" ]]; then
          # Normalize both to a lowercase host/owner/repo key so scp-form
          # (git@host:owner/repo.git) and https-form compare equal.
          local _repo_cmp
          _repo_cmp=$(python3 -c "
import re, sys
def key(u):
    u = u.strip()
    u = re.sub(r'^[a-zA-Z][a-zA-Z0-9+.-]*://', '', u)  # strip scheme
    u = re.sub(r'^[^@/]+@', '', u)                      # strip user@
    u = u.replace(':', '/', 1)                          # scp host:owner → host/owner
    u = re.sub(r'\.git\$', '', u)                       # strip trailing .git
    parts = [p for p in u.split('/') if p]
    return '/'.join(parts[:3]).lower() if len(parts) >= 3 else ''
url_key, cur_key = key(sys.argv[1]), key(sys.argv[2])
if not url_key or not cur_key:
    print('UNKNOWN')
elif url_key == cur_key:
    print('MATCH')
else:
    print('MISMATCH\t{}\t{}'.format(url_key, cur_key))
" "$input" "$_current_url" 2>/dev/null)
          if [[ "$_repo_cmp" == MISMATCH* ]]; then
            local _url_key _cur_key
            _url_key=$(printf '%s' "$_repo_cmp" | cut -f2)
            _cur_key=$(printf '%s' "$_repo_cmp" | cut -f3)
            _tackle_err "PR belongs to ${_url_key}, but you're in ${_cur_key}."
            _tackle_err "cd into that repo (or clone it) first, then re-run with the PR URL or number."
            return 1
          fi
        fi
      fi
    fi
    if ! command -v gh &>/dev/null; then
      _tackle_err "gh CLI is required to resolve PR numbers/URLs (brew install gh)"
      return 1
    fi
    _tackle_log "resolving PR $input ..."
    local gh_fields="headRefName,number,title"
    [[ "$prompt" == *"{pr_description}"* ]] && gh_fields="$gh_fields,body"
    local pr_json
    pr_json=$(gh pr view "$input" --json "$gh_fields" 2>/dev/null)
    if [[ -z "$pr_json" ]]; then
      _tackle_err "could not resolve PR '$input' — is this a valid PR number or URL?"
      return 1
    fi
    local resolved
    resolved=$(printf '%s' "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['headRefName'])")
    pr_number=$(printf '%s' "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('number','') or '')")
    pr_title=$(printf '%s' "$pr_json"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title','') or '')")
    if [[ "$prompt" == *"{pr_description}"* ]]; then
      pr_body=$(printf '%s' "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('body','') or '')")
    fi
    _tackle_ok "branch: $resolved"
    branch="$resolved"
  fi

  # For plain branch inputs (no PR resolved yet), try to auto-resolve an open
  # PR via gh CLI. Handles 1, multiple, and 0 results differently.
  if ! $new_mode && [[ -z "$pr_number" ]] && command -v gh &>/dev/null; then
    local _auto_fields="number,title"
    [[ "$prompt" == *"{pr_description}"* ]] && _auto_fields="$_auto_fields,body"
    local _pr_list
    _pr_list=$(gh pr list --head "$branch" --json "$_auto_fields" --limit 11 2>/dev/null)
    local _pr_count
    _pr_count=$(printf '%s' "$_pr_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

    if [[ "$_pr_count" -eq 1 ]]; then
      pr_number=$(printf '%s' "$_pr_list" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['number'])")
      pr_title=$(printf '%s' "$_pr_list"  | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('title','') or '')")
      if [[ "$prompt" == *"{pr_description}"* ]]; then
        pr_body=$(printf '%s' "$_pr_list" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('body','') or '')")
      fi
      _tackle_ok "auto-resolved to PR #$pr_number: $pr_title"

    elif [[ "$_pr_count" -gt 1 ]]; then
      if command -v fzf &>/dev/null; then
        local _fzf_input
        _fzf_input=$(printf '%s' "$_pr_list" | python3 -c "
import sys, json
for p in json.load(sys.stdin)[:10]:
    print('#{}\t{}'.format(p['number'], p['title']))
")
        local _selected
        _selected=$(printf '%s' "$_fzf_input" | fzf --prompt="Select PR > " --height=40% --reverse --delimiter=$'\t' --with-nth=1,2)
        if [[ -n "$_selected" ]]; then
          local _sel_num
          _sel_num=$(printf '%s' "$_selected" | cut -f1 | tr -d '#')
          local _sel_fields="number,title"
          [[ "$prompt" == *"{pr_description}"* ]] && _sel_fields="$_sel_fields,body"
          local _sel_json
          _sel_json=$(gh pr view "$_sel_num" --json "$_sel_fields" 2>/dev/null)
          pr_number=$(printf '%s' "$_sel_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
          pr_title=$(printf '%s' "$_sel_json"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('title','') or '')")
          if [[ "$prompt" == *"{pr_description}"* ]]; then
            pr_body=$(printf '%s' "$_sel_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('body','') or '')")
          fi
          _tackle_ok "using PR #$pr_number: $pr_title"
        else
          _tackle_warn "no PR selected — continuing without PR context"
        fi
      else
        _tackle_err "branch '$branch' has multiple open PRs — re-run with the PR number:"
        printf '%s' "$_pr_list" | python3 -c "
import sys, json
for p in json.load(sys.stdin)[:10]:
    print('  tackle {}  # {}'.format(p['number'], p['title']))
" >&2
        return 1
      fi
    fi
    # _pr_count == 0: no open PRs — continue silently as branch-only
  fi

  # If the template references PR variables but no PR was resolved, the
  # placeholders would silently become empty → misleading or duplicate name.
  if [[ -z "$pr_number" ]]; then
    local _pr_vars_in_template=""
    [[ "$template" == *"{pr_number}"* ]] && _pr_vars_in_template="${_pr_vars_in_template}{pr_number} "
    [[ "$template" == *"{pr_title}"* ]]  && _pr_vars_in_template="${_pr_vars_in_template}{pr_title} "
    if [[ -n "$_pr_vars_in_template" ]]; then
      _tackle_err "template uses ${_pr_vars_in_template% } but no open PR found for branch '$branch'"
      _tackle_err "pass a PR number/URL directly, or update TACKLE_DIR_TEMPLATE to remove PR-specific variables"
      return 1
    fi
  fi

  # Bail early if the branch is already checked out in any worktree
  local already_at
  already_at=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " b { print path }
  ')
  if [[ -n "$already_at" ]]; then
    _tackle_err "branch '$branch' is already checked out at: $already_at"
    return 1
  fi

  # Build worktree directory name from the template.
  # Always derive {repo} from the main worktree so running tackle from inside
  # a linked worktree produces a clean name rather than a chained one.
  local main_repo
  main_repo=$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
  local repo
  repo="$(basename "$main_repo")"

  # Sanitize placeholder values for directory names:
  #   {branch} — replace / (feature/foo → feature-foo) to avoid nested dirs
  #   {input}  — if a PR URL, extract just the PR number
  local safe_branch="${branch//\//-}"
  local safe_input
  if [[ "$input" == *"/pull/"* ]]; then
    safe_input=$(printf '%s' "$input" | sed 's|.*/pull/\([0-9]*\).*|\1|')
  else
    safe_input="${input//\//-}"
  fi

  local wt_name
  wt_name=$(python3 -c "
import re, sys
t = sys.argv[1]
t = t.replace('{repo}',   sys.argv[2])
t = t.replace('{branch}', sys.argv[3])
t = t.replace('{input}',  sys.argv[4])
# Collapse consecutive separators and strip leading/trailing ones that
# result from an empty substitution (e.g. {repo}_{pr_number} with no PR).
t = re.sub(r'[-_]{2,}', '_', t)
t = t.strip('-_')
print(t, end='')
" "$template" "$repo" "$safe_branch" "$safe_input")
  if [[ "$wt_name" == *"{"* || -z "$wt_name" ]]; then
    _tackle_err "template produced an invalid worktree name: '${wt_name:-<empty>}'"
    _tackle_err "  template: $template  |  repo=$repo  branch=$safe_branch  input=$safe_input"
    return 1
  fi

  local worktree_path
  worktree_path="$(dirname "$main_repo")/$wt_name"

  if [[ -e "$worktree_path" ]]; then
    _tackle_err "target directory already exists: $worktree_path"
    _tackle_err "remove it first, or adjust TACKLE_DIR_TEMPLATE to produce a unique name"
    return 1
  fi

  # Resolve trust once (covers every hook phase) and run pre_create BEFORE the
  # worktree exists — a failing pre_create aborts cleanly with nothing created.
  if [[ -n "$_cfg_json" ]] && _tackle_cfg_has_hooks; then
    _tackle_cfg_trust
    if $_cfg_run_hooks; then
      _tackle_run_hooks pre_create "$main_repo" "" || return 1
    fi
  fi

  if $new_mode; then
    local _base="${base_ref:-HEAD}"
    _tackle_log "creating worktree at $worktree_path (new branch '$branch' from $_base) ..."
    git worktree add -b "$branch" "$worktree_path" "$_base" || return 1
  else
    if ! git rev-parse --verify "$branch" &>/dev/null; then
      _tackle_log "fetching $branch from origin ..."
      git fetch origin "$branch":"$branch" || {
        _tackle_err "could not fetch branch '$branch' from origin"
        return 1
      }
    fi

    _tackle_log "creating worktree at $worktree_path ..."
    git worktree add "$worktree_path" "$branch" || return 1
  fi

  cd "$worktree_path" || return 1

  _tackle_setup_deps "$main_repo" || return 1

  # Copy unversioned .env files from the main repo into the worktree.
  # git worktree add only materialises *tracked* files, so any gitignored .env
  # (the common case — secrets) is missing and the app can't build/run. We walk
  # the real tree rather than trusting gitignore alone: env files can sit deep in
  # the structure, and when a whole dir is ignored `git ls-files` reports the dir,
  # not the .env inside it — a filesystem scan catches them wherever they are.
  # Package-manager / VCS dirs are pruned for speed. A file already present in
  # the worktree was tracked (checked out) — i.e. versioned — so we skip it; that
  # existence check IS the not-versioned test, and it never clobbers the checkout.
  # We COPY, not symlink (unlike node_modules): env files are tiny and often
  # tweaked per-worktree, and a copy keeps those edits out of main.
  # Opt out with TACKLE_COPY_ENV=false (persistent) or --no-env (per-run).
  if $copy_env; then
    local _env_copied=0 _envf _rel
    while IFS= read -r _envf; do
      [[ -z "$_envf" ]] && continue
      # Skip template/example env files: they carry no secrets, are meant to be
      # committed, and copying a stray untracked one just adds noise. Matched on
      # the trailing keyword so .env.example, .env.local-example, .env.sample,
      # .env.template, and .env.dist are all caught.
      case "${_envf##*/}" in
        *example|*sample|*template|*.dist) continue ;;
      esac
      _rel="${_envf#"$main_repo"/}"
      [[ -e "$_rel" ]] && continue     # already in worktree ⇒ versioned; skip
      mkdir -p "$(dirname "$_rel")"
      if cp -p "$_envf" "$_rel"; then
        _env_copied=$((_env_copied + 1))
        _tackle_log "copied .env → $worktree_path/$_rel"
      fi
    done < <(find "$main_repo" \
               -type d \( -name .git -o -name node_modules -o -name vendor \
                          -o -name .venv -o -name venv -o -name __pycache__ \
                          -o -name .tox -o -name .pnpm-store \) -prune \
               -o -type f \( -name '.env' -o -name '.env.*' \) -print 2>/dev/null)
    if [[ "$_env_copied" -gt 0 ]]; then
      _tackle_ok "copied $_env_copied unversioned .env file(s) from main repo"
    fi
  fi

  # Project config: materialize declared copy/symlink paths, then run the setup
  # hook (in the worktree). Materialize is ungated (it only moves files within
  # your own checkout); setup is command execution, so it honors the trust gate.
  if [[ -n "$_cfg_json" ]]; then
    _tackle_cfg_materialize "$main_repo"
    if $_cfg_run_hooks; then
      _tackle_run_hooks setup "$worktree_path" "$worktree_path"
    fi
  fi

  _tackle_ok "worktree ready — $worktree_path"

  if $launch_agent; then
    # Step 1 — incorporate --add into the base prompt.
    # Substituted at {additive_prompt} if present, otherwise appended.
    local additive_subst=""
    if [[ -n "$prompt_extra" ]]; then
      if [[ "$prompt" == *"{additive_prompt}"* ]]; then
        additive_subst="$prompt_extra"
      else
        prompt="${prompt}${prompt:+

}${prompt_extra}"
      fi
    fi
    # Step 2 — wrap the prepared prompt with --before / --after.
    if [[ -n "$prompt_before" ]]; then
      prompt="${prompt_before}${prompt:+

}${prompt}"
    fi
    if [[ -n "$prompt_after" ]]; then
      prompt="${prompt}${prompt:+

}${prompt_after}"
    fi

    if [[ -n "$prompt" ]]; then
      # Substitute prompt template variables using python3 (literal replacement,
      # no regex surprises). {pr_description} is XML-wrapped so the model treats
      # it as external data rather than instructions — basic injection defence.
      local pr_desc_block=""
      if [[ -n "$pr_title" || -n "$pr_body" ]]; then
        pr_desc_block="<pr_description>
# $pr_title

$pr_body
</pr_description>"
      fi
      prompt=$(python3 -c "
import re, sys
t = sys.argv[1]
t = t.replace('{branch}',           sys.argv[2])
t = t.replace('{pr_number}',        sys.argv[3])
t = t.replace('{pr_title}',         sys.argv[4])
t = t.replace('{pr_description}',   sys.argv[5])
t = t.replace('{additive_prompt}',  sys.argv[6])
# Drop lines that became empty (or only punctuation/whitespace) after an empty
# substitution, then collapse runs of blank lines to a single blank line.
lines = [l for l in t.splitlines() if re.search(r'[A-Za-z0-9]', l)]
t = '\n'.join(lines)
t = re.sub(r'\n{3,}', '\n\n', t)
print(t.strip())
" "$prompt" "$branch" "$pr_number" "$pr_title" "$pr_desc_block" "$additive_subst")
      _tackle_log "launching $agent with initial prompt ..."
      $agent "$prompt"
    else
      _tackle_log "launching $agent ..."
      $agent
    fi
  fi
}

# Remove any existing alias so our function takes precedence — zsh expands
# aliases before invoking functions, so an alias (e.g. a `gwt = worktree` git
# alias exposed to the shell) would otherwise silently win.
unalias tackle 2>/dev/null || true
function tackle { _tackle_impl "$@"; }

# `gwt` is kept as a short alias — the tool was named gwt before it moved to its
# own repo, so muscle memory still reaches for it. Same implementation.
unalias gwt 2>/dev/null || true
function gwt { _tackle_impl "$@"; }
