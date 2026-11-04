#!/usr/bin/env bash
# wait-prs.sh, in-flight.sh 의 시험 하네스. 네트워크를 쓰지 않고, gh 는 PATH 의 스텁으로 갈음한다.
#
# 실행:
#   bash plugins/agent-dispatch/skills/agent-dispatch/scripts/test-scripts.sh
#   ONLY='in-flight --peers' bash .../test-scripts.sh    라벨(PASS/FAIL 줄의 글)이 ERE 에 맞는 경우만 돈다. 맞는 것이 없으면 exit 1(MUTATE 와 함께면 exit 2), ERE 가 틀리면 exit 2
#   MUTATE='in-flight.sh:s/exit 2/exit 1/' ONLY='git 밖' bash .../test-scripts.sh
#                                                        $TMP 의 사본에 perl 변이를 걸고 돈다(원본은 그대로). FAIL 이 있으면
#                                                        MUTANT KILLED(exit 0), 없으면 MUTANT SURVIVED(exit 1), 변이 오류, 무변경, 돈 경우 없음은 exit 2
#
# 경우를 더하는 법:
#   1. case_<이름>() 함수를 쓴다. 안에서 run_script 로 스크립트를 돌리고 OUT/ERR/RC 를 expect_* 로 대조한다.
#   2. 아래 CASES 목록에 이름을 적는다.
#   gh 스텁 응답은 $STUB_DATA 아래 파일로 정한다(set_pr <PR> <state> <mergeable> [<리뷰>] [<댓글>], set_pr_list '<json>').
#   in-flight 의 세션 fixture(가짜 세션 파일, 세션 기록, claim)는 peers_setup 과 fake_session/fake_transcript/fake_claim 으로 둔다.
#   bash:3.2 컨테이너에서도 돌릴 경우는 CASES_32 에 적는다 -- run_script 가 알아서 docker 로 돌린다.
# shellcheck disable=SC2016  # 정적 검사의 시험 입력이 작은따옴표 안의 ${...} 를 담는다
set -uo pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WAIT=$SCRIPTS/wait-prs.sh
FLIGHT=$SCRIPTS/in-flight.sh

TMP=$(mktemp -d)
trap 'kill ${PEER_PIDS[@]+"${PEER_PIDS[@]}"} 2>/dev/null; rm -rf "$TMP"' EXIT
STUB_BIN=$TMP/bin
STUB_DATA=$TMP/data
mkdir -p "$STUB_BIN" "$STUB_DATA"

# MUTATE='<스크립트 이름>:<perl 식>' -- 두 스크립트를 $TMP 로 복사하고 대상 사본에만 perl 식을 건다. 원본은 건드리지 않는다.
# 정적 검사와 docker 경로도 WAIT/FLIGHT 를 거치므로 사본을 본다($TMP 는 컨테이너에 마운트된다).
if [ -n "${MUTATE:-}" ]; then
  case $MUTATE in
    *:*) m_target=${MUTATE%%:*}; m_expr=${MUTATE#*:} ;;
    *) echo "MUTATE 는 '<스크립트 이름>:<perl 식>' 꼴이어야 한다: '$MUTATE'" >&2; exit 2 ;;
  esac
  case $m_target in wait-prs.sh|in-flight.sh) ;; *) echo "MUTATE 의 대상은 wait-prs.sh 나 in-flight.sh 여야 한다: '$m_target'" >&2; exit 2 ;; esac
  mkdir -p "$TMP/mutant"
  cp "$WAIT" "$FLIGHT" "$TMP/mutant/"
  timeout 30 perl -pi -e "$m_expr" "$TMP/mutant/$m_target" || { echo "MUTATE 의 perl 식이 실패했거나 30초를 넘겼다: '$m_expr'" >&2; exit 2; }
  if cmp -s "$SCRIPTS/$m_target" "$TMP/mutant/$m_target"; then echo "변이가 아무것도 바꾸지 않았다: '$MUTATE'" >&2; exit 2; fi
  WAIT=$TMP/mutant/wait-prs.sh
  FLIGHT=$TMP/mutant/in-flight.sh
fi

# gh 스텁: 함수가 아니라 실행 파일이다(컨테이너의 busybox timeout 도 실행 파일만 부른다).
# api graphql 은 fixture(GraphQL 응답 JSON)에 wait-prs.sh 가 넘긴 --jq 프로그램을 실제 jq 로 적용해 낸다.
# jq 가 없는 bash:3.2 컨테이너에서는 미리 정한 "--jq 적용 뒤 출력"(pr_<PR>.out)으로 갈음한다.
# 호스트에서 pr_<PR>.out 이 있으면 jq 결과와 대조하고, 다르면 $STUB_DATA/mismatch 에 적는다(run_script 가 실패로 센다).
# 질의 변수는 gh 처럼 다룬다: number/feedback 을 -f(문자열)로 넘기면 형 오류로 1 로 끝나고, 질의가 $feedback 을
# 선언했는데 -F feedback 이 없으면 1 로 끝난다. -F feedback=true 도 아니고 $feedback 없는 질의(--show)도 아니면
# fixture 의 reviews/comments 를 지운 뒤 적용한다(@include(if: $feedback) 흉내). 출력은 gh 처럼 한 줄 JSON 이다.
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
    case $fb:$q in
      :*'$feedback'*) echo "gh: Variable \$feedback of required type Boolean! was not provided." >&2; exit 1 ;;
    esac
    strip=.; [ "$fb" = true ] || [ -z "$fb" ] || strip='if .data.repository.pullRequest | type == "object"
      then del(.data.repository.pullRequest.reviews, .data.repository.pullRequest.comments) else . end'
    out=$(jq "$strip" "$f" | jq -rc "$prog") || exit 1
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

# set_pr <PR> <state> <mergeable> [<리뷰 nodes JSON> [<대화 댓글 nodes JSON>]] -- 그 PR 의 GraphQL 응답 fixture 를 둔다.
# 리뷰, 댓글이 없는 fixture 는 bash:3.2 용 미리 정한 출력을 "<state> <mergeable>" 로 둔다. 있는 fixture 를 bash:3.2 에서
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
# review <state> <submittedAt|null> [<author __typename|null>], comment <createdAt> [<isMinimized>] [<author __typename|null>]
# -- fixture 의 nodes 한 칸. author 를 null 로 주면 지운 계정이다.
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

# 경우마다 첫 실패만, 사유의 줄바꿈을 공백으로 펴서 한 줄로 낸다(바이트로 자르지 않는다 -- 멀티바이트가 깨진다)
bad() { local r=${1//$'\n'/ }; [ $BAD = 1 ] || printf 'FAIL %s: %s\n' "$CASE" "$r"; BAD=1; }
expect_rc() { [ "$RC" = "$1" ] || bad "exit $1 이어야 하는데 $RC (stderr: $ERR)"; }
expect_out() { [ "$OUT" = "$1" ] || bad "stdout 이 '$1' 이어야 하는데 '$OUT' (stderr: $ERR)"; }
expect_out_has() { case $OUT in *"$1"*) ;; *) bad "stdout 에 '$1' 이 없다: '$OUT'" ;; esac; }
expect_err_empty() { [ -z "$ERR" ] || bad "stderr 가 비어 있어야 한다: '$ERR'"; }
expect_out_empty() { [ -z "$OUT" ] || bad "stdout 이 비어 있어야 한다: '$OUT'"; }


