#!/usr/bin/env bash
# wait-prs.sh · in-flight.sh 의 시험 하네스. 네트워크를 쓰지 않고, gh 는 PATH 의 스텁으로 갈음한다.
#
# 실행:
#   bash plugins/agent-dispatch/skills/agent-dispatch/scripts/test-scripts.sh
#
# 경우를 더하는 법:
#   1. case_<이름>() 함수를 쓴다. 안에서 run_script 로 스크립트를 돌리고 OUT·ERR·RC 를 expect_* 로 대조한다.
#   2. 아래 CASES 목록에 이름을 적는다.
#   gh 스텁 응답은 $STUB_DATA 아래 파일로 정한다(set_pr <PR> <state> <mergeable> [<리뷰>] [<댓글>], set_pr_list '<json>').
#   bash:3.2 컨테이너에서도 돌릴 경우는 CASES_32 에 적는다 — run_script 가 알아서 docker 로 돌린다.
# shellcheck disable=SC2016  # 정적 검사의 시험 입력이 작은따옴표 안의 ${...} 를 담는다
set -uo pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WAIT=$SCRIPTS/wait-prs.sh
FLIGHT=$SCRIPTS/in-flight.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUB_BIN=$TMP/bin
STUB_DATA=$TMP/data
mkdir -p "$STUB_BIN" "$STUB_DATA"

# gh 스텁: 함수가 아니라 실행 파일이다(컨테이너의 busybox timeout 도 실행 파일만 부른다).
# api graphql 은 fixture(GraphQL 응답 JSON)에 wait-prs.sh 가 넘긴 --jq 프로그램을 실제 jq 로 적용해 낸다.
# jq 가 없는 bash:3.2 컨테이너에서는 미리 정한 "--jq 적용 뒤 출력"(pr_<PR>.out)으로 갈음한다.
# 호스트에서 pr_<PR>.out 이 있으면 jq 결과와 대조하고, 다르면 $STUB_DATA/mismatch 에 적는다(run_script 가 실패로 센다).
# 질의 변수는 gh 처럼 다룬다: number·feedback 을 -f(문자열)로 넘기면 형 오류로 1 로 끝나고, -F feedback=true 가
# 아니면 fixture 의 reviews·comments 를 지운 뒤 적용한다(@include(if: $feedback) 흉내).
# 받은 인자(query 밖)는 argv_<PR>, 질의는 query_<PR>, --jq 프로그램은 jq_<PR> 에 남긴다.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
d=${STUB_DATA:?}
case "$1 $2" in
  "api graphql")
    shift 2
    n='' prog='' q='' fb='' argv=''
    while [ $# -gt 0 ]; do
      case $1 in
        --jq) prog=$2; shift 2 ;;
        --hostname) argv+="$1 $2"$'\n'; shift 2 ;;
        -f|-F)
          case $1=$2 in
            -F=number=*) n=${2#number=} ;;
            -F=feedback=*) fb=${2#feedback=} ;;
            -f=number=*|-f=feedback=*) echo "gh: Variable \$${2%%=*} was provided invalid value" >&2; exit 1 ;;
            *=query=*) q=${2#query=} ;;
          esac
          case $2 in query=*) ;; *) argv+="$1 $2"$'\n' ;; esac
          shift 2 ;;
        *) echo "gh stub: 모르는 인자: $1" >&2; exit 1 ;;
      esac
    done
    f=$d/pr_$n.json
    [ -f "$f" ] || { echo "no stub for PR $n" >&2; exit 1; }
    printf '%s\n' "$prog" > "$d/jq_$n"; printf '%s\n' "$q" > "$d/query_$n"; printf '%s' "$argv" > "$d/argv_$n"
    if ! command -v jq >/dev/null; then
      [ -f "$d/pr_$n.out" ] || { echo "gh stub: jq 가 없고 pr_$n.out 도 없다" >&2; exit 1; }
      cat "$d/pr_$n.out"; exit 0
    fi
    # gh 처럼: 응답에 errors 가 있으면 본문을 내고 첫 message 를 stderr 로 내며 1 로 끝난다.
    if jq -e 'has("errors")' "$f" >/dev/null 2>&1; then
      cat "$f"; echo "gh: $(jq -r '.errors[0].message' "$f")" >&2; exit 1
    fi
    strip=.; [ "$fb" = true ] || strip='if .data.repository.pullRequest | type == "object"
      then del(.data.repository.pullRequest.reviews, .data.repository.pullRequest.comments) else . end'
    out=$(jq "$strip" "$f" | jq -r "$prog") || exit 1
    if [ -f "$d/pr_$n.out" ]; then
      echo "$n" >> "$d/checked"
      [ "$out" = "$(cat "$d/pr_$n.out")" ] || echo "PR $n: 미리 정한 출력 '$(cat "$d/pr_$n.out")' 이 jq 결과 '$out' 와 다르다" >> "$d/mismatch"
    fi
    printf '%s\n' "$out" ;;
  "pr list") if [ -f "$d/pr_list" ]; then cat "$d/pr_list"; else echo '[]'; fi ;;
  "repo view") echo owner/repo ;;
  *) echo "gh stub: 모르는 호출: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# set_pr <PR> <state> <mergeable> [<리뷰 nodes JSON> [<대화 댓글 nodes JSON>]] — 그 PR 의 GraphQL 응답 fixture 를 둔다.
