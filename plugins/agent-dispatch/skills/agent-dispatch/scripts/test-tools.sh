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

# gh 스텁. 상태: $ST/pr_<N>.json, $ST/merge_err, $ST/repo.json, $ST/issue_<N>, $ST/mseq_<N>(mergeable 을 차례로 낸다),
# $ST/sub_issues.json, $ST/search.json. 받은 호출은 $ST/calls 에 한 줄씩 남는다. $ST/issue_<N> 내용이 FAIL 이면 조회가 exit 1 이다.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
st=${ST:?}
echo "$*" >> "$st/calls"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
jqf=$(arg --jq "$@")
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
setf() { local f=$st/pr_$1.json t; t=$(mktemp); jq "$2" "$f" > "$t" && mv "$t" "$f"; }
case "$1 $2" in
  "pr view")
    n=$3; f=$st/pr_$n.json; [ -f "$f" ] || { echo "no PR $n" >&2; exit 1; }
    if [ -s "$st/mseq_$n" ]; then m=$(head -1 "$st/mseq_$n"); sed -i 1d "$st/mseq_$n"; setf "$n" ".mergeable=\"$m\""; fi
    [ ! -f "$st/merge_on_view_$n" ] || setf "$n" '.state="MERGED" | .mergeCommit={"oid":"feedface0000"}'
    emit < "$f" ;;
  "pr ready") setf "$3" '.isDraft=false' ;;
  "pr merge")
    n=$3; [ ! -f "$st/merge_err" ] || { cat "$st/merge_err" >&2; exit 1; }
    want=$(arg --match-head-commit "$@"); head=$(jq -r .headRefOid "$st/pr_$n.json")
    [ "$want" = "$head" ] || { echo "Head branch was modified" >&2; exit 1; }
    setf "$n" '.state="MERGED" | .mergeCommit={"oid":"cafebabe1234"}' ;;
  "pr close") setf "$3" '.state="CLOSED"' ;;
  "issue comment") cp "$(arg --body-file "$@")" "$st/comment_$3" ;;
  "issue view")
    if [ -f "$st/issue_$3" ]; then [ "$(cat "$st/issue_$3")" != FAIL ] || { echo "gh: issue $3 not found" >&2; exit 1; }; cat "$st/issue_$3"; else echo OPEN; fi ;;
  "repo view") echo main ;;
  "api user") echo me ;;
  *)
    case " $* " in
      *" -X PATCH "*pulls/*) all="$*"; n=${all##*pulls/}; n=${n%% *}; b=$(arg -f "$@"); setf "$n" ".baseRefName=\"${b#base=}\"" ;;
      *sub_issues*) cat "$st/sub_issues.json" ;;
      *search/issues*) arg -f "$@" > "$st/search_q"; cat "$st/search.json" ;;
      *" api repos/"*) emit < "$st/repo.json" ;;
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
  echo '{"allow_rebase_merge":true,"allow_squash_merge":true}' > "$ST/repo.json"
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
  expect_rc 1; expect_has "BLOCKED #7 PR HEAD 가 리뷰한 SHA 와 다르다"; expect_not_called "pr merge"; expect_not_called "pr ready"; expect_path "$T/wt"
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
t_land_method_squash() { # 저장소가 rebase 를 막았으면 squash
  setup_repo; echo '{"allow_rebase_merge":false,"allow_squash_merge":true}' > "$ST/repo.json"
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA"; expect_rc 0; expect_called "pr merge 7 --repo o/r --squash"
}
t_land_via() { # 저장소의 착륙 명령을 PR 의 worktree 에서 돌리고 MERGED 를 확인한다
  setup_repo
  run land.sh --repo o/r --pr 7 --sha "$HEAD_SHA" --via "pwd > $T/via_cwd; touch $ST/merge_on_view_7"
  expect_rc 0; expect_has "LANDED #7 feedface0000"; expect_not_called "pr merge"
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
t_check_unknown() {
  setup_repo; git -C "$T/wt" fetch -q origin; pr 7 mergeable=UNKNOWN; printf 'UNKNOWN\nMERGEABLE\n' > "$ST/mseq_7"
  run pr-check.sh --repo o/r --pr 7 --worktree "$T/wt"; expect_rc 0; expect_has "OK 충돌 없음"
}
t_check_args() { setup_repo; run pr-check.sh --repo o/r --pr 7 --worktree "$T/none"; expect_rc 2; }

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
t_frontier_body_others_skip() {
  T=$(mktemp -d "$ROOT/f.XXXX"); ST=$T/st; mkdir -p "$ST"; export ST
  echo '[{"number":3,"state":"open","title":"theirs","labels":[],"user":{"login":"bob"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"body":"선행: #9"},
   {"number":4,"state":"closed","title":"done","labels":[],"user":{"login":"me"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"body":"선행: #9"}]' > "$ST/sub_issues.json"
  RUN_DIR=$T run frontier.sh --repo o/r --map 9; RUN_DIR=''; expect_rc 0; expect_has OTHERS; expect_not_called "issue view"; }
t_frontier_body_fail() { fb_run '"선행: #9"' FAIL; expect_rc 1; case $ERR in *"frontier: 선행 #9 조회 실패"*) ;; *) bad "stderr: $ERR" ;; esac; }

CASES='land_gh land_head_moved land_conflict land_unknown_then_ok land_needs_human land_merge_fail land_method_squash
land_via land_via_fails land_via_not_merged land_stack land_keep land_cleanup land_args
check_ok check_fails check_unknown check_args tree_roundtrip tree_refuses
mut_killed mut_survived mut_baseline_red mut_not_unique mut_literal frontier_map frontier_query
frontier_body_open frontier_body_closed frontier_body_mid frontier_body_linked frontier_body_union frontier_body_refs frontier_body_repo_case frontier_body_cross_repo frontier_body_prefix
frontier_body_others_skip frontier_body_fail'
ran=0
for c in $CASES; do
  label=${c//_/ }
  if [ -n "${ONLY:-}" ] && ! printf '%s\n' "$label" | grep -qE -- "$ONLY"; then continue; fi
  CASE=$label BAD=0 ran=$((ran + 1)); "t_$c"
  if [ $BAD = 0 ]; then PASS=$((PASS + 1)); echo "PASS $label"; else FAIL=$((FAIL + 1)); fi
done
[ $ran -gt 0 ] || { echo "ONLY='${ONLY:-}' 에 맞는 경우가 없다" >&2; exit 1; }
echo "pass $PASS fail $FAIL"
[ $FAIL = 0 ]