# run_script <native|docker> <스크립트> [인자...] -- OUT/ERR/RC 를 채운다. 제한 시간 20초.
run_script() {
  local via=$1 script=$2; shift 2
  local so=$TMP/so se=$TMP/se
  if [ "$via" = docker ]; then
    timeout -k 5 60 docker run --rm --init --network none -v "$TMP:$TMP" -v "$SCRIPTS:$SCRIPTS:ro" -w "$TMP" \
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
case_wait_other_conflict_ignored() { # 남의 PR 의 충돌은 일이 아니다 -- 아무 일 없이 --timeout 이 지난다
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
case_fb_after_cursor() { # 커서 뒤의 것만 세고, 리뷰, 대화 댓글 가운데 가장 늦은 시각을 낸다
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
case_fb_excluded() { # 보류 리뷰(submittedAt null), Bot 의 리뷰, 댓글, 숨긴 댓글은 세지 않는다
  set_pr 7 OPEN MERGEABLE \
    "[$(review PENDING null),$(review COMMENTED 2026-10-30T11:00:00Z Bot)]" \
    "[$(comment 2026-10-30T11:00:00Z false Bot),$(comment 2026-10-30T11:00:00Z true)]"
  run_script "$1" "$WAIT" --repo o/r --timeout 1 --since "7=$C" 7
  expect_rc 3; expect_out 'TIMEOUT'
}
case_fb_deleted_author() { # author 가 null 인 지운 계정의 리뷰, 댓글은 센다
  set_pr 7 OPEN MERGEABLE "[$(review COMMENTED 2026-10-30T11:00:00Z null)]"
  set_pr 8 OPEN MERGEABLE '[]' "[$(comment 2026-10-30T12:00:00Z false null)]"
  run_script "$1" "$WAIT" --repo o/r --since "7=$C" --since "8=$C" 7 8
  expect_rc 0; expect_out $'FEEDBACK 7 2026-10-30T11:00:00Z\nFEEDBACK 8 2026-10-30T12:00:00Z'
}
case_fb_approved() { # APPROVED 리뷰도 센다 -- 수정 요청인지는 오케스트레이터가 가른다
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
case_fb_broken() { # 응답, --jq 가 깨지면 실패로 센다(GH_FAILING)
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
case_fb_query_args() { # 이 실행의 PR 은 -F feedback=true, 남의 PR 은 -F feedback=false. number 는 -F, owner/name/hostname 은 --repo 에서
  local a
  set_pr 7 OPEN MERGEABLE; set_pr 5 OPEN MERGEABLE
  run_script native "$WAIT" --repo https://ghe.example/o/r.git --timeout 1 --other 5 7
  expect_rc 3; expect_out 'TIMEOUT'
  for a in '-F feedback=true' '-F number=7' '-f owner=o' '-f name=r' '--hostname ghe.example'; do
    grep -qxF -- "$a" "$STUB_DATA/argv_7" 2>/dev/null || bad "PR 7 조회에 '$a' 가 없다: $(tr '\n' ' ' < "$STUB_DATA/argv_7" 2>/dev/null)"
  done
  grep -qxF -- '-F feedback=false' "$STUB_DATA/argv_5" 2>/dev/null || bad "남의 PR 5 조회가 -F feedback=false 가 아니다"
}
# ---- wait-prs.sh --show ----
# show_fixture -- 커서 C 앞뒤의 리뷰, 댓글과 빼야 할 것(보류, Bot, 숨김)을 고루 둔 PR 7 응답
show_fixture() {
  set_pr_raw 7 '{"data":{"repository":{"pullRequest":{"state":"OPEN","mergeable":"MERGEABLE",
    "reviews":{"nodes":[
      {"state":"COMMENTED","submittedAt":"2026-10-30T09:00:00Z","url":"u/r1","body":"old","author":{"login":"h","__typename":"User"},"comments":{"nodes":[]}},
      {"state":"CHANGES_REQUESTED","submittedAt":"2026-10-30T11:00:00Z","url":"u/r2","body":"fix","author":{"login":"h","__typename":"User"},
       "comments":{"nodes":[{"path":"a.sh","line":3,"originalLine":2,"url":"u/i1","body":"here"},{"path":"b.md","line":null,"originalLine":5,"url":"u/i2","body":"gone"}]}},
      {"state":"PENDING","submittedAt":null,"url":"u/r3","body":"draft","author":{"login":"h","__typename":"User"},"comments":{"nodes":[]}},
      {"state":"COMMENTED","submittedAt":"2026-10-30T12:00:00Z","url":"u/r4","body":"bot","author":{"login":"b","__typename":"Bot"},"comments":{"nodes":[]}}]},
    "comments":{"nodes":[
      {"createdAt":"2026-10-30T09:30:00Z","isMinimized":false,"url":"u/c1","body":"early","author":{"login":"h","__typename":"User"}},
      {"createdAt":"2026-10-30T12:30:00Z","isMinimized":false,"url":"u/c2","body":"q?","author":null},
      {"createdAt":"2026-10-30T12:40:00Z","isMinimized":true,"url":"u/c3","body":"hidden","author":{"login":"h","__typename":"User"}},
      {"createdAt":"2026-10-30T12:50:00Z","isMinimized":false,"url":"u/c4","body":"botc","author":{"login":"b","__typename":"Bot"}}]}}}}}'
}
case_show_after_cursor() { # 커서 뒤의 리뷰(인라인 자리는 line, 없으면 originalLine), 댓글만 한 줄 JSON 으로 낸다
  show_fixture
  run_script native "$WAIT" --show --repo o/r --since "7=$C" 7
  expect_rc 0; expect_err_empty
  expect_out '{"at":"2026-10-30T11:00:00Z","state":"CHANGES_REQUESTED","url":"u/r2","body":"fix","inline":[{"where":"a.sh:3","url":"u/i1","body":"here"},{"where":"b.md:5","url":"u/i2","body":"gone"}]}
{"at":"2026-10-30T12:30:00Z","url":"u/c2","body":"q?"}'
}
case_show_no_cursor() { # --since 가 없으면 빼야 할 것 말고는 모두 낸다. 커서와 같은 시각은 뺀다
  show_fixture
  run_script native "$WAIT" --show --repo o/r 7
  expect_rc 0
  [ "$(printf '%s\n' "$OUT" | wc -l)" = 4 ] || bad "네 줄이어야 하는데: '$OUT'"
  expect_out_has '"url":"u/r1"'; expect_out_has '"url":"u/c1"'
  run_script native "$WAIT" --show --repo o/r --since 7=2026-10-30T11:00:00Z 7
  expect_rc 0; expect_out '{"at":"2026-10-30T12:30:00Z","url":"u/c2","body":"q?"}'
  run_script native "$WAIT" --show --repo o/r --since 7=2026-10-30T12:30:00Z 7
  expect_rc 0; expect_out_empty
}
case_show_empty() { # 피드백이 없으면 아무것도 내지 않고 0
  set_pr 7 OPEN MERGEABLE; rm -f "$STUB_DATA/pr_7.out"   # 미리 정한 출력은 지켜보기의 것이다
  run_script native "$WAIT" --show --repo o/r 7
  expect_rc 0; expect_out_empty; expect_err_empty
}
case_show_query() { # $feedback 없는 질의로, 본문, URL, 인라인 자리를 받는다. number 는 -F, hostname 은 --repo 에서
  local f
  set_pr 7 OPEN MERGEABLE; rm -f "$STUB_DATA/pr_7.out"   # 미리 정한 출력은 지켜보기의 것이다
  run_script native "$WAIT" --show --repo ghe.example/o/r 7
  expect_rc 0
  for f in reviews submittedAt url body path line originalLine comments createdAt isMinimized __typename; do
    grep -qw "$f" "$STUB_DATA/query_7" 2>/dev/null || bad "질의에 $f 가 없다"
  done
  ! grep -q feedback "$STUB_DATA/query_7" "$STUB_DATA/argv_7" 2>/dev/null || bad "--show 가 feedback 변수를 쓴다"
  for f in '-F number=7' '-f owner=o' '-f name=r' '--hostname ghe.example'; do
    grep -qxF -- "$f" "$STUB_DATA/argv_7" 2>/dev/null || bad "조회에 '$f' 가 없다"
  done
}
case_show_gh_fail() { # 조회가 실패하면 gh 의 오류를 stderr 로 내고 1 (기다리거나 되풀이하지 않는다)
  run_script native "$WAIT" --show --repo o/r 6
  expect_rc 1; expect_out_empty
  case $ERR in *'no stub for PR 6'*) ;; *) bad "stderr 에 gh 의 오류가 없다: '$ERR'" ;; esac
}
case_show_bad_args() { # --show 에 지켜보기 옵션, PR 0개나 2개, 위치 인자에 없는 --since 를 주면 exit 2
  local a
  set_pr 7 OPEN MERGEABLE; set_pr 8 OPEN MERGEABLE
  for a in '--other 8 7' '--interval 5 7' '--timeout 5 7' '7 8' '' "--since 8=$C 7"; do
    # shellcheck disable=SC2086
    run_script native "$WAIT" --show --repo o/r $a
    expect_rc 2; expect_out_empty
  done
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
  expect_out_has 'FREE'; expect_out_has 'in-flight.sh --peers [--repo owner/repo]'
  case $(printf '%s\n' "$OUT" | tail -n 1) in '필요한 것: '*) ;; *) bad "마지막 줄이 '필요한 것' 이 아니다: '$(printf '%s\n' "$OUT" | tail -n 1)'" ;; esac
}
case_flight_no_args() {
  run_script "$1" "$FLIGHT"
  expect_rc 2; expect_out_empty
  [ -n "$ERR" ] || bad "인자 오류의 도움말은 stderr 로 나와야 한다"
}