# 리뷰·댓글이 없는 fixture 는 bash:3.2 용 미리 정한 출력을 "<state> <mergeable>" 로 둔다. 있는 fixture 를 bash:3.2 에서
# 쓰려면 set_pr_out 으로 정한다(호스트에서 실제 jq 결과와 대조한다).
set_pr() {
  printf '{"data":{"repository":{"pullRequest":{"state":"%s","mergeable":"%s","reviews":{"nodes":%s},"comments":{"nodes":%s}}}}}\n' \
    "$2" "$3" "${4:-[]}" "${5:-[]}" > "$STUB_DATA/pr_$1.json"
  rm -f "$STUB_DATA/pr_$1.out"
  case ${4:-[]}${5:-[]} in '[][]') printf '%s %s\n' "$2" "$3" > "$STUB_DATA/pr_$1.out" ;; esac
}
set_pr_raw() { printf '%s\n' "$2" > "$STUB_DATA/pr_$1.json"; rm -f "$STUB_DATA/pr_$1.out"; }  # <PR> <응답 JSON 그대로>
set_pr_out() { printf '%s\n' "$2" > "$STUB_DATA/pr_$1.out"; }  # <PR> <bash:3.2 에서 낼 --jq 적용 뒤 출력>
set_pr_list() { printf '%s\n' "$1" > "$STUB_DATA/pr_list"; }
# review <state> <submittedAt|null> [<author __typename|null>] · comment <createdAt> [<isMinimized>] [<author __typename|null>]
# — fixture 의 nodes 한 칸. author 를 null 로 주면 지운 계정이다.
author_json() { if [ "$1" = null ]; then printf null; else printf '{"__typename":"%s"}' "$1"; fi; }
review() {
  local at=null; [ "$2" = null ] || at="\"$2\""
  printf '{"state":"%s","submittedAt":%s,"author":%s}' "$1" "$at" "$(author_json "${3:-User}")"
}
comment() { printf '{"createdAt":"%s","isMinimized":%s,"author":%s}' "$1" "${2:-false}" "$(author_json "${3:-User}")"; }

PASS=0 FAIL=0 SKIP=0
OUT='' ERR='' RC=0
CASE=''
BAD=0

# 경우마다 첫 실패만, 사유의 줄바꿈을 공백으로 펴서 한 줄로 낸다(바이트로 자르지 않는다 — 멀티바이트가 깨진다)
bad() { local r=${1//$'\n'/ }; [ $BAD = 1 ] || printf 'FAIL %s: %s\n' "$CASE" "$r"; BAD=1; }
expect_rc() { [ "$RC" = "$1" ] || bad "exit $1 이어야 하는데 $RC (stderr: $ERR)"; }
expect_out() { [ "$OUT" = "$1" ] || bad "stdout 이 '$1' 이어야 하는데 '$OUT' (stderr: $ERR)"; }
expect_out_has() { case $OUT in *"$1"*) ;; *) bad "stdout 에 '$1' 이 없다: '$OUT'" ;; esac; }
expect_err_empty() { [ -z "$ERR" ] || bad "stderr 가 비어 있어야 한다: '$ERR'"; }
expect_out_empty() { [ -z "$OUT" ] || bad "stdout 이 비어 있어야 한다: '$OUT'"; }


