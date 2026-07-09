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
unset TACKLE_PROMPT TACKLE_COPY_ENV 2>/dev/null || true

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

print -r -- "zsh smoke: OK (create + --done + dep-registry under zsh $ZSH_VERSION)"
