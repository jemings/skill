# 구현 서브에이전트 지시문

`agent-dispatch` 6단계에서 이슈마다 채워 보낸다. `<…>` 를 채우고, 그 이슈의 종류에 맞는 절차 하나만 남긴다.
이 파일을 가리키지 말고 내용을 지시문에 그대로 넣는다.

---

Implement issue **#<N> "<제목>"** of `<owner>/<repo>`.
- The issue body is your **contract**. Read it and its comments first: `<트래커 조회 명령>`.
- Then read the repo's `CLAUDE.md`. Its rules bind you: worktree, tests and local CI, commits, PR, version and CHANGELOG, file ownership.

Respond in <언어>.

## Where to work

- Work in your own worktree: `<저장소 규칙의 worktree 자리와 브랜치 이름, 예: .claude/worktrees/<N>-<slug>>`, created from the current `origin/main`.
- Put the issue number `<N>` in both the worktree directory name and the branch name. Other sessions recognise work in flight by it.
- Leave the main checkout and every other tree as they are.
- <겹침이 있으면: #<M> 도 <파일> 을 바꾼다 — 먼저 병합되는 쪽 위로 rebase 한다.>

## Procedure

<bug 라벨이면 이 절을 남긴다>
**Diagnose, then fix.**
1. Call the Skill tool with "diagnosing-bugs" and follow it.
2. Even when the contract already names the cause, build the Phase 1 loop. It must go **red** on the reported symptom before you touch the fix.
3. Write the regression test at the seam the contract names. Show it red on the pre-fix commit and green after the fix.
4. When there are several defects, use one commit per defect, each with its own red→green.

<그 밖이면 이 절을 남긴다>
**Implement.**
1. Call the Skill tool with "tdd" and work test-first at the seams the contract names.
2. Run typecheck and single test files regularly. Run the full suites once at the end.
3. For a pure refactor, the contract's regression guards (snapshots, import guards) must stay green without editing their expectations. Any intended change must be called out with its reason, as the contract says.

<항상 남긴다>
**Then, on either path:**
1. Call the Skill tool with "code-review" on your diff. Fix what it finds, or say why not.
2. Commit per the repo's conventions. Split commits by kind: code, tests, docs.
3. Run the repo's required tests on the exact SHA you will push. If no push hook runs them, run them by hand.
4. Push and open the PR as the contract says: number of PRs, `Closes`/`Refs`, and the passing SHA in the body. Hand the PR over open. Merging belongs to the repo's review process.

## When to stop and report instead

Stop and report, with the exact passage and the evidence, when:
- the contract contradicts the code;
- the contract leaves a decision open;
- the work would need changes outside the contract's scope.

The orchestrator resolves it and re-dispatches you. Record found bugs outside the scope in your report.

## Report

- PR URL(s) and the tested SHA. Confirm it equals the PR HEAD.
- Each completion criterion of the contract: met, with how you checked it.
- Deviations from the contract and why.
- Follow-ups: out-of-scope bugs found, boundary notes for sibling issues.