# run_script <native|docker> <스크립트> [인자...] — OUT·ERR·RC 를 채운다. 제한 시간 20초.
run_script() {
  local via=$1 script=$2; shift 2
  local so=$TMP/so se=$TMP/se
  if [ "$via" = docker ]; then
    timeout 60 docker run --rm --network none -v "$TMP:$TMP" -v "$SCRIPTS:$SCRIPTS:ro" -w "$TMP" \
      -e STUB_DATA -e WAIT_PRS_INTERVAL -e WAIT_PRS_MAX_FAIL \
      -e PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      bash:3.2 bash "$script" "$@" >"$so" 2>"$se"
  else
    ( cd "$TMP" && PATH="$STUB_BIN:$PATH" STUB_DATA=$STUB_DATA timeout 20 bash "$script" "$@" ) >"$so" 2>"$se"
  fi
  RC=$?
  OUT=$(cat "$so"); ERR=$(cat "$se")
  if [ -f "$STUB_DATA/mismatch" ]; then bad "$(cat "$STUB_DATA/mismatch")"; fi
}
export STUB_DATA WAIT_PRS_INTERVAL=1 WAIT_PRS_MAX_FAIL=10

# ---- wait-prs.sh ----
case_wait_other_merged() { # via
  set_pr 5 MERGED UNKNOWN
  run_script "$1" "$WAIT" --repo o/r --other 5
  expect_rc 0; expect_out 'MERGED 5'
}
case_wait_mine_conflicting() {
  set_pr 7 OPEN CONFLICTING
  run_script "$1" "$WAIT" --repo o/r 7
  expect_rc 0; expect_out 'CONFLICTING 7'
}
case_wait_mine_merged() {
  set_pr 7 MERGED UNKNOWN
  run_script "$1" "$WAIT" --repo o/r 7
  expect_rc 0; expect_out 'MERGED 7'
}
case_wait_mine_closed() {
  set_pr 7 CLOSED UNKNOWN
  run_script "$1" "$WAIT" --repo o/r 7
  expect_rc 0; expect_out 'CLOSED 7'
}
case_wait_other_conflict_ignored() { # 남의 PR 의 충돌은 일이 아니다 — 아무 일 없이 --timeout 이 지난다
  set_pr 5 OPEN CONFLICTING
  run_script "$1" "$WAIT" --repo o/r --timeout 1 --other 5
  expect_rc 3; expect_out 'TIMEOUT'
}
case_wait_together() { # 한 차례 조회에 생긴 일을 모두 낸다
  set_pr 7 OPEN CONFLICTING
  set_pr 5 MERGED UNKNOWN
  run_script "$1" "$WAIT" --repo o/r --other 5 7
  expect_rc 0; expect_out $'CONFLICTING 7\nMERGED 5'
}
case_wait_gh_failing() { # 조회가 잇달아 실패하면 gh 의 마지막 오류 한 줄을 이유로 낸다
  WAIT_PRS_MAX_FAIL=1 run_script "$1" "$WAIT" --repo o/r 6
  expect_rc 0; expect_out 'GH_FAILING 6 no stub for PR 6'
}
# ---- wait-prs.sh: PR 피드백(FEEDBACK) ----
C=2026-10-30T10:00:00Z   # 경우들이 쓰는 피드백 커서
case_fb_after_cursor() { # 커서 뒤의 것만 세고, 리뷰·대화 댓글 가운데 가장 늦은 시각을 낸다
  set_pr 7 OPEN MERGEABLE \
    "[$(review COMMENTED 2026-10-30T09:59:59Z),$(review COMMENTED 2026-10-30T10:30:00Z)]" \
    "[$(comment 2026-10-30T10:45:00Z),$(comment 2026-10-30T10:00:01Z)]"
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" 7
  expect_rc 0; expect_out 'FEEDBACK 7 2026-10-30T10:45:00Z'
}
case_fb_review_latest() { # 리뷰가 가장 늦으면 그 시각이다
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]" "[$(comment 2026-10-30T10:30:00Z)]"
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" 7
  expect_rc 0; expect_out 'FEEDBACK 7 2026-10-30T11:00:00Z'
}
case_fb_cursor_equal() { # 커서와 같은 시각과 그 앞의 것은 세지 않는다(엄격한 >)
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED "$C"),$(review CHANGES_REQUESTED 2026-10-30T09:00:00Z)]" "[$(comment "$C")]"
  run_script "$1" "$WAIT" --repo o/r --timeout 1 --since "7=$C" 7
  expect_rc 3; expect_out 'TIMEOUT'
}
case_fb_no_cursor() { # --since 를 주지 않은 PR 은 모든 피드백을 센다
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2020-01-02T03:04:05Z)]"
  run_script "$1" "$WAIT" --repo o/r --timeout 2 7
  expect_rc 0; expect_out 'FEEDBACK 7 2020-01-02T03:04:05Z'
}
case_fb_excluded() { # 보류 리뷰(submittedAt null), Bot 의 리뷰·댓글, 숨긴 댓글은 세지 않는다
  set_pr 7 OPEN MERGEABLE \
    "[$(review PENDING null),$(review COMMENTED 2026-10-30T11:00:00Z Bot)]" \
    "[$(comment 2026-10-30T11:00:00Z false Bot),$(comment 2026-10-30T11:00:00Z true)]"
  run_script "$1" "$WAIT" --repo o/r --timeout 1 --since "7=$C" 7
  expect_rc 3; expect_out 'TIMEOUT'
}
case_fb_deleted_author() { # author 가 null 인 지운 계정의 리뷰·댓글은 센다
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z null)]"
  set_pr 8 OPEN MERGEABLE '[]' "[$(comment 2026-10-30T12:00:00Z false null)]"
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" --since "8=$C" 7 8
  expect_rc 0; expect_out $'FEEDBACK 7 2026-10-30T11:00:00Z\nFEEDBACK 8 2026-10-30T12:00:00Z'
}
case_fb_approved() { # APPROVED 리뷰도 센다 — 수정 요청인지는 오케스트레이터가 가른다
  set_pr 7 OPEN MERGEABLE "[$(review APPROVED 2026-10-30T11:00:00Z)]"
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" 7
  expect_rc 0; expect_out 'FEEDBACK 7 2026-10-30T11:00:00Z'
}
case_fb_other_ignored() { # 남의 PR 의 피드백은 보지 않는다(같은 피드백이 달린 이 실행의 PR 은 낸다)
  set_pr 5 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]" "[$(comment 2026-10-30T11:00:00Z)]"
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]" "[$(comment 2026-10-30T11:00:00Z)]"
  run_script "$1" "$WAIT" --repo o/r --timeout 2 --other 5 7
  expect_rc 0; expect_out 'FEEDBACK 7 2026-10-30T11:00:00Z'
}
case_fb_merged_closed() { # 병합되거나 닫힌 PR 은 피드백이 있어도 FEEDBACK 을 내지 않는다
  set_pr 7 MERGED UNKNOWN "[$(review COMMENTED 2026-10-30T11:00:00Z)]"
  set_pr 8 CLOSED UNKNOWN '[]' "[$(comment 2026-10-30T11:00:00Z)]"
  set_pr 9 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]"
  run_script "$1" "$WAIT" --repo o/r 7 8 9
  expect_rc 0; expect_out $'MERGED 7\nCLOSED 8\nFEEDBACK 9 2026-10-30T11:00:00Z'
}
case_fb_with_conflict() { # 열린 PR 이면 CONFLICTING 과 FEEDBACK 을 같은 차례에 함께 낸다
  set_pr 7 OPEN CONFLICTING "[$(review COMMENTED 2026-10-30T11:00:00Z)]"
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" 7
  expect_rc 0; expect_out $'CONFLICTING 7\nFEEDBACK 7 2026-10-30T11:00:00Z'
}
case_fb_since_32() { # bash:3.2 대리 시험에서도 도는 --since 호출(남의 PR 과 함께)
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T10:30:00Z)]"
  set_pr_out 7 'OPEN MERGEABLE 2026-10-30T10:30:00Z'
  set_pr 5 OPEN MERGEABLE
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" --other 5 7
  expect_rc 0; expect_out 'FEEDBACK 7 2026-10-30T10:30:00Z'; expect_err_empty
  # 컨테이너의 스텁은 프로그램을 적용하지 않으므로, 받은 프로그램을 직접 본다
  grep -qF "> \"$C\"" "$STUB_DATA/jq_7" 2>/dev/null || bad "PR 7 의 --jq 에 커서가 박히지 않았다: $(cat "$STUB_DATA/jq_7" 2>/dev/null)"
  ! grep -q reviews "$STUB_DATA/jq_5" 2>/dev/null || bad "남의 PR 5 의 --jq 가 피드백을 본다: $(cat "$STUB_DATA/jq_5")"
}
case_fb_bad_since() { # --since 의 꼴이 틀리거나, 그 PR 이 위치 인자에 없거나, 같은 PR 을 두 번 주면 exit 2
  local a
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]"; set_pr 5 OPEN MERGEABLE
  run_script native "$WAIT" --repo o/r --timeout 2 --since "7=$C" --other 5 7   # 맞는 꼴은 받는다
  expect_rc 0; expect_out 'FEEDBACK 7 2026-10-30T11:00:00Z'
  for a in '7=2026-10-30 10:00:00Z' '7=2026-10-30T10:00:00+09:00' '7=2026-10-30T10:00:00' '7=2026-10-30' '7=' \
           "=$C" "x=$C" "7:$C" "$C" "7=$C " "#7=$C" "PR7=$C" \
           '7=2026-10-30T1:00:00Z' '7=2026-1-30T10:00:00Z' '7=26-10-30T10:00:00Z' '7=12026-10-30T10:00:00Z'; do
    run_script native "$WAIT" --repo o/r --timeout 1 --since "$a" 7
    expect_rc 2; expect_out_empty
  done
  run_script native "$WAIT" --repo o/r --timeout 1 --since; expect_rc 2; expect_out_empty
  run_script native "$WAIT" --repo o/r --timeout 1 --since "8=$C" 7; expect_rc 2; expect_out_empty
  run_script native "$WAIT" --repo o/r --timeout 1 --since "5=$C" --other 5 7; expect_rc 2; expect_out_empty
  run_script native "$WAIT" --repo o/r --timeout 1 --since "7=$C" --since "7=$C" 7; expect_rc 2; expect_out_empty
}
case_wait_bad_repo() { # --repo 가 [HOST/]OWNER/REPO 꼴이 아니면 exit 2
  local r
  set_pr 7 OPEN MERGEABLE
  for r in foo /r o/ a/b/c/d; do
    run_script native "$WAIT" --repo "$r" --timeout 1 7
    expect_rc 2; expect_out_empty
  done
}
case_fb_broken() { # 응답·--jq 가 깨지면 실패로 센다(GH_FAILING)
  set_pr_raw 7 '{"data":{"repository":{"pullRequest":{"state":"OPEN","mergeable":"MERGEABLE","reviews":null,"comments":{"nodes":[]}}}}}'
  set_pr_raw 8 '{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a PullRequest with the number of 8."}]}'
  set_pr 9 OPEN MERGEABLE "[$(review COMMENTED yesterday)]"
  set_pr 6 WEIRD MERGEABLE
  WAIT_PRS_MAX_FAIL=1 run_script "$1" "$WAIT" --repo o/r 6 7 8 9
  expect_rc 0
  [ "$(printf '%s\n' "$OUT" | wc -l)" = 4 ] || bad "GH_FAILING 네 줄이어야 하는데: '$OUT'"
  expect_out_has 'GH_FAILING 6 알 수 없는 응답: WEIRD MERGEABLE'
  expect_out_has 'GH_FAILING 7 '
  expect_out_has 'GH_FAILING 8 gh: Could not resolve to a PullRequest with the number of 8.'
  expect_out_has 'GH_FAILING 9 알 수 없는 응답: OPEN MERGEABLE yesterday'
}
case_fb_query_fields() { # 질의가 --jq 프로그램이 읽는 필드를 받는다(스텁은 질의를 보지 않고 fixture 전체에 프로그램을 적용한다)
  local f
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]"
  run_script native "$WAIT" --repo o/r --timeout 1 7
  for f in state mergeable reviews submittedAt author __typename comments createdAt isMinimized; do
    grep -qw "$f" "$STUB_DATA/query_7" 2>/dev/null || bad "질의에 $f 가 없다: $(cat "$STUB_DATA/query_7" 2>/dev/null)"
  done
  for f in 'reviews(last: 100) @include(if: $feedback)' 'comments(last: 100) @include(if: $feedback)'; do
    grep -qF "$f" "$STUB_DATA/query_7" 2>/dev/null || bad "질의에 '$f' 가 없다"
  done
}
case_fb_query_args() { # 이 실행의 PR 은 -F feedback=true, 남의 PR 은 -F feedback=false. number 는 -F, owner·name·hostname 은 --repo 에서
  local a
  set_pr 7 OPEN MERGEABLE; set_pr 5 OPEN MERGEABLE
  run_script native "$WAIT" --repo https://ghe.example/o/r.git --timeout 1 --other 5 7
  expect_rc 3; expect_out 'TIMEOUT'
  for a in '-F feedback=true' '-F number=7' '-f owner=o' '-f name=r' '--hostname ghe.example'; do
    grep -qxF -- "$a" "$STUB_DATA/argv_7" 2>/dev/null || bad "PR 7 조회에 '$a' 가 없다: $(tr '\n' ' ' < "$STUB_DATA/argv_7" 2>/dev/null)"
  done
  grep -qxF -- '-F feedback=false' "$STUB_DATA/argv_5" 2>/dev/null || bad "남의 PR 5 조회가 -F feedback=false 가 아니다"
}
case_precomputed_vs_jq() { # bash:3.2 경우의 미리 정한 출력이 같은 fixture 에 실제 jq 를 적용한 결과와 같다
  local c fn
  for c in "${CASES_32[@]}"; do
    fn=case_${c#*:case_}
    rm -rf "$STUB_DATA"; mkdir -p "$STUB_DATA"
    "$fn" native   # 다르면 run_script 가 mismatch 로 실패를 적는다
    [ -s "$STUB_DATA/checked" ] || bad "$fn: 미리 정한 출력을 대조하지 못했다"
  done
  # 대조 자체의 시험: 틀린 미리 정한 출력은 잡힌다
  rm -rf "$STUB_DATA"; mkdir -p "$STUB_DATA"
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z)]"
  set_pr_out 7 'OPEN MERGEABLE'
  ( cd "$TMP" && PATH="$STUB_BIN:$PATH" timeout 20 bash "$WAIT" --repo o/r 7 ) >/dev/null 2>&1   # run_script 는 mismatch 를 실패로 센다
  [ -s "$STUB_DATA/mismatch" ] || bad "틀린 미리 정한 출력('OPEN MERGEABLE')을 잡지 못했다"
}