# ---- in-flight.sh --peers: 세션 fixture ----
# 가짜 설정 디렉터리 $PCFG 아래에 세션 파일, 세션 기록, claim 을 둔다. 진짜 ~/.claude 는 건드리지 않는다.
# 저장소 $PREPO 에는 worktree $PWT 가 하나 걸려 있다. 살아 있는 pid 는 sleep 으로 세운다(procStart "-" 라 alive 가 pid 만 본다).
PEER_PIDS=()
peers_setup() {
  PCFG=$TMP/cfg PREPO=$TMP/repo PWT=$TMP/wt-5
  rm -rf "$PCFG" "$PREPO" "$PWT"; mkdir -p "$PCFG/sessions" "$PCFG/projects/x" "$PCFG/agent-dispatch/claims" "$PREPO"
  git -C "$PREPO" init -q -b main && git -C "$PREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$PREPO" worktree add -q -b feat/5 "$PWT"
}
live_pid() { sleep 60 >/dev/null 2>&1 & PEER_PIDS+=("$!"); LIVE=$!; }   # LIVE 에 살아 있는 pid
dead_pid() { sleep 0 & DEAD=$!; wait "$DEAD"; }                         # DEAD 에 끝난 pid
peers_teardown() { kill ${PEER_PIDS[@]+"${PEER_PIDS[@]}"} 2>/dev/null; PEER_PIDS=(); }
# fake_session <pid> <이름> <sessionId> <cwd>
fake_session() {
  printf '{"pid":%s,"procStart":"-","name":"%s","sessionId":"%s","cwd":"%s"}\n' "$1" "$2" "$3" "$4" > "$PCFG/sessions/$1.json"
}
# fake_transcript <sessionId> <cwd>... -- 세션 기록에 cwd 를 단 줄을 차례로 더한다
fake_transcript() {
  local sid=$1 c; shift
  for c; do printf '{"type":"user","cwd":"%s","message":{"content":"hi"}}\n' "$c"; done >> "$PCFG/projects/x/$sid.jsonl"
}
# fake_claim <파일 이름> <pid> <이름> -- claims/<파일 이름> 에 그 세션이 맡았다는 표시
fake_claim() {
  printf '{"pid":%s,"procStart":"-","name":"%s","sessionId":"s-%s"}\n' "$2" "$3" "$2" > "$PCFG/agent-dispatch/claims/$1"
}
# fake_session_raw <pid> <JSON> -- 세션 파일에 JSON 을 그대로 쓴다(procStart 가 null 인 꼴 등)
fake_session_raw() { printf '%s\n' "$2" > "$PCFG/sessions/$1.json"; }
# fake_claim_ps <파일 이름> <pid> <이름> <procStart> -- fake_claim 의 procStart 를 정하는 변형(빈 문자열도 쓴다)
fake_claim_ps() {
  printf '{"pid":%s,"procStart":"%s","name":"%s","sessionId":"s-%s"}\n' "$2" "$4" "$3" "$2" > "$PCFG/agent-dispatch/claims/$1"
}
# run_flight_at <디렉터리> [인자...] -- 그 디렉터리 안에서 in-flight.sh 를 가짜 설정 디렉터리 $PCFG 로 돌린다
# GIT_CEILING_DIRECTORIES 를 $TMP 로 두어, TMPDIR 이 git 체크아웃 안이어도 $TMP 아래는 git 밖이다
run_flight_at() {
  local dir=$1; shift
  RC=0
  OUT=$(cd "$dir" && PATH="$STUB_BIN:$PATH" CLAUDE_CONFIG_DIR=$PCFG GIT_CEILING_DIRECTORIES=$TMP timeout 20 bash "$FLIGHT" "$@" 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
}
# run_peers [인자...] -- $PREPO 안에서 in-flight.sh --peers --repo o/r 를 돌린다
run_peers() { run_flight_at "$PREPO" --peers --repo o/r "$@"; }
case_peers_session_cwd() { # 세션 파일의 cwd 가 worktree 아래면 그 세션을 낸다
  peers_setup; live_pid
  fake_session "$LIVE" peer-a sa "$PWT/src"
  run_peers
  expect_rc 0; expect_out "peer-a"$'\t'"세션 파일 cwd $PWT/src"; expect_err_empty
  peers_teardown
}
case_peers_transcript_cwd() { # 세션 파일 cwd 는 밖이어도 기록의 cwd 가 worktree 면 낸다(이름이 이어 붙은 형제 경로는 아니다)
  peers_setup; live_pid
  fake_session "$LIVE" peer-b sb "$TMP/elsewhere"
  fake_transcript sb "$TMP/elsewhere" "$PWT" "$PWT/a/b" "$PWT/a" "$PWT-other"
  run_peers
  expect_rc 0; expect_out "peer-b"$'\t'"기록 cwd $PWT/a"; expect_err_empty   # 저장소 안의 마지막 것(첫 것, 최단, 최장이 아니다)
  peers_teardown
}
case_peers_claim() { # 이 저장소에 대한 claim 이 있으면 낸다(다른 저장소의 claim 은 보지 않는다)
  peers_setup; live_pid
  fake_session "$LIVE" peer-c sc "$TMP/elsewhere"
  fake_claim o_r_5.json "$LIVE" peer-c
  fake_claim o_r_x_9.json "$LIVE" peer-c
  run_peers
  expect_rc 0; expect_out "peer-c"$'\t'"claim #5"; expect_err_empty
  peers_teardown
}
case_peers_excluded() { # 죽은 세션, 자기 세션, 저장소 밖의 세션은 내지 않는다 -- 아무도 없으면 (없음), exit 0
  peers_setup; live_pid; dead_pid
  fake_session "$DEAD" peer-dead sd "$PREPO"; fake_transcript sd "$PWT"; fake_claim o_r_5.json "$DEAD" peer-dead
  fake_session $$ peer-self ss "$PREPO"; fake_transcript ss "$PWT"; fake_claim o_r_6.json $$ peer-self   # 하네스가 in-flight 의 조상이다
  fake_session "$LIVE" peer-far sf "$TMP/elsewhere"
  run_peers
  expect_rc 0; expect_out '(없음)'; expect_err_empty
  peers_teardown
}
case_peers_main_checkout() { # 세션 파일 cwd 가 주 체크아웃(git worktree list 의 첫 줄)이어도 낸다
  peers_setup; live_pid
  fake_session "$LIVE" peer-m sm "$PREPO"
  run_peers
  expect_rc 0; expect_out "peer-m"$'\t'"세션 파일 cwd $PREPO"; expect_err_empty
  peers_teardown
}
case_peers_rejects_number() { # --peers 는 이슈 번호를 받지 않는다
  peers_setup
  run_peers 5
  expect_rc 2; expect_out_empty
  [ -n "$ERR" ] || bad "stderr 에 이유가 없다"
}
case_peers_outside_git() { # 체크아웃 밖에서 돌리면 이유를 stderr 에 내고 exit 2(TMPDIR 이 git 안이어도 맞다)
  peers_setup; rm -rf "$TMP/nogit"; mkdir -p "$TMP/nogit"
  run_flight_at "$TMP/nogit" --peers --repo o/r
  expect_rc 2; expect_out_empty
  case $ERR in *'git 저장소 안에서 돌려라'*) ;; *) bad "stderr 에 이유가 없다: '$ERR'" ;; esac
}
# 판정 모드와 --release 도 --peers 가 고친 세션 수집(.cwd 조립)과 모드 분기를 쓴다 -- 그 회귀를 지킨다
case_flight_busy_transcript_cwd() { # 기록 cwd 가 그 이슈의 worktree 면 BUSY
  peers_setup; live_pid
  fake_session "$LIVE" peer-b sb "$TMP/elsewhere"; fake_transcript sb "$PWT"
  run_flight_at "$PREPO" --repo o/r 5
  expect_rc 0; expect_out_has '#5 BUSY'; expect_out_has "세션 peer-b 이 worktree $PWT 에서 일한다"
  peers_teardown
}
case_flight_busy_session_cwd() { # 세션 파일 cwd 가 그 이슈의 worktree 면 BUSY
  peers_setup; live_pid
  fake_session "$LIVE" peer-s ss2 "$PWT"
  run_flight_at "$PREPO" --repo o/r 5
  expect_rc 0; expect_out_has '#5 BUSY'; expect_out_has "세션 peer-s 이 worktree $PWT 에서 일한다"
  peers_teardown
}
case_flight_release() { # --release 는 판정으로 새지 않고 표시를 지운다
  peers_setup
  fake_session $$ me sme "$PREPO"; fake_claim o_r_5.json $$ me   # 하네스가 in-flight 의 조상이다
  run_flight_at "$PREPO" --release --repo o/r 5
  expect_rc 0; expect_out 'released #5'; expect_err_empty
  [ ! -e "$PCFG/agent-dispatch/claims/o_r_5.json" ] || bad "claim 파일이 남았다"
}

