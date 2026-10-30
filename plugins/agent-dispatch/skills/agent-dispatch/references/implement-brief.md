# 구현 서브에이전트 지시문

`agent-dispatch` 6단계에서 이슈마다 채워 보낸다. `<…>` 를 채우고, 그 이슈의 종류에 맞는 절차 하나만 남긴다.
리뷰 단계의 빈 블록에는 [`review-brief.md`](review-brief.md) 를 이 이슈로 다 채워 넣는다. 리뷰어의 크기는 크기 표의
"grilling · 적대적 리뷰" 열이다. 이 파일을 가리키지 말고 내용을 지시문에 그대로 넣는다.

---

Implement issue **#<N> "<제목>"** of `<owner>/<repo>`.
- The issue body is your **contract**. Read it and its comments first: `<트래커 조회 명령>`.
- Then read the repo's `CLAUDE.md`. Its rules bind you: worktree, tests and local CI, commits, PR, version and CHANGELOG, file ownership.

Respond in <언어>.

## Where to work

- Work in your own worktree: `<저장소 규칙의 worktree 자리와 브랜치 이름, 예: .claude/worktrees/<N>-<slug>>`, created from the current `origin/<base>`.
- Put the issue number `<N>` in both the worktree directory name and the branch name. Other sessions recognise work in flight by it.
- Leave the main checkout and every other tree as they are.
- <겹침이 있으면: #<M> 도 <파일> 을 바꾼다 — 먼저 병합되는 쪽 위로 rebase 한다.>
- <이어 하기면 위 첫 줄 대신 이 줄을 남긴다: **Continue existing work.** This issue already has worktree `<경로>` on branch `<브랜치>`<, open PR #<P>><, and merged PR #<Q>>. Work there and leave every other worktree, branch and PR alone. First read the PR body, its review comments and its review table, and `git log` since the base. Your request is a follow-up (see "Follow-up requests" below): **<Fix — <고칠 점 목록> / Rebase / Next PR — 계약서의 <k> 번째 PR>**.>

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
1. Commit per the repo's conventions. Split commits by kind: code, tests, docs.
2. **Adversarial review — before you hand anything over.** Spawn one reviewer with the Agent tool: a general-purpose type (the brief keeps it read-only and it must be able to run the tests), model `<리뷰어 model>`, effort `<리뷰어 effort>`, in the foreground. Pass it the brief below **verbatim**. Leave out your own summary, reasoning and confidence. A reviewer handed your conclusion returns it confirmed; one handed only the contract and the code finds what you missed.

   ````
   <review-brief.md 의 지시문을 이 이슈로 채워 넣는다>
   ````

3. Settle every finding with evidence: reproduce it, or refute it with a command or `file:line`.
   - **Fixed**: fix each real one in its own commit. Where a test can show the defect, add one that goes red without the fix.
   - **Rejected**: give the evidence that refutes it.
   - **Deferred**: out of the contract's scope; becomes a follow-up in your report.
4. **Second round**: if your fixes changed behaviour or reached beyond the finding's own lines, spawn a **fresh** reviewer on the new diff with the same brief. Two rounds at most; carry anything still open into the report.
5. **No Agent tool?** If you cannot spawn a subagent here, skip steps 2–4 and say so in the report. The orchestrator runs the review instead.
6. Run the repo's required tests on the exact SHA you will push. If no push hook runs them, run them by hand.
7. Push and open the PR as the contract says: number of PRs, `Closes`/`Refs`, the passing SHA and the review table (below) in the body.
   - Open it as a **draft** (`gh pr create --draft`). If the repo's tooling opens it for you, convert it with `gh pr ready --undo` right after.
   - If drafts are unavailable, start the body with `> ⚠️ 오케스트레이터 검수 전 — 병합하지 마세요.`
   - The orchestrator reviews it, then marks it ready. Merging belongs to the repo's review process.
   - Post no comments, reviews or replies on the PR, and never resolve a thread. Pushing, toggling draft and editing the body are fine. Report to the orchestrator instead.

**Follow-up requests.** The orchestrator may message you after you report. The message is one or both of Fix and Rebase (Rebase first when both), or Next PR:
- **Fix**: the orchestrator's final review found problems, or a human asked for changes on the PR. For a human's PR feedback, the orchestrator gives each item's URL, `path:line` and body.
- **Rebase**: a sibling PR merged and yours now conflicts.
- **Next PR**: an earlier PR of this issue merged, and the contract plans another one.

For a Fix or a Rebase:
1. Put the PR back into draft first (`gh pr ready --undo`). If drafts are unavailable, put the warning line back at the top of the body.
2. For a rebase, rebase onto the current base; never merge. Resolve each conflict so that both sides survive as their contracts say.
3. For a fix, fix each point, with a test where one can show it.
4. If the change altered behaviour, or you resolved a conflict by meaning rather than mechanically, run steps 2–4 of "Then" on the new commits with a fresh reviewer. Add the new rows to the review table.
5. Rerun the required tests, push with `--force-with-lease`, and update the passing SHA in the PR body.
6. Report what you changed (for a rebase: the conflicted files and how you resolved each), the new review rows and the new SHA. The orchestrator reviews again and marks the PR ready.

For a Next PR, start from the current base in the same worktree.
- If the repo's rules fix one branch name per issue, reset that branch to the current base.
- Otherwise create a new branch whose name contains `<N>`.

Then implement that PR's part of the contract with the procedure above, from step 1 through "Then", and open it as a draft.

## When to stop and report instead

Stop and report, with the exact passage and the evidence, when:
- the contract contradicts the code;
- the contract leaves a decision open;
- the work would need changes outside the contract's scope.

The orchestrator resolves it and re-dispatches you. Record found bugs outside the scope in your report.

## Report

- PR URL(s) and the tested SHA. Confirm it equals the PR HEAD.
- Each completion criterion of the contract: met, with how you checked it. A criterion you met only partly is **not met**; leave its checkbox unchecked and say what is missing.
- The review table, one row per finding of every round: `# | severity | finding | outcome (fixed <commit> / rejected / deferred) | evidence`. Say how many rounds ran, or that none could.
- Deviations from the contract and why.
- Follow-ups: out-of-scope bugs found, boundary notes for sibling issues.