case_wait_help() {
  run_script "$1" "$WAIT" -h
  expect_rc 0; expect_err_empty
  expect_out_has '--interval'
  case $(printf '%s\n' "$OUT" | tail -n 1) in '필요한 것: '*) ;; *) bad "마지막 줄이 '필요한 것' 이 아니다: '$(printf '%s\n' "$OUT" | tail -n 1)'" ;; esac
}
case_wait_no_args() {
  run_script "$1" "$WAIT"
  expect_rc 2; expect_out_empty
  [ -n "$ERR" ] || bad "인자 오류의 도움말은 stderr 로 나와야 한다"
}

# ---- in-flight.sh ----
case_flight_free() {
  local cfg=$TMP/cfg repo=$TMP/repo
  rm -rf "$cfg" "$repo"; mkdir -p "$cfg" "$repo"
  git -C "$repo" init -q -b main && git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  RC=0
  OUT=$(cd "$repo" && PATH="$STUB_BIN:$PATH" CLAUDE_CONFIG_DIR=$cfg timeout 20 bash "$FLIGHT" --repo o/r 77 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
  expect_rc 0; expect_out '#77 FREE'
}
case_flight_help() {
  run_script "$1" "$FLIGHT" -h
  expect_rc 0; expect_err_empty
  expect_out_has 'FREE'
  case $(printf '%s\n' "$OUT" | tail -n 1) in '필요한 것: '*) ;; *) bad "마지막 줄이 '필요한 것' 이 아니다: '$(printf '%s\n' "$OUT" | tail -n 1)'" ;; esac
}
case_flight_no_args() {
  run_script "$1" "$FLIGHT"
  expect_rc 2; expect_out_empty
  [ -n "$ERR" ] || bad "인자 오류의 도움말은 stderr 로 나와야 한다"
}