# ---- in-flight.sh: 빈 문자열, null 필드가 값을 밀지 않는다 ----
case_flight_empty_name_busy() { # "name":"" 세션이 기록 cwd 로 worktree 에 있으면 BUSY(이름 자리는 -)
  peers_setup; live_pid
  fake_session "$LIVE" "" sb "$TMP/elsewhere"; fake_transcript sb "$PWT"
  run_flight_at "$PREPO" --repo o/r 5
  expect_rc 0; expect_out_has '#5 BUSY'; expect_out_has "세션 - 이 worktree $PWT 에서 일한다"
  peers_teardown
}
case_peers_empty_name_transcript() { # "name":"" 세션은 --peers 에서 이름이 - 이고 기록 cwd 로 나온다
  peers_setup; live_pid
  fake_session "$LIVE" "" sb "$TMP/elsewhere"; fake_transcript sb "$PWT"
  run_peers
  expect_rc 0; expect_out "-"$'\t'"기록 cwd $PWT"; expect_err_empty
  peers_teardown
}
case_peers_empty_name_session_cwd() { # "name":"" 세션은 sessionId 를 이름으로 달지 않는다
  peers_setup; live_pid
  fake_session "$LIVE" "" sid-xyz "$PWT/src"
  run_peers
  expect_rc 0; expect_out "-"$'\t'"세션 파일 cwd $PWT/src"; expect_err_empty
  peers_teardown
}
# claim_alive_check <claim JSON> -- 살아 있는 pid 의 claim: 판정 BUSY, 파일 유지, --peers 에 claim #5
claim_alive_check() {
  peers_setup; live_pid
  fake_session "$LIVE" peer-x sx "$TMP/elsewhere"
  printf "$1\n" "$LIVE" > "$PCFG/agent-dispatch/claims/o_r_5.json"
  run_flight_at "$PREPO" --repo o/r 5
  expect_rc 0; expect_out_has '#5 BUSY'; expect_out_has 'claim: 세션 peer-x 이 맡았다'
  [ -e "$PCFG/agent-dispatch/claims/o_r_5.json" ] || bad "살아 있는 세션의 claim 파일이 지워졌다"
  run_peers
  expect_rc 0; expect_out "peer-x"$'\t'"claim #5"; expect_err_empty
  peers_teardown
}
case_flight_empty_procstart_claim() { claim_alive_check '{"pid":%s,"procStart":"","name":"peer-x"}'; }
case_flight_null_procstart_claim() { claim_alive_check '{"pid":%s,"procStart":null,"name":"peer-x"}'; }
case_flight_missing_procstart_claim() { claim_alive_check '{"pid":%s,"name":"peer-x"}'; }
case_peers_empty_procstart_session() { # 세션 파일의 procStart 가 빈 문자열이어도 이름이 밀리지 않는다
  peers_setup; live_pid
  fake_session_raw "$LIVE" "{\"pid\":$LIVE,\"procStart\":\"\",\"name\":\"peer-p\",\"sessionId\":\"sp\",\"cwd\":\"$PWT/src\"}"
  run_peers
  expect_rc 0; expect_out "peer-p"$'\t'"세션 파일 cwd $PWT/src"; expect_err_empty
  peers_teardown
}
case_peers_null_procstart_session() { # procStart 가 null 이어도 같다
  peers_setup; live_pid
  fake_session_raw "$LIVE" "{\"pid\":$LIVE,\"procStart\":null,\"name\":\"peer-p\",\"sessionId\":\"sp\",\"cwd\":\"$PWT/src\"}"
  run_peers
  expect_rc 0; expect_out "peer-p"$'\t'"세션 파일 cwd $PWT/src"; expect_err_empty
  peers_teardown
}
case_flight_outside_git() { # 판정 모드를 체크아웃 밖에서 돌리면 이유를 stderr 에 내고 exit 2
  peers_setup; rm -rf "$TMP/nogit"; mkdir -p "$TMP/nogit"
  run_flight_at "$TMP/nogit" --repo o/r 5
  expect_rc 2; expect_out_empty
  case $ERR in *'git 저장소 안에서 돌려라'*) ;; *) bad "stderr 에 이유가 없다: '$ERR'" ;; esac
}

# unreadable_claim_check <claim 파일에 쓸 내용> -- 읽을 수 없는 claim 이 판정을 막지 않는다
# (이슈 7 은 worktree 가 없어 원래 FREE 다 -- 판정을 올리는 변이가 보인다)
unreadable_claim_check() {
  peers_setup
  printf '%s' "$1" > "$PCFG/agent-dispatch/claims/o_r_7.json"
  run_flight_at "$PREPO" --repo o/r 7 6
  expect_rc 0
  printf '%s\n' "$OUT" | grep -qx '#7 FREE' || bad "'#7 FREE' 줄이 없다: $OUT"
  printf '%s\n' "$OUT" | grep -qx '#6 FREE' || bad "'#6 FREE' 줄이 없다: $OUT"
  expect_out_has "claim: 읽을 수 없는 표시 $PCFG/agent-dispatch/claims/o_r_7.json"
  [ -e "$PCFG/agent-dispatch/claims/o_r_7.json" ] || bad "읽을 수 없는 claim 파일이 지워졌다"
}
case_flight_empty_claim_file() { unreadable_claim_check ''; }
case_flight_broken_claim_file() { unreadable_claim_check '{"pid":12'; }
case_flight_claim_atomic() { # --claim 뒤에 임시 파일이 남지 않고 claim 은 JSON 이며, 다시 쓰면 새 파일(inode)이다
  peers_setup
  fake_session $$ me sme "$PREPO"
  run_flight_at "$PREPO" --claim --repo o/r 5
  expect_rc 0; expect_out 'claimed #5'
  local cf="$PCFG/agent-dispatch/claims/o_r_5.json" i1 i2
  jq -e .pid "$cf" >/dev/null || bad "claim 파일이 JSON 이 아니다"
  i1=$(ls -i "$cf" | awk '{print $1}')
  run_flight_at "$PREPO" --claim --repo o/r 5
  expect_rc 0
  i2=$(ls -i "$cf" | awk '{print $1}')
  [ "$i1" != "$i2" ] || bad "claim 파일의 inode 가 그대로다(직접 썼다): $i1"
  local left; left=$(ls -A "$PCFG/agent-dispatch/claims")
  [ "$left" = o_r_5.json ] || bad "claims 에 다른 파일이 남았다: $left"
}
# claim_bad_self_check <세션 파일에 쓸 내용> -- 자기 세션 파일을 못 읽으면 --claim 은 실패하고 claim 도 임시 파일도 남기지 않는다
claim_bad_self_check() {
  peers_setup
  printf '%s' "$1" > "$PCFG/sessions/$$.json"
  run_flight_at "$PREPO" --claim --repo o/r 5
  [ "$RC" -ne 0 ] || bad "exit 0 으로 끝났다: $OUT"
  case $ERR in *'세션 파일을 읽지 못해'*) ;; *) bad "stderr 에 이유가 없다: '$ERR'" ;; esac
  local left; left=$(ls -A "$PCFG/agent-dispatch/claims")
  [ -z "$left" ] || bad "claims 에 파일이 남았다: $left"
}
case_flight_claim_broken_self() { claim_bad_self_check '{"pid":'; }
case_flight_claim_empty_self() { claim_bad_self_check ''; }
case_flight_claim_nopid_self() { claim_bad_self_check '{}'; }
case_flight_claim_dir_slot() { # 표시 자리가 디렉터리면 --claim 은 실패하고 아무것도 더하지 않는다
  peers_setup
  fake_session $$ me sme "$PREPO"
  mkdir "$PCFG/agent-dispatch/claims/o_r_5.json"
  run_flight_at "$PREPO" --claim --repo o/r 5
  [ "$RC" -ne 0 ] || bad "exit 0 으로 끝났다: $OUT"
  case $ERR in *'표시 자리가 디렉터리다'*) ;; *) bad "stderr 에 이유가 없다: '$ERR'" ;; esac
  [ -z "$(ls -A "$PCFG/agent-dispatch/claims/o_r_5.json")" ] || bad "디렉터리 안에 파일이 생겼다"
  [ "$(ls -A "$PCFG/agent-dispatch/claims")" = o_r_5.json ] || bad "claims 에 다른 파일이 생겼다"
}

