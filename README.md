# skill

A Claude Code **plugin marketplace** of independently installable skills.
Each skill in the table below is its own plugin — install only the ones you
want, each as its own `plugins/<name>/`.

| Skill               | Plugin            | What it does                                                                 |
| ------------------- | ------------------ | ---------------------------------------------------------------------------- |
| **github-workflow**  | `github-workflow`  | Start/finish issue-based work sessions: pick next issue → dependency gate → worktree-isolated branch → `In progress` → test/commit/push → PR (`Closes #N`) → `In review`. Supports stacked PRs. |
| **gh-pr-reply**      | `gh-pr-reply`      | Fetch a PR's review comments (humans + bots), apply valid fixes, reply to every thread. |
| **gh-pr-approve**    | `gh-pr-approve`    | Review a colleague's PR, then approve or request changes and file follow-up issues. |
| **gh-triage**        | `gh-triage`        | Triage Backlog issues — promote ready ones, enhance with code exploration, split, or ask for clarification. |
| **hud**              | `hud`              | Install the statusline (model, cwd/branch, context usage, session token totals) into a fresh environment, identical to wherever it was set up originally. |
| **skill-optimizer**  | `skill-optimizer`  | Slim and restructure a SKILL.md without losing behavior, trigger coverage, anchors, or facts: measure → invariants → plan → five levers (description slim, prose compression, reference split, shell externalization, hook absorption) → verify. Also detects duplicated skill copies and unifies them. |

