#!/usr/bin/env bash
# Shared helpers for the tackle bats suite.
#
# Design notes:
#  - Every test runs in its own $BATS_TEST_TMPDIR (auto-created + auto-removed).
#  - We source tackle.zsh under bash; the function is written to be portable, and a
#    separate zsh smoke test (tackle_zsh_smoke.sh) covers the shell you actually run
#    it in day to day.
#  - Hermetic: a stub `gh` shadows the real one so tests never hit the network or
#    depend on GitHub auth; TACKLE_ENV_FILE points at a nonexistent file so the real
#    ~/.zsh/.env is never sourced; TACKLE_AGENT is stubbed so nothing interactive
#    fires.

# Per-test setup: isolate config, install stubs, source the function under test.
tackle_setup() {
  TACKLE_SRC="$BATS_TEST_DIRNAME/../tackle.zsh"

  # Never source the operator's real ~/.zsh/.env — point at a file that does not
  # exist so the auto-load is skipped.
  export TACKLE_ENV_FILE="$BATS_TEST_TMPDIR/no.env"
  # Stub the agent launch so nothing interactive fires. `true` ignores its args.
  export TACKLE_AGENT=true
  # Deterministic worktree naming.
  export TACKLE_DIR_TEMPLATE='{repo}_{branch}'
  unset TACKLE_PROMPT TACKLE_COPY_ENV TACKLE_DEPS TACKLE_CONFIG
  # Isolate the project-config trust store so tests never read or write the
  # operator's real ~/.local/state/tackle and start from an untrusted state.
  export TACKLE_STATE_DIR="$BATS_TEST_TMPDIR/state"

  # Hermetic stubs ahead of the real binaries on PATH.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  _write_gh_stub
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # Source the function under test.
  # shellcheck source=/dev/null
  source "$TACKLE_SRC"
}

# gh stub — reads fixtures from env so each test controls the PR data it sees:
#   GH_STUB_PRLIST   → body for `gh pr list`   (default: [] = no open PRs → branch-only)
#   GH_STUB_PRVIEW   → body for `gh pr view`   (default: empty = unresolvable)
#   GH_STUB_REPOVIEW → output for `gh repo view` (default: empty = gh can't answer,
#                      so --repo-check=remote falls back to the local origin check)
_write_gh_stub() {
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list")   printf '%s' "${GH_STUB_PRLIST:-[]}" ;;
  "pr view")   printf '%s' "${GH_STUB_PRVIEW:-}" ;;
  "repo view") printf '%s' "${GH_STUB_REPOVIEW:-}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# Create a git repo at $BATS_TEST_TMPDIR/<name> with one tracked file, one
# commit, and a `feature` branch. Echoes the repo path on stdout.
init_repo() {
  local name="${1:-repo}"
  local dir="$BATS_TEST_TMPDIR/$name"
  git init -q "$dir"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name  tester
  mkdir -p "$dir/apps/web"
  printf 'console.log("hi")\n' > "$dir/apps/web/app.js"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  git -C "$dir" branch feature
  printf '%s' "$dir"
}

# Package-manager stub: shadows a real installer (npm/pnpm/yarn/cargo/go/poetry/uv/pip)
# so dependency tests assert install-vs-symlink hermetically, with no network and no
# real toolchain. When invoked it (a) appends its own name to ./.tackle-installed in
# the cwd, and (b) fakes materialisation by creating its reuse dir ($2, default
# node_modules) so downstream steps see a populated tree. Always exits 0.
write_install_stub() {
  local name="$1" reuse_dir="${2:-node_modules}"
  cat > "$BATS_TEST_TMPDIR/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$name" >> ./.tackle-installed
mkdir -p "./$reuse_dir/.installed-by-$name"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/$name"
}

# fzf stub for the multi-PR picker: emits the stdin line matching $FZF_STUB_PICK
# (a substring), or nothing + exit 1 when FZF_STUB_PICK is unset (simulating a
# cancelled picker).
write_fzf_stub() {
  cat > "$BATS_TEST_TMPDIR/bin/fzf" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
[[ -n "${FZF_STUB_PICK:-}" ]] || exit 1
printf '%s\n' "$input" | grep -F -- "$FZF_STUB_PICK" | head -1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
}

# Point TACKLE_AGENT at a recorder that writes the prompt it is launched with into
# the file $1 — lets prompt-assembly tests inspect exactly what the agent got.
use_recording_agent() {
  local out="$1"
  cat > "$BATS_TEST_TMPDIR/bin/agent-rec" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$out"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/agent-rec"
  export TACKLE_AGENT="$BATS_TEST_TMPDIR/bin/agent-rec"
}