# ---- in-flight --where: 실행 위치(플러그인인가, 낡은 사본인가) ----
# where_setup -- $WH 아래에 가짜 설정 디렉터리, 설치된 플러그인(inst), 사본(copy)을 둔다. 스크립트는 $FLIGHT(변이 사본일 수 있다)를 복사해 쓴다.
# 플러그인 SKILL.md 는 "plug", 사본은 "old" 로 다르게 둔다. installed_plugins.json 은 inst 를 가리킨다.
where_setup() {
  WH=$TMP/wh; rm -rf "$WH"; mkdir -p "$WH/cfg/plugins" "$TMP/nogit"
  WINST=$WH/inst/agent-dispatch/1.11.0
  mkdir -p "$WINST/skills/agent-dispatch/scripts" "$WH/copy/skills/agent-dispatch/scripts"
  cp "$FLIGHT" "$WINST/skills/agent-dispatch/scripts/in-flight.sh"
  cp "$FLIGHT" "$WH/copy/skills/agent-dispatch/scripts/in-flight.sh"
  echo plug > "$WINST/skills/agent-dispatch/SKILL.md"
  echo old > "$WH/copy/skills/agent-dispatch/SKILL.md"
  printf '{"plugins":{"agent-dispatch@skill":[{"scope":"user","installPath":"%s","version":"1.11.0"}],"other@skill":[{"installPath":"/x","version":"9"}]}}\n' "$WINST" > "$WH/cfg/plugins/installed_plugins.json"
}
# run_where <스크립트 디렉터리(scripts)> [인자...] -- git 밖에서 그 스크립트를 $WH/cfg 설정으로 돌린다. PATH 앞에 STUB_BIN(gh 스텁)이 있다
run_where() {
  local sd=$1; shift
  RC=0
  OUT=$(cd "$TMP/nogit" && PATH="$STUB_BIN:$PATH" CLAUDE_CONFIG_DIR=$WH/cfg GIT_CEILING_DIRECTORIES=$TMP timeout 20 bash "$sd/in-flight.sh" "$@" 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
}
WCOPY() { echo "$WH/copy/skills/agent-dispatch/scripts"; }
WPLUG() { echo "$WINST/skills/agent-dispatch/scripts"; }
case_where_plugin() { # installPath 안에서 돌면 PLUGIN
  where_setup
  run_where "$(WPLUG)" --where
  expect_rc 0; expect_err_empty
  expect_out "WHERE plugin $WINST/skills/agent-dispatch"$'\n'"INSTALLED agent-dispatch@skill 1.11.0 $WINST"$'\n'"VERDICT PLUGIN"
}
case_where_stale() { # 다른 디렉터리이고 SKILL.md 가 다르면 copy, STALE
  where_setup
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_err_empty
  expect_out "WHERE copy $WH/copy/skills/agent-dispatch"$'\n'"INSTALLED agent-dispatch@skill 1.11.0 $WINST"$'\n'"VERDICT STALE"
}
case_where_same() { # 내용이 같은 사본은 SAME
  where_setup; cp "$WINST/skills/agent-dispatch/SKILL.md" "$WH/copy/skills/agent-dispatch/SKILL.md"
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_out_has "WHERE copy "; expect_out_has "VERDICT SAME"
}
case_where_none_no_file() { # installed_plugins.json 이 없으면 NONE
  where_setup; rm "$WH/cfg/plugins/installed_plugins.json"
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_out "WHERE copy $WH/copy/skills/agent-dispatch"$'\n'"VERDICT NONE"
}
case_where_none_no_entry() { # agent-dispatch 항목이 없으면 NONE (다른 플러그인만 있다)
  where_setup; echo '{"plugins":{"other@skill":[{"installPath":"/x","version":"9"}]}}' > "$WH/cfg/plugins/installed_plugins.json"
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_out "WHERE copy $WH/copy/skills/agent-dispatch"$'\n'"VERDICT NONE"
}
case_where_broken_json() { # 깨진 JSON 이면 UNKNOWN, exit 0
  where_setup; echo '{"plugins": [' > "$WH/cfg/plugins/installed_plugins.json"
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_out "WHERE copy $WH/copy/skills/agent-dispatch"$'\n'"VERDICT UNKNOWN"
}
case_where_no_jq() { # jq 가 없어도 죽지 않고 UNKNOWN (PATH 에는 dirname, cmp 만 둔다)
  where_setup; rm -rf "$WH/nojq"; mkdir "$WH/nojq"
  ln -s "$(command -v dirname)" "$WH/nojq/dirname"; ln -s "$(command -v cmp)" "$WH/nojq/cmp"
  RC=0
  OUT=$(cd "$TMP/nogit" && PATH="$WH/nojq" CLAUDE_CONFIG_DIR=$WH/cfg "$BASH" "$(WCOPY)/in-flight.sh" --where 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
  expect_rc 0; expect_out "WHERE copy $WH/copy/skills/agent-dispatch"$'\n'"VERDICT UNKNOWN"
}
case_where_symlink_to_plugin() { # skills/agent-dispatch 가 installPath 를 가리키는 링크면 실제 경로로 풀어 PLUGIN
  where_setup; rm -rf "$WH/copy/skills/agent-dispatch"
  ln -s "$WINST/skills/agent-dispatch" "$WH/copy/skills/agent-dispatch"
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_out_has "WHERE plugin $WINST/skills/agent-dispatch"; expect_out_has "VERDICT PLUGIN"
}
case_where_symlink_to_copy() { # 링크 대상이 다른 곳(낡은 사본)이면 그 실제 경로로 STALE
  where_setup; mkdir -p "$WH/real"; mv "$WH/copy/skills/agent-dispatch" "$WH/real/agent-dispatch"
  ln -s "$WH/real/agent-dispatch" "$WH/copy/skills/agent-dispatch"
  run_where "$(WCOPY)" --where
  expect_rc 0; expect_out_has "WHERE copy $WH/real/agent-dispatch"$'\n'; expect_out_has "VERDICT STALE"
}
case_where_installpath_via_symlink() { # installPath 가 링크를 거치고 끝에 슬래시가 있어도 실제 경로로 풀어 PLUGIN
  where_setup
  ln -s "$WH/inst" "$WH/instlink"
  printf '{"plugins":{"agent-dispatch@skill":[{"scope":"user","installPath":"%s/agent-dispatch/1.11.0/","version":"1.11.0"}]}}\n' "$WH/instlink" > "$WH/cfg/plugins/installed_plugins.json"
  run_where "$(WPLUG)" --where
  expect_rc 0; expect_out_has "WHERE plugin $WINST/skills/agent-dispatch"; expect_out_has "VERDICT PLUGIN"
}
case_where_outside_git_no_gh() { # git 밖, gh 없이 돈다(PATH 에 dirname, cmp, jq 만 둔다)
  where_setup; rm -rf "$WH/min"; mkdir "$WH/min"
  local t; for t in dirname cmp jq; do ln -s "$(command -v $t)" "$WH/min/$t"; done
  RC=0
  OUT=$(cd "$TMP/nogit" && PATH="$WH/min" CLAUDE_CONFIG_DIR=$WH/cfg GIT_CEILING_DIRECTORIES=$TMP "$BASH" "$(WCOPY)/in-flight.sh" --where 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
  expect_rc 0; expect_err_empty; expect_out_has "VERDICT STALE"
}
case_where_empty_version() { # version 이 빈 문자열이어도 칸이 밀리지 않아 PLUGIN, INSTALLED 의 installPath 칸이 맞다
  where_setup
  printf '{"plugins":{"agent-dispatch@skill":[{"scope":"user","installPath":"%s","version":""}]}}\n' "$WINST" > "$WH/cfg/plugins/installed_plugins.json"
  run_where "$(WPLUG)" --where
  expect_rc 0; expect_err_empty
  expect_out "WHERE plugin $WINST/skills/agent-dispatch"$'\n'"INSTALLED agent-dispatch@skill - $WINST"$'\n'"VERDICT PLUGIN"
}
case_where_empty_installpath() { # installPath 가 빈 문자열인 항목은 건너뛰고 뒤 항목으로 PLUGIN, 칸은 밀리지 않는다
  where_setup
  printf '{"plugins":{"agent-dispatch@skill":[{"installPath":"","version":"2.0.0"},{"installPath":"%s","version":"1.11.0"}]}}\n' "$WINST" > "$WH/cfg/plugins/installed_plugins.json"
  run_where "$(WPLUG)" --where
  expect_rc 0; expect_err_empty
  expect_out "WHERE plugin $WINST/skills/agent-dispatch"$'\n'"INSTALLED agent-dispatch@skill 2.0.0 "$'\n'"INSTALLED agent-dispatch@skill 1.11.0 $WINST"$'\n'"VERDICT PLUGIN"
}
case_where_cdpath() { # CDPATH 아래에 scripts/ 가 있고 상대 $0 으로 불러도 D 는 한 줄이고 PLUGIN
  where_setup; mkdir -p "$WH/cdx/scripts"
  RC=0
  OUT=$(cd "$WINST/skills/agent-dispatch" && PATH="$STUB_BIN:$PATH" CDPATH=$WH/cdx CLAUDE_CONFIG_DIR=$WH/cfg GIT_CEILING_DIRECTORIES=$TMP timeout 20 bash scripts/in-flight.sh --where 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
  expect_rc 0; expect_err_empty
  expect_out "WHERE plugin $WINST/skills/agent-dispatch"$'\n'"INSTALLED agent-dispatch@skill 1.11.0 $WINST"$'\n'"VERDICT PLUGIN"
}
case_where_rejects_args() { # 인자를 주면 exit 2
  where_setup
  run_where "$(WCOPY)" --where 5
  expect_rc 2; expect_out_empty
  [ -n "$ERR" ] || bad "stderr 에 이유가 없다"
  run_where "$(WCOPY)" --where --repo o/r
  expect_rc 2; expect_out_empty
}
case_where_skill_static() { # SKILL.md: CLAUDE_PLUGIN_ROOT 0건, 호출은 CLAUDE_SKILL_DIR, 0단계에 --where 와 쓰기 금지
  local sk=$SCRIPTS/../SKILL.md bad_calls step0
  [ -f "$sk" ] || { bad "SKILL.md 가 없다: $sk"; return; }
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$sk" || bad "SKILL.md 에 CLAUDE_PLUGIN_ROOT 가 남았다"
  bad_calls=$(grep -nE '(in-flight|wait-prs)\.sh' "$sk" | grep -E 'bash "' | grep -v 'bash "\${CLAUDE_SKILL_DIR}/scripts/' || true)
  [ -z "$bad_calls" ] || bad "스크립트 호출이 \${CLAUDE_SKILL_DIR}/scripts/ 로 시작하지 않는다: $bad_calls"
  [ "$(grep -c 'bash "${CLAUDE_SKILL_DIR}/scripts/' "$sk")" -ge 4 ] || bad "CLAUDE_SKILL_DIR 호출이 4곳 미만이다"
  step0=$(awk '/^## 0\./{f=1;next} /^## 1\./{f=0} f' "$sk")
  case $step0 in *'in-flight.sh" --where'*) ;; *) bad "0단계에 --where 호출이 없다" ;; esac
  case $step0 in *'쓰기를 하지 않는다'*) ;; *) bad "0단계에 쓰기 금지 문장이 없다" ;; esac
  case $step0 in *'AskUserQuestion'*) ;; *) bad "0단계에 AskUserQuestion 이 없다" ;; esac
}

