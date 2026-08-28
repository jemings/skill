---
name: claude-delegation
license: Apache-2.0
description: >-
  Delegate a GitHub issue to Claude Code CLI end to end: implement, open a
  PR, adversarially review it yourself, and loop re-delegation until every
  review comment is resolved. Use when the user says "do #N", "#N 해줘",
  or references any bare "#N" issue number as a task — treat "#N" as
  GitHub issue #N and run this skill.
allowed-tools: Bash, Read, Grep, Glob
---

# claude-delegation — Issue → Claude Code → PR → Adversarial Review Loop

End-to-end: take a GitHub issue, delegate implementation to the Claude Code
CLI, verify the PR really exists, review it adversarially yourself, and loop
re-delegation until all review comments are resolved. **Completion = all
comments closed with independent verification on the final head SHA**, not
"PR exists".

## When to Use

- "do #N", "#N 해줘" — a bare issue number is enough; treat `#N` as GitHub
  issue #N in the current repo and run this skill.
- Any request to delegate implementation to Claude Code and gate it on your own adversarial review.

If the user gives only `#N` with no other instruction, default to this
skill's full loop (implement → PR → adversarial review → resolve comments).

## Procedure

### Step 1: Read the live issue

```bash
gh issue view <N> --json title,body,state,labels,comments
gh pr list --search "#<N>" --state all   # duplicate sweep
```

The body is a snapshot from filing time; newest comments carry the live
state. Done when the requested behavior, non-goals, and any thread questions
are known.

### Step 2: Delegate to Claude Code (generous limits — never let it get killed)

**Work in a Claude worktree, not the main checkout.** Branches alone block
parallel work — other sessions can't run concurrently on the same working
tree. Create it yourself to match Claude's convention (directory and branch
share the same name, 1:1):

```bash
git worktree add .claude/worktrees/issue-<N> -b issue-<N>
```

(The `claude -w` flag does this too, but it's interactive-mode oriented —
in print mode (`-p`) create the worktree directly as above.)

Run Claude with the working directory set to that worktree. After merge,
clean up: `git worktree remove .claude/worktrees/issue-<N>` — keeps the main
checkout on main, clean, so multiple issues can proceed in parallel across
sessions.

Run in a **background process** (e.g. `terminal(background=true,
notify_on_complete=true)`), not foreground with a timeout — foreground
timeouts kill long delegations mid-flight.

**Permissions: prefer scoped `--allowedTools` over
`--dangerously-skip-permissions`.** Print mode (`-p`) is non-interactive:
unapproved tools simply fail rather than prompt, so autonomous work needs
pre-approved permissions — but that can be an allowlist, not a blanket
bypass:

```bash
claude -p "$(cat /tmp/task.md)" \
  --allowedTools 'Read' 'Edit' 'Write' 'Bash(git *)' 'Bash(gh *)' 'Bash(uv run pytest *)' 'Bash(bun run *)' \
  --output-format json --max-turns 200 --max-budget-usd 25 --effort high \
  > /tmp/result.json 2>/tmp/stderr.log; echo "EXIT=$?" >> /tmp/stderr.log
```

Rules of thumb:

- Default to `--allowedTools` scoped to what the task needs (git, gh, test
  runner, formatter). Least privilege. `rm -rf`, network installs etc.
  stay blocked.
- Reach for `--dangerously-skip-permissions` only when the task legitimately
  needs arbitrary commands (unknown build tooling, network installs) and the
  workdir is disposable/isolated.
- Middle ground: `--permission-mode acceptEdits` (auto-accept file edits
  only; bash still needs explicit allows).
- Generous ceilings so it never dies mid-task: `--max-turns 200`,
  `--max-budget-usd 25`, `--effort high`.