`github-workflow` and `gh-triage` both drive the same GitHub Project board and
share one function library (`scripts/github-workflow.sh`) — `gh-triage` links
to it (see [Repository layout](#repository-layout)) so it stays installable
on its own, but in practice the two are normally installed together. The
other four plugins have no shared files and are fully independent.

## Prerequisites

- **[GitHub CLI](https://cli.github.com)** authenticated, with the `project`
  scope: `gh auth login` then `gh auth refresh -s project`. Needed by
  `github-workflow`, `gh-triage`, `gh-pr-reply`, `gh-pr-approve`.
- **`jq`**, **`git`**, **`bash` 4+**.
- An **org-scoped GitHub Project (v2)** with a single-select `Status` field whose
  options are exactly the six above. Create/configure it with
  [`docs/board-setup.md`](plugins/github-workflow/docs/board-setup.md) or the
  helper `scripts/setup-board.sh`. Needed by `github-workflow` and `gh-triage`.
- Optional: `shellcheck` (push-time lint of any shell scripts), `actionlint`
  (workflow lint).
- `hud` and `skill-optimizer` have no external dependencies beyond `bash`.

> **Scope note:** the board functions query `organization(login: …)`, so the
> Project must be **organization-owned**, not user-owned. See [Limitations](#limitations).

## Install

In Claude Code:

```text
/plugin marketplace add jemings/skill
/plugin install github-workflow@skill
/plugin install gh-triage@skill
/plugin install gh-pr-reply@skill
/plugin install gh-pr-approve@skill
/plugin install hud@skill
/plugin install skill-optimizer@skill
```

Install only the plugins you want — each is independent. Then reload plugins
(`/reload-plugins`) if prompted. The skills are invoked as
`/github-workflow:github-workflow`, `/gh-pr-reply:gh-pr-reply`,
`/gh-pr-approve:gh-pr-approve`, `/gh-triage:gh-triage`, `/hud:hud`,
`/skill-optimizer:skill-optimizer` — or auto-trigger from natural-language
requests (see each skill's description).

## Set up the board

Pick one (needs the `github-workflow` plugin installed):

**A. Helper script** (creates the Project, writes the per-repo config, and tells
you which `Status` options to set):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-board.sh" --owner <your-org> --title "My Board" --repo /path/to/your-repo
```

**B. Manual** — follow [`docs/board-setup.md`](plugins/github-workflow/docs/board-setup.md).

## Configure

The functions need to know your board. Resolution order (first wins):

1. Environment: `export CLAUDE_PROJECT_OWNER=<org> CLAUDE_PROJECT_NUMBER=<n>`
2. A `.github-workflow.config` file at the **root of the repo you run in** (copy
   [`.github-workflow.config.example`](plugins/github-workflow/.github-workflow.config.example) and fill it).

If neither is set, the first board call prints a clear setup message and stops.
Full options (hold labels, local CI hook): [`docs/configuration.md`](plugins/github-workflow/docs/configuration.md).

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
in [`docs/github-integration.md`](plugins/github-workflow/docs/github-integration.md).

## Push-time checks

Before creating a PR, `claude-close-issue` runs a **best-effort lint guard**
(`shellcheck` on tracked `*.sh`/`*.bash` if installed; `actionlint` if installed)
and an optional **local CI gate**. Builds/tests are project-specific, so the gate
is pluggable — set `CLAUDE_LOCAL_CI_CMD` or add `.github-workflow/local-ci.sh`.
See [`docs/configuration.md`](plugins/github-workflow/docs/configuration.md).

## hud — statusline setup

Installs the statusline (model · cwd/branch · context usage · session token
totals) into `~/.claude/`, so a new machine or container gets the exact same
setup in one shot:

```text
/hud:hud
```

or just ask "새 환경에 statusline 셋업해줘" / "set up the statusline here". See
[`plugins/hud/skills/hud/SKILL.md`](plugins/hud/skills/hud/SKILL.md) for what
it installs and how.

## Repository layout

This is a **multi-plugin marketplace**: `.claude-plugin/marketplace.json`
lists one plugin per skill, each rooted at `plugins/<name>/` with its own
`.claude-plugin/plugin.json`. Installing one plugin never pulls in another's
files — each is a self-contained, independently installable unit.

```
.claude-plugin/
└── marketplace.json                          # catalog: one entry per plugin below
plugins/
├── github-workflow/
│   ├── .claude-plugin/plugin.json
│   ├── skills/github-workflow/SKILL.md
│   ├── scripts/
│   │   ├── github-workflow.sh                # function SSOT (real file)
│   │   ├── test-github-workflow.sh
│   │   └── setup-board.sh
│   ├── docs/
│   │   ├── github-integration.md             # policy SSOT
│   │   ├── board-setup.md
│   │   └── configuration.md
│   └── .github-workflow.config.example
├── gh-triage/
│   ├── .claude-plugin/plugin.json
│   ├── skills/gh-triage/SKILL.md
│   ├── scripts/github-workflow.sh            # symlink → ../github-workflow/scripts/…
│   └── docs/github-integration.md            # symlink → ../github-workflow/docs/…
├── gh-pr-reply/   (plugin.json + skills/gh-pr-reply/{SKILL.md, references/})
├── gh-pr-approve/ (plugin.json + skills/gh-pr-approve/{SKILL.md, references/})
├── hud/           (plugin.json + skills/hud/{SKILL.md, scripts/})
└── skill-optimizer/ (plugin.json + skills/skill-optimizer/SKILL.md)
```

`gh-triage`'s two symlinks point at `github-workflow`'s copies of the shared
script/doc. Claude Code dereferences marketplace-internal symlinks at install
time — each plugin's cache copy ends up with a real file at that path, so
`gh-triage` installs and runs standalone even without `github-workflow`
installed. Edit the function library only under `plugins/github-workflow/` —
`gh-triage`'s copy always follows it.

New skills land here the same way — add `plugins/<name>/.claude-plugin/plugin.json`
+ `plugins/<name>/skills/<name>/SKILL.md`, then list it in `marketplace.json`.

## Develop / test

```bash
cd plugins/github-workflow/scripts
bash test-github-workflow.sh   # pure-helper unit tests (no network)
shellcheck -x -S warning github-workflow.sh setup-board.sh

bash ../../hud/skills/hud/scripts/test-install.sh   # hud install script (isolated tmp HOME)
```

## Limitations

- **Org-scoped Projects only.** All board queries use `organization(login: …)`;
  user-owned Projects aren't supported yet.
- The board's six `Status` options must match exactly — GitHub's API can't reliably
  edit the built-in `Status` options, so that step is manual (the helper verifies
  and guides you).

## License

[Apache-2.0](LICENSE).