# ---- 정적 검사 ----
# 길이 확인 없이 펼친 배열("${a[@]}", ${a[*]}, ${a[@]:1})이 없어야 한다. bash 4.3 이하는 set -u 아래 빈 배열 펼침에서 죽는다.
# 안전한 꼴: ${a[@]+"${a[@]}"}, ${a[*]+${a[*]}}, ${#a[@]}, ${!a[@]}.
# 예외 "파일:줄에 든 글": 바로 앞에서 길이를 확인하는 자리. 줄 내용으로 매칭한다.
STATIC_ALLOW=(
  'wait-prs.sh:printf '\''%s\n'\'' "${events[@]}"'   # `if [ ${#events[@]} -gt 0 ]` 안에서만 펼친다
)
# find_unguarded <파일> -- 길이 확인 없이 펼친 줄을 "줄번호:내용" 으로 낸다(주석 줄 제외).
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

# ---- 하네스 자신: ONLY, MUTATE ----
# 변이하지 않은 원본 하네스($SCRIPTS/test-scripts.sh)를 다시 불러 OUT/ERR/RC 를 채운다. 바깥의 ONLY/MUTATE 가 새어 들지 않게
# 안쪽 실행은 둘을 언제나 명시적으로 준다(없앨 것은 env -u). 안쪽의 ONLY 는 이 절의 경우에 맞지 않는 라벨로 골라야 같은 경우가 또 돌지 않는다.
# SELF_DOCKER=none|fake 이면 안쪽 PATH 앞에 docker 스텁을 둔다: none 은 이미지가 없는 호스트(docker 가 exit 1), fake 는 이미지가 있고
# `docker run` 이 컨테이너 없이 같은 bash 로 스크립트를 돌리는 호스트다. 그래서 호스트와 상관없이 두 분기를 모두 본다.
make_docker_stub() { # <none|fake>
  local d=$TMP/dstub_$1
  mkdir -p "$d"
  if [ "$1" = none ]; then printf '#!/bin/sh\nexit 1\n' > "$d/docker"; else cat > "$d/docker" <<'STUB'
#!/usr/bin/env bash
[ "$1" = image ] && exit 0
[ "$1" = run ] || exit 1
shift; wd=.
while [ $# -gt 0 ]; do
  case $1 in
    -w) wd=$2; shift 2 ;;
    -e) case $2 in *=*) export "$2" ;; esac; shift 2 ;;
    -v|--network) shift 2 ;;
    bash:3.2) shift; break ;;
    *) shift ;;
  esac
done
cd "$wd" && exec "$@"
STUB
  fi
  chmod +x "$d/docker"
}
# HARNESS_INNER 는 안쪽 실행의 표시다: 안쪽에서 이 절의 경우가 돌면 끝없이 불러 대지 않고 바로 실패한다.
run_self() { # <ONLY|빈 문자열> [<MUTATE>]
  local -a e=(-u ONLY -u MUTATE HARNESS_INNER=1)
  OUT='' ERR='' RC=0
  if [ -n "${HARNESS_INNER:-}" ]; then bad "안쪽 실행에서 하네스 자신을 다시 불렀다(ONLY 가 이 절의 경우를 거르지 못했다)"; return; fi
  [ -z "${SELF_DOCKER:-}" ] || { make_docker_stub "$SELF_DOCKER"; e+=("PATH=$TMP/dstub_$SELF_DOCKER:$PATH"); }
  [ -n "$1" ] && e+=("ONLY=$1")
  [ -n "${2:-}" ] && e+=("MUTATE=$2")
  env "${e[@]}" timeout 600 bash "$SCRIPTS/test-scripts.sh" >"$TMP/self_so" 2>"$TMP/self_se" || RC=$?
  OUT=$(cat "$TMP/self_so"); ERR=$(cat "$TMP/self_se")
}
count_lines() { printf '%s\n' "$OUT" | grep -c "$1" || true; }  # OUT 에서 정규식(BRE)에 맞는 줄 수
orig_sum() { cksum "$SCRIPTS/wait-prs.sh" "$SCRIPTS/in-flight.sh"; }
ONE='^in-flight 77 -> FREE$'   # 값싼 경우 하나의 라벨

