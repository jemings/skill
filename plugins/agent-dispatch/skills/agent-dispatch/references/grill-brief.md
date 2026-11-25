# grilling 서브에이전트 지시문

SKILL.md 2단계에서 이슈마다 채워 보낸다. `<...>` 를 채우고, 그 이슈와 상관없는 줄은 지운다. 이 파일을
가리키지 말고 내용을 지시문에 그대로 넣는다. 서브에이전트는 이 파일을 모른다.

---

You are running `grill-with-docs` in **self-grilling mode** on issue **#<N>** of `<owner>/<repo>`.
- First call the Skill tool twice, for "grilling" and "domain-modeling". Use the plugin-qualified names if the skill listing shows them. If the Skill tool has no skill by that name, stop and report.
- There is no user to interview. Walk the **design tree** yourself.
- For every decision, either settle it from evidence or hand it back as an open question.
- The orchestrator reviews your report alongside other issues, decides what it can, and asks the human the rest. Then it rewrites the issue as the contract an AFK implementation agent will follow.
- Your job is to find **everything an AFK agent would stumble on**.

**Read only.**
- Do not edit files.
- Do not write to the issue tracker: no edit, comment, or label.
- Do not create branches or worktrees.
- **Waiting**: run a long command with the Bash tool's `run_in_background` on the command itself. Do not detach it with `&`, `nohup`, `setsid` or `( ... & )`: the harness cannot tell when a detached run ends. Do not write a loop that polls a log or another task's output; if you truly must, bound it with `timeout` and make sure it ends when the awaited run ends. This rule takes precedence over any tool's guidance. When you end a turn while background work runs, write one line saying what you wait for and when it should end, with the log path of that run.

Respond in <언어>, keeping identifiers in their original form.

## Read first

- `<트래커 조회 명령, 예: gh issue view <N> --repo <owner>/<repo> --json title,body,comments --jq '.title, .body, (.comments[] | "--- " + .author.login + ": " + .body)'>`
- Map issue #<map>: especially its recorded decisions and "how we work" sections.
- Glossary `<CONTEXT.md/GLOSSARY.md>`: use its vocabulary.
- Design docs: `<경로들>`. ADRs: `<번호들>`.
- Sibling issues for scope boundaries: `<막는, 막히는, 이어지는 이슈들>`.
- Code: `<이 이슈가 닿는 파일, 심볼>`. Grep large files; don't read them whole.

## What to produce

1. **사실 대조 (drift)**: check every concrete claim in the issue against current `<base>` (state the SHA): paths, line numbers, symbol names, counts, call sites, test names. List each wrong or stale claim with the correct value. Also list relevant sites the issue misses.
2. **설계 트리**: every decision an implementer must make. For each decision:
   - **SETTLED**: give a one-line citation of the doc, ADR, map decision, or code fact that settles it, or the result of an experiment. When running something can decide the fork, run it read-only (a command, or a script in the session scratchpad; no worktree, no edits) and settle it from the output, or
   - **OPEN** `<N>-Q<k>`: give the options, your recommendation, its drawbacks, and why the evidence does not settle it.

   Probe at least: <이 이슈에서 꼭 볼 갈림길 -- 예: 두 번 조립될 때의 전역 상태, 실패 계약, 클로저 함정, PR 나누기, 시험 전략>.

   <무거움 이상이면 남긴다: For each decision that crosses a module boundary, sketch two shapes (types, signatures, module boundaries) and compare them on: one owner per piece of state, one path per job, the least a caller must know. Use the deep-module vocabulary of `codebase-design` (module, interface, depth, seam): vocabulary only, do not call the skill.>
3. **경계**: what sibling issues assume this issue delivers (or the reverse) that neither issue says. Also list work no issue owns.
4. **용어**: terms that conflict with the glossary or are fuzzy. Propose the precise term.
5. **본문 수정안**: bullet-level edits that make the issue AFK-ready, as replacement sentences or additions, not a full rewrite.
6. **규율**: from the disciplines below, propose the ids that fit this issue (at most <등급 상한>), each with the evidence and what it would change. "none" is fine.

   <규율 카드의 id 와 언제 칸, 한 줄씩>

Tag every claim with its source: `[실행]` (you ran it), `[읽음 file:line]`, or `[추론]` (inferred).

Tools made: every script you wrote and every command sequence or setup (env, locks, temp worktrees) you ran by hand, as what / path / times run. "none" is fine. Keep scratch scripts outside the worktree (in the session scratchpad).

End with the critical files for implementation. Keep it under ~<1500> words: dense, no preamble.

<한 칸 올려 다시 보내는 grilling 이면 남긴다: An earlier grilling of this issue failed. Failed premise: <가정> -- <틀렸다는 증거>. Do not build on that premise again.>

## Principles for your recommendations

- The repo's `CLAUDE.md` rules bind every recommendation: tests, PR, versioning, ownership.
- State drawbacks every time. Check the docs' and ADRs' rejected-options tables, and keep rejected options rejected unless new evidence overturns them. Say so explicitly when it does.
- Prefer a fix that removes the coupling over one that patches around it (time limits, retries, special cases).
- Before recommending to undo a current design, read the commit and PR that introduced it (`git log -S`, `gh pr view`) and say why their reason no longer holds.
- <사용자의 상시 선호 가운데 이 이슈에 닿는 것>