# ---- 정적 검사 ----
# 길이 확인 없이 펼친 배열("${a[@]}" · ${a[*]} · ${a[@]:1})이 없어야 한다. bash 4.3 이하는 set -u 아래 빈 배열 펼침에서 죽는다.
# 안전한 꼴: ${a[@]+"${a[@]}"} · ${a[*]+${a[*]}} · ${#a[@]} · ${!a[@]}.
# 예외 "파일:줄에 든 글": 바로 앞에서 길이를 확인하는 자리. 줄 내용으로 매칭한다.
STATIC_ALLOW=(
  'wait-prs.sh:printf '\''%s\n'\'' "${events[@]}"'   # `if [ ${#events[@]} -gt 0 ]` 안에서만 펼친다
)
# find_unguarded <파일> — 길이 확인 없이 펼친 줄을 "줄번호:내용" 으로 낸다(주석 줄 제외).
find_unguarded() {
  grep -n -v '^[[:space:]]*#' "$1" \
    | sed -E 's/\$\{([A-Za-z_][A-Za-z_0-9]*)\[[@*]\]\+"\$\{\1\[[@*]\]\}"\}//g; s/\$\{([A-Za-z_][A-Za-z_0-9]*)\[\*\]\+\$\{\1\[\*\]\}\}//g' \
    | grep -E '\$\{[A-Za-z_][A-Za-z_0-9]*\[[@*]\][^}]*\}' || true
}
case_static_empty_array() {
  local f line a ok
  for f in "$WAIT" "$FLIGHT"; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ok=0
      for a in "${STATIC_ALLOW[@]}"; do
        [ "${a%%:*}" = "$(basename "$f")" ] && case $line in *"${a#*:}"*) ok=1 ;; esac
      done
      [ $ok = 1 ] || bad "$(basename "$f"): 길이 확인 없이 펼친 배열: $line"
    done <<<"$(find_unguarded "$f")"
  done
}
case_static_detects() { # 검사 자체의 시험: 실제 검사(find_unguarded)가 풀어 쓴 꼴은 잡고 안전한 꼴은 놓아준다
  local t=$TMP/probe.sh r
  printf '%s\n' 'x=("${a[@]}")' 'y=${b[*]}' 'z=${c[@]:1}' > "$t"
  r=$(find_unguarded "$t" | wc -l)
  [ "$r" = 3 ] || bad "unguarded 세 줄을 잡아야 하는데 $r"
  printf '%s\n' 'x=(${a[@]+"${a[@]}"})' 'echo ${#a[@]} ${!a[@]} ${b[*]+${b[*]}}' '# "${c[@]}"' > "$t"
  r=$(find_unguarded "$t" | wc -l)
  [ "$r" = 0 ] || bad "안전한 꼴을 놓아줘야 하는데 $r 줄을 잡았다"
}