case_only_one() {
  run_self "$ONE"
  expect_rc 0
  [ "$(count_lines '^PASS ')" = 1 ] || bad "PASS 줄이 하나여야 한다: '$OUT'"
  expect_out_has 'PASS in-flight 77 -> FREE'
  [ "$(count_lines '^FAIL \|^SKIP ')" = 0 ] || bad "FAIL/SKIP 줄이 없어야 한다: '$OUT'"
  expect_out_has '1 passed, 0 failed, 0 skipped'
}
case_only_no_match() {
  run_self '^맞는-경우-없음$'
  expect_rc 1
  [ -n "$ERR" ] || bad "맞는 항목이 없을 때 stderr 에 이유가 있어야 한다"
  [ "$(count_lines '^PASS \|^FAIL \|^SKIP ')" = 0 ] || bad "PASS/FAIL/SKIP 줄이 없어야 한다: '$OUT'"
}
case_only_bad_ere() { # ONLY 가 올바른 ERE 가 아니면 exit 2 와 이유 (맞는 것 없음의 exit 1 과 구별)
  run_self '('
  expect_rc 2
  case $ERR in *'올바른 정규식'*) ;; *) bad "stderr 에 '올바른 정규식' 이 있어야 한다: '$ERR'" ;; esac
  [ "$(count_lines '^PASS \|^FAIL \|^SKIP ')" = 0 ] || bad "PASS/FAIL/SKIP 줄이 없어야 한다: '$OUT'"
}
case_only_32() { # bash:3.2 경우만 고르면: 이미지가 없으면 SKIP 한 번, 있으면 PASS
  local pat='^bash:3\.2 wait-prs 7 -> CONFLICTING 7$'
  SELF_DOCKER=none run_self "$pat"
  expect_rc 0
  [ "$(count_lines '^SKIP bash:3.2 (이미지 없음)$')" = 1 ] || bad "이미지가 없으면 SKIP 줄이 한 번이어야 한다: '$OUT'"
  expect_out_has '0 passed, 0 failed, 1 skipped'
  SELF_DOCKER=fake run_self "$pat"
  expect_rc 0
  expect_out_has 'PASS bash:3.2 wait-prs 7 -> CONFLICTING 7'; expect_out_has '1 passed, 0 failed, 0 skipped'
  [ "$(count_lines '^SKIP ')" = 0 ] || bad "이미지가 있으면 SKIP 줄이 없어야 한다: '$OUT'"
}
case_only_32_unselected_no_skip() { # bash:3.2 경우를 하나도 고르지 않으면 이미지가 없어도 SKIP 줄이 없다
  SELF_DOCKER=none run_self "$ONE"
  expect_rc 0
  [ "$(count_lines '^SKIP ')" = 0 ] || bad "SKIP 줄이 없어야 한다: '$OUT'"
}
case_mutate_killed() {
  local before; before=$(orig_sum)
  run_self "$ONE" 'in-flight.sh:s/FREE/XFREE/'
  expect_rc 0; expect_out_has 'MUTANT KILLED'
  [ "$(count_lines '^FAIL in-flight 77 -> FREE')" = 1 ] || bad "죽인 경우의 FAIL 줄이 있어야 한다: '$OUT'"
  [ "$(orig_sum)" = "$before" ] || bad "원본 스크립트가 바뀌었다"
}
case_mutate_survived() { # 주석 줄만 바꾼다
  local before; before=$(orig_sum)
  run_self "$ONE" 'in-flight.sh:s/$/ x/ if $. == 2'
  expect_rc 1; expect_out_has 'MUTANT SURVIVED'
  expect_out_has '1 passed, 0 failed, 0 skipped'
  [ "$(orig_sum)" = "$before" ] || bad "원본 스크립트가 바뀌었다"
}
case_mutate_noop() {
  local before; before=$(orig_sum)
  run_self "$ONE" 'in-flight.sh:s/이_글은_스크립트에_없다/x/'
  expect_rc 2; [ -n "$ERR" ] || bad "stderr 에 이유가 있어야 한다"
  [ "$(count_lines '^PASS \|^FAIL \|MUTANT')" = 0 ] || bad "경우를 돌거나 판정을 냈다: '$OUT'"
  [ "$(orig_sum)" = "$before" ] || bad "원본 스크립트가 바뀌었다"
}
case_mutate_bad_input() { # 대상이 틀리거나, ':' 가 없거나, perl 식이 틀리면 exit 2 와 그 이유
  local m why
  for m in 'other.sh:s/a/b/|대상은' 'in-flight.sh|꼴이어야' 'in-flight.sh:s/(/x/|perl 식이 실패'; do
    why=${m##*|}; m=${m%|*}
    run_self "$ONE" "$m"
    [ "$RC" = 2 ] || bad "MUTATE='$m' 는 exit 2 여야 하는데 $RC"
    case $ERR in *"$why"*) ;; *) bad "MUTATE='$m' 의 stderr 에 '$why' 가 있어야 한다: '$ERR'" ;; esac
    [ "$(count_lines '^PASS \|MUTANT')" = 0 ] || bad "MUTATE='$m' 가 경우를 돌았다: '$OUT'"
  done
}
case_mutate_wait_native() { # wait-prs.sh 대상: 출력되는 일 이름만 바꿔 네이티브 경우를 죽인다
  local before; before=$(orig_sum)
  run_self '^wait-prs 7 -> CONFLICTING 7$' 'wait-prs.sh:s/events\+=\("CONFLICTING \$n"\)/events+=("XCONFLICTING \$n")/'
  expect_rc 0; expect_out_has 'MUTANT KILLED'
  [ "$(count_lines '^FAIL wait-prs 7 -> CONFLICTING 7')" = 1 ] || bad "죽인 경우의 FAIL 줄이 있어야 한다: '$OUT'"
  [ "$(orig_sum)" = "$before" ] || bad "원본 스크립트가 바뀌었다"
}
case_mutate_wait_docker() { # docker 경로도 사본을 돈다: bash:3.2 경우를 죽인다. 이미지가 없어 아무 경우도 못 돌면 exit 2
  local pat='^bash:3\.2 wait-prs 7 -> CONFLICTING 7$' m='wait-prs.sh:s/events\+=\("CONFLICTING \$n"\)/events+=("XCONFLICTING \$n")/'
  SELF_DOCKER=fake run_self "$pat" "$m"
  expect_rc 0; expect_out_has 'MUTANT KILLED'
  [ "$(count_lines '^FAIL bash:3.2 wait-prs 7 -> CONFLICTING 7')" = 1 ] || bad "죽인 경우의 FAIL 줄이 있어야 한다: '$OUT'"
  SELF_DOCKER=none run_self "$pat" "$m"
  expect_rc 2; expect_out_has 'SKIP bash:3.2 (이미지 없음)'
  case $ERR in *'아무 경우도 돌지 않았다'*) ;; *) bad "stderr 에 이유가 있어야 한다: '$ERR'" ;; esac
  case $OUT in *MUTANT*) bad "판정을 내면 안 된다: '$OUT'" ;; esac
}
case_mutate_no_match() { # MUTATE 일 때 ONLY 에 맞는 것이 없으면 exit 2 (MUTATE 없이는 exit 1)
  run_self '^맞는-경우-없음$' 'in-flight.sh:s/FREE/XFREE/'
  expect_rc 2; [ -n "$ERR" ] || bad "stderr 에 이유가 있어야 한다"
  case $OUT in *MUTANT*) bad "판정을 내면 안 된다: '$OUT'" ;; esac
}
case_mutate_static_sees_copy() { # 정적 검사도 변이한 사본을 읽는다: 둘째 줄을 길이 확인 없는 펼침으로 바꾼다
  local before; before=$(orig_sum)
  run_self '^정적 검사: 빈 배열 펼침 없음$' 'in-flight.sh:s/^#.*/y=\$\{b[*]\}/ if $. == 2'
  expect_rc 0; expect_out_has 'MUTANT KILLED'
  [ "$(orig_sum)" = "$before" ] || bad "원본 스크립트가 바뀌었다"
}

# ---- 실행 ----
run_case() { # <표시 이름> <함수> [인자...]
  local label=$1; shift
  CASE=$label BAD=0
  rm -rf "$STUB_DATA"; mkdir -p "$STUB_DATA"   # 앞 경우의 fixture 가 남지 않게
  "$@"
  if [ $BAD = 0 ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL + 1)); fi
}