**Task file** (`/tmp/task.md`) must be self-contained: issue summary,
branch/commit/PR steps, quality gates to run, scope constraints ("no
out-of-scope refactors", "if blocked, print what blocked you and stop"),
and required final output (PR URL, head SHA, files). Feeding everything it
needs up front also reduces the tool surface Claude needs — fewer surprises
under an allowlist.

**If interrupted:** do NOT just do it yourself. Diagnose root cause from
`result.json` `subtype` (`error_max_turns`, permission denials),
`stderr.log`, cost/turns — then fix the config (raise turns/budget, extend
the allowlist) and rerun.

### Step 3: Verify the PR yourself — never trust the child's report

```bash
gh pr view <N> --json number,url,state,headRefOid,baseRefName,files
gh pr diff <N> > /tmp/pr.diff   # read it fully
```

Independently run the gates in a clean clone: tests, the guard script,
plus a **sabotage check** — temporarily break the thing the guard/tests
protect (e.g. mutate a revision id), confirm FAIL + exit 1, restore.
A test that passes with and without the fix proves nothing; sabotage is
the only proof a guard actually bites.

### Step 4: Adversarial review → inline comments via one atomic API call

Write the review payload to a JSON file (avoids heredoc/backtick shell
mangling), fill `commit_id` with the real head SHA, then:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/reviews --input /tmp/review.json
```

Include per-file inline comments with exact new-file line numbers,
verified against full file context, not just the diff. Review checklist:
correctness/edge cases, security, scope discipline ("every changed line
traces to the issue"), sibling call sites of the same bug, missing tests,
fail-open vs fail-closed direction.

**Note:** GitHub rejects APPROVE on your own PR (422 "Can not approve your
own pull request") when the same token authored it — use
`event: "COMMENT"` for the verdict in that case.

### Step 5: Re-delegation loop until every comment is resolved

Loop Steps 2–4 on the SAME PR branch until each review comment is either
fixed or explicitly justified as no-change (with reasoning). Then post a
re-review confirming each comment resolved/closed.

**GitHub is the only medium — never the launcher↔child channel.** This is
the single most important rule of the loop, and the easiest to violate:

- **Do NOT paste review comment text into the child's prompt.** Handing the
  child the exact comment text trains it to "answer you" (the launcher)
  instead of writing to the PR. Instead, tell the child to **read the PR
  comments itself** (`gh api repos/<owner>/<repo>/pulls/<N>/comments` and
  `/reviews`) and address each one. It sees the canonical source and stays in
  the GitHub loop.
- **Do NOT ask the child to "report back to me / summarize to the launcher".**
  Its deliverable is (1) code fixes and (2) PR comments it posts. You verify by
  **reading the PR**, not by reading the child's stdout. If the child's final
  message is addressed to you, that is a smell — the responses belong on
  GitHub.
- **Child response recording:** where inline reply is 404 (some repos block
  `POST /pulls/comments/{id}/replies`), instruct the child to post a single
  `gh pr comment <N> --body "..."` summarizing how it addressed each comment
  (with file:line refs). That comment IS its response and the audit trail;
  your next re-review confirms closure.
- **Keep the follow-up task SHORT** and self-contained: issue summary, the PR
  number, the gates to run, scope constraints, and "read the PR comments
  yourself, fix them, post your response as a PR comment." Don't paste the
  full comment text into the prompt — cleaner, less drift, Claude sees the
  canonical source:

```
gh api repos/<owner>/<repo>/pulls/<N>/comments --jq '.[].body' 로 리뷰 코멘트를 읽고,
각 코멘트에 대해 반영하거나 반영하지 않을 근거를 답변으로 남겨라.
```

- **Verify the child edited the WORKTREE, not main:** after the child
  finishes, run `git -C <worktree> status --short` and `git -C <worktree> log -1`
  (NOT `git status`/`git log` in the repo root — the root is a different tree)
  and re-read the changed files in the worktree before posting the re-review.

After the fix push: re-read the diff, re-run gates independently on the new
head SHA, then close each comment in a re-review.

### Step 6: Done only when

- All inline comments have resolution replies or fixes,
- independent verification passes on the final head SHA (tests + sabotage),
- no out-of-scope files changed,
- worktree cleaned up after merge (main checkout back on main, clean).

**Always finish with a PR + adversarial review.** Any completed change —
even skill/doc edits like updating this file itself — goes through the same
loop: commit → push → open PR → adversarial review → resolve all comments.
Local-only edits are not "done".

## Pre-Flight Check (run before every delegation)

### Claude CLI auth
```bash
claude auth status   # expect loggedIn: true
# If first call ever, or auth seems stuck:
claude -p "hello"   # confirms session cache works; watch for OAuth init extrapost on the first call
```
If `claude -p` hangs or returns empty, diagnose before delegating real work — don't send a long task into a broken auth session.

### GitHub API availability (review loop)
**Test these before designing the loop.** The repo may restrict some endpoints — discover that up front, not mid-loop:
```bash
# inline reply:
gh api repos/OWNER/REPO/pulls/COMMENT_ID/replies --method POST --input /dev/null
# → 200 OK, or 404 (repo blocks it → use PR issue comments instead)

# resolve:
gh api repos/OWNER/REPO/pulls/comments/COMMENT_ID/resolve --method POST --input /dev/null
# → 200 OK, or 404 (cannot resolve → settle via APPROVE/COMMENT review or leave open)

# self-approve:
gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews --method POST --input <(jq -n '{body:"ok",event:"APPROVE"}')
# → 422 "Can not approve your own pull request" → use event: "COMMENT"
```
Record results in your task file so the loop can adapt without guessing.

### Worktree sanity (subagent will run here)
```bash
cd $WORKTREE
git branch --show-current   # MUST equal the branch name, not main
ls $FILE                   # confirm files the subagent will read actually exist
```

## Delegation Design Rules

- **One subagent, one task.** Don't bundle "read comments + answer + amend PR body + settle review state" into a single subagent. Split: answers-only, amend-only, review-state-only.
- **Avoid /tmp file dependencies for subagents.** A subagent's environment may not see files you wrote in the parent session. Inline instructions in `goal`/`context` strings instead of pointing at `/tmp/x.md`. If you must use a file, have the subagent `cat` it and assert it's non-empty, or write it from within the subagent's own session.
- **Tell the subagent to `cd` into the worktree explicitly.** Giving the path is not enough — subagents may run from the parent cwd. First command: `cd $WORKTREE && git branch --show-current` and assert it matches the branch.
- **Foreground timeouts are normal; background is not always stable.** If a foreground `claude -p` hits the time limit, the CLI may leave an OAuth/auth wait state. Background runs can hit PTY/ioctl errors. Prefer foreground with a generous timeout for short tasks; for long tasks, accept that you may need to re-delegate with a longer budget rather than blindly falling back to background.

## Review Loop — Decision Tree When APIs Reject

When an endpoint returns 404/422, don't retry the same call — switch paths:

| Blocked endpoint | Symptom | Fallback |
|---|---|---|
| `POST /pulls/comments/{id}/replies` | 404 Not Found | Post as PR issue comment: `gh pr comment <N> --body "..."` |
| `POST /pulls/comments/{id}/resolve` | 404 Not Found | Cannot resolve inline; settle via APPROVE/COMMENT review or leave open |
| `POST /pulls/<N>/reviews event=APPROVE` | 422 "Can not approve your own pull request" | Use `event: "COMMENT"` with verdict text, or have another account approve |
| `POST /repos/.../issues/comments/{id}` DELETE | 404 Not Found (already auto-deleted or endpoint differs) | Leave duplicates; trim in a later amend rather than fight the API |

Test each before relying on it — don't discover mid-loop.

## Anti-Duplication

Before posting a PR comment or review comment:
1. `gh api repos/.../issues/<N>/comments --jq '.[].body[0:40]'` — scan for your text
2. `gh api repos/.../pulls/<N>/reviews/<review_id>/comments --jq '.[].body[0:40]'` — scan inline replies

If a near-duplicate exists, edit the existing one (if supported) or skip rather than post twice.

## PR Body ↔ Code Consistency

After drafting the PR body, verify against the actual diff before submitting:
```bash
gh pr diff <N> > /tmp/pr.diff
# For each claim in the body (file changed, function signature, parameter added/removed),
# grep /tmp/pr.diff AND read the actual worktree file to confirm.
```
Flag any mismatch and amend the body (or the code) before `gh pr create` / `gh pr edit`.

## Test Stub Breakage — Discovery Order

When a function signature gains an optional parameter and tests monkeypatch it:
1. **Run pytest FIRST** (before fixing stubs) — let it fail.
2. Confirm the failure is a `TypeError` (wrong arg count) on the monkeypatched stub.
3. **Then** expand the stub to `*_args` absorption or add the new param.
4. Run pytest again — green.
5. Document the discovery order in the PR comment: "pytest first → TypeError → stub fix" so reviewers see the sequence was correct.

This avoids the "should have caught this before running tests" critique and proves the stub change is minimal and justified.

## Merge Strategy (repo-specific)

This repo's `github-workflow` plugin provides `claude-pr-merge` which delegates to
`gh pr merge --rebase --auto` — rebase (fast-forward) with auto-merge, no merge
commits by default. When using claude-delegation outside that plugin, prefer the
same order: **squash → rebase → (if both blocked) report to user**, never fall back
to merge commit automatically.

## Pitfalls

- Foreground timeouts kill long delegations → always background +
  notify_on_complete.
- Trusting child's "PR created" summary without checking head SHA/diff.
- Heredoc/quoting mangles JSON review payloads with backticks/`$` — write
  the payload with a file-write tool instead.
- APPROVE 422 on own PR → use COMMENT event.
- Sabotage test is the only proof a guard actually bites.
- Blanket `--dangerously-skip-permissions` on a repo checkout lets the
  child touch anything — prefer scoped allowlists.
- Working on a branch in the shared checkout kills parallelism — always use
  `.claude/worktrees/issue-<N>`; clean up after merge.
- The `-w` flag is interactive-mode oriented; in print mode (`-p`) create
  the worktree yourself and pass it as the working directory.
- Merge commits are not the default merge strategy. Prefer squash or rebase
  (fast-forward). A repository that only allows merge commits is an exception
  — report it to the user rather than merging with a merge commit by default.
- This repo's `github-workflow` plugin defaults to `claude-pr-merge`
  (`gh pr merge --rebase --auto`); when delegating outside that plugin, follow
  the same rebase-first principle.
- **Edit paths must target the WORKTREE, never the main checkout.**
  `write_file`/`patch` resolve absolute paths against CWD. If you
  `git worktree add` then call `patch` with `/repo/apps/...` (main) instead of
  `/repo/.claude/worktrees/issue-<N>/apps/...`, the edits land in `main` and
  `git status` in the worktree shows nothing — you silently corrupt main and
  the PR stays empty. Always prefix paths with the worktree root. Verify with
  `git -C <worktree> status --short` (not `git status` in the repo root) after
  every batch of edits.
- **lefthook pre-commit fail-closed in a fresh worktree.** A hand-owned
  pre-commit shim (`core.hooksPath=.githooks`) exits 1 when it can't locate the
  `lefthook` binary, which aborts the commit and git resets it. A worktree has
  no `node_modules`, so `bun install` must run at the repo root first, OR commit
  with `LEFTHOOK=0 git commit ...` (documented escape hatch). `LEFTHOOK=0` only
  bypasses the missing-binary fail-closed — the lint/prettier hooks still ran
  and passed in this session.
- **`gh pr create` may abort with "push first or use --head" even right after
  `git push`.** Pass `--head issue-<N>` explicitly (and `--base main`) to force
  it.
- **Child commits under lefthook:** if you delegate the commit to Claude Code,
  it hits the same fail-closed unless `bun install` ran or you pass
  `LEFTHOOK=0` through the env. Tell the child to use `LEFTHOOK=0 git commit` in
  the task brief if lefthook isn't installed in the worktree.
