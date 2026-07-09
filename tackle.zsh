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
#   tackle <branch> --install            # force full install even if lockfile unchanged
#   tackle <branch> --no-env             # skip copying unversioned .env files into the worktree
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
# When the main repo has node_modules, it is symlinked into the worktree (instant).
# Pass --install to force a real isolated install instead.
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
  local show_time=false
  # Copy unversioned .env files into the worktree by default; TACKLE_COPY_ENV=false
  # (env) or --no-env (per-run) disables it.
  local copy_env=true
  [[ "${TACKLE_COPY_ENV:-true}" == "true" ]] || copy_env=false
  local repo_check_flag=""  # --repo-check: local|remote|off (overrides TACKLE_REPO_CHECK)
  local prompt=""
  local prompt_extra=""   # --add   : placed at {additive_prompt} or appended
  local prompt_before=""  # --before: always prepended
  local prompt_after=""   # --after : always appended

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

  # Optional env file for centralised config. Resolution order:
  #   1. TACKLE_ENV_FILE env var (explicit override)
  #   2. .env in the same directory as tackle.zsh (auto-detected at source time)
  # Caller's shell env still wins — values set before calling tackle are captured
  # first so a one-shot TACKLE_AGENT=cursor tackle ... overrides the env file.
  local _env_agent="$TACKLE_AGENT"
  local _env_template="$TACKLE_DIR_TEMPLATE"
  local _env_prompt="$TACKLE_PROMPT"
  local _env_file="${TACKLE_ENV_FILE:-${_TACKLE_SCRIPT_DIR:+${_TACKLE_SCRIPT_DIR}/.env}}"
  if [[ -n "${_env_file:-}" && -f "$_env_file" ]]; then
    # shellcheck source=/dev/null
    source "$_env_file"
  fi
  [[ -n "$_env_agent" ]]    && TACKLE_AGENT="$_env_agent"
  [[ -n "$_env_template" ]] && TACKLE_DIR_TEMPLATE="$_env_template"
  [[ -n "$_env_prompt" ]]   && TACKLE_PROMPT="$_env_prompt"

  local agent="${TACKLE_AGENT:-claude}"
  local template="${TACKLE_DIR_TEMPLATE:-}"
  [[ -z "$template" ]] && template='{repo}_{branch}'
  prompt="${TACKLE_PROMPT:-}"

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
        shift ;;
      --prompt)
        if [[ -z "$2" || "$2" == -* ]]; then
          _tackle_err "--prompt requires a value"; return 2
        fi
        prompt="$2"; shift 2 ;;
      --prompt=*) prompt="${1#--prompt=}"; shift ;;
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

  local install_cmd="" lockfile=""
  if [[ -f "pnpm-lock.yaml" ]];      then install_cmd="pnpm i";  lockfile="pnpm-lock.yaml"
  elif [[ -f "yarn.lock" ]];         then install_cmd="yarn";     lockfile="yarn.lock"
  elif [[ -f "package-lock.json" ]]; then install_cmd="npm i";    lockfile="package-lock.json"
  elif [[ -f "package.json" ]];      then install_cmd="npm i"
  fi

  if [[ -n "$install_cmd" ]]; then
    if ! $force_install \
      && [[ -n "$lockfile" ]] \
      && [[ -d "$main_repo/node_modules" ]]; then
      ln -s "$main_repo/node_modules" ./node_modules
      # .gitignore typically has node_modules/ (trailing slash) which matches
      # real dirs but not symlinks. Write to the common gitdir's info/exclude
      # so git doesn't show the symlink as untracked.
      local common_gitdir
      common_gitdir=$(git rev-parse --git-common-dir)
      mkdir -p "$common_gitdir/info"
      grep -qxF "node_modules" "$common_gitdir/info/exclude" 2>/dev/null \
        || echo "node_modules" >> "$common_gitdir/info/exclude"
      _tackle_ok "node_modules symlinked from main repo"
      _tackle_warn "dep changes here (e.g. pnpm add) will affect the main repo — use --install to isolate"
      if ! diff -q "$main_repo/$lockfile" "./$lockfile" &>/dev/null; then
        _tackle_warn "lockfiles differ — some deps may be missing; run 'pnpm i' or re-run with --install if builds fail"
      fi
    else
      _tackle_log "installing dependencies ($install_cmd) ..."
      eval "$install_cmd" || return 1
    fi
  fi

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
