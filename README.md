# skill

A Claude Code **plugin marketplace** of independently installable skills.
Each skill in the table below is its own plugin — install only the ones you
want, each as its own `plugins/<name>/`.

| Skill               | Plugin            | What it does                                                                 |
| ------------------- | ------------------ | ---------------------------------------------------------------------------- |
| **gh-pr-reply**      | `gh-pr-reply`      | Fetch a PR's review comments (humans + bots), apply valid fixes, reply to every thread. |
| **gh-pr-approve**    | `gh-pr-approve`    | Review a colleague's PR, then approve or request changes and file follow-up issues. |
| **statusline-kit**   | `statusline-kit`   | Install the statusline (model, cwd/branch, context usage, session token totals) into a fresh environment, identical to wherever it was set up originally. |
| **skill-optimizer**  | `skill-optimizer`  | Slim and restructure a SKILL.md without losing behavior, trigger coverage, anchors, or facts: measure → invariants → plan → five levers (description slim, prose compression, reference split, shell externalization, hook absorption) → verify. Also detects duplicated skill copies and unifies them. |
| **agent-clinic**     | `agent-clinic`     | Diagnose and treat a repo's context/doc health: trim bloated CLAUDE.md/AGENTS.md, resync public docs with the current code, untrack leaked editor config, and clear out finished planning artifacts. |
| **agent-update**     | `agent-update`     | Install the latest native release directly, skipping `claude update`'s fixed download deadline that fails on a slow proxy: manifest lookup, resumable checksum-verified download, atomic symlink swap. |
| **agent-delegation**  | `agent-delegation`  | Delegate a GitHub issue to Claude Code CLI end to end: implement → open PR → adversarial review by the delegating agent → re-delegation loop until every review comment is resolved and independently verified. |
| **agent-dispatch**    | `agent-dispatch`    | Advance a map issue's frontier (or that of a condition-defined issue set, e.g. by label or author): subagents self-grill every startable `needs-triage` sub-issue → the orchestrator decides what the evidence settles and asks the human only the contested rest (one round) → each issue is rewritten as an agent contract and moved to `ready-for-agent` → implement / diagnosing-bugs subagents open draft PRs → the orchestrator runs an adversarial reviewer in parallel with its final review of every PR (reruns the tests, checks the diff against the contract, reproduces the key claims) and sends one combined fix request → it watches the PRs and, as each one merges, cleans up and moves on to the next frontier until the scope is done, putting defects it files along the way straight into the frontier. Each subagent is sized (`model`·`effort`) to the difficulty of its issue, never below `sonnet`·`medium`. |