# 헤더 구조 시험: 헤더 한가운데(`필요한 것` 줄 바로 앞)에 줄을 끼운 사본으로 -h 를 돌린다. 기대 줄은 여기서 직접 정한다.
# 끼운 줄이 주석이면 도움말에 들어가고 마지막 줄은 그대로 `필요한 것:` 이다(줄 번호 범위면 잘린다).
case_header_mid_comment() { # <스크립트>
  local t=$TMP/hdr.sh
  awk '/^# 필요한 것:/ { print "# 시험용으로 끼운 줄" } { print }' "$1" > "$t"
  run_script native "$t" -h
  expect_rc 0; expect_out_has '시험용으로 끼운 줄'
  case $(printf '%s\n' "$OUT" | tail -n 1) in '필요한 것: '*) ;; *) bad "마지막 줄이 '필요한 것' 이 아니다: '$(printf '%s\n' "$OUT" | tail -n 1)'" ;; esac
}
# 끼운 줄이 빈 줄이면 도움말은 그 앞에서 끊긴다: 마지막 줄은 바로 앞의 `헤더 규칙:` 줄이고 `필요한 것` 은 나오지 않는다.
case_header_mid_blank() { # <스크립트>
  local t=$TMP/hdr.sh
  awk '/^# 필요한 것:/ { print "" } { print }' "$1" > "$t"
  run_script native "$t" -h
  expect_rc 0
  case $OUT in *'필요한 것'*) bad "빈 줄 뒤의 '필요한 것' 이 나왔다" ;; esac
  case $(printf '%s\n' "$OUT" | tail -n 1) in '헤더 규칙: '*) ;; *) bad "마지막 줄이 '헤더 규칙' 이 아니다: '$(printf '%s\n' "$OUT" | tail -n 1)'" ;; esac
}

