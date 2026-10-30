# 구현 서브에이전트 지시문

`agent-dispatch` 6단계에서 이슈마다 채워 보낸다. `<…>` 를 채우고, 그 이슈의 종류에 맞는 절차 하나만 남긴다.
리뷰어는 서브에이전트가 띄우지 않는다. 7단계에서 오케스트레이터가 따로 띄운다.

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
- <이어 하기면 위 첫 줄 대신 이 줄을 남긴다: **Continue existing work.** This issue already has worktree `<경로>` on branch `<브랜치>`<, open PR #<P>><, and merged PR #<Q>>. Work there and leave every other worktree, branch and PR alone. First read the PR body, its review comments, and `git log` since the base. Your request is a follow-up (see "Follow-up requests" below): **<Fix — <고칠 점 목록> / Rebase / Next PR — 계약서의 <k> 번째 PR>**.>

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
2. **Tidy the history.** If a commit fixes something an earlier commit of this same PR introduced, fold it into that commit instead of leaving it as a separate one: `git commit --fixup=<that commit>`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash $(git merge-base origin/<base> HEAD)`. Never merge. The repo is rebase-merge only, so the branch history lands on the base as is.
3. **Do not spawn a reviewer.** The orchestrator runs the adversarial review in parallel with its own final check as soon as you hand over the PR.
4. Run the repo's required tests on the exact SHA you will push. If no push hook runs them, run them by hand.
5. Push and open the PR as the contract says: number of PRs, `Closes`/`Refs`, the passing SHA in the body, and a line `리뷰: 오케스트레이터가 수행`.
   - Open it as a **draft** (`gh pr create --draft`). If the repo's tooling opens it for you, convert it with `gh pr ready --undo` right after.
   - If drafts are unavailable, start the body with `> ⚠️ 오케스트레이터 검수 전 — 병합하지 마세요.`
   - The orchestrator reviews it, then marks it ready. Merging belongs to the repo's review process.
   - Post no comments, reviews or replies on the PR, and never resolve a thread. Pushing, toggling draft and editing the body are fine. Report to the orchestrator instead.

**Follow-up requests.** The orchestrator may message you after you report. The message is one or both of Fix and Rebase (Rebase first when both), or Next PR:
- **Fix**: the orchestrator's final check and its reviewer found problems, or a human asked for changes on the PR. The message carries each item: for review findings, severity, finding and evidence; for a human's PR feedback, its URL, `path:line` and body.
- **Rebase**: a sibling PR merged and yours now conflicts.
- **Next PR**: an earlier PR of this issue merged, and the contract plans another one.

For a Fix or a Rebase:
1. Put the PR back into draft first (`gh pr ready --undo`). If drafts are unavailable, put the warning line back at the top of the body.
2. For a rebase, rebase onto the current base; never merge. Resolve each conflict so that both sides survive as their contracts say.
3. For a fix, fix each point, with a test where one can show it.
4. Fold each fix into the commit that introduced the problem (step 2 of "Then"). Spawn no reviewer; the orchestrator re-reviews when behaviour changed or a conflict was resolved by meaning.
5. Rerun the required tests, push with `--force-with-lease`, and update the passing SHA in the PR body.
6. Report what you changed (for a rebase: the conflicted files, and for each whether you resolved it mechanically or by meaning) and the new SHA. The orchestrator checks again and marks the PR ready.

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
- Deviations from the contract and why.
- Follow-ups: out-of-scope bugs found, boundary notes for sibling issues.
