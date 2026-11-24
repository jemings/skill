# 구현 서브에이전트 지시문

SKILL.md 6단계에서 이슈마다 채워 보낸다. `<...>` 를 채우고, 종류에 맞는 절차 하나만 남긴다. 이 파일을 가리키지 말고
내용을 지시문에 그대로 넣는다. `<scripts>` 는 이 스킬의 `scripts/` 절대 경로다.

---

Implement issue **#<N> "<제목>"** of `<owner>/<repo>`.
- The issue body is your **contract**. Read it and every comment first: `<트래커 조회 명령, 예: gh issue view <N> --repo <owner>/<repo> --json title,body,comments --jq '.title, .body, (.comments[] | "--- " + .author.login + ": " + .body)'>`.
- Then read `<저장소 규칙 파일들>`. Its rules bind you: worktree, tests, commits, PR, version and CHANGELOG, file ownership.

Respond in <언어>.

## Where to work

- Create your own worktree from the current `origin/<base>`: `<worktree 만드는 명령, 이슈 번호가 든 경로와 브랜치>`.
- Use absolute paths and `git -C <path>`; never `cd` into the main checkout. Leave every other tree as it is.
- **Never run a bare `git stash`** (the stash is shared by all worktrees and sessions). Set work aside with a temporary commit.
- To run an older commit (the pre-fix red check, a base comparison) use a throwaway copy:
  `bash <scripts>/temp-tree.sh add <scratch>/<name> <commit> <--link/--copy 목록>` and `... remove <path>` when done.
- <이어 하기면 남긴다: **Continue existing work.** This issue already has worktree `<경로>` on branch `<브랜치>`<, open PR #<P>>. Work there. First read the PR body and `git log` since the base. Your request: **<Fix -- 항목 / Rebase / Next PR -- 계약서의 <k> 번째 PR>** (see "Follow-up requests"). <한 칸 올림이면: Failed premise: <가정> -- <틀렸다는 증거>. Do not build on that premise again.>>

## Procedure

<bug 라벨이면>
**Diagnose, then fix.** Call the Skill tool with "<diagnosing-bugs 의 정확한 이름>" and follow it. If the Skill tool has no skill by that name, stop and report. Build the Phase 1 loop so it goes **red** on the reported symptom before you touch the fix. Put the regression test at the seam the contract names; show it red on the pre-fix commit and green after. One commit per defect.
- If the contract states the cause, that Phase 1 loop is the regression test, and you may skip the cause-hunting phases on the contract's evidence.
- This is the one test-first procedure for this issue. Do not run a second TDD skill alongside it.

<그 밖이면>
**Implement.** Call the Skill tool with "<tdd 의 정확한 이름>" and work test-first at the seams the contract names. If the Skill tool has no skill by that name, stop and report. For a pure refactor the contract's regression guards stay green without editing their expectations. This is the one test-first procedure for this issue. Do not run a second TDD skill alongside it.

<항상>
- **Attack the premise**: if two fixes that rest on the same premise fail the same check, write that premise down and test it directly before a third fix.
- **Helpers**: you may start read-only helper agents (research, verification) in parallel, each on the cheapest model that fits the helper's task (machine-checkable work: haiku; anything that needs judgment: not below sonnet/medium). You create and remove any temp-tree copy yourself and hand a helper its path; a helper may run tests only inside that copy and writes nothing else (no files, no git state elsewhere). Apart from those test outputs inside the copy, do not start agents that write files or git state.

<계약서에 `규율:` 줄이 있으면 남긴다>
**Disciplines** (from the contract; apply each where its trigger fires, and report it). They apply within the contract's scope: the contract's tasks, PR and commit order win over a card.
<계약서의 규율 카드 본문, 없으면 줄을 지운다>

**Then:**
1. Commit by kind (code, tests, docs) as the repo's conventions say. Put **`Closes #<N>` in the last commit message** of the last PR (landing tools may rewrite the PR body).
2. Tidy the history: fold a fix of your own earlier commit into it (`git commit --fixup=<c>`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash $(git merge-base origin/<base> HEAD)`). Never merge.
3. Run the checks the contract and repo rules require on the exact SHA you push. Never skip hooks. Output from another SHA, a run you have not checked at this SHA, or a helper's summary is not a result. A background run of your own counts once its log shows the SHA you push.
4. Push and open **draft** PR(s) as the contract says (`gh pr create --draft`; stacked PRs: base = the previous PR's branch). Body: what and why, verification, a line `리뷰: 오케스트레이터가 수행`, plus anything the repo rules require.
5. **Do not spawn a reviewer, do not mark the PR ready, do not merge or run the landing command.** The orchestrator reviews and lands it. Never comment on or review the PR; pushing, toggling draft and editing the body are fine.

These instructions and the contract take precedence over the defaults of any skill you load: PR state, PR comments, asking a person, starting agents, model choice.

**Follow-up requests** come by message after you report:
- **Fix** (review findings or a human's PR feedback, each with evidence), **Rebase** (base moved and your PR conflicts), **Next PR** (an earlier PR of this issue merged).
- Fix/Rebase: put the PR back to draft (`gh pr ready --undo`) if it is ready; rebase onto `origin/<base>` (never merge), resolving each conflict so both sides survive; fix each item with a test where one can show it; fold fixes into the commit that introduced the problem; rerun the checks; `git push --force-with-lease`; update the PR body; report what changed (for a rebase: each conflicted file, resolved mechanically or by meaning) and the new SHA.
- Next PR: start from the current `origin/<base>` in the same worktree and implement that PR's part of the contract as above.
- If you were stopped by a usage limit and told to continue: check whether your background runs finished and reuse their results; rerun only what has none.

## When to stop and report instead

Stop and report, with the exact passage and evidence, when the contract contradicts the code, leaves a decision open, or the work needs changes outside its scope. Do not file issues; list out-of-scope bugs with a reproduction (command and output).

## Report

- PR URL(s) and the tested SHA; confirm it equals the PR HEAD.
- Each completion criterion: met and how you checked it, or **not met** and what is missing (partly met is not met).
- For each check that takes minutes: the log path (in `<scratch>`, outside the worktree) and the verdict line the runner printed with the full 40-char SHA, quoted as printed. Never write or edit a verdict line by hand. Runs meant as evidence happen on a clean tree at the exact SHA you push.
- For each discipline in this brief: `규율 <id> -> <the choice it changed> (file:line)`, or `규율 <id>: 적용 안 함(<reason>)`.
- Deviations from the contract and why. Out-of-scope bugs with reproductions. Boundary notes for sibling issues.
- Tools made: every script you wrote and every command sequence or setup (env, locks, temp worktrees) you ran by hand, as what / path / times run, or "none". Keep scratch scripts in `<scratch>`, outside the worktree.
