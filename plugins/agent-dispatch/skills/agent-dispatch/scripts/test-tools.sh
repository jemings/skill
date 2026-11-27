#!/usr/bin/env bash
# land.sh, pr-check.sh, temp-tree.sh, mutate.sh, frontier.sh 의 시험 하네스. 네트워크를 쓰지 않는다.
# gh 는 PATH 의 스텁(상태 파일로 움직인다), git 은 진짜이고 원격은 임시 bare 저장소다.
#
#   bash plugins/agent-dispatch/skills/agent-dispatch/scripts/test-tools.sh
#   ONLY='land' bash .../test-tools.sh       라벨이 ERE 에 맞는 경우만 돈다(맞는 것이 없으면 exit 1)
#
# 경우를 더하는 법: t_<이름>() 를 쓰고 CASES 에 이름을 적는다. 안에서 setup_repo 로 저장소를 만들고,
# run <스크립트> [인자...] 로 돌린 뒤 expect_* 로 대조한다. gh 상태는 pr <N> <필드>=<값>... 으로 둔다.
set -uo pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
BIN=$ROOT/bin; mkdir -p "$BIN"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1 HOME=$ROOT
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# gh 스텁. 상태: $ST/pr_<N>.json, $ST/merge_err, $ST/repo.json(repo view --json 의 병합 설정, $ST/fail_repo_view 면 exit 1), $ST/issue_<N>, $ST/mseq_<N>(mergeable 을 차례로 낸다),
# $ST/sub_issues.json, $ST/search.json, $ST/fail_json_<필드>(pr view --json <필드> 가 exit 1). 받은 호출은 $ST/calls 에 한 줄씩 남는다. $ST/issue_<N> 내용이 FAIL 이면 조회가 exit 1 이다.
# opt-in: $ST/live_head(내용은 bare 원격 경로)가 있으면 headRefOid 를 그 원격의 head 브랜치에서 읽고, 병합은 base 를 그 HEAD 로
# 앞당긴다(--squash 면 HEAD 의 트리로 base 하나만 부모인 병합 커밋을 만들어 base 를 그것으로 옮긴다). $ST/on_merge_<N> 은 병합 호출마다 한 줄 "<move|stay> [gh 오류]" 를 꺼내 move 면 base 에 빈 커밋을 올리고, 그 오류
# (없으면 "Base branch was modified")로 exit 1. $ST/merge_hook 이 있으면 병합 호출의 맨 앞에서 sh 로 돌린다.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
st=${ST:?}
echo "$*" >> "$st/calls"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
jqf=$(arg --jq "$@")
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
setf() { local f=$st/pr_$1.json t; t=$(mktemp); jq "$2" "$f" > "$t" && mv "$t" "$f"; }
field() { jq -r ".$2" "$st/pr_$1.json"; }
bare() { git --git-dir="$(cat "$st/live_head")" "$@"; }
live() { [ ! -f "$st/live_head" ] || setf "$1" ".headRefOid=\"$(bare rev-parse "refs/heads/$(field "$1" headRefName)")\""; }
on_merge() {
  local f=$st/on_merge_$1 ev msg b old
  [ -s "$f" ] || return 0
  ev=$(head -1 "$f"); sed -i 1d "$f"; b=refs/heads/$(field "$1" baseRefName)
  msg=${ev#* }; [ "$msg" != "$ev" ] || msg="GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)"
  if [ "${ev%% *}" = move ]; then old=$(bare rev-parse "$b"); bare update-ref "$b" "$(bare commit-tree "$old^{tree}" -p "$old" -m moved)"; fi
  echo "$msg" >&2; exit 1
}
case "$1 $2" in
  "pr view")
    n=$3; f=$st/pr_$n.json; [ -f "$f" ] || { echo "no PR $n" >&2; exit 1; }
    [ ! -f "$st/fail_json_$(arg --json "$@")" ] || { echo "gh: could not read $(arg --json "$@")" >&2; exit 1; }
    live "$n"
    if [ -s "$st/mseq_$n" ]; then m=$(head -1 "$st/mseq_$n"); sed -i 1d "$st/mseq_$n"; setf "$n" ".mergeable=\"$m\""; fi
    [ ! -f "$st/merge_on_view_$n" ] || setf "$n" '.state="MERGED" | .mergeCommit={"oid":"feedface0000"}'
    emit < "$f" ;;
  "pr ready") setf "$3" '.isDraft=false' ;;
  "pr merge")
    n=$3; [ ! -f "$st/merge_hook" ] || sh "$st/merge_hook"
    [ ! -f "$st/merge_err" ] || { cat "$st/merge_err" >&2; exit 1; }
    live "$n"; on_merge "$n"
    want=$(arg --match-head-commit "$@"); head=$(field "$n" headRefOid)
    [ "$want" = "$head" ] || { echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" >&2; exit 1; }
    if [ -f "$st/live_head" ]; then
      b=refs/heads/$(field "$n" baseRefName); mc=$head
      case " $* " in *" --squash "*) mc=$(bare commit-tree "$head^{tree}" -p "$(bare rev-parse "$b")" -m squash) ;; esac
      bare update-ref "$b" "$mc"; setf "$n" ".state=\"MERGED\" | .mergeCommit={\"oid\":\"$mc\"}"
    else
      setf "$n" '.state="MERGED" | .mergeCommit={"oid":"cafebabe1234"}'
    fi ;;
  "pr close") setf "$3" '.state="CLOSED"' ;;
  "issue comment") cp "$(arg --body-file "$@")" "$st/comment_$3" ;;
  "issue view")
    if [ -f "$st/issue_$3" ]; then [ "$(cat "$st/issue_$3")" != FAIL ] || { echo "gh: issue $3 not found" >&2; exit 1; }; cat "$st/issue_$3"; else echo OPEN; fi ;;
  "repo view")
    case " $* " in
      *" defaultBranchRef "*) echo main ;;
      *) [ ! -f "$st/fail_repo_view" ] || { echo "gh: could not read repository" >&2; exit 1; }; emit < "$st/repo.json" ;;
    esac ;;
  "api user") echo me ;;
  *)
    case " $* " in
      *" -X PATCH "*pulls/*) all="$*"; n=${all##*pulls/}; n=${n%% *}; b=$(arg -f "$@"); setf "$n" ".baseRefName=\"${b#base=}\"" ;;
      *sub_issues*) cat "$st/sub_issues.json" ;;
      *search/issues*) arg -f "$@" > "$st/search_q"; cat "$st/search.json" ;;
      *) echo "gh stub: 모르는 호출: $*" >&2; exit 1 ;;
    esac ;;
esac
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH" LAND_POLL=0 PR_CHECK_POLL=0

PASS=0 FAIL=0 CASE='' BAD=0 OUT='' ERR='' RC=0
bad() { [ $BAD = 1 ] || printf 'FAIL %s: %s\n' "$CASE" "${1//$'\n'/ }"; BAD=1; }
expect_rc() { [ "$RC" = "$1" ] || bad "exit $1 이어야 하는데 $RC (out: $OUT) (err: $ERR)"; }
expect_last() { [ "$(printf '%s\n' "$OUT" | tail -1)" = "$1" ] || bad "마지막 줄이 '$1' 이어야 하는데 '$(printf '%s\n' "$OUT" | tail -1)'"; }
expect_has() { case $OUT in *"$1"*) ;; *) bad "출력에 '$1' 이 없다: $OUT" ;; esac; }
expect_not() { case $OUT in *"$1"*) bad "출력에 '$1' 이 있으면 안 된다: $OUT" ;; esac; }
expect_called() { grep -qF -- "$1" "$ST/calls" 2>/dev/null || bad "gh 호출 '$1' 이 없다: $(tr '\n' '|' < "$ST/calls" 2>/dev/null)"; }
expect_not_called() { ! grep -qF -- "$1" "$ST/calls" 2>/dev/null || bad "gh 호출 '$1' 이 있으면 안 된다"; }
expect_err() { case $ERR in *"$1"*) ;; *) bad "stderr 에 '$1' 이 없다: $ERR" ;; esac; }
expect_path() { [ -e "$1" ] || bad "$1 이 있어야 한다"; }
expect_gone() { [ ! -e "$1" ] || bad "$1 이 없어야 한다"; }

# setup_repo -- $T 아래에 bare 원격 o/r.git, 주 체크아웃 repo, 브랜치 feat 의 worktree wt(커밋 하나, push 됨)를 만든다
setup_repo() {
  T=$(mktemp -d "$ROOT/c.XXXX"); ST=$T/st; mkdir -p "$ST" "$T/o"; export ST
  git init -q --bare "$T/o/r.git"
  git clone -q "$T/o/r.git" "$T/repo" 2>/dev/null
  ( cd "$T/repo" && echo a > a && git add a && git commit -qm init && git push -q origin main
    git worktree add -q "$T/wt" -b feat && cd "$T/wt" && echo b > b && git add b && git commit -qm "feat: b" -m "Closes #5" && git push -q -u origin feat ) >/dev/null 2>&1
  HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
  echo '{"rebaseMergeAllowed":true,"squashMergeAllowed":true,"mergeCommitAllowed":false}' > "$ST/repo.json"
  pr 7 state=OPEN isDraft=true headRefOid="$HEAD_SHA" headRefName=feat baseRefName=main mergeable=MERGEABLE
}
pr() { # pr <N> k=v... -- PR 상태 파일을 만들거나 고친다(isDraft 는 불리언)
  local n=$1 f; shift; f=$ST/pr_$n.json; [ -f "$f" ] || echo '{"mergeCommit":null}' > "$f"
  local kv k v t
  for kv in "$@"; do k=${kv%%=*}; v=${kv#*=}; t=$(mktemp)
    if [ "$k" = isDraft ]; then jq ".$k=$v" "$f" > "$t"; else jq --arg v "$v" ".$k=\$v" "$f" > "$t"; fi; mv "$t" "$f"; done
}
run() { local s=$1; shift; ( cd "${RUN_DIR:-$T/repo}" && bash "$SCRIPTS/$s" "$@" ) >"$T/so" 2>"$T/se"; RC=$?; OUT=$(cat "$T/so"); ERR=$(cat "$T/se"); }

# ---- land.sh
t_land_gh() { # draft 를 ready 로 바꾸고, 리뷰한 HEAD 로 rebase 병합하고, 기록을 남기고, 뒷정리한다
  setup_repo; echo "기록" > "$T/ev"
  run land.sh --repo o/r --pr 7 --sha "${HEAD_SHA:0:9}" --issue 5 --evidence "$T/ev"
  expect_rc 0; expect_last "LANDED #7 cafebabe1234 ISSUE #5 OPEN"
  expect_called "pr ready 7"; expect_called "pr merge 7 --repo o/r --rebase --match-head-commit $HEAD_SHA"
  [ "$(cat "$ST/comment_5" 2>/dev/null)" = "기록" ] || bad "검증 기록이 이슈 댓글로 가지 않았다"
  expect_gone "$T/wt"
  git -C "$T/repo" show-ref --verify -q refs/heads/feat && bad "로컬 브랜치가 남았다"
  [ -z "$(git -C "$T/repo" ls-remote --heads origin feat)" ] || bad "원격 브랜치가 남았다"
}
t_land_head_moved() { # 리뷰 뒤 HEAD 가 바뀌면 넣지도 지우지도 않는다
  setup_repo; run land.sh --repo o/r --pr 7 --sha 0123456789
  expect_rc 1; expect_has "BLOCKED #7 PR HEAD 가 검수한 SHA 와 다르다"; expect_not_called "pr merge"; expect_not_called "pr ready"; expect_path "$T/wt"
}
t_land_conflict() {
  setup_repo; pr 7 mergeable=CONFLICTING; run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 1; expect_has "충돌"; expect_not_called "pr merge"; expect_path "$T/wt"
}
t_land_unknown_then_ok() { # mergeable 이 UNKNOWN 이면 다시 본다
  setup_repo; pr 7 mergeable=UNKNOWN; printf 'UNKNOWN\nMERGEABLE\n' > "$ST/mseq_7"; run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 0; expect_has "LANDED #7"
}
t_land_needs_human() { # 보호 규칙이 승인을 요구하면 exit 3 이고 worktree 를 남긴다
  setup_repo; echo "GraphQL: At least 1 approving review is required by reviewers with write access." > "$ST/merge_err"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 3; expect_has "NEEDS_HUMAN #7"; expect_path "$T/wt"
}
t_land_merge_fail() { # 그 밖의 병합 실패는 BLOCKED
  setup_repo; echo "something else broke" > "$ST/merge_err"; run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 1; expect_has "BLOCKED #7 gh pr merge 실패: something else broke"; expect_path "$T/wt"
}
t_land_gh_transient() { # 저장소 명령 없이도 base 이동 경합(Base branch was modified)은 같은 HEAD 로 다시 병합한다
  setup_repo; echo stay > "$ST/on_merge_7"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 0; expect_has "LANDED #7"; expect_not "NEEDS_HUMAN"; expect_merges 2
}
t_land_gh_transient_limit() { # 다시 하는 횟수는 LAND_ROUNDS 가 정하고, 넘으면 BLOCKED 다
  setup_repo; printf 'stay\nstay\nstay\n' > "$ST/on_merge_7"
  LAND_ROUNDS=2 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 1; expect_last "BLOCKED #7 base 가 움직여 2번 다시 했다"; expect_merges 2
  : > "$ST/calls"; printf 'stay\nstay\nstay\nstay\n' > "$ST/on_merge_7"
  LAND_ROUNDS=3 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 1; expect_last "BLOCKED #7 base 가 움직여 3번 다시 했다"; expect_merges 3
}
t_land_gh_retry_mergeable() { # 다시 하기 전에 mergeable 을 다시 읽는다
  setup_repo; printf 'stay\nstay\n' > "$ST/on_merge_7"; printf 'MERGEABLE\nCONFLICTING\n' > "$ST/mseq_7"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 1; expect_has "충돌"; expect_merges 1
  setup_repo; printf 'stay\n' > "$ST/on_merge_7"; printf 'MERGEABLE\nUNKNOWN\nMERGEABLE\n' > "$ST/mseq_7"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 0; expect_has "LANDED #7"; expect_merges 2
}
t_land_gh_rounds_arg() { # gh 길도 LAND_ROUNDS 를 검증하고 --via 는 검증하지 않는다
  setup_repo; LAND_ROUNDS=x run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"; expect_rc 2
  LAND_ROUNDS=0 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"; expect_rc 2
  LAND_ROUNDS=x run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via true; expect_rc 1
}
t_land_gh_head_modified() { # 병합 직전에 HEAD 가 바뀌었다는 오류는 사람 승인이 아니라 BLOCKED 다
  setup_repo; echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" > "$ST/merge_err"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"
  expect_rc 1; expect_last "BLOCKED #7 PR HEAD 가 병합 직전에 바뀌었다: GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)"
}
t_land_loop_head_modified() { # 고리 길도 같다. PR 브랜치는 검수한 SHA 로 돌아간다
  loop_setup; echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" > "$ST/merge_err"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_has "BLOCKED #7 PR HEAD 가 병합 직전에 바뀌었다"; expect_pr_branch "$HEAD_SHA"
}
t_land_method_squash() { # 저장소가 rebase 를 막았으면 squash
  setup_repo; echo '{"rebaseMergeAllowed":false,"squashMergeAllowed":true,"mergeCommitAllowed":false}' > "$ST/repo.json"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"; expect_rc 0; expect_called "pr merge 7 --repo o/r --squash"
}
t_land_method_explicit() { # 설정이 rebase, squash 를 모두 허용해도 --method squash 면 squash 로 넣는다
  setup_repo; run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash
  expect_rc 0; expect_called "pr merge 7 --repo o/r --squash --match-head-commit $HEAD_SHA"; expect_not_called "--rebase"
}
t_land_method_disallowed() { # 저장소가 허용하지 않는 --method 는 기록, ready, push, 병합 전에 BLOCKED 다(gh 길, 고리 길)
  setup_repo; echo "기록" > "$T/ev"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --issue 5 --evidence "$T/ev" --method merge
  expect_rc 1; expect_last "BLOCKED #7 저장소가 merge 병합을 허용하지 않는다"
  expect_not_called "pr ready"; expect_not_called "pr merge"; expect_gone "$ST/comment_5"; expect_path "$T/wt"
  loop_setup; echo '{"rebaseMergeAllowed":true,"squashMergeAllowed":false,"mergeCommitAllowed":false}' > "$ST/repo.json"
  base_commit c c
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --pre-merge "$PRE"
  expect_rc 1; expect_last "BLOCKED #7 저장소가 squash 병합을 허용하지 않는다"
  expect_not_called "pr ready"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"
}
t_land_method_merge() { # 설정이 merge 커밋을 허용하면 --method merge 로 넣는다
  setup_repo; echo '{"rebaseMergeAllowed":true,"squashMergeAllowed":true,"mergeCommitAllowed":true}' > "$ST/repo.json"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method merge
  expect_rc 0; expect_called "pr merge 7 --repo o/r --merge --match-head-commit $HEAD_SHA"
}
t_land_method_unreadable() { # 병합 설정을 읽지 못하면 기록, ready, 병합 전에 BLOCKED 다
  setup_repo; echo "기록" > "$T/ev"; touch "$ST/fail_repo_view"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --issue 5 --evidence "$T/ev"
  expect_rc 1; expect_last "BLOCKED #7 저장소의 병합 방식을 읽지 못했다"
  expect_not_called "pr ready"; expect_not_called "pr merge"; expect_gone "$ST/comment_5"
}
t_land_via() { # 저장소의 착륙 명령을 PR 의 worktree 에서 돌리고 MERGED 를 확인한다. 병합 설정은 읽지 않는다
  setup_repo
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via "pwd > $T/via_cwd; touch $ST/merge_on_view_7"
  expect_rc 0; expect_has "LANDED #7 feedface0000"; expect_not_called "pr merge"; expect_not_called "repo view"
  [ "$(cat "$T/via_cwd" 2>/dev/null)" = "$(cd "$T" && pwd -P)/wt" ] || bad "착륙 명령이 PR worktree 에서 돌지 않았다: $(cat "$T/via_cwd" 2>/dev/null)"
  expect_gone "$T/wt"
}
t_land_via_fails() {
  setup_repo; run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via "exit 4"
  expect_rc 1; expect_has "착륙 명령이 실패했다"; expect_path "$T/wt"
}
t_land_via_not_merged() { # 착륙 명령이 0 으로 끝나도 MERGED 가 아니면 BLOCKED, 정리하지 않는다
  setup_repo; LAND_TRIES=2 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via "true"
  expect_rc 1; expect_has "PR 이 OPEN 다"; expect_path "$T/wt"
}
t_land_stack() { # 마지막 층의 대상을 base 로 바꾸고, 앞 층을 닫고 그 브랜치도 정리한다
  setup_repo
  ( cd "$T/repo" && git worktree add -q "$T/wt0" -b low main && cd "$T/wt0" && echo c > c && git add c && git commit -qm low && git push -q -u origin low ) >/dev/null 2>&1
  pr 6 state=OPEN isDraft=false headRefOid=x headRefName=low baseRefName=main mergeable=MERGEABLE
  pr 7 baseRefName=low
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --base main --close-stack 6
  expect_rc 0; expect_called "api -X PATCH repos/o/r/pulls/7 -f base=main"; expect_called "pr close 6 --repo o/r --comment #7 로 들어갔다"
  expect_gone "$T/wt0"; [ -z "$(git -C "$T/repo" ls-remote --heads origin low)" ] || bad "앞 층 원격 브랜치가 남았다"
}
t_land_keep() {
  setup_repo; run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --keep
  expect_rc 0; expect_path "$T/wt"; [ -z "$(git -C "$T/repo" ls-remote --heads origin feat)" ] || bad "--keep 이어도 원격 브랜치는 지운다"
}
t_land_cleanup() { # --cleanup 은 MERGED 일 때만 정리한다
  setup_repo; run land.sh --cleanup --repo o/r --pr 7
  expect_rc 1; expect_path "$T/wt"
  pr 7 state=MERGED; echo CLOSED > "$ST/issue_5"; run land.sh --cleanup --repo o/r --pr 7 --issue 5
  expect_rc 0; expect_last "CLEANED #7 ISSUE #5 CLOSED"; expect_gone "$T/wt"
}
t_land_args() {
  setup_repo
  run land.sh --repo o/r --pr 7; expect_rc 2
  run land.sh --repo bad --pr 7 --sha "$HEAD_SHA"; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --evidence "$T/none"; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method fast; expect_rc 2
  run land.sh --cleanup --repo o/r --pr 7 --via x; expect_rc 2
  expect_not_called "pr merge"
}

# ---- pr-check.sh
t_check_ok() {
  setup_repo; git -C "$T/wt" fetch -q origin
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --sha "${HEAD_SHA:0:9}" --closes 5 --forbid-trailer '^Co-Authored-By:' --forbid-path '^CHANGELOG\.md$'
  expect_rc 0; expect_last "SHAPE OK"; expect_has "OK Closes #5"; expect_has "INFO 커밋 1개"
}
t_check_fails() { # 각 검사가 저마다 걸린다
  setup_repo; git -C "$T/wt" fetch -q origin
  ( cd "$T/wt" && echo x > CHANGELOG.md && git add CHANGELOG.md && git commit -qm "chore" -m "Co-Authored-By: x <x@x>" && echo dirt > d ) >/dev/null
  pr 7 mergeable=CONFLICTING baseRefName=dev
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --sha 0123456 --closes 9 --forbid-trailer '^Co-Authored-By:' --forbid-path '^CHANGELOG\.md$'
  expect_rc 1; expect_last "SHAPE FAIL"
  for w in "FAIL 대상" "FAIL HEAD" "FAIL 보고한 SHA" "FAIL 작업 트리" "FAIL 충돌" "FAIL Closes" "FAIL 커밋 메시지" "FAIL 바뀐 파일"; do expect_has "$w"; done
}
t_check_forbid_rename() { # 금지 경로를 이름 바꾸기로 옮겨도 옛 경로로 걸린다
  setup_repo; git -C "$T/wt" fetch -q origin
  ( cd "$T/wt" && git mv a moved-a && git commit -qm "chore: move" ) >/dev/null
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --forbid-path '^a$'
  expect_rc 1; expect_last "SHAPE FAIL"; expect_has "FAIL 바뀐 파일"
}
t_check_closes_body() { # --closes-body: Closes 를 커밋 메시지 대신 PR 본문에서 찾는다
  setup_repo; git -C "$T/wt" fetch -q origin
  git -C "$T/wt" commit -q --amend -m "feat: b"; HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD); pr 7 headRefOid="$HEAD_SHA" body="무엇을 고쳤나

Closes #5"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --closes 5 --closes-body
  expect_rc 0; expect_last "SHAPE OK"; expect_has "OK Closes #5"; expect_called "--json body"
  pr 7 body="본문에는 없다"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --closes 5 --closes-body
  expect_rc 1; expect_last "SHAPE FAIL"; expect_has "FAIL Closes: PR 본문에"
  setup_repo; git -C "$T/wt" fetch -q origin; pr 7 body="본문에는 없다"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --closes 5 --closes-body
  expect_rc 1; expect_last "SHAPE FAIL"; expect_has "FAIL Closes: PR 본문에"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --closes 5
  expect_rc 0; expect_has "OK Closes #5"
  touch "$ST/fail_json_body"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --closes 5 --closes-body
  expect_rc 1; expect_last "SHAPE FAIL"; expect_has "FAIL Closes: PR 본문을 읽지 못했다"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --closes-body
  expect_rc 2; expect_err "--closes-body"; expect_not "SHAPE"
}
t_check_unknown() {
  setup_repo; git -C "$T/wt" fetch -q origin; pr 7 mergeable=UNKNOWN; printf 'UNKNOWN\nMERGEABLE\n' > "$ST/mseq_7"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt"; expect_rc 0; expect_has "OK 충돌 없음"
}
t_check_args() { setup_repo; run pr-check.sh --repo o/r --pr 7 --worktree "$T/none"; expect_rc 2; }
t_check_draft_ok() { # --draft: draft PR 이면 OK draft
  setup_repo; git -C "$T/wt" fetch -q origin
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --draft
  expect_rc 0; expect_last "SHAPE OK"; expect_has "OK draft"
}
t_check_draft_ready() { # --draft: ready 인 PR 은 FAIL draft. --draft 가 없으면 draft 를 보지 않는다
  setup_repo; git -C "$T/wt" fetch -q origin; pr 7 isDraft=false
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --draft
  expect_rc 1; expect_last "SHAPE FAIL"; expect_has "FAIL draft: "
  : > "$ST/calls"; run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt"
  expect_rc 0; expect_last "SHAPE OK"; expect_not "draft"; expect_not_called "isDraft"
}
t_check_draft_unreadable() { # --draft: isDraft 를 읽지 못하면 draft 로 치지 않는다
  setup_repo; git -C "$T/wt" fetch -q origin; touch "$ST/fail_json_isDraft"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --draft
  expect_rc 1; expect_last "SHAPE FAIL"; expect_has "FAIL draft: "; expect_has "isDraft=?"; expect_called "--json isDraft"
}
# 증거 판정(--verdict, --carry): EVIDENCE OK 나 RERUN 을 내되 fails 에 세지 않는다
vsetup() { setup_repo; git -C "$T/wt" fetch -q origin; mkdir -p "$T/logs"; }
vlog() { printf 'run e2e\n%s\n' "$1" > "$T/logs/e2e.log"; }
t_check_verdict_ok() {
  vsetup; vlog "통과: $HEAD_SHA e2e-login"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=통과: {sha} e2e-login"
  expect_rc 0; expect_last "SHAPE OK"; expect_has "EVIDENCE OK verdict#1 $T/logs/e2e.log: 통과: $HEAD_SHA e2e-login"; expect_not RERUN
}
t_check_verdict_short_sha() { # 12자 SHA 는 PR HEAD 의 증거가 아니다
  vsetup; vlog "통과: ${HEAD_SHA:0:12}"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=통과: {sha}"
  expect_rc 0; expect_last "SHAPE OK"; expect_has "RERUN verdict#1 $T/logs/e2e.log"; expect_not "EVIDENCE OK"
}
t_check_verdict_old_sha() { # 앞 커밋에서 찍힌 판정 줄은 받지 않는다
  vsetup; OLD=$(git -C "$T/wt" rev-parse HEAD~1); vlog "통과: $OLD"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=통과: {sha}"
  expect_rc 0; expect_last "SHAPE OK"; expect_has "RERUN verdict#1 $T/logs/e2e.log"; expect_not "EVIDENCE OK"
}
t_check_verdict_no_placeholder() { # {sha} 가 없는 글자는 아무 SHA 에나 맞으므로 인자 오류다
  vsetup; vlog "통과: $HEAD_SHA"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=통과:"
  expect_rc 2; expect_err "{sha}"; expect_not "SHAPE"
}
t_check_verdict_newline() { # 줄바꿈이 든 글자는 grep -F 가 패턴 여럿으로 가르므로 인자 오류다
  vsetup; vlog "통과: $HEAD_SHA"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=x {sha}"$'\n'"통과"
  expect_rc 2; expect_err "줄바꿈"; expect_not "SHAPE"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=통과: {sha}"$'\r'
  expect_rc 2; expect_err "줄바꿈"; expect_not "SHAPE"
}
t_check_verdict_labels() { # 같은 로그를 여러 번 줘도 라벨이 순번으로 갈리고, 못 읽는 로그는 RERUN
  vsetup; vlog "통과: $HEAD_SHA"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --verdict "$T/logs/e2e.log=통과: {sha}" \
    --verdict "$T/logs/e2e.log=불가 {sha}" --verdict "$T/logs/none.log=통과: {sha}"
  expect_rc 0; expect_last "SHAPE OK"; expect_has "EVIDENCE OK verdict#1 $T/logs/e2e.log: 통과: $HEAD_SHA"
  expect_has "RERUN verdict#2 $T/logs/e2e.log: "; expect_has "RERUN verdict#3 $T/logs/none.log: 로그를 읽지 못했다"
}
# carry_commit <메시지> <파일>... -- wt 에 파일을 고쳐 커밋하고 PR HEAD 를 그리로 옮긴다. OLD 는 앞 HEAD 다
carry_commit() { local m=$1 f; shift; OLD=$(git -C "$T/wt" rev-parse HEAD)
  for f in "$@"; do echo "$m" >> "$T/wt/$f"; done
  git -C "$T/wt" add -A && git -C "$T/wt" commit -qm "$m"; carry_head; }
carry_head() { HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD); pr 7 headRefOid="$HEAD_SHA"; }
t_check_carry_same_tree() { # 메시지만 바꾼 HEAD 는 선언 없이 이어 받고, 선언이 없으면 tree 가 같을 때만 받는다
  setup_repo; git -C "$T/wt" fetch -q origin; OLD=$HEAD_SHA
  git -C "$T/wt" commit -q --amend -m "feat: b 다시"; carry_head
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD"
  expect_rc 0; expect_last "SHAPE OK"; expect_has "EVIDENCE OK carry#1 ${OLD:0:12}"; expect_not RERUN
  local same=$OLD; carry_commit "chore: version" VERSION
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$same"
  expect_rc 0; expect_last "SHAPE OK"; expect_has "RERUN carry#1 ${same:0:12}: --may-touch 밖 경로 VERSION"; expect_not "EVIDENCE OK"
}
t_check_carry_allowed() { # 허용 경로는 합집합이다(두 경로가 각각 다른 ERE 에만 맞는다)
  setup_repo; git -C "$T/wt" fetch -q origin; carry_commit "chore: version" VERSION CHANGELOG.md
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch '^CHANGELOG\.md$' --may-touch '^VERSION$'
  expect_rc 0; expect_last "SHAPE OK"; expect_has "EVIDENCE OK carry#1 ${OLD:0:12}: 2 files changed"; expect_not RERUN
}
t_check_carry_outside() { # 허용 밖 경로가 하나라도 있으면 다시 돌리라고 하고, 그 경로만 댄다
  setup_repo; git -C "$T/wt" fetch -q origin; carry_commit "fix: src" VERSION src.sh
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch '^VERSION$'
  expect_rc 0; expect_last "SHAPE OK"; expect_has "RERUN carry#1 ${OLD:0:12}: "; expect_has "src.sh"; expect_not "VERSION"; expect_not "EVIDENCE OK"
}
t_check_carry_rebased() { # base 가 움직였으면 base 쪽 변경도 시험의 입력이다
  setup_repo; OLD=$HEAD_SHA
  ( cd "$T/repo" && echo s > sibling.sh && git add sibling.sh && git commit -qm "형제 PR" && git push -q origin main ) >/dev/null 2>&1
  git -C "$T/wt" fetch -q origin && git -C "$T/wt" rebase -q origin/main >/dev/null 2>&1; carry_head
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch '^VERSION$'
  expect_rc 0; expect_last "SHAPE OK"; expect_has "RERUN carry#1 ${OLD:0:12}: "; expect_has "sibling.sh"; expect_not "EVIDENCE OK"
}
t_check_carry_bad_sha() {
  setup_repo; run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry deadbeef
  expect_rc 2; expect_err "deadbeef"; expect_not "SHAPE"
}
t_check_carry_ref() { # 참조 이름(HEAD, 브랜치, HEAD~1)과 7자 미만 SHA 는 받지 않는다. --carry HEAD 는 언제나 맞기 때문이다
  setup_repo; run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry HEAD
  expect_rc 2; expect_err "HEAD"; expect_not "SHAPE"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "${HEAD_SHA:0:6}"
  expect_rc 2; expect_err "${HEAD_SHA:0:6}"; expect_not "SHAPE"
}
t_check_carry_wide_ere() { # 줄바꿈이 든 값, 빈 경로에도 맞는 ERE 는 모든 경로를 허용하므로 인자 오류다
  setup_repo; git -C "$T/wt" fetch -q origin; carry_commit "fix: src" src.sh
  local e
  for e in '^VERSION$'$'\n' '^VERSION$'$'\n''^X$' '^VERSION$'$'\r' '^VERSION$|' '.*'; do
    run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch "$e"
    expect_rc 2; expect_err "--may-touch"; expect_not "EVIDENCE OK"
  done
}
t_check_carry_bad_ere() { # 틀린 ERE 를 통과로 읽지 않는다
  setup_repo; git -C "$T/wt" fetch -q origin; carry_commit "fix: src" src.sh
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch '^src\.sh$' --may-touch '['
  expect_rc 2; expect_err "--may-touch"; expect_not "EVIDENCE OK"
}
t_check_carry_rename() { # 시험이 읽는 파일을 허용 경로로 옮기면 옛 경로가 RERUN 에 나온다
  setup_repo; git -C "$T/wt" fetch -q origin; mkdir -p "$T/wt/lib"; seq 1 50 > "$T/wt/lib/reader.sh"; carry_commit "feat: reader"
  OLD=$HEAD_SHA; mkdir -p "$T/wt/docs"; git -C "$T/wt" mv lib/reader.sh docs/reader.sh; git -C "$T/wt" commit -qm "mv"; carry_head
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch '^docs/'
  expect_rc 0; expect_last "SHAPE OK"; expect_has "RERUN carry#1 ${OLD:0:12}: --may-touch 밖 경로 lib/reader.sh"; expect_not "EVIDENCE OK"
}
t_check_carry_nonascii() { # 한글 경로도 ERE 에 그대로 맞는다
  setup_repo; git -C "$T/wt" fetch -q origin; carry_commit "docs" "문서.md"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --may-touch '^문서\.md$'
  expect_rc 0; expect_last "SHAPE OK"; expect_has "EVIDENCE OK carry#1 ${OLD:0:12}"; expect_not RERUN
}
t_check_carry_two() { # --may-touch 는 바로 앞 --carry 에만 붙고, 같은 SHA 둘은 순번으로 갈린다
  setup_repo; git -C "$T/wt" fetch -q origin; carry_commit "chore: version" VERSION
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt" --carry "$OLD" --carry "$OLD" --may-touch '^VERSION$'
  expect_rc 0; expect_last "SHAPE OK"
  expect_has "RERUN carry#1 ${OLD:0:12}: --may-touch 밖 경로 VERSION"; expect_has "EVIDENCE OK carry#2 ${OLD:0:12}: 1 file changed"
}

# ---- temp-tree.sh
t_tree_roundtrip() { # 사본을 꺼내 의존성을 걸고 복사하고 표식을 쓰며, 작업 트리를 더럽히지 않고, 지우면 사라진다
  setup_repo; mkdir -p "$T/repo/deps" "$T/src"; echo dep > "$T/repo/deps/x"; echo p > "$T/src/p"
  run temp-tree.sh add "$T/tmp1" main --link deps --copy "$T/src:plugins" --file .marker=v3
  expect_rc 0; expect_last "$(cd "$T" && pwd -P)/tmp1"
  [ -L "$T/tmp1/deps" ] && [ "$(cat "$T/tmp1/deps/x")" = dep ] || bad "--link 가 걸리지 않았다"
  [ -f "$T/tmp1/plugins/p" ] && [ ! -L "$T/tmp1/plugins" ] || bad "--copy 가 복사본이 아니다"
  [ "$(cat "$T/tmp1/.marker")" = v3 ] || bad "--file 이 쓰이지 않았다"
  case $(git -C "$T/tmp1" status --porcelain) in *temp-tree*) bad "기록 파일이 작업 트리에 있다" ;; esac
  run temp-tree.sh remove "$T/tmp1"; expect_rc 0; expect_gone "$T/tmp1"; [ -f "$T/repo/deps/x" ] || bad "remove 가 주 체크아웃의 의존성을 지웠다"
}
t_tree_refuses() {
  setup_repo; run temp-tree.sh remove "$T/repo"; expect_rc 2
  run temp-tree.sh add "$T/wt" main; expect_rc 2
  run temp-tree.sh add "$T/tmp2" main --link nope; expect_rc 2; expect_gone "$T/tmp2"
  mkdir "$T/plain"; run temp-tree.sh remove "$T/plain"; expect_rc 2
}

# ---- mutate.sh
mut_setup() { T=$(mktemp -d "$ROOT/m.XXXX"); printf 'limit=3\nother=1\n' > "$T/f"; printf '#!/bin/sh\ngrep -q "limit=3" %s\n' "$T/f" > "$T/t.sh"; }
t_mut_killed() { mut_setup; RUN_DIR=$T run mutate.sh --file "$T/f" --from 'limit=3' --to 'limit=4' -- sh "$T/t.sh"
  RUN_DIR=''; expect_rc 0; expect_last "KILLED rc=1"; grep -q 'limit=3' "$T/f" || bad "되돌리지 않았다"; }
t_mut_survived() { mut_setup; RUN_DIR=$T run mutate.sh --file "$T/f" --from 'other=1' --to 'other=2' -- sh "$T/t.sh"
  RUN_DIR=''; expect_rc 1; expect_last "SURVIVED"; grep -q 'other=1' "$T/f" || bad "되돌리지 않았다"; }
t_mut_baseline_red() { mut_setup; RUN_DIR=$T run mutate.sh --file "$T/f" --from 'other=1' --to 'other=2' -- false
  RUN_DIR=''; expect_rc 2; grep -q 'other=1' "$T/f" || bad "파일이 바뀌었다"; }
t_mut_not_unique() { mut_setup; printf 'a\na\n' > "$T/g"; RUN_DIR=$T run mutate.sh --file "$T/g" --from 'a' --to 'b' -- true
  RUN_DIR=''; expect_rc 2; [ "$(cat "$T/g")" = $'a\na' ] || bad "파일이 바뀌었다"
  RUN_DIR=$T run mutate.sh --file "$T/g" --from 'zz' --to 'b' -- true; RUN_DIR=''; expect_rc 2; }
t_mut_literal() { # 정규식 특수문자도 글자 그대로 바꾼다
  mut_setup; printf 'x = a.b(c)*$d\n' > "$T/h"; RUN_DIR=$T run mutate.sh --no-baseline --file "$T/h" --from 'a.b(c)*$d' --to 'q' -- grep -q 'a.b' "$T/h"
  RUN_DIR=''; expect_rc 0; [ "$(cat "$T/h")" = 'x = a.b(c)*$d' ] || bad "되돌리지 않았다"; }

# ---- frontier.sh
t_frontier_map() {
  T=$(mktemp -d "$ROOT/f.XXXX"); ST=$T/st; mkdir -p "$ST"; export ST
  cat > "$ST/sub_issues.json" <<'J'
[{"number":1,"state":"open","title":"mine","labels":[{"name":"needs-triage"}],"user":{"login":"me"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0}},
 {"number":2,"state":"open","title":"blocked","labels":[],"user":{"login":"me"},"assignees":[],"issue_dependencies_summary":{"blocked_by":1}},
 {"number":3,"state":"open","title":"theirs","labels":[],"user":{"login":"bob"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0}},
 {"number":4,"state":"open","title":"assigned to me","labels":[],"user":{"login":"bob"},"assignees":[{"login":"me"}],"issue_dependencies_summary":{"blocked_by":0}},
 {"number":5,"state":"closed","title":"done","labels":[],"user":{"login":"me"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0}},
 {"number":6,"state":"open","title":"mine but assigned away","labels":[],"user":{"login":"me"},"assignees":[{"login":"bob"}],"issue_dependencies_summary":{"blocked_by":0}}]
J
  RUN_DIR=$T run frontier.sh --repo o/r --map 9; RUN_DIR=''
  expect_rc 0
  [ "$OUT" = "# me=me"$'\n'"READY"$'\t'"#1"$'\t'"needs-triage"$'\t'"mine"$'\n'"BLOCKED"$'\t'"#2"$'\t\t'"blocked"$'\n'"OTHERS"$'\t'"#3"$'\t\t'"theirs"$'\t'"등록 bob, assignee 없음"$'\n'"READY"$'\t'"#4"$'\t\t'"assigned to me"$'\n'"OTHERS"$'\t'"#6"$'\t\t'"mine but assigned away"$'\t'"등록 me, assignee bob" ] || bad "분류가 틀렸다: $OUT"
  RUN_DIR=$T run frontier.sh --repo o/r --map 9 --anyone; RUN_DIR=''
  expect_not OTHERS; expect_has "# me=*"
}
t_frontier_query() {
  T=$(mktemp -d "$ROOT/f.XXXX"); ST=$T/st; mkdir -p "$ST"; export ST
  echo '{"items":[{"number":8,"state":"open","title":"q","labels":[{"name":"bug"}],"user":{"login":"me"},"assignees":[]}]}' > "$ST/search.json"
  RUN_DIR=$T run frontier.sh --repo o/r --query 'label:bug' --me me; RUN_DIR=''
  expect_rc 0; expect_has "READY"$'\t'"#8"$'\t'"bug"$'\t'"q"
  [ "$(cat "$ST/search_q")" = "q=repo:o/r is:issue is:open label:bug" ] || bad "질의가 틀렸다: $(cat "$ST/search_q")"
  RUN_DIR=$T run frontier.sh --repo o/r --query x --map 1; RUN_DIR=''; expect_rc 2
}

# frontier 의 본문 선행 시험: fb_run <본문 JSON 문자열> [issue_9 상태] [blocked_by]. 이슈 #1 하나, 본문 선행은 #9 를 가리킨다
fb_run() {
  T=$(mktemp -d "$ROOT/f.XXXX"); ST=$T/st; mkdir -p "$ST"; export ST
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$ST/issue_9"
  printf '[{"number":1,"state":"open","title":"t","labels":[],"user":{"login":"me"},"assignees":[],"issue_dependencies_summary":{"blocked_by":%s},"body":%s}]\n' "${3:-0}" "$1" > "$ST/sub_issues.json"
  RUN_DIR=$T run frontier.sh --repo "${4:-o/r}" --map 9; RUN_DIR=''
}
t_frontier_body_open() { fb_run '"\u26d4 선행: #9 끝날 때까지\n\n본문"' OPEN
  expect_rc 0; expect_has "BLOCKED"$'\t'"#1"$'\t\t'"t"$'\t'"선행 #9(본문), 링크 없음"; expect_called "issue view 9 --repo o/r --json state"; }
t_frontier_body_closed() { fb_run '"\u26d4 선행: #9"' CLOSED; expect_rc 0; expect_has "READY"$'\t'"#1"; expect_not BLOCKED
  fb_run '"선행: #9"' MERGED; expect_has "READY"$'\t'"#1"; }
t_frontier_body_mid() { fb_run '"a\nb\n\nc\nd\ne\nf\n선행: #9"' OPEN; expect_rc 0; expect_has "READY"$'\t'"#1"; expect_not_called "issue view"
  fb_run '"a\nb\nc\nd\ne\n\n\uc120\ud589: #9"' OPEN; expect_has "READY"$'\t'"#1"
  fb_run '"a\n\n\nb\nc\nd\n선행: #9"' OPEN; expect_has "BLOCKED"; }
t_frontier_body_linked() { fb_run '"선행: #9"' OPEN 1; expect_rc 0; expect_has "BLOCKED"$'\t'"#1"$'\t\t'"t"$'\t'"선행 #9(본문)"; expect_not "링크 없음"; }
t_frontier_body_cross_repo() { fb_run '"선행: x/y#3 와 #9"' OPEN; expect_rc 0
  expect_called "issue view 3 --repo x/y"; expect_called "issue view 9 --repo o/r"; expect_has "선행 #9 x/y#3(본문)"; }
t_frontier_body_union() { fb_run '"\uc120\ud589: #9\nBlocked by: x/y#3"' OPEN; expect_rc 0
  expect_called "issue view 9 --repo o/r"; expect_called "issue view 3 --repo x/y"; expect_has "선행 #9 x/y#3(본문)"; }
t_frontier_body_refs() {
  fb_run '"\uc120\ud589: o/r2#3"' OPEN; expect_called "issue view 3 --repo o/r2"; expect_has "선행 o/r2#3(본문)"
  fb_run '"\uc120\ud589: \uc774\uc288/\uac74#3"' OPEN; expect_rc 0; expect_called "issue view 3 --repo o/r"; expect_not_called "--repo 이슈"
  fb_run '"\uc120\ud589: O/R#1"' OPEN; expect_rc 0; expect_has "READY"$'\t'"#1"
  fb_run '"\uc120\ud589: O/R#9 #9"' OPEN; expect_has "선행 #9(본문)"; expect_not "#9 #9"
  fb_run '"\uc120\ud589: #10, #9, #9"' OPEN; expect_has "선행 #9 #10(본문)"; }
t_frontier_body_repo_case() { fb_run '"\uc120\ud589: #9 o/r#9 O/R#1"' OPEN 0 O/R; expect_rc 0
  expect_has "BLOCKED"$'\t'"#1"$'\t\t'"t"$'\t'"선행 #9(본문), 링크 없음"; expect_not "#9 #9"; expect_not_called "issue view 1 "; expect_called "issue view 9 --repo o/r"; }
t_frontier_body_prefix() { local b
  for b in '"Blocked By: #9"' '"- Blocked by: #9"' '"**선행**: #9"' '"> blocked by: #9"'; do fb_run "$b" OPEN; expect_has "선행 #9(본문)"; done
  fb_run '"선행: 없음"' OPEN; expect_has "READY"; fb_run 'null' OPEN; expect_has "READY"
  fb_run '"선행: #1 #9"' OPEN; expect_has "선행 #9(본문)"; expect_not "#1 #9"; }
t_frontier_body_none() { local b
  fb_run '"\u26d4 선행: 없음. #9 보다 먼저 한다."' OPEN; expect_rc 0; expect_has "READY"$'\t'"#1"; expect_not BLOCKED; expect_not_called "issue view"
  for b in '"Blocked by: none (#9 가 이것을 기다린다)"' '"선행: None, #9 참고"' '"**선행**: 없음 -- #9"' \
    '"선행:없음 #9"' '"선행:\t없음 #9"' '"선행: **없음** #9"' '"Blocked by: NONE #9"'; do
    fb_run "$b" OPEN; expect_rc 0; expect_has "READY"$'\t'"#1"; expect_not BLOCKED; expect_not_called "issue view"; done
  fb_run '"선행: 없음. #9 참고\nBlocked by: x/y#3"' OPEN; expect_rc 0
  expect_has "선행 x/y#3(본문)"; expect_not "#9"; expect_called "issue view 3 --repo x/y"; expect_not_called "issue view 9"
  for b in '"선행: 없음표 #9"' '"선행: nonexistent #9"' '"선행: 없음2 #9"' '"선행: none2 #9"'; do
    fb_run "$b" OPEN; expect_rc 0; expect_has "BLOCKED"$'\t'"#1"$'\t\t'"t"$'\t'"선행 #9(본문)"; done; }
t_frontier_body_others_skip() {
  T=$(mktemp -d "$ROOT/f.XXXX"); ST=$T/st; mkdir -p "$ST"; export ST
  echo '[{"number":3,"state":"open","title":"theirs","labels":[],"user":{"login":"bob"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"body":"선행: #9"},
   {"number":4,"state":"closed","title":"done","labels":[],"user":{"login":"me"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"body":"선행: #9"}]' > "$ST/sub_issues.json"
  RUN_DIR=$T run frontier.sh --repo o/r --map 9; RUN_DIR=''; expect_rc 0; expect_has OTHERS; expect_not_called "issue view"; }
t_frontier_body_fail() { fb_run '"선행: #9"' FAIL; expect_rc 1; case $ERR in *"frontier: 선행 #9 조회 실패"*) ;; *) bad "stderr: $ERR" ;; esac; }

# ---- land.sh 고리(저장소 명령이 있을 때). live_head 로 PR HEAD 를 bare 원격의 feat 에서 읽는다
loop_setup() { setup_repo; echo "$T/o/r.git" > "$ST/live_head"; }
bare() { git --git-dir="$T/o/r.git" "$@"; }
base_commit() { # <파일> <내용> -- main 에 커밋 하나를 올린다
  ( cd "$T/repo" && printf '%s\n' "$2" > "$1" && git add "$1" && git commit -qm "base: $1" && git push -q origin main ) >/dev/null 2>&1
}
PRE='echo pre >> pre-merge.txt && git add pre-merge.txt && git commit -q -m pre-merge'
last_merge_tip() { grep 'pr merge' "$ST/calls" 2>/dev/null | tail -1 | sed 's/.*--match-head-commit //'; }
expect_pr_branch() { [ "$(bare rev-parse feat)" = "$1" ] || bad "원격 feat 가 $1 이어야 하는데 $(bare rev-parse feat)"; }
expect_no_temp() { # land.sh 를 TMPDIR=$T/tmp 로 돌린 뒤: 임시 디렉터리도 임시 worktree 도 남지 않았다
  [ -z "$(ls -A "$T/tmp")" ] || bad "임시 디렉터리가 남았다: $(ls -A "$T/tmp")"
  [ "$(git -C "$T/repo" worktree list | wc -l)" = 2 ] || bad "임시 worktree 가 남았다: $(git -C "$T/repo" worktree list)"
}
expect_merges() { [ "$(grep -c 'pr merge' "$ST/calls" 2>/dev/null)" = "$1" ] || bad "병합 시도가 $1번이어야 하는데 $(grep -c 'pr merge' "$ST/calls" 2>/dev/null)번"; }
t_land_loop_retry() { # 병합 때 base 가 움직였으면 새 base 위에서 처음부터 다시 하고, 병합 전 명령도 새 base 위에서 다시 돈다.
  # remote 의 fetch 설정이 base 를 덮지 않아도 base 의 추적 ref 를 갱신해 이동을 본다
  loop_setup; local b0 b1 tip; b0=$(bare rev-parse main); echo move > "$ST/on_merge_7"
  git -C "$T/repo" config remote.origin.fetch +refs/heads/feat:refs/remotes/origin/feat
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "echo \$LAND_BASE_SHA >> $T/pm && $PRE"
  expect_rc 0; expect_has "LANDED #7"; expect_called "pr ready 7"
  [ -f "$T/pm" ] && [ "$(wc -l < "$T/pm")" = 2 ] || bad "병합 전 명령이 두 번 돌아야 하는데: $(cat "$T/pm" 2>/dev/null)"
  b1=$(sed -n 2p "$T/pm" 2>/dev/null); tip=$(last_merge_tip)
  [ "$(sed -n 1p "$T/pm" 2>/dev/null)" = "$b0" ] || bad "첫 LAND_BASE_SHA 가 처음 base 가 아니다"
  [ -n "$b1" ] && [ "$b1" != "$b0" ] && [ "$(bare rev-parse "$b1^" 2>/dev/null)" = "$b0" ] || bad "두 번째 LAND_BASE_SHA 가 움직인 base 가 아니다: $b1"
  bare merge-base --is-ancestor "$b1" "$tip" 2>/dev/null || bad "마지막 병합 tip $tip 이 새 base 의 자손이 아니다"
  [ "$(bare rev-list --count "$b1..$tip" 2>/dev/null)" = 2 ] || bad "검수한 SHA 에서 새로 돌지 않았다: 새 base 위 커밋 $(bare rev-list --count "$b1..$tip")개"
  expect_err "land: 올린 tip $tip"
}
t_land_loop_transient() { # base 가 그대로인데 Base branch was modified 이면 같은 tip 으로 다시 병합한다
  loop_setup; echo stay > "$ST/on_merge_7"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "echo x >> $T/pm && $PRE"
  expect_rc 0; expect_has "LANDED #7"
  [ -f "$T/pm" ] && [ "$(wc -l < "$T/pm")" = 1 ] || bad "병합 전 명령은 한 번만 돌아야 한다"
  [ "$(grep -oE '^pr merge|headRefOid,mergeable' "$ST/calls" | tr '\n' ' ')" = "headRefOid,mergeable pr merge headRefOid,mergeable pr merge " ] \
    || bad "mergeable 을 다시 기다린 뒤 두 번 병합해야 한다: $(grep -oE '^pr merge|headRefOid,mergeable' "$ST/calls" | tr '\n' ' ')"
}
t_land_loop_check_fails() { # 검사가 지면 병합 전 명령도 push 도 병합도 하지 않고 PR 은 draft 로 남는다
  loop_setup; base_commit c c
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check "exit 1" --pre-merge "touch $T/pm && $PRE"
  expect_rc 1; expect_last "BLOCKED #7 검사 실패: exit 1"; expect_not_called "pr merge"; expect_not_called "pr ready"; expect_gone "$T/pm"
  expect_pr_branch "$HEAD_SHA"; [ "$(jq .isDraft "$ST/pr_7.json")" = true ] || bad "draft 로 남아야 한다"
}
t_land_loop_conflict() { # rebase 가 충돌하면 되돌리고 충돌 파일을 stderr 로 내며, 임시 worktree 와 디렉터리를 남기지 않는다
  loop_setup; base_commit b other; mkdir "$T/tmp"
  TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 와 충돌한다 -- 따라잡기가 필요하다"; expect_not_called "pr merge"
  printf '%s\n' "$ERR" | grep -qx b || bad "stderr 에 충돌 파일 b 가 한 줄로 없다: $ERR"
  expect_no_temp; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_rebase_fails() { # 충돌 없이 rebase 가 지면(prepare-commit-msg 훅이 거절) 충돌이 아닌 이유로 BLOCKED, 임시 worktree 를 남기지 않는다. error: 앞의 훅 줄은 건너뛴다
  loop_setup; base_commit d d; reject_hook prepare-commit-msg; mkdir "$T/tmp"
  LC_ALL=C TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_not "충돌"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"; expect_no_temp
  expect_last "BLOCKED #7 base 를 합치지 못했다: error: 'prepare-commit-msg' hook failed"
  expect_err "hook: rejected"
}
stub_rebase_fail() { # <printf 서식> -- rebase 만 그 stderr 를 찍고 지는 git 을 PATH 앞에 둔다(--abort 는 조용히 성공)
  mkdir "$T/bin"
  printf '#!/bin/sh\nfor a in "$@"; do\n  case $a in --abort) exit 0 ;; rebase) printf "%s" >&2; exit 1 ;; esac\ndone\nexec %s "$@"\n' "$1" "$(command -v git)" > "$T/bin/git"
  chmod +x "$T/bin/git"
}
t_land_loop_base_fail_hook_error() { # 훅이 error: 원인을 찍으면 git 이 뒤에 붙인 일반 error: 줄이 아니라 그 첫 error: 줄이 실린다
  loop_setup; base_commit d d; reject_hook prepare-commit-msg; mkdir "$T/tmp"
  printf '#!/bin/sh\necho "error: hook says no" >&2\nexit 1\n' > "$T/hooks/prepare-commit-msg"
  LC_ALL=C TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 합치지 못했다: error: hook says no"; expect_not_called "pr merge"; expect_no_temp
}
t_land_loop_base_fail_first_error() { # 줄머리 error:/fatal: 중 첫 줄을 고른다(줄머리가 아닌 error:, warning:, hint: 는 건너뛴다)
  loop_setup; base_commit d d; mkdir "$T/tmp"; stub_rebase_fail 'warning: w\nx error: not a cause\nfatal: real cause\nerror: later\nhint: h\n'
  PATH=$T/bin:$PATH TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 합치지 못했다: fatal: real cause"; expect_not_called "pr merge"; expect_no_temp
}
t_land_loop_base_fail_no_cause() { # error:/fatal: 줄이 없는 실패(빈 줄로 시작, 비공백 줄 둘 이상)면 첫 비공백 줄로 떨어진다
  loop_setup; base_commit d d; mkdir "$T/tmp"; stub_rebase_fail '\n  \ncause line\n\nadvice line\n\n'
  PATH=$T/bin:$PATH TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 합치지 못했다: cause line"; expect_not_called "pr merge"; expect_no_temp
}
patch_setup() { # main 에 아홉 줄 파일 p, feat 위에 p 의 1행과 5행을 바꾼 커밋
  loop_setup; base_commit p "$(seq 1 9)"
  ( cd "$T/wt" && git fetch -q origin && git rebase -q origin/main && sed -i -e 1s/1/one/ -e 5s/5/five/ p \
    && git commit -qam "feat: p" && git push -qf origin feat ) >/dev/null 2>&1
  HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
}
base_edit() { ( cd "$T/repo" && sed -i "$1" p && git commit -qam "base: p" && git push -q origin main ) >/dev/null 2>&1; }
t_land_loop_patch() { # base 가 문맥 줄만 바꾸면 패치가 같고(-U0), PR 이 바꾼 줄을 base 가 먼저 바꿨거나 PR 을 이미 품었으면 바뀌었다
  patch_setup; base_edit 3s/3/three/
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 0; expect_has "LANDED #7"
  patch_setup; base_edit 1s/1/one/
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 얹은 뒤 패치가 달라졌다"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"
  patch_setup; bare update-ref refs/heads/main "$(bare commit-tree "$HEAD_SHA^{tree}" -p "$HEAD_SHA" -m after)"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 얹은 뒤 패치가 달라졌다"
}
t_land_loop_patch_count() { # rebase 가 base 에 이미 있는 PR 커밋 하나를 빼면, 남은 커밋과 patch-id 가 같아도 개수가 달라 바뀌었다
  loop_setup; base_commit q "$(seq 1 9)"
  ( cd "$T/wt" && git fetch -q origin && git rebase -q origin/main && sed -i '2a x' q && git commit -qam "feat: q 2" \
    && sed -i '7a x' q && git commit -qam "feat: q 7" && git push -qf origin feat ) >/dev/null 2>&1
  HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
  ( cd "$T/repo" && sed -i '6a x' q && git commit -qam "base: q" && git push -q origin main ) >/dev/null 2>&1
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 얹은 뒤 패치가 달라졌다"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_rounds() { # round 마다 base 가 움직이면 상한(기본 3)에서 멈추고 PR 브랜치를 검수한 SHA 로 되돌린다. round 는 병합 시도다
  loop_setup; printf 'move\nmove\nmove\nmove\n' > "$ST/on_merge_7"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_last "BLOCKED #7 base 가 움직여 3번 다시 했다"; expect_merges 3; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_push_env() { # --push-env 는 여러 번 주고, tip push 와 복원 push 모두에 붙는다(pre-push git hook 이 env 를 기록한다)
  loop_setup; echo "something else broke" > "$ST/merge_err"
  printf '#!/bin/sh\nwhile read -r l s r o; do echo "${PUSH_X:-none}/${PUSH_Y:-none} $s" >> %s/hook; done\n' "$T" > "$T/repo/.git/hooks/pre-push"
  chmod +x "$T/repo/.git/hooks/pre-push"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE" --push-env PUSH_X=q1 --push-env PUSH_Y=q2
  expect_rc 1; expect_last "BLOCKED #7 gh pr merge 실패: something else broke"; expect_pr_branch "$HEAD_SHA"
  local first; first=$(head -1 "$T/hook" 2>/dev/null)
  [ "${first% *}" = q1/q2 ] && [ "${first#* }" != "$HEAD_SHA" ] || bad "tip push 에 env 가 없다: $first"
  grep -qx "q1/q2 $HEAD_SHA" "$T/hook" 2>/dev/null || bad "복원 push 에 env 가 없다: $(cat "$T/hook" 2>/dev/null)"
}
t_land_loop_needs_human() { # 사람의 승인이 필요하면 올린 tip 을 되돌리지 않는다
  loop_setup; echo "GraphQL: At least 1 approving review is required by reviewers with write access." > "$ST/merge_err"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 3; expect_has "NEEDS_HUMAN #7"
  [ "$(bare rev-parse feat)" != "$HEAD_SHA" ] && [ "$(bare rev-parse feat^)" = "$HEAD_SHA" ] || bad "올린 tip 이 남아야 한다"
}
t_land_loop_hn_nopush() { # 올릴 것이 없으면 NEEDS_HUMAN 이어도 PR HEAD 는 검수한 SHA 이고 올린 tip 줄이 없다
  loop_setup; echo "GraphQL: At least 1 approving review is required by reviewers with write access." > "$ST/merge_err"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 3; expect_pr_branch "$HEAD_SHA"; case $ERR in *"land: 올린 tip"*) bad "push 했다" ;; esac
}
t_land_loop_args() {
  setup_repo
  run land.sh --repo o/r --pr 7 --sha 0123456789 --check true --pre-merge true --push-env A=1 --push-env B=x=y; expect_rc 1
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via x --check true; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via x --push-env A=1; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true --push-env BAD; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true --push-env 1A=1; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --push-env A=1; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true --check false; expect_rc 2
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge true --pre-merge false; expect_rc 2
  run land.sh --cleanup --repo o/r --pr 7 --pre-merge true; expect_rc 2
  run land.sh --cleanup --repo o/r --pr 7 --check true; expect_rc 2
  expect_not_called "pr merge"; expect_not_called "pr ready"
}

t_land_loop_lease() { # 검수 뒤 남이 PR 브랜치에 push 하고 그것이 fetch 돼 추적 ref 가 따라가도 명시 lease 가 덮지 않는다
  loop_setup; base_commit c c
  git clone -q "$T/o/r.git" "$T/other" 2>/dev/null; git -C "$T/other" checkout -q feat
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" \
    --check "( cd $T/other && echo z > z && git add z && git commit -qm other && git push -q origin feat ) >/dev/null 2>&1 && git fetch -q origin"
  local theirs; theirs=$(git -C "$T/other" rev-parse HEAD)
  expect_rc 1; expect_last "BLOCKED #7 PR 브랜치에 push 하지 못했다"; expect_pr_branch "$theirs"
}
t_land_loop_merged_keeps_tip() { # gh pr merge 가 0 으로 끝난 뒤의 BLOCKED 는 올린 tip 을 되돌리지 않는다(큐에 든 PR 을 덮지 않게)
  loop_setup; touch "$ST/fail_json_state"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_has "gh pr merge 뒤에도"
  [ "$(bare rev-parse feat^)" = "$HEAD_SHA" ] || bad "병합 뒤에 PR 브랜치를 되돌렸다: $(bare rev-parse feat)"
}
t_land_loop_transient_counts() { # base 가 그대로인 Base branch was modified 도 round 로 센다
  loop_setup; printf 'stay\nstay\n' > "$ST/on_merge_7"
  LAND_ROUNDS=1 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_last "BLOCKED #7 base 가 움직여 1번 다시 했다"; expect_merges 1; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_delete_no_env() { # 정리 단계의 브랜치 삭제 push 에는 --push-env 를 주지 않는다
  loop_setup
  printf '#!/bin/sh\nwhile read -r l s r o; do echo "${PUSH_X:-none} $s" >> %s/hook; done\n' "$T" > "$T/repo/.git/hooks/pre-push"
  chmod +x "$T/repo/.git/hooks/pre-push"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE" --push-env PUSH_X=q1
  expect_rc 0; expect_has "LANDED #7"
  grep -qx "none 0000000000000000000000000000000000000000" "$T/hook" 2>/dev/null || bad "삭제 push 가 env 없이 돌지 않았다: $(cat "$T/hook" 2>/dev/null)"
}
t_land_loop_merge_commit() { # 범위에 merge 커밋이 있으면 패치가 바뀐 것으로 본다. side 의 날짜를 하루 늦춰 log 순서가 rebase 순서와 같게 한다(patch-id 목록만으로는 같음)
  loop_setup
  ( cd "$T/wt" && git checkout -q -b side HEAD~1 && echo s > s && git add s && GIT_COMMITTER_DATE="$(( $(date +%s) + 86400 )) +0000" git commit -qm side && git checkout -q feat \
    && git merge -q --no-ff side -m merge && git push -q origin feat ) >/dev/null 2>&1
  HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD); base_commit c c
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 를 얹은 뒤 패치가 달라졌다"; expect_not_called "pr merge"
}
t_land_loop_premerge_bad() { # 병합 전 명령이 지거나, 트리를 더럽히거나, rebase 된 tip 을 버리면 BLOCKED 이고 push 하지 않는다
  local c
  for c in "exit 1" "touch junk" "git commit -q --amend -m rewritten"; do
    loop_setup; base_commit c c
    run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$c"
    expect_rc 1; expect_last "BLOCKED #7 병합 전 명령이 실패했다: $c"; expect_pr_branch "$HEAD_SHA"; expect_not_called "pr merge"
  done
}
t_land_loop_rounds_arg() { setup_repo; LAND_ROUNDS=1 run land.sh --repo o/r --pr 7 --sha 0123456789 --check true; expect_rc 1
  LAND_ROUNDS=0 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true; expect_rc 2
  LAND_ROUNDS=x run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true; expect_rc 2; }
t_land_loop_env() { # 두 명령은 rebase 된 tip 의 임시 worktree 루트에서 env 를 받아 돌고, 출력은 stderr 로 간다. 커밋 0개인 병합 전 명령,
  # --keep 이어도 임시 worktree 는 지우고 PR 의 worktree 와 로컬 브랜치는 건드리지 않는다
  loop_setup; base_commit c c; mkdir "$T/tmp"; local b k e h tmp cwd top at
  b=$(bare rev-parse main); tmp=$(cd "$T/tmp" && pwd -P)
  printf '%s\n' 'echo "out-$1"' 'echo "$LAND_REPO $LAND_PR $LAND_BRANCH $LAND_BASE $LAND_BASE_SHA $LAND_SHA $LAND_HEAD" > "$0.$1"' \
    'echo "$(pwd -P) $(git rev-parse --show-toplevel) $(git rev-parse HEAD)" >> "$0.$1"' > "$T/rec"
  TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "${HEAD_SHA:0:9}" --keep --check "sh $T/rec check" --pre-merge "sh $T/rec pre"
  expect_rc 0; expect_has "LANDED #7"; expect_not "out-"; expect_err "out-check"; expect_err "out-pre"
  for k in check pre; do
    e=$(sed -n 1p "$T/rec.$k" 2>/dev/null); h=${e##* }
    [ "$e" = "o/r 7 feat main $b $HEAD_SHA $h" ] || bad "$k 의 env: $e"
    [ "$(git -C "$T/repo" rev-parse "$h^" 2>/dev/null)" = "$b" ] || bad "$k 의 LAND_HEAD 가 base $b 위에 rebase 된 tip 이 아니다: $h"
    read -r cwd top at < <(sed -n 2p "$T/rec.$k" 2>/dev/null)
    [ "$cwd" = "$top" ] && [ "${cwd#"$tmp"/}" != "$cwd" ] && [ "$at" = "$h" ] || bad "$k 이 rebase 된 tip 의 임시 worktree 루트에서 돌지 않았다: $cwd $top $at"
  done
  [ "$(last_merge_tip)" = "$h" ] || bad "커밋 0개인 병합 전 명령 뒤에는 rebase 된 tip 으로 병합해야 한다"
  expect_no_temp
  [ "$(git -C "$T/wt" rev-parse HEAD)" = "$HEAD_SHA" ] && [ "$(git -C "$T/repo" rev-parse feat)" = "$HEAD_SHA" ] || bad "PR 의 worktree 나 로컬 브랜치가 움직였다"
}
t_land_loop_base() { # --base 로 바꾼 대상 위로 rebase 하고, 기록 댓글과 대상 변경은 round 를 거듭해도 고리 앞에서 한 번만 한다
  loop_setup; local n
  ( cd "$T/repo" && git checkout -q -b next && echo n > n && git add n && git commit -qm next && git push -q origin next && git checkout -q main ) >/dev/null 2>&1
  n=$(bare rev-parse next); echo move > "$ST/on_merge_7"; echo 기록 > "$T/ev"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --issue 5 --evidence "$T/ev" --base next --pre-merge "echo \$LAND_BASE \$LAND_BASE_SHA >> $T/pm && $PRE"
  expect_rc 0; expect_has "LANDED #7"
  [ "$(grep -c 'issue comment' "$ST/calls")" = 1 ] && [ "$(grep -c 'X PATCH' "$ST/calls")" = 1 ] || bad "기록 댓글, 대상 변경이 한 번이 아니다: $(tr '\n' '|' < "$ST/calls")"
  [ "$(sed -n 1p "$T/pm" 2>/dev/null)" = "next $n" ] || bad "첫 round 의 base 가 next 가 아니다: $(cat "$T/pm" 2>/dev/null)"
  bare merge-base --is-ancestor "$n" "$(last_merge_tip)" 2>/dev/null || bad "병합한 tip 이 next 위가 아니다"
}
t_land_loop_unknown() { # mergeable 이 끝내 UNKNOWN 이면 병합하지 않고 BLOCKED, 되돌린다
  loop_setup; base_commit c c; pr 7 mergeable=UNKNOWN
  LAND_TRIES=2 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 mergeable 이 끝내 UNKNOWN 이다"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_base_rewound() { # base 가 강제로 되감겨도 받는다(+refspec): 되감긴 base 가 조상이면 rebase 없이 넣는다
  loop_setup; base_commit c c; bare update-ref refs/heads/main "$(bare rev-parse main^)"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 0; expect_has "LANDED #7"; [ "$(last_merge_tip)" = "$HEAD_SHA" ] || bad "rebase 없이 검수한 SHA 로 병합해야 한다"
}
t_land_loop_conflicting() { loop_setup; pr 7 mergeable=CONFLICTING
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_last "BLOCKED #7 base 와 충돌한다 -- 따라잡기가 필요하다"; expect_not_called "pr merge"; }

t_land_loop_term_on_push() { # push 하는 동안 TERM 을 받아도 끝나기 전에 PR 브랜치를 검수한 SHA 로 되돌린다
  loop_setup
  printf '#!/bin/sh\ncat >/dev/null\n[ -e %s/killed ] && exit 0\ntouch %s/killed\nkill -TERM "$(ps -o ppid= -p $PPID | tr -d " ")"\n' "$T" "$T" > "$T/repo/.git/hooks/pre-push"
  chmod +x "$T/repo/.git/hooks/pre-push"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_term_on_poll() { # push 뒤 기다리는 동안 TERM 을 받으면 되돌린다
  loop_setup; pr 7 mergeable=UNKNOWN
  ( cd "$T/repo" && LAND_POLL=1 LAND_TRIES=20 exec bash "$SCRIPTS/land.sh" --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE" ) >"$T/so" 2>"$T/se" &
  local p=$! i
  for i in $(seq 1 50); do [ "$(bare rev-parse feat)" != "$HEAD_SHA" ] && break; sleep 0.1; done
  kill -TERM $p; wait $p; RC=$?
  expect_rc 1; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_undo_round2() { # 2 round 의 push 가 지면 1 round 에 올린 tip 에서 검수한 SHA 로 되돌린다
  loop_setup; echo move > "$ST/on_merge_7"
  printf '#!/bin/sh\nn=$(cat %s/n 2>/dev/null || echo 0); echo $((n+1)) > %s/n\n[ "$n" != 1 ]\n' "$T" "$T" > "$T/repo/.git/hooks/pre-push"
  chmod +x "$T/repo/.git/hooks/pre-push"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_last "BLOCKED #7 PR 브랜치에 push 하지 못했다"; expect_merges 1; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_undo_round1_noise() { # 1 round 의 push 가 지면 PR 브랜치는 검수한 SHA 그대로라 되돌리지 않고, 되돌리기 실패도 알리지 않는다
  loop_setup
  printf '#!/bin/sh\nexit 1\n' > "$T/repo/.git/hooks/pre-push"; chmod +x "$T/repo/.git/hooks/pre-push"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_last "BLOCKED #7 PR 브랜치에 push 하지 못했다"; expect_pr_branch "$HEAD_SHA"
  case $ERR in *되돌리지*) bad "거짓 복원 실패 알림: $ERR" ;; esac
}
t_land_loop_restore_lease() { # 복원 push 도 명시 lease 다: 병합 시도 중 남이 push 하고 그것이 fetch 돼도 덮지 않고 실패를 알린다
  loop_setup; echo "something else broke" > "$ST/merge_err"
  git clone -q "$T/o/r.git" "$T/other" 2>/dev/null
  printf 'cd %s/other && git fetch -q origin && git checkout -q -B feat origin/feat && echo z > z && git add z && git commit -qm other && git push -q origin feat && git -C %s/repo fetch -q origin\n' "$T" "$T" > "$ST/merge_hook"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE"
  expect_rc 1; expect_last "BLOCKED #7 gh pr merge 실패: something else broke"; expect_pr_branch "$(git -C "$T/other" rev-parse HEAD)"
  expect_err "되돌리지 못했다"
}
t_land_loop_tip_unseen() { # PR HEAD 가 올린 tip 이 되지 않으면 ready 도 병합도 하지 않고 BLOCKED, 되돌린다
  setup_repo; base_commit c c
  LAND_TRIES=2 run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 1; expect_has "BLOCKED #7 PR HEAD 가 올린 tip"; expect_not_called "pr merge"; expect_not_called "pr ready"; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_move_other_msg() { # base 이동은 gh 메시지가 아니라 fetch 비교로 판정한다
  loop_setup; echo "move GraphQL: Pull Request is not mergeable (mergePullRequest)" > "$ST/on_merge_7"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "echo x >> $T/pm && $PRE"
  expect_rc 0; expect_has "LANDED #7"; [ "$(wc -l < "$T/pm")" = 2 ] || bad "다시 돌지 않았다: $(cat "$T/pm")"
}
t_land_loop_merge_commit_no_rebase() { # base 가 이미 조상이면 패치 판정을 건너뛰므로 범위에 merge 커밋이 있어도 넣는다. tip 이 PR HEAD 그대로라 push 하지 않는다
  loop_setup
  ( cd "$T/wt" && git checkout -q -b side HEAD~1 && echo s > s && git add s && git commit -qm side && git checkout -q feat \
    && git merge -q --no-ff side -m merge && git push -q origin feat ) >/dev/null 2>&1
  HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --check true
  expect_rc 0; expect_has "LANDED #7"; case $ERR in *"land: 올린 tip"*) bad "올릴 것이 없는데 push 했다: $ERR" ;; esac
}
squash_setup() { # 고리 꼴에, base 를 한 번 움직인 뒤 feat 에서 git merge origin/main 으로 따라잡아 push 한다(PR HEAD 가 merge 커밋)
  loop_setup; base_commit c c
  ( cd "$T/wt" && git fetch -q origin && git merge -q --no-edit origin/main && git push -q origin feat ) >/dev/null 2>&1
  HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
}
pushed_tips() { printf '%s\n' "$ERR" | sed -n 's/^land: 올린 tip //p'; }
t_land_loop_squash_catchup() { # squash 면 따라잡기 merge 뒤 base 가 움직여도 rebase 하지 않고 검수한 SHA 에 base 를 합친 tip 으로 넣는다.
  # tip 이 검수한 SHA 의 자손이라 push 는 fast-forward 다. 사용자 설정이 merge.ff=only 여도 base 를 merge 커밋으로 합친다
  squash_setup; base_commit d d; git -C "$T/repo" config merge.ff only; local b tip
  b=$(bare rev-parse main)
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --pre-merge "$PRE"
  expect_rc 0; expect_has "LANDED #7"; tip=$(last_merge_tip)
  expect_called "pr merge 7 --repo o/r --squash --match-head-commit $tip"
  [ -n "$tip" ] && [ "$(pushed_tips)" = "$tip" ] || bad "올린 tip 이 병합한 tip 하나가 아니다: $(pushed_tips | tr '\n' ' ')"
  [ "$(git -C "$T/repo" log -1 --format=%s "$tip" 2>/dev/null)" = pre-merge ] || bad "tip 이 병합 전 커밋이 아니다"
  [ "$(git -C "$T/repo" rev-parse "$tip^^1" "$tip^^2" 2>/dev/null | tr '\n' ' ')" = "$HEAD_SHA $b " ] \
    || bad "병합 전 커밋 아래가 검수한 SHA 와 base $b 를 합친 merge 커밋이 아니다"
  case $ERR in *경고*) bad "경고가 나왔다: $ERR" ;; esac
}
t_land_loop_squash_ancestor() { # squash 에서도 base 가 이미 조상이면 base 를 합치지 않고 검수한 SHA 로 넣는다(push 없음)
  squash_setup
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
  expect_rc 0; expect_has "LANDED #7"
  [ "$(last_merge_tip)" = "$HEAD_SHA" ] || bad "검수한 SHA 로 병합해야 한다: $(last_merge_tip)"
  [ -z "$(pushed_tips)" ] || bad "올릴 것이 없는데 push 했다: $ERR"
}
t_land_loop_squash_absorbed() { # base 가 PR 변경을 흡수하면(같은 변경을 따로 넣었거나 PR 을 품었으면) 고유 diff 가 비어 바뀐 것이다
  local c
  for c in "base_commit b b" 'bare update-ref refs/heads/main "$(bare commit-tree "$HEAD_SHA^{tree}" -p "$HEAD_SHA" -m after)"'; do
    squash_setup; eval "$c"
    run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
    expect_rc 1; expect_last "BLOCKED #7 base 를 얹은 뒤 패치가 달라졌다"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"
  done
}
t_land_loop_squash_conflict() { # squash 갈래도 base 와 충돌하면 merge 를 되돌리고 충돌 파일을 stderr 로 내며, 임시 worktree 와 디렉터리를 남기지 않는다
  squash_setup; base_commit b other; mkdir "$T/tmp"
  TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
  expect_rc 1; expect_last "BLOCKED #7 base 와 충돌한다 -- 따라잡기가 필요하다"; expect_not_called "pr merge"
  printf '%s\n' "$ERR" | grep -qx b || bad "stderr 에 충돌 파일 b 가 한 줄로 없다: $ERR"
  expect_no_temp; expect_pr_branch "$HEAD_SHA"
}
t_land_loop_squash_retry() { # 병합 때 base 가 움직이면 round 2 는 검수한 SHA 에서 base 를 새로 합친 tip 을 만들어 round 1 에 올린 tip 을 lease 로 대체한다
  loop_setup; base_commit c c; echo move > "$ST/on_merge_7"; local t1 t2 b
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
  expect_rc 0; expect_has "LANDED #7"; expect_merges 2
  t1=$(pushed_tips | sed -n 1p); t2=$(pushed_tips | sed -n 2p); b=$(bare rev-parse main^)
  [ "$(pushed_tips | wc -l)" = 2 ] && [ "$t1" != "$t2" ] && [ "$(last_merge_tip)" = "$t2" ] || bad "올린 tip 이 서로 다른 둘이고 둘째로 병합해야 한다: $(pushed_tips | tr '\n' ' ')"
  [ "$(git -C "$T/repo" rev-parse "$t1^1" "$t2^1" "$t2^2" 2>/dev/null | tr '\n' ' ')" = "$HEAD_SHA $HEAD_SHA $b " ] \
    || bad "두 tip 이 검수한 SHA 에서 만든 것이 아니거나 둘째가 움직인 base $b 를 합치지 않았다"
  case $ERR in *경고*) bad "경고가 나왔다: $ERR" ;; esac
}
reject_hook() { # <훅 이름> -- $T/hooks 에 거절하는 훅을 두고 주 체크아웃의 core.hooksPath 로 건다(임시 worktree 도 따른다)
  mkdir -p "$T/hooks"; printf '#!/bin/sh\necho "hook: rejected" >&2\nexit 1\n' > "$T/hooks/$1"; chmod +x "$T/hooks/$1"
  git -C "$T/repo" config core.hooksPath "$T/hooks"
}
t_land_loop_squash_no_verify() { # base 를 합치는 merge 는 rebase 처럼 commit-msg, pre-merge-commit 훅을 돌리지 않는다
  local h
  for h in commit-msg pre-merge-commit; do
    squash_setup; base_commit d d; reject_hook "$h"
    run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
    expect_rc 0; expect_has "LANDED #7"
  done
}
t_land_loop_squash_signatures() { # merge.verifySignatures=true 여도 base 의 서명을 따지지 않고 합친다(rebase 갈래와 같다)
  squash_setup; base_commit d d; git -C "$T/repo" config merge.verifySignatures true
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
  expect_rc 0; expect_has "LANDED #7"
}
t_land_loop_squash_merge_fails() { # 충돌 없이 merge 가 지면(prepare-commit-msg 훅이 거절) 충돌이 아닌 이유로 BLOCKED, 임시 worktree 를 남기지 않는다
  squash_setup; base_commit d d; reject_hook prepare-commit-msg; mkdir "$T/tmp"
  LC_ALL=C TMPDIR=$T/tmp run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
  expect_rc 1; expect_not "충돌"; expect_not_called "pr merge"; expect_pr_branch "$HEAD_SHA"; expect_no_temp
  expect_last "BLOCKED #7 base 를 합치지 못했다: hook: rejected"
  expect_err "hook: rejected"
}
t_land_loop_squash_context() { # base 가 PR 이 바꾼 줄 옆의 문맥 줄만 바꾸면 고유 diff(-U0)가 같아 넣는다
  patch_setup; base_edit 3s/3/three/
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --method squash --check true
  expect_rc 0; expect_has "LANDED #7"
}
t_land_loop_term_in_merge() { # 병합 호출 중에 TERM 을 받아도 병합이 이뤄졌으면 PR 브랜치를 되돌리지 않는다
  loop_setup; printf 'while [ ! -s %s/pid ]; do sleep 0.05; done; kill -TERM "$(cat %s/pid)"\n' "$T" "$T" > "$ST/merge_hook"
  ( cd "$T/repo" && exec bash "$SCRIPTS/land.sh" --repo o/r --pr 7 --sha "$HEAD_SHA" --pre-merge "$PRE" ) >"$T/so" 2>"$T/se" &
  local p=$!; echo "$p" > "$T/pid"; wait "$p"; RC=$?
  [ "$(jq -r .state "$ST/pr_7.json")" = MERGED ] || bad "병합 호출에 닿지 않았다: $(cat "$T/se")"
  expect_rc 1; expect_pr_branch "$(jq -r .mergeCommit.oid "$ST/pr_7.json")"
}

# CASES 에 적힌 이름의 함수가 없으면(오타, 이름 바꾸기, 지운 함수) 그 경우를 FAIL 로 센다. 이 하네스의 복사본에
# 없는 이름을 끼워 돌려 본다.
t_missing_case_fn() {
  local cp=$ROOT/self.sh
  sed -e "s|^SCRIPTS=.*|SCRIPTS=$SCRIPTS|" -e "s|^CASES='|CASES='no_such_case |" "${BASH_SOURCE[0]}" > "$cp"
  OUT=$(ONLY='^no such case$' bash "$cp" 2>&1); RC=$?
  expect_rc 1; expect_has 'FAIL no such case: t_no_such_case 함수가 없다'; expect_not 'PASS no such case'; expect_has 'pass 0 fail 1'
}

CASES='land_gh land_head_moved land_conflict land_unknown_then_ok land_needs_human land_merge_fail land_gh_transient land_gh_transient_limit land_gh_retry_mergeable land_gh_rounds_arg land_gh_head_modified land_loop_head_modified land_method_squash land_method_explicit land_method_disallowed land_method_merge land_method_unreadable
land_via land_via_fails land_via_not_merged land_stack land_keep land_cleanup land_args
land_loop_retry land_loop_transient land_loop_check_fails land_loop_conflict land_loop_rebase_fails land_loop_base_fail_hook_error land_loop_base_fail_first_error land_loop_base_fail_no_cause land_loop_patch land_loop_rounds land_loop_push_env land_loop_needs_human land_loop_args land_loop_lease land_loop_merged_keeps_tip land_loop_transient_counts land_loop_delete_no_env land_loop_merge_commit land_loop_premerge_bad land_loop_rounds_arg land_loop_env land_loop_conflicting land_loop_term_on_push land_loop_term_on_poll land_loop_term_in_merge
land_loop_undo_round2 land_loop_undo_round1_noise land_loop_restore_lease land_loop_tip_unseen land_loop_move_other_msg land_loop_merge_commit_no_rebase
land_loop_base land_loop_unknown land_loop_base_rewound land_loop_patch_count land_loop_hn_nopush
land_loop_squash_catchup land_loop_squash_ancestor land_loop_squash_absorbed land_loop_squash_conflict land_loop_squash_retry
land_loop_squash_no_verify land_loop_squash_signatures land_loop_squash_merge_fails land_loop_squash_context
check_ok check_fails check_forbid_rename check_closes_body check_unknown check_args check_draft_ok check_draft_ready check_draft_unreadable
check_verdict_ok check_verdict_short_sha check_verdict_old_sha check_verdict_no_placeholder check_verdict_newline check_verdict_labels
check_carry_same_tree check_carry_allowed check_carry_outside check_carry_rebased check_carry_bad_sha
check_carry_ref check_carry_wide_ere check_carry_bad_ere check_carry_rename check_carry_nonascii check_carry_two tree_roundtrip tree_refuses
mut_killed mut_survived mut_baseline_red mut_not_unique mut_literal frontier_map frontier_query
frontier_body_open frontier_body_closed frontier_body_mid frontier_body_linked frontier_body_union frontier_body_refs frontier_body_repo_case frontier_body_cross_repo frontier_body_prefix frontier_body_none
frontier_body_others_skip frontier_body_fail missing_case_fn'
ran=0
for c in $CASES; do
  label=${c//_/ }
  if [ -n "${ONLY:-}" ] && ! printf '%s\n' "$label" | grep -qE -- "$ONLY"; then continue; fi
  CASE=$label BAD=0 ran=$((ran + 1))
  if declare -F "t_$c" >/dev/null; then "t_$c"; else bad "t_$c 함수가 없다"; fi
  if [ $BAD = 0 ]; then PASS=$((PASS + 1)); echo "PASS $label"; else FAIL=$((FAIL + 1)); fi
done
[ $ran -gt 0 ] || { echo "ONLY='${ONLY:-}' 에 맞는 경우가 없다" >&2; exit 1; }
echo "pass $PASS fail $FAIL"
[ $FAIL = 0 ]
