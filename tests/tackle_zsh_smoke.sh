#!/usr/bin/env zsh
# Cross-shell guard for tackle.
#
# The bats suite runs under bash, but tackle.zsh is sourced into *zsh* in real use.
# This smoke test exercises a create + --done cycle under zsh so a zsh-only
# regression (e.g. in the BASH_SOURCE/ZSH_VERSION detection block, or word
# splitting) can't slip past the bash suite. Exits non-zero on any failure.

set -e

SRC="${0:A:h}/../tackle.zsh"       # ${0:A:h} = absolute dir of this script (zsh)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Same isolation as the bats helpers: no real .env, stubbed agent + gh.
export TACKLE_ENV_FILE="$TMP/no.env"
export TACKLE_AGENT=true
export TACKLE_DIR_TEMPLATE='{repo}_{branch}'
export TACKLE_STATE_DIR="$TMP/state"     # isolate the project-config trust store
unset TACKLE_PROMPT TACKLE_COPY_ENV TACKLE_DEPS TACKLE_CONFIG 2>/dev/null || true

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "pr list" ]] && { printf '[]'; exit 0; }
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck source=/dev/null
source "$SRC"

git init -q "$TMP/repo"
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name  tester
git -C "$TMP/repo" commit -q --allow-empty -m init
git -C "$TMP/repo" branch feature

cd "$TMP/repo"
tackle feature --no-agent
[[ -d "$TMP/repo_feature" ]] || { print -r -- "FAIL: worktree not created"; exit 1 }

cd "$TMP/repo_feature/"
tackle --done
[[ ! -d "$TMP/repo_feature" ]] || { print -r -- "FAIL: worktree not removed"; exit 1 }

# ── dependency registry under real zsh ───────────────────────────────────────
# The registry loop leans on constructs that behave differently in zsh than bash
# (quoted array-by-value iteration, `IFS='|' read <<<`, `${//,/$'\n'}` splitting,
# and zsh's no-word-split-on-unquoted-$var). Exercise it via the hermetic symlink
# path (identical lockfile + non-empty main node_modules → symlink, no installer
# binary needed) so a zsh-only parsing regression can't slip past the bash suite.
git init -q "$TMP/deprepo"
git -C "$TMP/deprepo" config user.email test@example.com
git -C "$TMP/deprepo" config user.name  tester
printf '{}\n'      > "$TMP/deprepo/package.json"
printf 'lock-v1\n' > "$TMP/deprepo/package-lock.json"
git -C "$TMP/deprepo" add -A
git -C "$TMP/deprepo" commit -q -m deps
git -C "$TMP/deprepo" branch feature
mkdir -p "$TMP/deprepo/node_modules/foo"      # non-empty deps dir in main

cd "$TMP/deprepo"
tackle feature --no-agent
[[ -L "$TMP/deprepo_feature/node_modules" ]] \
  || { print -r -- "FAIL: node_modules not symlinked under zsh"; exit 1 }
[[ -d "$TMP/deprepo_feature/node_modules/foo" ]] \
  || { print -r -- "FAIL: symlinked node_modules does not resolve to main's"; exit 1 }

# ── project config under real zsh ────────────────────────────────────────────
# The config path leans on process substitution (`< <(_tackle_cfg_list ...)`),
# dynamic-scope assignment of $_cfg_run_hooks from a nested helper, and a python
# heredoc — all worth exercising under zsh, not just bash. Use --trust so the
# setup hook actually runs (no interactive prompt).
git init -q "$TMP/cfgrepo"
git -C "$TMP/cfgrepo" config user.email test@example.com
git -C "$TMP/cfgrepo" config user.name  tester
printf 'seed\n' > "$TMP/cfgrepo/seed.txt"
git -C "$TMP/cfgrepo" add -A
git -C "$TMP/cfgrepo" commit -q -m init
cat > "$TMP/cfgrepo/tackle.toml" <<'TOML'
copy = ["seed.txt"]
[hooks]
setup = ["echo ran > hook_ran.txt"]
TOML

cd "$TMP/cfgrepo"
tackle --new cfgbranch --no-agent --trust
[[ -f "$TMP/cfgrepo_cfgbranch/seed.txt" ]] \
  || { print -r -- "FAIL: config copy did not materialize under zsh"; exit 1 }
[[ -f "$TMP/cfgrepo_cfgbranch/hook_ran.txt" ]] \
  || { print -r -- "FAIL: config setup hook did not run under zsh"; exit 1 }

print -r -- "zsh smoke: OK (create + --done + dep-registry + project-config under zsh $ZSH_VERSION)"
