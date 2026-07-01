# skill

A Claude Code **plugin marketplace** that bundles a growing collection of
skills. One plugin (`skill`) ships everything: today that's issue-driven
GitHub work backed by a GitHub Project (v2) board, plus environment-setup
utilities — more skills land here over time, each as its own
`skills/<name>/SKILL.md`, sharing this one plugin/marketplace root.

| Skill              | What it does                                                                 |
| ------------------ | --------------------------------------------------------------------------- |
| **github-workflow** | Start/finish issue-based work sessions: pick next issue → dependency gate → worktree-isolated branch → `In progress` → test/commit/push → PR (`Closes #N`) → `In review`. Supports stacked PRs. |
| **gh-pr-reply**    | Fetch a PR's review comments (humans + bots), apply valid fixes, reply to every thread. |
| **gh-pr-approve**  | Review a colleague's PR, then approve or request changes and file follow-up issues. |
| **gh-triage**      | Triage Backlog issues — promote ready ones, enhance with code exploration, split, or ask for clarification. |
| **hud**            | Install the statusline (model, cwd/branch, context usage, session token totals) into a fresh environment, identical to wherever it was set up originally. |

The GitHub skills share `scripts/github-workflow.sh` (the function SSOT) and a
single GitHub Project board with a six-state `Status` field:

```
Backlog · Ready · In progress · In review · Approved · Done
```

## Prerequisites

- **[GitHub CLI](https://cli.github.com)** authenticated, with the `project`
  scope: `gh auth login` then `gh auth refresh -s project`.
- **`jq`**, **`git`**, **`bash` 4+**.
- An **org-scoped GitHub Project (v2)** with a single-select `Status` field whose
  options are exactly the six above. Create/configure it with
  [`docs/board-setup.md`](docs/board-setup.md) or the
  helper `scripts/setup-board.sh`.
- Optional: `shellcheck` (push-time lint of any shell scripts), `actionlint`
  (workflow lint).

> **Scope note:** the board functions query `organization(login: …)`, so the
> Project must be **organization-owned**, not user-owned. See [Limitations](#limitations).

## Install

In Claude Code:

```text
/plugin marketplace add jemings/skill
/plugin install skill@skill
```

Then reload plugins (`/reload-plugins`) if prompted. The skills are invoked as
`/skill:github-workflow`, `/skill:gh-pr-reply`, `/skill:gh-pr-approve`,
`/skill:gh-triage`, `/skill:hud` — or auto-trigger from natural-language
requests (see each skill's description).

## Set up the board

Pick one:

**A. Helper script** (creates the Project, writes the per-repo config, and tells
you which `Status` options to set):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-board.sh" --owner <your-org> --title "My Board" --repo /path/to/your-repo
```

**B. Manual** — follow [`docs/board-setup.md`](docs/board-setup.md).

## Configure

The functions need to know your board. Resolution order (first wins):

1. Environment: `export CLAUDE_PROJECT_OWNER=<org> CLAUDE_PROJECT_NUMBER=<n>`
2. A `.github-workflow.config` file at the **root of the repo you run in** (copy
   [`.github-workflow.config.example`](.github-workflow.config.example) and fill it).

If neither is set, the first board call prints a clear setup message and stops.
Full options (hold labels, local CI hook): [`docs/configuration.md`](docs/configuration.md).

## Use

Load the functions once per session, then drive the workflow:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"

# main worktree
claude-next-issue                 # pick the next pro-friendly issue
claude-check-deps <N>             # verify "Depends on #N" are closed/merged
claude-enter-issue <N>            # self-assign + create .claude/worktrees/issue-<N> + branch

# in the issue worktree
claude-start-issue <N>            # Status → In progress
# ... do the work ...
claude-close-issue <N> <type> "<description>"   # test → commit → push → PR (Closes #N) → In review

# main worktree, after merge
claude-cleanup-worktree <N>       # remove the worktree
```

Policy details (board transitions, labels, closing keywords, worktree rules) live
in [`docs/github-integration.md`](docs/github-integration.md).

## Push-time checks

Before creating a PR, `claude-close-issue` runs a **best-effort lint guard**
(`shellcheck` on tracked `*.sh`/`*.bash` if installed; `actionlint` if installed)
and an optional **local CI gate**. Builds/tests are project-specific, so the gate
is pluggable — set `CLAUDE_LOCAL_CI_CMD` or add `.github-workflow/local-ci.sh`.
See [`docs/configuration.md`](docs/configuration.md).

## hud — statusline setup

Installs the statusline (model · cwd/branch · context usage · session token
totals) into `~/.claude/`, so a new machine or container gets the exact same
setup in one shot:

```text
/skill:hud
```

or just ask "새 환경에 statusline 셋업해줘" / "set up the statusline here". See
[`skills/hud/SKILL.md`](skills/hud/SKILL.md) for what it installs and how.

## Repository layout

This is a **single-plugin marketplace**: the repo root is both the marketplace
and the plugin, so `marketplace.json` (plugin `"source": "."`) and `plugin.json`
share one root `.claude-plugin/`, and every skill's components sit at the repo
root under `skills/<name>/`. New skills land here the same way — add a
`skills/<name>/SKILL.md` (plus any scripts/references it needs) and it's
immediately available as `/skill:<name>`.

```
.claude-plugin/
├── marketplace.json                   # marketplace catalog (plugin source: ".")
└── plugin.json                        # plugin manifest
.github-workflow.config.example        # per-repo board config template
skills/
├── github-workflow/SKILL.md
├── gh-pr-reply/   (SKILL.md + references/)
├── gh-pr-approve/ (SKILL.md + references/)
├── gh-triage/SKILL.md
└── hud/           (SKILL.md + scripts/)
scripts/
├── github-workflow.sh                 # function SSOT
├── test-github-workflow.sh            # pure-helper unit tests
├── shgwt.sh                           # git worktree spawn/teardown helper
├── test-shgwt.sh
└── setup-board.sh                     # board bootstrap helper
docs/
├── github-integration.md              # policy SSOT
├── board-setup.md                     # board creation + Status field
└── configuration.md                   # env vars, config file, local CI hook
```

## Develop / test

```bash
cd scripts
bash test-github-workflow.sh   # pure-helper unit tests (no network)
bash test-shgwt.sh             # worktree helper tests
shellcheck -x -S warning github-workflow.sh shgwt.sh setup-board.sh
```

## Limitations

- **Org-scoped Projects only.** All board queries use `organization(login: …)`;
  user-owned Projects aren't supported yet.
- The board's six `Status` options must match exactly — GitHub's API can't reliably
  edit the built-in `Status` options, so that step is manual (the helper verifies
  and guides you).

## License

[Apache-2.0](LICENSE).