All eight plugins are fully independent — no shared files, no install ordering,
no cross-plugin requirements. `agent-dispatch` drives skills from the external
[mattpocock-skills](https://github.com/mattpocock/skills) plugin (see Prerequisites).

## Prerequisites

- **[GitHub CLI](https://cli.github.com)** authenticated (`gh auth login`).
  Needed by `gh-pr-reply`, `gh-pr-approve`, and `agent-delegation`.
- **`jq`**, **`git`**, **`bash` 4+**.
- Optional: `shellcheck` (lint of any shell scripts), `actionlint` (workflow lint).
- `statusline-kit`, `skill-optimizer`, and `agent-clinic` have no external dependencies
  beyond `bash`.
- `agent-update` needs `curl` and `sha256sum` (or macOS's `shasum`), no `jq`.
- `agent-delegation` needs the **Claude Code CLI** (`claude` on PATH,
  authenticated — `claude auth status` to check) in addition to `gh`.
- `agent-dispatch` needs `gh` and the **mattpocock-skills** plugin
  (`/plugin install mattpocock-skills@claude-plugins-official`), whose
  `grilling`, `domain-modeling`, `tdd`, and `diagnosing-bugs` skills it hands to
  its subagents. Merging stays with you: it polls its reviewed PRs, and other
  sessions' PRs that block the map, with `gh` in a background shell and resumes
  when one merges, conflicts, closes, or gets new review feedback (a review or
  conversation comment from a non-bot account) on one of its own PRs. Before
  taking an issue it reads the local Claude Code session records
  (`~/.claude/sessions`, `~/.claude/projects`) with `jq` and skips issues another
  live session already holds. The repo should have its triage labels
  (`needs-triage`, `ready-for-agent`, `ready-for-human` or their mapped names)
  and a map issue whose sub-issues use GitHub's native blocked-by dependencies.

## Install

In Claude Code:

```text
/plugin marketplace add jemings/skill
/plugin install gh-pr-reply@skill
/plugin install gh-pr-approve@skill
/plugin install statusline-kit@skill
/plugin install skill-optimizer@skill
/plugin install agent-clinic@skill
/plugin install agent-update@skill
/plugin install agent-delegation@skill
/plugin install agent-dispatch@skill
```

Install only the plugins you want — each is independent. Then reload plugins
(`/reload-plugins`) if prompted. The skills are invoked as
`/gh-pr-reply:gh-pr-reply`, `/gh-pr-approve:gh-pr-approve`,
`/statusline-kit:statusline-kit`, `/skill-optimizer:skill-optimizer`,
`/agent-clinic:agent-clinic`, `/agent-update:agent-update`,
`/agent-delegation:agent-delegation`, `/agent-dispatch:agent-dispatch` — or
auto-trigger from natural-language requests (see each skill's description).

## statusline-kit — statusline setup

Installs the statusline (model · cwd/branch · context usage · session token
totals) into `~/.claude/`, so a new machine or container gets the exact same
setup in one shot:

```text
/statusline-kit:statusline-kit
```

or just ask "새 환경에 statusline 셋업해줘" / "set up the statusline here". See
[`plugins/statusline-kit/skills/statusline-kit/SKILL.md`](plugins/statusline-kit/skills/statusline-kit/SKILL.md)
for what it installs and how.

## Repository layout

This is a **multi-plugin marketplace**: `.claude-plugin/marketplace.json`
lists one plugin per skill, each rooted at `plugins/<name>/` with its own
`.claude-plugin/plugin.json`. Installing one plugin never pulls in another's
files — each is a self-contained, independently installable unit.

```
.claude-plugin/
└── marketplace.json                          # catalog: one entry per plugin below
scripts/
└── check-ascii.sh                            # maintainer guard: non-ASCII (besides Hangul) under a path; not shipped with plugins
plugins/
├── gh-pr-reply/   (plugin.json + skills/gh-pr-reply/{SKILL.md, references/})
├── gh-pr-approve/ (plugin.json + skills/gh-pr-approve/{SKILL.md, references/})
├── statusline-kit/ (plugin.json + skills/statusline-kit/{SKILL.md, scripts/})
├── skill-optimizer/ (plugin.json + skills/skill-optimizer/SKILL.md)
├── agent-clinic/  (plugin.json + skills/agent-clinic/{SKILL.md, references/})
├── agent-update/ (plugin.json + skills/agent-update/{SKILL.md, scripts/})
├── agent-delegation/ (plugin.json + skills/agent-delegation/SKILL.md)
└── agent-dispatch/ (plugin.json + skills/agent-dispatch/{SKILL.md, references/, scripts/})
```

New skills land here the same way — add `plugins/<name>/.claude-plugin/plugin.json`
+ `plugins/<name>/skills/<name>/SKILL.md`, then list it in `marketplace.json`.

`marketplace.json`'s `renames` map records plugins that were renamed
(`"old": "new"`) or removed (`"old": null`), so existing installs migrate or get
cleaned up on the next marketplace sync instead of failing to load.

## Develop / test

```bash
bash plugins/statusline-kit/skills/statusline-kit/scripts/test-install.sh   # statusline-kit install script (isolated tmp HOME)
bash plugins/agent-dispatch/skills/agent-dispatch/scripts/test-scripts.sh   # agent-dispatch wait-prs.sh · in-flight.sh (gh stub that runs host jq, bash:3.2 if docker image exists)
bash scripts/check-ascii.sh plugins/agent-dispatch                              # agent-dispatch must stay ASCII punctuation (exit 1 lists offenders)
```

## License

[Apache-2.0](LICENSE).