case_hdr_comment_wait() { case_header_mid_comment "$WAIT"; }
case_hdr_comment_flight() { case_header_mid_comment "$FLIGHT"; }
case_hdr_blank_wait() { case_header_mid_blank "$WAIT"; }
case_hdr_blank_flight() { case_header_mid_blank "$FLIGHT"; }

# ---- 실행 ----
run_case() { # <표시 이름> <함수> [인자...]
  local label=$1; shift
  CASE=$label BAD=0
  rm -rf "$STUB_DATA"; mkdir -p "$STUB_DATA"   # 앞 경우의 fixture 가 남지 않게
  "$@"
  if [ $BAD = 0 ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL + 1)); fi
}

CASES=(
  'wait-prs --other 5 → MERGED 5:case_wait_other_merged native'
  'wait-prs 7 → CONFLICTING 7:case_wait_mine_conflicting native'
  'wait-prs 7 → MERGED 7:case_wait_mine_merged native'
  'wait-prs 7 → CLOSED 7:case_wait_mine_closed native'
  'wait-prs --other 5 충돌 → 일이 아니다(TIMEOUT):case_wait_other_conflict_ignored native'
  'wait-prs 한 차례 조회의 일을 모두 낸다:case_wait_together native'
  'wait-prs 조회 실패 → GH_FAILING:case_wait_gh_failing native'
  'wait-prs 피드백: 커서 뒤의 것만, 가장 늦은 시각:case_fb_after_cursor native'
  'wait-prs 피드백: 리뷰가 가장 늦으면 그 시각:case_fb_review_latest native'
  'wait-prs 피드백: 커서와 같은 시각은 뺀다:case_fb_cursor_equal native'
  'wait-prs 피드백: --since 가 없으면 모두 센다:case_fb_no_cursor native'
  'wait-prs 피드백: 보류 리뷰·Bot·숨긴 댓글은 뺀다:case_fb_excluded native'
  'wait-prs 피드백: author 가 null 이면 센다:case_fb_deleted_author native'
  'wait-prs 피드백: APPROVED 도 센다:case_fb_approved native'
  'wait-prs 피드백: --other 는 무시한다:case_fb_other_ignored native'
  'wait-prs 피드백: MERGED·CLOSED 면 FEEDBACK 이 없다:case_fb_merged_closed native'
  'wait-prs 피드백: CONFLICTING 과 함께 낸다:case_fb_with_conflict native'
  'wait-prs 피드백: --since 와 --other 를 함께:case_fb_since_32 native'
  'wait-prs --since 가 틀리면 exit 2:case_fb_bad_since'
  'wait-prs --repo 가 틀리면 exit 2:case_wait_bad_repo'
  'wait-prs 응답·--jq 가 깨지면 GH_FAILING:case_fb_broken native'
  'wait-prs 질의가 피드백 필드를 받는다:case_fb_query_fields'
  'wait-prs 질의 변수(feedback·number·owner·name·hostname):case_fb_query_args'
  'bash:3.2 미리 정한 출력 = 실제 jq 결과:case_precomputed_vs_jq'
  'wait-prs -h → 헤더 전체, exit 0:case_wait_help native'
  'wait-prs 인자 없음 → exit 2:case_wait_no_args native'
  'in-flight 77 → FREE:case_flight_free'
  'in-flight -h → 헤더 전체, exit 0:case_flight_help native'
  'in-flight 인자 없음 → exit 2:case_flight_no_args native'
  '정적 검사: 빈 배열 펼침 없음:case_static_empty_array'
  '정적 검사: 검사기 자체:case_static_detects'
  'wait-prs -h → 헤더 중간에 낀 주석 줄도 낸다:case_hdr_comment_wait'
  'in-flight -h → 헤더 중간에 낀 주석 줄도 낸다:case_hdr_comment_flight'
  'wait-prs -h → 헤더 중간의 빈 줄에서 끊긴다:case_hdr_blank_wait'
  'in-flight -h → 헤더 중간의 빈 줄에서 끊긴다:case_hdr_blank_flight'
)
# bash:3.2 컨테이너에서 같은 경우를 돌린다(3.2 의 빈 배열 동작은 4.0~4.3 과 같다)
CASES_32=(
  'wait-prs --other 5 → MERGED 5:case_wait_other_merged'
  'wait-prs 7 → CONFLICTING 7:case_wait_mine_conflicting'
  'wait-prs 피드백: --since 와 --other 를 함께:case_fb_since_32'
)

for c in "${CASES[@]}"; do
  label=${c%%:case_*}; rest=case_${c#*:case_}
  # shellcheck disable=SC2086
  run_case "$label" $rest
done

if docker image inspect bash:3.2 >/dev/null 2>&1; then
  for c in "${CASES_32[@]}"; do
    label=${c%%:case_*}; rest=case_${c#*:case_}
    run_case "bash:3.2 $label" "$rest" docker
  done
else
  SKIP=$((SKIP + 1)); echo 'SKIP bash:3.2 (이미지 없음)'
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
