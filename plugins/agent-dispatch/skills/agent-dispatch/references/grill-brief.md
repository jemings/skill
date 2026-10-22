# grilling 서브에이전트 지시문

`agent-dispatch` 2단계에서 이슈마다 채워 보낸다. `<…>` 를 채우고, 그 이슈와 상관없는 줄은 지운다. 이 파일을
가리키지 말고 내용을 지시문에 그대로 넣는다. 서브에이전트는 이 파일을 모른다.

---

You are running `grill-with-docs` in **self-grilling mode** on issue **#<N>** of `<owner>/<repo>`.
- First call the Skill tool twice, for "grilling" and "domain-modeling". Use the plugin-qualified names if the skill listing shows them.
- There is no user to interview. Walk the **design tree** yourself.
- For every decision, either settle it from evidence or hand it back as an open question.
- The orchestrator reviews your report alongside other issues, decides what it can, and asks the human the rest. Then it rewrites the issue as the contract an AFK implementation agent will follow.
- Your job is to find **everything an AFK agent would stumble on**.

**Read only.**
- Do not edit files.
- Do not write to the issue tracker: no edit, comment, or label.
- Do not create branches or worktrees.

Respond in <언어>, keeping identifiers in their original form.

## Read first

- `<트래커 조회 명령, 예: gh issue view <N> --repo <owner>/<repo> --comments>`
- Map issue #<map>: especially its recorded decisions and "how we work" sections.
- Glossary `<CONTEXT.md/GLOSSARY.md>`: use its vocabulary.
- Design docs: `<경로들>`. ADRs: `<번호들>`.
- Sibling issues for scope boundaries: `<막는·막히는·이어지는 이슈들>`.
- Code: `<이 이슈가 닿는 파일·심볼>`. Grep large files; don't read them whole.

## What to produce

1. **사실 대조 (drift)**: check every concrete claim in the issue against current `main` (state the SHA): paths, line numbers, symbol names, counts, call sites, test names. List each wrong or stale claim with the correct value. Also list relevant sites the issue misses.
2. **설계 트리**: every decision an implementer must make. For each decision:
   - **SETTLED**: give a one-line citation of the doc, ADR, map decision, or code fact that settles it, or
   - **OPEN** `<N>-Q<k>`: give the options, your recommendation, its drawbacks, and why the evidence does not settle it.

   Probe at least: <이 이슈에서 꼭 볼 갈림길 — 예: 두 번 조립될 때의 전역 상태, 실패 계약, 클로저 함정, PR 나누기, 시험 전략>.
3. **경계**: what sibling issues assume this issue delivers (or the reverse) that neither issue says. Also list work no issue owns.
4. **용어**: terms that conflict with the glossary or are fuzzy. Propose the precise term.
5. **본문 수정안**: bullet-level edits that make the issue AFK-ready, as replacement sentences or additions, not a full rewrite.

End with the critical files for implementation. Keep it under ~<1500> words: dense, no preamble.

## Principles for your recommendations

- The repo's `CLAUDE.md` rules bind every recommendation: tests, PR, versioning, ownership.
- State drawbacks every time. Check the docs' and ADRs' rejected-options tables, and keep rejected options rejected unless new evidence overturns them. Say so explicitly when it does.
- Prefer a fix that removes the coupling over one that patches around it (time limits, retries, special cases).
- <사용자의 상시 선호 가운데 이 이슈에 닿는 것>
