# tackle — share copy

Two-part split for posting: a short intro, then a detailed follow-up to drop
in the thread for anyone who wants more.

---

## 📌 Main post (the intro)

Not sure if it's interesting to anyone else, but I wrote a small bash/zsh helper — `tackle` — that automates git worktrees, and it's honestly changed how I juggle work locally.

The gist: I can move straight on to the next task but still jump back to an earlier PR the moment review feedback lands — make the changes, then return to what I was doing — all without stashing or disturbing my current branch. And when I'm reviewing someone else's PR, it drops me into an LLM session (Claude by default, but it works with Cursor/Codex too) already primed on the diff, so it explains what the branch is even about before I've read a line.

Two things it's great for:
- **Parallel work on the same repo** — a second (or third) fully isolated checkout in one command, no `stash → switch → stash pop` dance.
- **Instant local code-review sessions** — `review 1234` builds a throwaway worktree for that PR and hands you an LLM already up to speed on it. `tackle --done` cleans it up.

Works in bash and zsh. 🧵 More detail in the thread if you want it — happy to share the script.

---

## 🧵 Thread reply (for people who want to know more)

**How it works & what it handles for you** 👇

`git worktree` lets you check out multiple branches into separate directories at once — no stashing, no context loss. But the raw command leaves you to do the boring setup by hand every time. `tackle` does it all in one command:

**Parallel dev:**
```
tackle my-feature-branch      # isolated checkout, deps ready, agent launched
```
A real, independent working directory — nothing you do in it disturbs your current branch. Great for letting an agent run in one worktree while you keep coding in another.

**Local LLM review without stashing:**
```
tackle 1234 --review      # or just:  review 1234
```
Resolves PR #1234 to its branch, creates a dedicated worktree, and opens an LLM session primed with the diff, PR title, and description. You review it as a *conversation*, in your own editor, with the code actually checked out and runnable — your original work untouched the whole time. `tackle --done` tears it down and cds you back.
(`review` is just `alias review="tackle --review"` in my shell rc.)

**Works with your LLM of choice** — defaults to Claude Code, but it just launches whatever agent binary you point `TACKLE_AGENT` at (Cursor, Codex, etc.), passing the primed prompt straight through. Not tied to Claude.

**What it automates:**
- **Branch & PR auto-resolution** — pass a branch name, PR number, or PR URL. A plain branch name auto-finds its open PR (multiple → `fzf` picker); a branch that isn't local yet gets fetched from origin first. Never have to look up "which branch was that PR again?"
- **Dependencies, instantly** — symlinks `node_modules` from the main repo instead of reinstalling, so the worktree is usable immediately no matter how big the dep tree is. It also diffs the worktree's lockfile against the main repo's and warns you if they've drifted, in case a real install is worth it. Pass `--install` to force a full isolated install.
- **Automatic `.env` handling** — `git worktree` only checks out *tracked* files, so gitignored secrets would be missing and the app wouldn't run. `tackle` finds every `.env` / `.env.*` (even deep ones like `apps/web/.env.local`) and copies them into the worktree, skipping committed templates (`.env.example` etc.) and never overwriting existing files.
- **Custom prompts** — `--review` for the built-in "what changed?", `--prompt` for your own, or `TACKLE_PROMPT` (even a slash command like `/pr-review`) as a persistent default.

**Requirements:** `git` + `python3`; `gh` and `fzf` unlock the PR features. Auto dep-install covers JS package managers (pnpm/yarn/npm) — in other repos that step is just skipped. Save the file, add one `source` line to your shell rc. Ping me and I'll share it.