CASES=(
  'wait-prs --other 5 -> MERGED 5:case_wait_other_merged native'
  'wait-prs 7 -> CONFLICTING 7:case_wait_mine_conflicting native'
  'wait-prs 7 -> MERGED 7:case_wait_mine_merged native'
  'wait-prs 7 -> CLOSED 7:case_wait_mine_closed native'
  'wait-prs --other 5 충돌 -> 일이 아니다(TIMEOUT):case_wait_other_conflict_ignored native'
  'wait-prs 한 차례 조회의 일을 모두 낸다:case_wait_together native'
  'wait-prs 조회 실패 -> GH_FAILING:case_wait_gh_failing native'
  'wait-prs 피드백: 커서 뒤의 것만, 가장 늦은 시각:case_fb_after_cursor native'
  'wait-prs 피드백: 리뷰가 가장 늦으면 그 시각:case_fb_review_latest native'
  'wait-prs 피드백: 커서와 같은 시각은 뺀다:case_fb_cursor_equal native'
  'wait-prs 피드백: --since 가 없으면 모두 센다:case_fb_no_cursor native'
  'wait-prs 피드백: 보류 리뷰, Bot, 숨긴 댓글은 뺀다:case_fb_excluded native'
  'wait-prs 피드백: author 가 null 이면 센다:case_fb_deleted_author native'
  'wait-prs 피드백: APPROVED 도 센다:case_fb_approved native'
  'wait-prs 피드백: --other 는 무시한다:case_fb_other_ignored native'
  'wait-prs 피드백: MERGED/CLOSED 면 FEEDBACK 이 없다:case_fb_merged_closed native'
  'wait-prs 피드백: CONFLICTING 과 함께 낸다:case_fb_with_conflict native'
  'wait-prs 피드백: --since 와 --other 를 함께:case_fb_since_32 native'
  'wait-prs --since 가 틀리면 exit 2:case_fb_bad_since'
  'wait-prs --repo 가 틀리면 exit 2:case_wait_bad_repo'
  'wait-prs 응답, --jq 가 깨지면 GH_FAILING:case_fb_broken native'
  'wait-prs 질의가 피드백 필드를 받는다:case_fb_query_fields'
  'wait-prs 질의 변수(feedback, number, owner, name, hostname):case_fb_query_args'
  'wait-prs --show: 커서 뒤의 리뷰, 댓글을 한 줄 JSON 으로:case_show_after_cursor'
  'wait-prs --show: --since 가 없으면 모두, 커서와 같은 시각은 뺀다:case_show_no_cursor'
  'wait-prs --show: 피드백이 없으면 빈 출력, exit 0:case_show_empty'
  'wait-prs --show: 질의와 변수:case_show_query'
  'wait-prs --show: 조회 실패 -> stderr 와 exit 1:case_show_gh_fail'
  'wait-prs --show: 인자가 틀리면 exit 2:case_show_bad_args'
  'bash:3.2 미리 정한 출력 = 실제 jq 결과:case_precomputed_vs_jq'
  'wait-prs -h -> 헤더 전체, exit 0:case_wait_help native'
  'wait-prs 인자 없음 -> exit 2:case_wait_no_args native'
  'in-flight 77 -> FREE:case_flight_free'
  'in-flight -h -> 헤더 전체, exit 0:case_flight_help native'
  'in-flight 인자 없음 -> exit 2:case_flight_no_args native'
  'in-flight --peers: 세션 파일 cwd 로 찾는다:case_peers_session_cwd'
  'in-flight --peers: 기록 cwd 로 찾는다:case_peers_transcript_cwd'
  'in-flight --peers: claim 으로 찾는다:case_peers_claim'
  'in-flight --peers: 죽은 세션, 자기 세션은 뺀다:case_peers_excluded'
  'in-flight --peers: 주 체크아웃의 세션도 낸다:case_peers_main_checkout'
  'in-flight --peers 5 -> exit 2:case_peers_rejects_number'
  'in-flight --peers 를 git 밖에서 -> 이유와 exit 2:case_peers_outside_git'
  'in-flight 5: 기록 cwd 가 worktree -> BUSY:case_flight_busy_transcript_cwd'
  'in-flight 5: 세션 파일 cwd 가 worktree -> BUSY:case_flight_busy_session_cwd'
  'in-flight --release 5 -> 표시를 지운다:case_flight_release'
  'in-flight 5: name 이 빈 세션도 기록 cwd 로 BUSY:case_flight_empty_name_busy'
  'in-flight --peers: name 이 빈 세션은 이름 -, 기록 cwd:case_peers_empty_name_transcript'
  'in-flight --peers: name 이 빈 세션은 이름 -, 세션 파일 cwd:case_peers_empty_name_session_cwd'
  'in-flight 5: procStart 가 빈 claim -> BUSY, claim 유지, --peers 에 claim:case_flight_empty_procstart_claim'
  'in-flight 5: procStart 가 null 인 claim -> BUSY, claim 유지, --peers 에 claim:case_flight_null_procstart_claim'
  'in-flight 5: procStart 키가 없는 claim -> BUSY, claim 유지, --peers 에 claim:case_flight_missing_procstart_claim'
  'in-flight --peers: 세션 파일 procStart 가 빈 문자열:case_peers_empty_procstart_session'
  'in-flight --peers: 세션 파일 procStart 가 null:case_peers_null_procstart_session'
  'in-flight 5 를 git 밖에서 -> 이유와 exit 2:case_flight_outside_git'
  'in-flight --where: installPath 안이면 PLUGIN:case_where_plugin'
  'in-flight --where: 다른 SKILL.md 의 사본은 STALE:case_where_stale'
  'in-flight --where: 같은 SKILL.md 의 사본은 SAME:case_where_same'
  'in-flight --where: 파일이 없으면 NONE:case_where_none_no_file'
  'in-flight --where: 항목이 없으면 NONE:case_where_none_no_entry'
  'in-flight --where: 깨진 JSON 은 UNKNOWN, exit 0:case_where_broken_json'
  'in-flight --where: jq 가 없으면 UNKNOWN:case_where_no_jq'
  'in-flight --where: 링크가 installPath 를 가리키면 PLUGIN:case_where_symlink_to_plugin'
  'in-flight --where: 링크가 다른 곳을 가리키면 실제 경로로 STALE:case_where_symlink_to_copy'
  'in-flight --where: installPath 가 링크를 거쳐도 PLUGIN:case_where_installpath_via_symlink'
  'in-flight --where: git 밖, gh 없이 돈다:case_where_outside_git_no_gh'
  'in-flight --where: version 이 빈 문자열이어도 PLUGIN:case_where_empty_version'
  'in-flight --where: installPath 가 빈 문자열이면 건너뛴다:case_where_empty_installpath'
  'in-flight --where: CDPATH 가 걸려도 상대 경로 실행이 PLUGIN:case_where_cdpath'
  'in-flight --where: 인자를 주면 exit 2:case_where_rejects_args'
  'in-flight --where: SKILL.md 정적 검사:case_where_skill_static'
  'in-flight 7 6 -> 0바이트 claim 이 판정을 막지 않는다:case_flight_empty_claim_file'
  'in-flight 7 6 -> 깨진 claim 이 판정을 막지 않는다:case_flight_broken_claim_file'
  'in-flight --claim -> 임시 파일이 남지 않고 새 파일로 바뀐다:case_flight_claim_atomic'
  'in-flight --claim -> 깨진 자기 세션 파일이면 실패하고 아무것도 남기지 않는다:case_flight_claim_broken_self'
  'in-flight --claim -> 0바이트 자기 세션 파일이면 실패하고 아무것도 남기지 않는다:case_flight_claim_empty_self'
  'in-flight --claim -> pid 없는 자기 세션 파일이면 실패하고 아무것도 남기지 않는다:case_flight_claim_nopid_self'
  'in-flight --claim -> 표시 자리가 디렉터리면 실패하고 아무것도 더하지 않는다:case_flight_claim_dir_slot'
  '정적 검사: 빈 배열 펼침 없음:case_static_empty_array'
  '정적 검사: 검사기 자체:case_static_detects'
  'wait-prs -h -> 헤더 중간에 낀 주석 줄도 낸다:case_hdr_comment_wait'
  'in-flight -h -> 헤더 중간에 낀 주석 줄도 낸다:case_hdr_comment_flight'
  'wait-prs -h -> 헤더 중간의 빈 줄에서 끊긴다:case_hdr_blank_wait'
  'in-flight -h -> 헤더 중간의 빈 줄에서 끊긴다:case_hdr_blank_flight'
  'ONLY=<라벨> -> 그 경우 하나만 돈다:case_only_one'
  'ONLY=<맞는 것 없음> -> exit 1 과 이유:case_only_no_match'
  'ONLY 가 bash:3.2 경우만 고르면 PASS 나 SKIP 한 번:case_only_32'
  'ONLY 가 bash:3.2 경우를 안 고르면 SKIP 줄이 없다:case_only_32_unselected_no_skip'
  'MUTATE 가 경우를 죽이면 MUTANT KILLED, exit 0:case_mutate_killed'
  'MUTATE 가 주석만 바꾸면 MUTANT SURVIVED, exit 1:case_mutate_survived'
  'MUTATE 가 아무것도 안 바꾸면 exit 2:case_mutate_noop'
  'MUTATE 의 대상, 형식, perl 식이 틀리면 exit 2:case_mutate_bad_input'
  'MUTATE 의 변이를 정적 검사도 본다:case_mutate_static_sees_copy'
  'MUTATE 가 wait-prs.sh 사본의 네이티브 경우를 죽인다:case_mutate_wait_native'
  'MUTATE 가 docker 경로의 사본도 돌고, 못 돌면 exit 2:case_mutate_wait_docker'
  'MUTATE 일 때 ONLY 에 맞는 것이 없으면 exit 2:case_mutate_no_match'
  'ONLY 가 올바른 ERE 가 아니면 exit 2 와 이유:case_only_bad_ere'
)
# bash:3.2 컨테이너에서 같은 경우를 돌린다(3.2 의 빈 배열 동작은 4.0~4.3 과 같다)
CASES_32=(
  'wait-prs --other 5 -> MERGED 5:case_wait_other_merged'
  'wait-prs 7 -> CONFLICTING 7:case_wait_mine_conflicting'
  'wait-prs 피드백: --since 와 --other 를 함께:case_fb_since_32'
)

# ONLY=<ERE> -- 라벨(PASS/FAIL 줄에 찍히는 글)이 맞는 경우만 돈다. 배열은 그대로 두고 루프에서 거른다.
selected() { [ -z "${ONLY:-}" ] || [[ $1 =~ $ONLY ]]; }
n_sel=0 n_sel32=0
if [ -n "${ONLY:-}" ]; then
  [[ x =~ $ONLY ]]; [ $? != 2 ] || { echo "ONLY 가 올바른 정규식이 아니다: '$ONLY'" >&2; exit 2; }
  for c in "${CASES[@]}"; do selected "${c%%:case_*}" && n_sel=$((n_sel + 1)); done
  for c in "${CASES_32[@]}"; do selected "bash:3.2 ${c%%:case_*}" && n_sel32=$((n_sel32 + 1)); done
  if [ $((n_sel + n_sel32)) = 0 ]; then echo "ONLY 에 맞는 경우가 없다: '$ONLY'" >&2; [ -z "${MUTATE:-}" ] && exit 1; exit 2; fi
fi

for c in "${CASES[@]}"; do
  label=${c%%:case_*}; rest=case_${c#*:case_}
  selected "$label" || continue
  # shellcheck disable=SC2086
  run_case "$label" $rest
done

if [ -z "${ONLY:-}" ] || [ "$n_sel32" -gt 0 ]; then
  if docker image inspect bash:3.2 >/dev/null 2>&1; then
    for c in "${CASES_32[@]}"; do
      label=${c%%:case_*}; rest=case_${c#*:case_}
      selected "bash:3.2 $label" || continue
      run_case "bash:3.2 $label" "$rest" docker
    done
  else
    SKIP=$((SKIP + 1)); echo 'SKIP bash:3.2 (이미지 없음)'
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ -n "${MUTATE:-}" ]; then
  if [ $((PASS + FAIL)) = 0 ]; then echo "MUTATE: 아무 경우도 돌지 않았다(판정할 수 없다)" >&2; exit 2; fi
  if [ "$FAIL" != 0 ]; then echo "MUTANT KILLED ($MUTATE)"; exit 0; fi
  echo "MUTANT SURVIVED ($MUTATE)"; exit 1
fi
[ "$FAIL" = 0 ]
