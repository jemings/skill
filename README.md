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
| **claude-update**    | `claude-update`    | Install the latest native release directly, skipping `claude update`'s fixed download deadline that fails on a slow proxy: manifest lookup, resumable checksum-verified download, atomic symlink swap. |
| **claude-delegation** | `claude-delegation` | Delegate a GitHub issue to Claude Code CLI end to end: implement → open PR → adversarial review by the delegating agent → re-delegation loop until every review comment is resolved and independently verified. |

All seven plugins are fully independent — no shared files, no install ordering,
no cross-plugin requirements.

## Prerequisites

- **[GitHub CLI](https://cli.github.com)** authenticated (`gh auth login`).
  Needed by `gh-pr-reply`, `gh-pr-approve`, and `claude-delegation`.
- **`jq`**, **`git`**, **`bash` 4+**.
- Optional: `shellcheck` (lint of any shell scripts), `actionlint` (workflow lint).
- `statusline-kit`, `skill-optimizer`, and `agent-clinic` have no external dependencies
  beyond `bash`.
- `claude-update` needs `curl` and `sha256sum` (or macOS's `shasum`), no `jq`.
- `claude-delegation` needs the **Claude Code CLI** (`claude` on PATH,
  authenticated — `claude auth status` to check) in addition to `gh`.

## Install

In Claude Code:

```text
/plugin marketplace add jemings/skill
/plugin install gh-pr-reply@skill
/plugin install gh-pr-approve@skill
/plugin install statusline-kit@skill
/plugin install skill-optimizer@skill
/plugin install agent-clinic@skill
/plugin install claude-update@skill
/plugin install claude-delegation@skill
```

Install only the plugins you want — each is independent. Then reload plugins
(`/reload-plugins`) if prompted. The skills are invoked as
`/gh-pr-reply:gh-pr-reply`, `/gh-pr-approve:gh-pr-approve`,
`/statusline-kit:statusline-kit`, `/skill-optimizer:skill-optimizer`,
`/agent-clinic:agent-clinic`, `/claude-update:claude-update`,
`/claude-delegation:claude-delegation` — or
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
plugins/
├── gh-pr-reply/   (plugin.json + skills/gh-pr-reply/{SKILL.md, references/})
├── gh-pr-approve/ (plugin.json + skills/gh-pr-approve/{SKILL.md, references/})
├── statusline-kit/ (plugin.json + skills/statusline-kit/{SKILL.md, scripts/})
├── skill-optimizer/ (plugin.json + skills/skill-optimizer/SKILL.md)
├── agent-clinic/  (plugin.json + skills/agent-clinic/{SKILL.md, references/})
├── claude-update/ (plugin.json + skills/claude-update/{SKILL.md, scripts/})
└── claude-delegation/ (plugin.json + skills/claude-delegation/SKILL.md)
```

New skills land here the same way — add `plugins/<name>/.claude-plugin/plugin.json`
+ `plugins/<name>/skills/<name>/SKILL.md`, then list it in `marketplace.json`.

`marketplace.json`'s `renames` map records plugins that were renamed
(`"old": "new"`) or removed (`"old": null`), so existing installs migrate or get
cleaned up on the next marketplace sync instead of failing to load.

## Develop / test

```bash
bash plugins/statusline-kit/skills/statusline-kit/scripts/test-install.sh   # statusline-kit install script (isolated tmp HOME)
```

## License

[Apache-2.0](LICENSE).
