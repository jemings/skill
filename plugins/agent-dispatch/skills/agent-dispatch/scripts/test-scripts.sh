#!/usr/bin/env bash
# wait-prs.sh, in-flight.sh 의 시험 하네스. 네트워크를 쓰지 않고, gh 는 PATH 의 스텁으로 갈음한다.
# SKILL.md 와 references/ 의 정적 검사(스크립트 호출, 지시문의 정책 문장, 규율 카드, 조회 예시, land.sh 판정 줄의 8단계 행)도 여기서 돈다.
# 그래서 SKILL.md, references/ 만 고쳐도 이 하네스를 돌린다.
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

# ---- in-flight --agent: 서브에이전트의 정체 판정(흔적: 기록, 기록에 나온 task 출력, --path 아래 파일) ----
# $PCFG/projects/x/<세션 id>/subagents/agent-<id>.jsonl 이 그 agent 의 기록이다(하네스의 배치). 이슈의 scratch 는 $AS,
# 하네스의 공용 task 출력 디렉터리는 $AT 다. 낡은 흔적은 touch -t 202601010000 으로 만든다.
agent_setup() {
  PCFG=$TMP/cfg AS=$TMP/scratch-65 AT=$TMP/tasks
  rm -rf "$PCFG" "$AS" "$AT" "$TMP/nogit"; mkdir -p "$PCFG/projects/x/sid1/subagents" "$AS" "$AT" "$TMP/nogit"
  AGENT_LOG=$PCFG/projects/x/sid1/subagents/agent-a65.jsonl
}
# fake_agent_log [<task 출력 경로>...] -- 기록 a65 를 쓴다. 출력 경로마다 하네스가 백그라운드 실행에 다는 문구의 줄을 더한다
fake_agent_log() {
  local o
  printf '{"type":"user","isSidechain":true,"agentId":"a65","message":{"role":"user","content":"go"}}\n' > "$AGENT_LOG"
  for o; do
    printf '{"type":"user","isSidechain":true,"agentId":"a65","message":{"role":"user","content":[{"type":"tool_result","content":"Command running in background with ID: b1. Output is being written to: %s. You will be notified when it completes \\u2014 do not poll that file.\\nSession cwd remains /x","is_error":false}]}}\n' "$o" >> "$AGENT_LOG"
  done
}
stale() { touch -t 202601010000 "$@"; }
age_secs() { perl -e '$t = time - $ARGV[0]; utime $t, $t, @ARGV[1..$#ARGV]' -- "$@"; }   # <초> <파일>... -- mtime 을 그만큼 앞으로
at_epoch() { perl -e 'utime $ARGV[0], $ARGV[0], @ARGV[1..$#ARGV]' -- "$@"; }   # <epoch> <파일>... -- mtime 을 그 시각으로
fmt_epoch() { perl -MPOSIX -e 'print strftime("%Y-%m-%d %H:%M", localtime($ARGV[0]))' "$1"; }   # 근거 줄의 시각 꼴
run_agent() { run_flight_at "$TMP/nogit" --agent "$@"; }
# run_agent_now <epoch> [인자...] -- PATH 앞의 가짜 date 가 `date +%s` 에 그 epoch 를 낸다(시계를 고정해 경계를 본다)
run_agent_now() {
  local now=$1; shift
  mkdir -p "$TMP/datestub"
  printf '#!/bin/sh\nif [ "$1" = +%%s ]; then echo %s; else exec %s "$@"; fi\n' "$now" "$(command -v date)" > "$TMP/datestub/date"
  chmod +x "$TMP/datestub/date"
  RC=0
  OUT=$(cd "$TMP/nogit" && PATH="$TMP/datestub:$PATH" CLAUDE_CONFIG_DIR=$PCFG timeout 20 bash "$FLIGHT" --agent "$@" 2>"$TMP/se") || RC=$?
  ERR=$(cat "$TMP/se")
}
first_line() { printf '%s\n' "$OUT" | head -n 1; }
case_agent_fresh_log() { # 기록이 새것이면 WORKING, 분은 0, 가장 늦은 흔적은 기록. 출력 문구가 없으면 근거 줄로 남긴다
  agent_setup; fake_agent_log
  run_agent a65
  expect_rc 0; expect_err_empty
  [ "$(first_line)" = "WORKING a65 0 $AGENT_LOG" ] || bad "첫 줄이 'WORKING a65 0 $AGENT_LOG' 가 아니다: '$OUT'"
  expect_out_has '    출력 파일을 찾지 못했다'
}
case_agent_unknown() { # 그 id 의 기록이 없으면 UNKNOWN, exit 0 (다른 agent 의 기록은 보지 않는다)
  agent_setup; fake_agent_log
  run_agent b77
  expect_rc 0
  [ "$(first_line)" = 'UNKNOWN b77 - -' ] || bad "첫 줄이 'UNKNOWN b77 - -' 가 아니다: '$OUT'"
}
case_agent_fresh_output() { # 기록은 낡았어도 기록에 나온 task 출력이 새것이면 WORKING, 가장 늦은 흔적은 그 출력
  agent_setup
  stale_out=$AT/bold.output; : > "$stale_out"; : > "$AT/bnew.output"
  fake_agent_log "$stale_out" "$AT/bnew.output"; stale "$AGENT_LOG" "$stale_out"
  run_agent a65
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AT/bnew.output" ] || bad "첫 줄이 'WORKING a65 0 $AT/bnew.output' 가 아니다: '$OUT'"
  expect_out_has "    출력 파일 2개, 가장 늦은 것 "
  case $OUT in *'출력 파일을 찾지 못했다'*) bad "출력 파일을 찾았는데 못 찾았다고 했다: '$OUT'" ;; esac
}
case_agent_fresh_path() { # 기록, 출력은 낡았어도 --path 아래 파일이 새것이면 WORKING
  agent_setup; fake_agent_log; stale "$AGENT_LOG"
  mkdir -p "$AS/sub"; : > "$AS/sub/run.log"
  run_agent a65 --path "$TMP/no-such-wt" --path "$AS"
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AS/sub/run.log" ] || bad "첫 줄이 'WORKING a65 0 $AS/sub/run.log' 가 아니다: '$OUT'"
  expect_out_has "    경로가 없다: $TMP/no-such-wt"
}
case_agent_incident() { # 사고 재연: 흔적이 모두 낡았고 scratch 의 로그를 기다리는 루프가 살아 있다 -> STALLED, 근거 줄에 그 pid
  agent_setup; : > "$AT/b1.output"; fake_agent_log "$AT/b1.output"
  : > "$AS/ctl3.log"; mkdir -p "$AS/node_modules/x" "$AS/.git"; : > "$AS/node_modules/x/new.js"; : > "$AS/.git/index"
  stale "$AGENT_LOG" "$AT/b1.output"; touch -t 202601011200 "$AS/ctl3.log"
  bash -c 'until grep -q "^never$" "$1"; do sleep 1; done' loop "$AS/ctl3.log" >/dev/null 2>&1 &
  PEER_PIDS+=("$!"); local loop_pid=$!
  bash -c 'sleep 60; :' sib "$AS-other/x.log" >/dev/null 2>&1 &
  PEER_PIDS+=("$!"); local sib_pid=$!
  run_agent a65 --path "$AS"
  expect_rc 0
  case $(first_line) in "STALLED a65 "*" $AS/ctl3.log") ;; *) bad "첫 줄이 'STALLED a65 <분> $AS/ctl3.log' 가 아니다: '$OUT'" ;; esac
  expect_out_has "    프로세스 $loop_pid "
  expect_out_has "    가장 늦은 흔적 2026-01-01 12:00 $AS/ctl3.log"
  case $OUT in *"프로세스 $sib_pid "*) bad "이름이 이어 붙은 형제 경로($AS-other)의 프로세스를 냈다: '$OUT'" ;; esac
  case $OUT in *in-flight.sh*) bad "감시(in-flight.sh) 자신을 프로세스로 냈다: '$OUT'" ;; esac
  peers_teardown
}
case_agent_incident2() { # 두 번째 사례(#2988): 프로세스 없음, worktree 에 커밋하지 않은 수정, 흔적이 모두 15분 넘게 그대로 -> 기본값으로 STALLED
  agent_setup; fake_agent_log
  local wt=$TMP/wt-2988
  rm -rf "$wt"; mkdir -p "$wt"
  git -C "$wt" init -q -b main && printf 'a\n' > "$wt/ci.yml" && git -C "$wt" add ci.yml \
    && git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m 'fix(ci): draft'
  printf 'b\n' >> "$wt/ci.yml"
  [ -n "$(git -C "$wt" status --porcelain)" ] || bad "fixture: worktree 에 커밋하지 않은 수정이 없다"
  age_secs 1200 "$AGENT_LOG"; age_secs 950 "$wt/ci.yml"
  run_agent a65 --path "$wt" --path "$AS"
  expect_rc 0
  [ "$(first_line)" = "STALLED a65 15 $wt/ci.yml" ] || bad "첫 줄이 'STALLED a65 15 $wt/ci.yml' 가 아니다: '$OUT'"
  case $OUT in *'    프로세스 '*) bad "프로세스가 없는데 프로세스 근거 줄을 냈다: '$OUT'" ;; esac
  rm -rf "$wt"
}
case_agent_foreign_output() { # 기록에 나오지 않은 task 출력(남의 것)만 새것이면 STALLED
  agent_setup; : > "$AT/mine.output"; fake_agent_log "$AT/mine.output"
  stale "$AGENT_LOG" "$AT/mine.output"; : > "$AT/theirs.output"
  run_agent a65
  expect_rc 0
  case $(first_line) in "STALLED a65 "*" $AT/mine.output") ;; *) bad "첫 줄이 'STALLED a65 <분> $AT/mine.output' 가 아니다: '$OUT'" ;; esac
}
case_agent_idle_boundary() { # --idle-min 은 분이다: 90초 전 흔적은 2분 안(WORKING 1분), 150초 전은 2분 넘음(STALLED 2분)
  agent_setup; fake_agent_log
  age_secs 90 "$AGENT_LOG"
  run_agent a65 --idle-min 2
  [ "$(first_line)" = "WORKING a65 1 $AGENT_LOG" ] || bad "90초: 첫 줄이 'WORKING a65 1 ...' 가 아니다: '$OUT'"
  age_secs 150 "$AGENT_LOG"
  run_agent a65 --idle-min 2
  [ "$(first_line)" = "STALLED a65 2 $AGENT_LOG" ] || bad "150초: 첫 줄이 'STALLED a65 2 ...' 가 아니다: '$OUT'"
  age_secs 120 "$AGENT_LOG"
  run_agent a65 --idle-min 2
  [ "$(first_line)" = "STALLED a65 2 $AGENT_LOG" ] || bad "꼭 2분(120초): 'STALLED a65 2 ...' 여야 한다: '$OUT'"
  age_secs 890 "$AGENT_LOG"
  run_agent a65
  [ "$(first_line)" = "WORKING a65 14 $AGENT_LOG" ] || bad "기본값 15분: 890초 전은 'WORKING a65 14 ...' 여야 한다: '$OUT'"
  age_secs 901 "$AGENT_LOG"
  run_agent a65
  [ "$(first_line)" = "STALLED a65 15 $AGENT_LOG" ] || bad "기본값 15분: 901초 전은 'STALLED a65 15 ...' 여야 한다: '$OUT'"
}
case_agent_wait_stalled() { # --wait: 흔적이 모두 낡았으면 STALLED 를 내고 끝난다(UNKNOWN 도 끝난다)
  agent_setup; fake_agent_log; stale "$AGENT_LOG"
  run_agent a65 --wait --interval 1
  expect_rc 0
  case $(first_line) in "STALLED a65 "*) ;; *) bad "STALLED 로 끝나야 한다: '$OUT'" ;; esac
  run_agent zz9 --wait --interval 1
  expect_rc 0
  [ "$(first_line)" = 'UNKNOWN zz9 - -' ] || bad "UNKNOWN 으로 끝나야 한다: '$OUT'"
}
case_agent_wait_working() { # --wait: 흔적을 계속 갱신하는 프로세스가 있으면 끝나지 않는다(timeout 의 rc 124)
  agent_setup; fake_agent_log; stale "$AGENT_LOG"; : > "$AS/run.log"
  bash -c 'while :; do touch "$1"; sleep 1; done' tick "$AS/run.log" >/dev/null 2>&1 &
  PEER_PIDS+=("$!")
  RC=0
  OUT=$(cd "$TMP/nogit" && CLAUDE_CONFIG_DIR=$PCFG timeout 4 bash "$FLIGHT" --agent a65 --path "$AS" --idle-min 1 --wait --interval 1 2>"$TMP/se") || RC=$?
  expect_rc 124; expect_out_empty
  peers_teardown
}
case_agent_api_error() { # 기록 끝의 마지막 assistant 기록이 API 오류 표식이면 근거 줄. 판정은 바꾸지 않는다
  agent_setup; fake_agent_log
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"API Error: usage limit reached\nmore"}]}}' \
    '{"type":"system","subtype":"hook"}' >> "$AGENT_LOG"
  run_agent a65
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AGENT_LOG" ] || bad "판정이 바뀌었다: '$OUT'"
  expect_out_has '    API 오류 rate_limit API Error: usage limit reached'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"resumed"}]}}' >> "$AGENT_LOG"
  run_agent a65
  case $OUT in *'API 오류'*) bad "오류 뒤에 이어 했는데 API 오류 줄이 남았다: '$OUT'" ;; esac
}
case_agent_bad_args() { # 인자 오류는 exit 2: 이슈 번호 꼴의 id, 양의 정수가 아닌 --idle-min/--interval, 다른 모드와 섞기, --agent 없는 감시 옵션
  agent_setup; fake_agent_log
  local a
  for a in '65' '' 'a/b' '--wait' '-x' '--after 0' '--after x' "--after $(( $(date +%s) + 3600 ))" '--after' '--idle-min 0' '--idle-min x' '--idle-min -3' '--interval 0 --wait' '--interval 1.5 --wait' '--interval 5' \
           '--repo o/r' '--claim' '--release' '--peers' '--where' '7' '--idle-min'; do
    case $a in ''|65|a/b|--wait|-x) run_flight_at "$TMP/nogit" --agent "$a" ;; *) # shellcheck disable=SC2086
      run_flight_at "$TMP/nogit" --agent a65 $a ;; esac
    [ "$RC" = 2 ] || bad "'--agent ... $a' 는 exit 2 여야 하는데 $RC: '$OUT'"
    [ -z "$OUT" ] || bad "'--agent ... $a' 가 stdout 에 냈다: '$OUT'"
  done
  for a in '--path /x' '--idle-min 5' '--wait' '--interval 5' '--after 5'; do
    # shellcheck disable=SC2086
    run_flight_at "$TMP/nogit" --peers $a
    [ "$RC" = 2 ] || bad "--agent 없는 '$a' 는 exit 2 여야 하는데 $RC"
    case $ERR in *'--agent 와 함께 쓴다'*) ;; *) bad "--agent 없는 '$a' 의 stderr 에 이유가 없다: '$ERR'" ;; esac
  done
}
# run_agent_sleep_stub [인자...] -- PATH 앞의 가짜 sleep 이 받은 인자를 $TMP/slept 에 적고 exit 1 한다(감시는 거기서 끝난다)
run_agent_sleep_stub() {
  mkdir -p "$TMP/sleepstub"; rm -f "$TMP/slept"
  printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$TMP/slept" > "$TMP/sleepstub/sleep"; chmod +x "$TMP/sleepstub/sleep"
  RC=0
  OUT=$(cd "$TMP/nogit" && PATH="$TMP/sleepstub:$PATH" CLAUDE_CONFIG_DIR=$PCFG timeout 20 bash "$FLIGHT" --agent a65 "$@" 2>"$TMP/se") || RC=$?
}
case_agent_wait_default_interval() { # --wait 는 WORKING 이면 --interval 초(기본 60) 잔 뒤 다시 본다
  agent_setup; fake_agent_log
  run_agent_sleep_stub --wait
  [ "$(cat "$TMP/slept" 2>/dev/null)" = 60 ] || bad "기본 간격으로 sleep 60 을 불러야 하는데 '$(cat "$TMP/slept" 2>/dev/null)'"
  expect_out_empty
  run_agent_sleep_stub --wait --interval 7
  [ "$(cat "$TMP/slept" 2>/dev/null)" = 7 ] || bad "--interval 7 이면 sleep 7 이어야 하는데 '$(cat "$TMP/slept" 2>/dev/null)'"
}
case_agent_digit_bounds() { # --idle-min, --interval 은 6자리 안의 양의 정수다. 7자리 이상은 bash 산술 오류 없이 exit 2(넘침으로 새 흔적이 STALLED 가 되지 않게)
  agent_setup; fake_agent_log
  local a
  run_agent a65 --idle-min 999999
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AGENT_LOG" ] || bad "--idle-min 999999 는 받아 WORKING 이어야 한다: '$OUT'"
  run_agent_sleep_stub --wait --interval 999999
  [ "$(cat "$TMP/slept" 2>/dev/null)" = 999999 ] || bad "--interval 999999 는 받아 sleep 999999 여야 하는데 '$(cat "$TMP/slept" 2>/dev/null)'"
  for a in '--idle-min 1000000' '--idle-min 153722867280912931' '--interval 1000000 --wait' '--interval 153722867280912931 --wait'; do
    # shellcheck disable=SC2086
    run_agent a65 $a
    [ "$RC" = 2 ] || bad "'$a' 는 exit 2 여야 하는데 $RC: '$OUT'"
    expect_out_empty
    case $ERR in *'6자리'*) ;; *) bad "'$a' 의 stderr 에 자릿수 이유가 없다: '$ERR'" ;; esac
    case $ERR in *'in-flight.sh:'*|*'integer'*|*'정수 표현식'*|*'syntax error'*|*'구문 오류'*|*'value too great'*) bad "'$a' 가 bash 산술 오류를 냈다: '$ERR'" ;; esac
  done
}
case_agent_rearm_after_wake() { # 깨운 뒤 다시 건 감시는 그 시각부터 idle-min 을 기다린다
  agent_setup; fake_agent_log; stale "$AGENT_LOG"
  RC=0
  OUT=$(cd "$TMP/nogit" && CLAUDE_CONFIG_DIR=$PCFG timeout 4 bash "$FLIGHT" --agent a65 --idle-min 1 --wait --interval 1 --after "$(date +%s)" 2>"$TMP/se") || RC=$?
  expect_rc 124; expect_out_empty
}
case_agent_after_old() { # --after 가 가장 늦은 흔적보다 늦으면 나이는 그 시각부터다: 1시간 전이면 STALLED 60분, 흔적 칸은 그대로, 근거 줄에 기준 시각
  agent_setup; fake_agent_log; stale "$AGENT_LOG"
  run_agent a65 --after "$(( $(date +%s) - 3600 ))"
  expect_rc 0
  [ "$(first_line)" = "STALLED a65 60 $AGENT_LOG" ] || bad "첫 줄이 'STALLED a65 60 $AGENT_LOG' 가 아니다: '$OUT'"
  expect_out_has '    기준 시각 '
  run_agent a65 --after 1000000000
  case $(first_line) in "STALLED a65 60 "*) bad "흔적보다 이른 --after 가 나이를 바꿨다: '$OUT'" ;; "STALLED a65 "*) ;; *) bad "STALLED 여야 한다: '$OUT'" ;; esac
  case $OUT in *'기준 시각'*) bad "흔적보다 이른 --after 인데 기준 시각 줄을 냈다: '$OUT'" ;; esac
}
case_agent_future_mtime() { # 지금보다 미래인 흔적은 판정에서 빼고 근거 줄로만 낸다(나머지 흔적으로 판정)
  agent_setup; fake_agent_log; stale "$AGENT_LOG"; : > "$AS/clock.log"
  age_secs -3600 "$AS/clock.log"
  run_agent a65 --path "$AS"
  expect_rc 0
  case $(first_line) in "STALLED a65 "*" $AGENT_LOG") ;; *) bad "첫 줄이 'STALLED a65 <분> $AGENT_LOG' 가 아니다: '$OUT'" ;; esac
  expect_out_has "    미래 시각 흔적 "
  expect_out_has "$AS/clock.log"
}
case_agent_trace_newline() { # 줄바꿈 든 파일 이름은 한 흔적 행으로 이어 붙고(\n 두 글자), 그 파일의 mtime 이 판정을 따른다
  agent_setup; fake_agent_log; stale "$AGENT_LOG"; mkdir "$AS/d"
  local f="$AS/d/new
line.txt" want
  want="$AS/d/new\\nline.txt"
  : > "$f"
  run_agent a65 --path "$AS/d"
  expect_rc 0; expect_err_empty
  [ "$(first_line)" = "WORKING a65 0 $want" ] || bad "줄바꿈 이름: 첫 줄이 'WORKING a65 0 $want' 가 아니다: '$OUT'"
  case $OUT in *'미래 시각 흔적'*) bad "줄바꿈 이름이 미래 시각 흔적 줄을 냈다: '$OUT'" ;; esac
  stale "$f"
  run_agent a65 --path "$AS/d"
  expect_rc 0; expect_err_empty
  case $(first_line) in "STALLED a65 "*" $want") ;; *) bad "낡은 줄바꿈 이름: 첫 줄이 'STALLED a65 <분> $want' 가 아니다: '$OUT'" ;; esac
  age_secs -9999 "$f"
  run_agent a65 --path "$AS/d"
  expect_rc 0; expect_err_empty
  printf '%s\n' "$OUT" | grep -F '    미래 시각 흔적 ' | grep -qF " $want" || bad "미래 줄바꿈 이름의 경로가 온전하지 않다: '$OUT'"
}
case_agent_trace_newline_joined() { # 이어진 줄이 숫자만이거나 숫자로 시작하지만 공백이 없거나 빈 줄이어도 한 흔적 행이다(빈 줄은 사라진다)
  agent_setup; fake_agent_log; stale "$AGENT_LOG"; mkdir "$AS/d"
  local n want f
  for n in 'x
99999999999999999999999|x\n99999999999999999999999' 'new
5x.txt|new\n5x.txt' 'new
5x line.txt|new\n5x line.txt' 'new

line.txt|new\nline.txt'; do
    f="$AS/d/${n%%|*}" want="$AS/d/${n##*|}"
    rm -rf "$AS/d"; mkdir "$AS/d"; : > "$f"
    run_agent a65 --path "$AS/d"
    expect_rc 0; expect_err_empty
    [ "$(first_line)" = "WORKING a65 0 $want" ] || bad "첫 줄이 'WORKING a65 0 $want' 가 아니다: '$OUT'"
    case $OUT in *'미래 시각 흔적'*) bad "'$want' 가 미래 시각 흔적 줄을 냈다: '$OUT'" ;; esac
  done
}
case_agent_trace_dash_path() { # - 로 시작하는 --path 는 find 의 표현식이 아니라 경로로 읽는다
  agent_setup; fake_agent_log; stale "$AGENT_LOG"
  : > "$TMP/nogit/-newer"
  run_agent a65 --path -newer
  expect_rc 0; expect_err_empty
  case $(first_line) in "WORKING a65 0 "*-newer) ;; *) bad "'-newer' --path: 첫 줄이 'WORKING a65 0 ...-newer' 가 아니다: '$OUT'" ;; esac
  printf '%s\n' "$OUT" | grep -F '    가장 늦은 흔적 ' | grep -q -- '-newer$' || bad "가장 늦은 흔적이 -newer 가 아니다: '$OUT'"
  rm -f "$TMP/nogit/-newer"
  : > "$TMP/nogit/!"
  run_agent a65 --path '!'
  expect_rc 0; expect_err_empty
  printf '%s\n' "$OUT" | grep -F '    가장 늦은 흔적 ' | grep -q -- '!$' || bad "가장 늦은 흔적이 ! 가 아니다: '$OUT'"
  rm -f "$TMP/nogit/!"
  : > "$TMP/nogit/("
  run_agent a65 --path '('
  expect_rc 0; expect_err_empty
  printf '%s\n' "$OUT" | grep -F '    가장 늦은 흔적 ' | grep -q -- '($' || bad "가장 늦은 흔적이 ( 가 아니다: '$OUT'"
  rm -f "$TMP/nogit/("
}
case_agent_future_skew() { # 흔적이 모두 몇 초 미래(시계 차이, 다른 파일 시스템)여도 허용 오차 안이면 지금으로 깎는다 -> WORKING 0
  agent_setup; fake_agent_log; age_secs -3 "$AGENT_LOG"
  run_agent a65
  expect_rc 0; expect_err_empty
  [ "$(first_line)" = "WORKING a65 0 $AGENT_LOG" ] || bad "첫 줄이 'WORKING a65 0 $AGENT_LOG' 가 아니다: '$OUT'"
  case $OUT in *'미래 시각 흔적'*) bad "허용 오차 안의 흔적을 미래 시각 흔적으로 냈다: '$OUT'" ;; esac
}
case_agent_future_all() { # 흔적이 모두 허용 오차보다 미래면 판정할 흔적이 없다 -> UNKNOWN, 근거 줄에 이유와 흔적마다 미래 시각 흔적
  agent_setup; : > "$AT/b1.output"; fake_agent_log "$AT/b1.output"; : > "$AS/run.log"
  age_secs -3600 "$AGENT_LOG" "$AT/b1.output" "$AS/run.log"
  run_agent a65 --path "$AS"
  expect_rc 0; expect_err_empty
  [ "$(first_line)" = 'UNKNOWN a65 - -' ] || bad "첫 줄이 'UNKNOWN a65 - -' 가 아니다: '$OUT'"
  expect_out_has '    판정할 흔적이 없다'
  printf '%s\n' "$OUT" | grep -qx '    출력 파일 1개' || bad "판정에서 뺀 출력 파일을 가장 늦은 것으로 냈다: '$OUT'"
  local f
  for f in "$AGENT_LOG" "$AT/b1.output" "$AS/run.log"; do
    printf '%s\n' "$OUT" | grep -F '    미래 시각 흔적 ' | grep -qF " $f" || bad "'$f' 의 미래 시각 흔적 줄이 없다: '$OUT'"
  done
}
case_agent_future_tolerance() { # 허용 오차는 300초: 지금+300 의 흔적은 지금으로 깎고(WORKING 0), 지금+301 은 판정에서 빼고 근거 줄로 낸다
  agent_setup; fake_agent_log; stale "$AGENT_LOG"; : > "$AS/edge.log"
  local now; now=$(date +%s)
  at_epoch $(( now + 300 )) "$AS/edge.log"
  run_agent_now "$now" a65 --path "$AS"
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AS/edge.log" ] || bad "+300초: 첫 줄이 'WORKING a65 0 $AS/edge.log' 가 아니다: '$OUT'"
  expect_out_has "    가장 늦은 흔적 $(fmt_epoch "$now") $AS/edge.log"
  case $OUT in *'미래 시각 흔적'*) bad "+300초를 미래 시각 흔적으로 냈다: '$OUT'" ;; esac
  at_epoch $(( now + 301 )) "$AS/edge.log"
  run_agent_now "$now" a65 --path "$AS"
  expect_rc 0
  case $(first_line) in "STALLED a65 "*" $AGENT_LOG") ;; *) bad "+301초: 첫 줄이 'STALLED a65 <분> $AGENT_LOG' 가 아니다: '$OUT'" ;; esac
  expect_out_has "    미래 시각 흔적 $(fmt_epoch $(( now + 301 ))) $AS/edge.log"
}
case_agent_after_bounds() { # --after: 지금+300 까지는 지금으로 깎고, 그보다 늦으면 exit 2. 12자리를 넘으면 산술 오류 없이 exit 2
  agent_setup; fake_agent_log; stale "$AGENT_LOG"
  local now a; now=$(date +%s)
  run_agent_now "$now" a65 --after $(( now + 300 ))
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AGENT_LOG" ] || bad "--after 지금+300: 첫 줄이 'WORKING a65 0 $AGENT_LOG' 가 아니다: '$OUT'"
  expect_out_has "    기준 시각 $(fmt_epoch "$now") (--after)"
  run_agent_now "$now" a65 --after $(( now + 301 ))
  [ "$RC" = 2 ] || bad "--after 지금+301 은 exit 2 여야 하는데 $RC: '$OUT'"
  expect_out_empty
  run_agent_now "$now" a65 --after 999999999999
  [ "$RC" = 2 ] || bad "--after 999999999999 는 exit 2 여야 하는데 $RC: '$OUT'"
  case $ERR in *'12자리'*) bad "12자리 --after 를 자릿수로 거부했다: '$ERR'" ;; *'늦다'*) ;; *) bad "12자리 --after 의 stderr 에 늦다는 이유가 없다: '$ERR'" ;; esac
  for a in 1234567890123 1234567890123456789012345; do
    run_agent_now "$now" a65 --after "$a"
    [ "$RC" = 2 ] || bad "--after $a 는 exit 2 여야 하는데 $RC: '$OUT'"
    case $ERR in *'12자리'*) ;; *) bad "--after $a 의 stderr 에 자릿수 이유가 없다: '$ERR'" ;; esac
    case $ERR in *'in-flight.sh:'*|*'integer'*|*'정수 표현식'*|*'syntax error'*|*'구문 오류'*|*'value too great'*) bad "--after $a 가 bash 산술 오류를 냈다: '$ERR'" ;; esac
  done
}
# log_entry <type> <epoch> [<밀리초>] -- 기록 a65 에 timestamp(ISO 8601 UTC, 밀리초)를 단 줄을 더한다(하네스의 꼴)
log_entry() {
  local ts; ts=$(perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%S", gmtime($ARGV[0]))' "$2").${3:-000}Z
  printf '{"type":"%s","isSidechain":true,"agentId":"a65","timestamp":"%s","message":{"role":"%s","content":[{"type":"text","text":"x"}]}}\n' "$1" "$ts" "$1" >> "$AGENT_LOG"
}
case_agent_wake_reply() { # --after 를 주면 근거 줄에 그 뒤 마지막 assistant 기록의 시각, 없으면 응답 없음. 하네스가 남긴 깨움(user)은 응답이 아니다
  agent_setup; fake_agent_log
  local w; w=$(( $(date +%s) - 600 ))
  log_entry assistant $(( w - 3000 )) 120
  log_entry user "$w" 573
  run_agent a65 --after "$w"
  expect_rc 0
  [ "$(first_line)" = "WORKING a65 0 $AGENT_LOG" ] || bad "깨움 뒤 응답이 판정을 바꿨다: '$OUT'"
  expect_out_has '    깨움 뒤 응답 없음'
  log_entry assistant $(( w + 1 )) 250
  log_entry assistant $(( w + 120 )) 999
  log_entry user $(( w + 200 ))
  printf '%s\n' '{"type":"assistant","timestamp":"garbage","message":{"role":"assistant","content":[]}}' \
    '{"type":"assistant","message":{"role":"assistant","content":[]}}' >> "$AGENT_LOG"
  run_agent a65 --after "$w"
  expect_rc 0
  expect_out_has "    깨움 뒤 응답 $(fmt_epoch $(( w + 120 )))"
  case $OUT in *'깨움 뒤 응답 없음'*) bad "응답이 있는데 응답 없음이라 했다: '$OUT'" ;; esac
  run_agent a65
  case $OUT in *'깨움 뒤 응답'*) bad "--after 없이 깨움 뒤 응답 줄을 냈다: '$OUT'" ;; esac
}
case_agent_wake_reply_boundary() { # timestamp 가 --after 와 같은 초면 응답이다(밀리초는 버린다). 한 초 앞(.999)은 아니다
  agent_setup; fake_agent_log
  local w; w=$(( $(date +%s) - 600 ))
  log_entry assistant $(( w - 1 )) 999
  run_agent a65 --after "$w"
  expect_out_has '    깨움 뒤 응답 없음'
  log_entry assistant "$w" 000
  run_agent a65 --after "$w"
  expect_out_has "    깨움 뒤 응답 $(fmt_epoch "$w")"
}
case_agent_wake_reply_unreadable() { # timestamp 는 줄마다 해석해 못 읽은 줄만 건너뛴다. 응답이 없고 못 읽은 assistant 기록이 있으면 판정 불가(응답 없음이 아니다)
  agent_setup; fake_agent_log
  local w bad='{"type":"assistant","timestamp":"2026-13-45T25:61:61Z","message":{"role":"assistant","content":[]}}'
  w=$(( $(date +%s) - 600 ))
  log_entry user "$w" 573; printf '%s\n' "$bad" >> "$AGENT_LOG"
  run_agent a65 --after "$w"
  expect_out_has '    깨움 뒤 응답 판정 불가(timestamp 를 읽지 못한 assistant 기록 1개)'
  case $OUT in *'깨움 뒤 응답 없음'*) bad "값이 틀린 timestamp 만 있는데 응답 없음이라 했다: '$OUT'" ;; esac
  fake_agent_log; log_entry user "$w" 573
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[]}}' >> "$AGENT_LOG"
  run_agent a65 --after "$w"
  expect_out_has '    깨움 뒤 응답 판정 불가(timestamp 를 읽지 못한 assistant 기록 1개)'
  fake_agent_log; log_entry user "$w" 573; log_entry assistant $(( w + 5 )) 100
  printf '%s\n' "$bad" 5 >> "$AGENT_LOG"
  run_agent a65 --after "$w"
  expect_out_has "    깨움 뒤 응답 $(fmt_epoch $(( w + 5 )))"
  case $OUT in *'판정 불가'*|*'응답 없음'*) bad "깨움 뒤 응답이 있는데 값이 틀린 줄 때문에 응답을 놓쳤다: '$OUT'" ;; esac
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$AGENT_LOG"; run_agent a65 --after "$w"; chmod 644 "$AGENT_LOG"
    expect_out_has '    깨움 뒤 응답 판정 불가(기록을 읽지 못했다)'
  fi
}
# 정체 감시와 기다림 규칙(#65): SKILL.md 의 감시, 깨우기, scratch, 상태 블록, 세 지시문의 기다림 규칙, watching.md, -h
case_agent_prose_static() {
  local dir=$SCRIPTS/.. sk ib f sec w
  sk=$dir/SKILL.md ib=$dir/references/implement-brief.md
  sec=$(awk '/^- \*\*서브에이전트의 알림/ { f = 1; print; next } f && /^- \*\*/ { f = 0 } f' "$sk")
  [ -n "$sec" ] || bad "SKILL.md 에 '서브에이전트의 알림' 항목이 없다"
  for f in 'in-flight.sh" --agent' '--wait' '`run_in_background`' '감시 <task id>' 'agent 마다 하나' '`TaskStop`' '다시 건다' \
           '`STALLED`' '`SendMessage` 로 깨운다' '--after <깨움 epoch>' '옛 agent 를 `TaskStop`' '`--after` 없이' '참이 될 수 없는' '다시 돌리지 않는다' '두 번 이어졌다' '같은 등급' '올림 계기가 아니다' \
           '살아 있는 프로세스' '공용 scratch' '사용 한도'; do
    case $sec in *"$f"*) ;; *) bad "'서브에이전트의 알림' 항목에 '$f' 가 없다" ;; esac
  done
  case $sec in *'기다린다"는 정상이다'*) bad "'서브에이전트의 알림' 항목에 백그라운드 대기가 정상이라는 문장이 남았다" ;; esac
  w=$(awk '/^  - \*\*감시를 건다\*\*/ { f = 1; print; next } f && /^  - \*\*/ { exit } f' "$sk" | awk '/^ *```/ { c = !c; next } !c' | tr '\n' ' ' | tr -s ' ')
  case $w in *'알림을 받으면 감시와 함께 같은 명령을 `--wait` 없이 한 번 돌려 그 판정 줄을 보고의 근거로 쓴다'*) ;;
    *) bad "감시를 건다: 알림을 받으면 --wait 없이 한 번 판정해 보고의 근거로 쓴다는 문장이 없다" ;; esac
  case $w in *'흔적이 모두 15분(`--idle-min`) 넘게'*) ;; *) bad "감시를 건다: 기본 판정 기준 15분이 없다" ;; esac
  case $w in *'`판정할 흔적이 없다` 면 감시를 다시 걸지 않고 진행 목록에 `감시 없음(판정할 흔적 없음)` 으로 적는다'*) ;;
    *) bad "감시를 건다: 판정할 흔적이 없으면 감시를 다시 걸지 않고 '감시 없음(판정할 흔적 없음)' 으로 적는 문장이 없다" ;; esac
  case $w in *'다음 알림과 보고 때마다 `--wait` 없이 한 번 판정해 판정이 나오면 그때 다시 건다'*) ;;
    *) bad "감시를 건다: 판정할 흔적이 없을 때 다음 알림과 보고마다 한 번 판정해 다시 거는 문장이 없다" ;; esac
  # 깨운다: 코드 블록을 뺀 글에서 번호 차례와 그 안의 bullet 을 한 줄씩(줄바꿈은 이어 붙인다) 보고 차례와 조건을 확인한다
  w=$(awk '/^  - \*\*깨운다\*\*/ { f = 1; print; next } f && /^  - \*\*/ { exit } f' "$sk" | awk '/^ *```/ { c = !c; next } !c' \
      | awk '/^    [0-9]+\. |^       - / { if (s != "") print s; s = $0; next } s != "" { sub(/^ +/, " "); s = s $0 } END { if (s != "") print s }')
  local d m r
  d=$(printf '%s\n' "$w" | grep -n -F '`date +%s`' | head -n 1 | cut -d: -f1)
  m=$(printf '%s\n' "$w" | grep -n -F '`SendMessage` 로 깨운다' | head -n 1 | cut -d: -f1)
  r=$(printf '%s\n' "$w" | grep -n -F '`--after <깨움 epoch>` 로 다시 건다' | head -n 1 | cut -d: -f1)
  if [ -n "$d" ] && [ -n "$m" ] && [ "$d" -lt "$m" ]; then
    f=$(printf '%s\n' "$w" | sed -n "${d}p")
    case $f in *'직전'*'`date +%s`'*'`깨움 <epoch>`'*) ;; *) bad "깨운다: SendMessage 직전에 date +%s 로 재어 '깨움 <epoch>' 으로 적는 차례가 아니다: '$f'" ;; esac
  else bad "깨운다: date +%s 로 깨움 시각을 재는 차례가 '\`SendMessage\` 로 깨운다' 앞에 없다"; fi
  [ -n "$r" ] && [ -n "$m" ] && [ "$r" -gt "$m" ] || bad "깨운다: 깨운 뒤 '\`--after <깨움 epoch>\` 로 다시 건다' 는 글(코드 블록 밖)이 없다"
  f=$(printf '%s\n' "$w" | grep -F '`깨움 뒤 응답 없음` 이면' || true)
  case $f in *'옛 agent 를 `TaskStop`'*'**같은 등급**'*) ;; *) bad "깨운다: '깨움 뒤 응답 없음' 이면 옛 agent 를 TaskStop 하고 같은 등급으로 새로 띄우는 줄이 없다: '$f'" ;; esac
  f=$(printf '%s\n' "$w" | grep -F '`깨움 뒤 응답 <시각>` 이면' || true)
  case $f in *'다시 깨운다'*'상한 없음'*) ;; *) bad "깨운다: '깨움 뒤 응답 <시각>' 이면 상한 없이 다시 깨우는 줄이 없다: '$f'" ;; esac
  f=$(printf '%s\n' "$w" | grep -F '`깨움 뒤 응답 판정 불가(...)` 이면' || true)
  case $f in *'`TaskStop` 하지 않고'*'다시 깨운다'*) ;; *) bad "깨운다: '깨움 뒤 응답 판정 불가' 이면 TaskStop 하지 않고 다시 깨우는 줄이 없다: '$f'" ;; esac
  case $w in *'시각보다 앞이면'*|*'시각보다 뒤면'*) bad "깨운다: 흔적 시각으로 반응을 가르는 옛 기준이 남았다" ;; esac
  grep -E '^\| `in-flight\.sh` \|' "$sk" | grep -F -- '--agent' | grep -qE '\| [0-9, ]*6, 7 \|$' || bad "스크립트 표의 in-flight.sh 행에 --agent 와 단계 6, 7 이 없다"
  awk '/^\*\*기다림에는 깨울 사건이 있어야 한다\*\*/ { f = 1 } f && /^$/ { exit } f' "$sk" | grep -qF 'in-flight.sh --agent --wait' || bad "'기다림에는 깨울 사건' 문단에 감시가 없다"
  w=$(awk '/^## 6\./ { f = 1; next } /^## 7\./ { f = 0 } f' "$sk")
  for f in '<세션 scratchpad>/<N>' '`<scratch>`' '`scratch <경로>`'; do
    case $w in *"$f"*) ;; *) bad "6단계에 '$f' 가 없다" ;; esac
  done
  w=$(awk '/^   - \(a\) \*\*재실행\*\*/ { f = 1; print; next } f && /^   - \(b\)/ { f = 0 } f' "$sk")
  for f in '`run_in_background`' '`( ... & )`' '`timeout`' '`**Waiting**`' '그 실행의 로그 경로' '마지막이' '기다리거나 `TaskStop` 하고' '멈춘 것을 리포트에 적어'; do
    case $w in *"$f"*) ;; *) bad "7단계 3항 (a) 에 '$f' 가 없다" ;; esac
  done
  w=$(awk '/^  - \*\*리포트 뒤의 알림\*\*/ { f = 1 } /^    근거:/ { f = 0 } f' "$sk")
  for f in '`has not reported yet` 이면 위 감시와 판정 규칙을 따른다' '`report was delivered` 이고 `still running` 이면' \
           '**그 agent id 로 `TaskStop`** 을 리포트마다 한 번 한다' '`No task found` 는 이미 끝난 것이니 무시한다' '`SendMessage` 가 agent 를 다시 깨우고'; do
    case $w in *"$f"*) ;; *) bad "알림 절 규칙에 '$f' 가 없다" ;; esac
  done
  awk '/^## 9\./ { f = 1; next } f' "$sk" | grep -F '일하는 중' | grep -qF -- '--agent' || bad "9단계에 '일하는 중' 의 --agent 판정 근거가 없다"
  w=$(awk '/^\*\*상태 블록\*\*/ { f = 1 } f && /^진행 목록:/ { g = 1 } g && /^```$/ { exit } g' "$sk")
  for f in '#<x> grilling, agent <id>, 감시 <task id|없음>[, 깨움 <epoch>]' 'scratch <경로>, 감시 <task id|없음>[, 깨움 <epoch>]'; do
    case $w in *"$f"*) ;; *) bad "상태 블록 진행 목록에 '$f' 가 없다" ;; esac
  done
  for f in "$dir/references/grill-brief.md" "$ib" "$dir/references/review-brief.md"; do
    w=$(grep -F -- '- **Waiting**:' "$f" || true)
    [ -n "$w" ] || { bad "$(basename "$f") 에 Waiting 줄이 없다"; continue; }
    for sec in '`run_in_background` on the command itself' '`( ... & )`' 'polls a log' 'bound it with `timeout`' \
               'ends when the awaited run ends' 'takes precedence over any tool' 'what you wait for and when it should end, with the log path of that run' \
               'not your last' 'before you send it' 'leave nothing running'; do
      case $w in *"$sec"*) ;; *) bad "$(basename "$f") 의 Waiting 줄에 '$sec' 가 없다" ;; esac
    done
  done
  w=$(grep -F -- '- **Waiting**:' "$dir/references/grill-brief.md" || true)
  for f in "$ib" "$dir/references/review-brief.md"; do
    [ "$(grep -F -- '- **Waiting**:' "$f" || true)" = "$w" ] || bad "$(basename "$f") 의 Waiting 줄이 grill-brief 와 바이트 단위로 같지 않다"
  done
  case $w in *'Your last act is the report: before you send it, wait for every background run you started to end or stop it (TaskStop), say in the report which runs you stopped and why, and leave nothing running.'*) ;; *) bad "Waiting 줄에 마지막 문장이 통째로 없다" ;; esac
  grep -F 'and told to continue' "$ib" | grep -qF 'woken because you looked stalled' || bad "implement-brief 의 이어 하기 줄에 정체로 깨웠을 때가 없다"
  grep -F 'Your scratch directory' "$ib" | grep -qF '`<scratch>`' || bad "implement-brief 에 <scratch> 를 정하는 줄이 없다"
  grep -F '감시' "$dir/references/watching.md" | grep -F 'wait-prs.sh' | grep -qF '따로 센다' || bad "watching.md 에 감시는 따로 센다는 줄이 없다"
  w=$(awk '/^# ---- --agent/ { f = 1 } /^# --where:/ { f = 0 } f' "$FLIGHT")
  [ -n "$w" ] || bad "in-flight.sh 에 --agent 절이 없다"
  for f in '/proc' '-printf' 'date -d' 'date -r' 'readlink -f'; do
    case $w in *"$f"*) bad "in-flight.sh 의 --agent 절이 이식되지 않는 '$f' 를 쓴다" ;; esac
  done
  run_script native "$FLIGHT" -h
  for f in 'in-flight.sh --agent <id> [--path <p>]... [--idle-min N] [--after T] [--wait [--interval S]]' '기준 시각' '미래 시각 흔적' '허용 오차는 300초' '깨움 뒤 응답 없음' '12자리' '6자리 안의 양의 정수가 아닌 --idle-min, --interval' '깨움 뒤 응답 판정 불가(<이유>)' '경로 속 줄바꿈은 근거 줄에서' '<숫자><공백><글자>' '이름 속 빈 줄과 끝 줄바꿈은 근거 줄에서 사라진다' '이름으로 흔적을 위조할 수 있다' '우연한 이름을 위한 처리이고 악의적 이름은 막지 않는다.' '위조는 정체를 늦게 알릴 뿐 WORKING 을 STALLED 로 바꾸지 않는다' '`subagents/` 바로 아래 기록만 본다' 'WORKING' 'STALLED' 'UNKNOWN' 'Output is being written to:'; do
    expect_out_has "$f"
  done
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
  local sk=$SCRIPTS/../SKILL.md bad_calls n_calls step0
  [ -f "$sk" ] || { bad "SKILL.md 가 없다: $sk"; return; }
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$sk" || bad "SKILL.md 에 CLAUDE_PLUGIN_ROOT 가 남았다"
  bad_calls=$(grep -nE '(in-flight|wait-prs)\.sh' "$sk" | grep -E 'bash "' | grep -v 'bash "\${CLAUDE_SKILL_DIR}/scripts/' || true)
  [ -z "$bad_calls" ] || bad "스크립트 호출이 \${CLAUDE_SKILL_DIR}/scripts/ 로 시작하지 않는다: $bad_calls"
  n_calls=$(grep -c 'bash "${CLAUDE_SKILL_DIR}/scripts/' "$sk")
  [ "$n_calls" -ge 4 ] || bad "CLAUDE_SKILL_DIR 호출이 4곳 미만이다"
  step0=$(awk '/^## 0\./{f=1;next} /^## 1\./{f=0} f' "$sk")
  case $step0 in *'in-flight.sh" --where'*) ;; *) bad "0단계에 --where 호출이 없다" ;; esac
  case $step0 in *'쓰기를 하지 않는다'*) ;; *) bad "0단계에 쓰기 금지 문장이 없다" ;; esac
  case $step0 in *'AskUserQuestion'*) ;; *) bad "0단계에 AskUserQuestion 이 없다" ;; esac
}
case_dispatch_prose_static() { # 지시문, 규율 카드: 정책 문장, pstack 이름, 경로 없음, 카드 칸, 접두어 규칙, 조회 예시
  local dir=$SCRIPTS/.. plug=$SCRIPTS/../../.. sk ib dc f id card field lines hit
  sk=$dir/SKILL.md ib=$dir/references/implement-brief.md dc=$dir/references/disciplines.md
  local briefs=("$dir/references/grill-brief.md" "$ib" "$dir/references/review-brief.md")
  # (a) 구현 지시문의 정책: draft, ready 금지, 병합 금지, PR 댓글 금지, 불러온 스킬의 기본값보다 앞선다
  for f in '**draft**' 'do not mark the PR ready' 'do not merge' 'Never comment on' 'take precedence over the defaults of any skill you load'; do
    grep -qF -- "$f" "$ib" || bad "(a) implement-brief 에 '$f' 가 없다"
  done
  # (b) 지시문은 pstack 의 스킬, 에이전트, 작업자 문서를 부르지 않는다
  for f in "${briefs[@]}"; do
    hit=$(grep -nE 'pstack:|poteto-agent|poteto-mode|worker\.md' "$f" || true)
    [ -z "$hit" ] || bad "(b) $(basename "$f") 에 pstack 이름이 있다: $hit"
  done
  # (c) 규율 카드 여섯 장마다 언제, 규칙, 자리, 출처 칸이 있고 SKILL.md 가 카드 파일을 가리킨다
  if [ -f "$dc" ]; then
    for id in laziness foundational boundary root-cause sequence measure; do
      card=$(awk -v h="### $id" '$0 == h { f = 1; next } /^##/ { f = 0 } f' "$dc")
      [ -n "$card" ] || { bad "(c) disciplines.md 에 카드 $id 가 없다"; continue; }
      for field in 언제 규칙 자리 출처; do
        case $card in *"**$field**:"*) ;; *) bad "(c) 카드 $id 에 $field 칸이 없다" ;; esac
      done
    done
  else
    bad "(c) disciplines.md 가 없다: $dc"
  fi
  grep -qF 'references/disciplines.md' "$sk" || bad "(c) SKILL.md 가 references/disciplines.md 를 가리키지 않는다"
  # (d) 플러그인 접두어 규칙
  grep -qF 'mattpocock-skills:tdd' "$sk" || bad "(d) SKILL.md 에 플러그인 접두어 규칙(mattpocock-skills:tdd)이 없다"
  # (e) 버전에 묶인 pstack 설치 경로를 박지 않는다
  hit=$(grep -rnE 'cursor-plugins/pstack/[0-9]' "$plug" || true)
  [ -z "$hit" ] || bad "(e) pstack 버전 경로가 있다: $hit"
  # (f) 트래커 조회 예시는 본문을 낸다. --comments 단독은 TTY 가 아니면 본문을 빼고 댓글만 낸다
  for f in "${briefs[@]}"; do
    lines=$(grep -F 'gh issue view' "$f" || true)
    [ -n "$lines" ] || { bad "(f) $(basename "$f") 에 gh issue view 조회 예시가 없다"; continue; }
    case $lines in *--comments*) bad "(f) $(basename "$f") 의 조회 예시가 --comments 를 쓴다: $lines" ;; esac
    hit=$(printf '%s\n' "$lines" | grep -vE -- '--json ([a-z]+,)*body(,| )' || true)
    [ -z "$hit" ] || bad "(f) $(basename "$f") 의 조회 예시가 --json 으로 본문(body)을 받지 않는다: $hit"
  done
  # (g) 주석 규칙: 구현 지시문의 상시 줄(변명 금지, only 한정, 공개 계약 예외, 린트 억제, 범위 밖은 보고), 리뷰 지시문 축 6 의 줄, 표 정정
  local rb=$dir/references/review-brief.md ax6 cm exc
  exc=('external dependency' 'public contract' '`-h`' 'API doc comment' 'license header' 'issue link' 'lint suppression directive with the reason the rule does not apply there')
  cm=$(grep -F -- '- **Comments**:' "$ib" || true)
  [ -n "$cm" ] || bad "(g) implement-brief 에 Comments 줄이 없다"
  for f in 'excuse a workaround' 'may state only' 'leave the code as it is' 'list it in the report as out of scope' "cannot be done without working around that shape, stop and report instead" "${exc[@]}"; do
    case $cm in *"$f"*) ;; *) bad "(g) implement-brief 의 Comments 줄에 '$f' 가 없다" ;; esac
  done
  awk '/^## Report/ { f = 1; next } /^## / { f = 0 } f' "$ib" | grep -qF 'Out-of-scope shapes to reshape' || bad "(g) implement-brief 의 Report 절에 'Out-of-scope shapes to reshape' 가 없다"
  ax6=$(grep -F '6. **Repo rules**' "$rb" || true)
  local ax5
  ax5=$(grep -F '5. **Regressions**' "$rb" || true)
  [ -n "$ax6" ] || bad "(g) review-brief 에 축 6 줄이 없다"
  for f in 'Flag comments' 'excuse a workaround' 'only allowed exceptions' 'name the symbol' 'report it as out of scope' "${exc[@]}"; do
    case $ax6 in *"$f"*) ;; *) bad "(g) review-brief 축 6 줄에 '$f' 가 없다" ;; esac
  done
  case $ax6 in *'implement-brief'*) bad "(g) review-brief 축 6 줄이 리뷰어가 받지 않는 implement-brief 를 가리킨다" ;; esac
  sec=$(awk '/^## 쓰지 않는 것/ { f = 1; next } /^##/ { f = 0 } f' "$dc")
  [ -n "$sec" ] || bad "(g) disciplines.md 에 '## 쓰지 않는 것' 절이 없거나 비었다"
  hit=$(printf '%s\n' "$sec" | grep -iE 'comment[-_ ]?sicko' || true)
  [ -z "$hit" ] || bad "(g) disciplines.md 의 쓰지 않는 것 표에 comment-sicko 가 있다: $hit"
  printf '%s\n' "$sec" | grep -qF '`no-comments`' || bad "(g) disciplines.md 의 쓰지 않는 것 표에 no-comments 행이 없다"
  awk '/^## 이미 있는 것/ { f = 1; next } /^##/ { f = 0 } f' "$dc" | grep -qE '^\| `comment-sicko`' || bad "(g) disciplines.md 의 이미 있는 것 표에 comment-sicko 행이 없다"
  # (h) 카드 보강: laziness 의 옛 API 삭제, foundational 의 수렴, measure 의 핵심 구절, 이미 있는 것 표의 행 셋
  local have
  have=$(awk '/^## 이미 있는 것/ { f = 1; next } /^##/ { f = 0 } f' "$dc")
  card=$(awk '$0 == "### laziness" { f = 1; next } /^##/ { f = 0 } f' "$dc")
  for f in '호환 껍데기' '옛 호출자가 남을 때' 'Out-of-scope shapes to reshape' '계약서가 허용할 때만' '공개 계약은 예외' '범위 밖 호출자가 남은 옛 API' 'principle-migrate-callers-then-delete-legacy-apis'; do
    case $card in *"$f"*) ;; *) bad "(h) laziness 카드에 '$f' 가 없다" ;; esac
  done
  card=$(awk '$0 == "### foundational" { f = 1; next } /^##/ { f = 0 } f' "$dc")
  for f in '같은 끝 상태' '중단 뒤 이어 하기' 'principle-make-operations-idempotent'; do
    case $card in *"$f"*) ;; *) bad "(h) foundational 카드에 '$f' 가 없다" ;; esac
  done
  card=$(awk '$0 == "### measure" { f = 1; next } /^##/ { f = 0 } f' "$dc")
  for f in '잡음 바닥' '원인(병목)' '수치에는 실행 횟수, 편차, 병목' '기본 5회는' '어림이면 1회' '로그 경로' '실 데이터로만 닫히는' '다시 돌려 확인한다' '불확실로 낸다' '수치로 대신하지 않는다' 'principle-explain-the-number' 'benchmark-checklist'; do
    case $card in *"$f"*) ;; *) bad "(h) measure 카드에 '$f' 가 없다" ;; esac
  done
  printf '%s\n' "$have" | grep -E '^\| `blast-radius`' | grep -qF '축 5' || bad "(h) blast-radius 행이 축 5 를 가리키지 않는다"
  grep -qF '카드 여섯 장' "$sk" || bad "(h) SKILL.md 에 '카드 여섯 장' 이 없다"
  grep -qF '수치 검증' "$sk" || bad "(h) SKILL.md 에 '수치 검증' 이 없다"
  for f in '8단계' '착륙 기록'; do
    case $(awk '$0 == "### measure" { f = 1; next } /^##/ { f = 0 } f' "$dc") in *"$f"*) bad "(h) measure 카드에 '$f' 가 있다" ;; esac
  done
  case $(awk '$0 == "### foundational" { f = 1; next } /^##/ || /\*\*규칙\*\*/ { f = 0 } f' "$dc") in *'생애 단계'*) bad "(h) foundational 언제 칸에 '생애 단계' 가 있다" ;; esac
  printf '%s\n' "$have" | grep -E '^\| `principle-exhaust' | grep -qF '약식' || bad "(h) exhaust 행에 '약식' 이 없다"
  printf '%s\n' "$have" | grep -E '^\| `principle-exhaust' | grep -qF '프로토타입은 짓지 않는다' || bad "(h) exhaust 행에 '프로토타입은 짓지 않는다' 가 없다"
  for f in 'blast-radius' 'principle-exhaust-the-design-space' 'principle-test-behavior-not-implementation'; do
    printf '%s\n' "$have" | grep -qE "^\| \`$f\`" || bad "(h) disciplines.md 의 이미 있는 것 표에 $f 행이 없다"
  done
  # (i) 실행 중에 낸 이슈: 즉시 진행 가능한 버그는 범위와 상관없이 진행 목록에 넣는다
  local ri
  ri=$(awk '$0 == "### 실행 중에 낸 이슈를 넣는다" { f = 1; next } /^##/ { f = 0 } f' "$sk")
  for f in '범위 밖 버그' '범위 판정과 상관없이' '`bug` 라벨' '재현 있는 결함' '같은 저장소' '사람 몫이 아니고' 'in-flight.sh' '진행 목록 밖' 'FREE' '넷 다 참'; do
    case $ri in *"$f"*) ;; *) bad "(i) '실행 중에 낸 이슈를 넣는다' 절에 '$f' 가 없다" ;; esac
  done
  grep -qF '함께 처리한 범위 밖 버그' "$sk" || bad "(i) SKILL.md 에 '함께 처리한 범위 밖 버그' 가 없다"
  grep -qF '처리한 착륙: #<PR>(#<이슈>[, 범위 밖 버그]' "$sk" || bad "(i) 상태 블록 착륙 줄에 '범위 밖 버그' 표식 꼴이 없다"
  grep -qF '범위 밖으로 낸 이슈(즉시 진행 불가 버그' "$sk" || bad "(i) 상태 블록에 좁아진 '범위 밖으로 낸 이슈' 문구가 없다"
  grep -qF 'PR #<d>[, 범위 밖 버그]' "$sk" || bad "(i) 상태 블록 진행 목록 줄 꼴에 '[, 범위 밖 버그]' 가 없다"
  grep -qF '#<w> 구현 대기[, #<K> 를 기다림][, 범위 밖 버그]' "$sk" || bad "(i) 상태 블록 구현 대기 줄 꼴에 '[, 범위 밖 버그]' 가 없다"
  local ts5 ts
  ts5=$(printf '%s\n' "$ri" | awk '/^5\. / { f = 1 } f')
  for f in '--claim' '7단계 7항'; do
    case $ts5 in *"$f"*) ;; *) bad "(i) 5항(5a-5e)에 '$f' 가 없다" ;; esac
  done
  grep -qF '`처리한 착륙` 에 `#<PR>(#<이슈>, 범위 밖 버그)` 로 옮긴다' "$sk" || bad "(i) 8단계 CLOSED 행에 표식 옮기기 구절이 없다"
  ts="$(dirname "$sk")/references/tool-sharing.md"
  [ -f "$ts" ] || bad "(i) tool-sharing.md 가 없다"
  grep -qF 'SKILL.md 1단계' "$ts" && grep -qF '5항의 버그가 아니' "$ts" || bad "(i) tool-sharing.md 에 새 근거 'SKILL.md 1단계 5항의 버그가 아니' 가 없다"
  grep -qF '범위 안이어야 하기 때문이다' "$ts" && bad "(i) tool-sharing.md 에 옛 근거 '범위 안이어야 하기 때문이다' 가 남아 있다"
  # (j) 수정이 새 결함을 들이면 한 칸 올리고 회귀 주의를 싣는다: 등급 절 계기와 판정, 1단계 5항, 7단계 걸림, 상태 블록, 8단계, 두 지시문
  local gr th line n
  gr=$(awk '/^- \*\*한 칸 올려 다시 보낸다\*\*/ { f = 1; print; next } /^- \*\*사람에게 넘긴다\*\*/ { f = 0 } f' "$sk")
  [ -n "$gr" ] || bad "(j) 등급 절에 '한 칸 올려 다시 보낸다' 항목이 없다"
  for f in '수정이 새 결함을 들였다' '이슈 안: ' '이슈 사이: ' '거짓 시험, 범위 밖 변경, 규칙 위반은 계기가 아니다' '견주어 높은 쪽' '`blocker`/`major`' '`SendMessage` 가 아니라 한 칸 올려' '원인 PR 의 구현 등급보다 한 칸 위' '수정 전 사본에서 재현이 없고' '수정 사본에서 있다' '판정을 못 하면 계기로 치지 않는다' '`Regression warning`' '`올림` 으로 센다' '올림은 이슈당 한 번이다' '더 올리지 않고' '리뷰 등급은 그대로다' '그 Fix 를 보내던 때의 PR HEAD' '동작이 깨졌다고 재현되는' '결함을 고친 Fix 라운드가 든 PR' '`Failed premise` 대신' '원인 PR 등급이 가장 높으면' '모르면 계약서 기준 등급' '진행 목록에 `올림 1` 로 적고' '`올림 0` 이다' '원인 이슈와 PR 을 적는다' '같은 내용을 메시지에 넣는다'; do
    case $gr in *"$f"*) ;; *) bad "(j) 등급 절 '한 칸 올려 다시 보낸다' 항목에 '$f' 가 없다" ;; esac
  done
  case $ts5 in *'이슈 사이 계기대로 매긴다'*) ;; *) bad "(j) 1단계 5항에 등급 문구 '이슈 사이 계기대로 매긴다' 가 없다" ;; esac
  grep -F '1. **착륙 기록**' "$sk" >/dev/null && awk '/^1\. \*\*착륙 기록\*\*/ { f = 1 } /^2\. 넣는다/ { f = 0 } f' "$sk" | grep -qF '계기가 있었으면 계기(이슈 안 / 이슈 사이)와 올린 등급' || bad "(j) 8단계 1항 착륙 기록에 계기 구절이 없다"
  grep -qF '처리한 착륙: #<PR>(#<이슈>[, 범위 밖 버그][, 유발 #<n>])' "$sk" || bad "(j) 상태 블록 처리한 착륙 꼴에 '[, 유발 #<n>]' 가 없다"
  grep -F 'LANDED #P <sha> ISSUE #N CLOSED' "$sk" | grep -qF '`유발 #<n>` 도 함께 옮긴다' || bad "(j) 8단계 CLOSED 행에 유발 옮기기 구절이 없다"
  case $ts5 in *'`유발 #N(PR #P)`'*) ;; *) bad "(j) 1단계 5항에 '유발 #N(PR #P)' 표식이 없다" ;; esac
  case $(awk '/^6\. \*\*리뷰 결과를 판정한다\*\*/ { f = 1; print; next } /^7\. / { f = 0 } f' "$sk") in *'이 PR 의 Fix 가 들인 회귀'*'(판정은 등급 절)'*) ;; *) bad "(j) 7단계 6항에 '이 PR 의 Fix 가 들인 회귀' 구절이 없다" ;; esac
  th=$(awk '/^\*\*걸림\*\*/ { f = 1 } f && /^$/ { exit } f' "$sk")
  case $th in *'다음 Fix 는 한 칸 올려 다시 보낸다(등급 절의 올림 한 번 규칙대로)'*) ;; *) bad "(j) 7단계 걸림 문단에 '다음 Fix 는 한 칸 올려 다시 보낸다' 가 없다" ;; esac
  for f in '#<z> 수정, ' '#<w> 구현 대기'; do
    line=$(grep -F -- "$f" "$sk" | tail -n 1)
    case $line in *'[, 유발 #<n>(PR #<p>)]'*) ;; *) bad "(j) 상태 블록 '$f' 줄에 '[, 유발 #<n>(PR #<p>)]' 가 없다" ;; esac
  done
  n=$(grep -cF 'Regression warning' "$ib" || true)
  [ "$n" -ge 2 ] || bad "(j) implement-brief 에 Regression warning 칸이 둘(이어 하기 줄, 결함 절차) 아니다: $n"
  for line in "$(grep -F '**Continue existing work.**' "$ib")" "$(grep -F '**Regression warning**' "$ib")"; do
    for f in 'Regression warning' 'Repro:' 'Missed because:' 'red before the fix' 'original fix'; do
      case $line in *"$f"*) ;; *) bad "(j) implement-brief 의 Regression warning 칸에 '$f' 가 없다" ;; esac
    done
  done
  for f in '<이슈 사이 계기면 남긴다:' 'original fix' 'regression test' 'undo'; do
    case $ax5 in *"$f"*) ;; *) bad "(j) review-brief 축 5 줄에 '$f' 가 없다" ;; esac
  done
  # (k) 기계 등급은 없다. 가벼움 구현은 haiku/max 다
  grep -qE '^\| 기계 \|' "$sk" && bad "(k) 등급 표에 기계 행이 남아 있다"
  grep -qF '기계 등급' "$sk" && bad "(k) SKILL.md 에 '기계 등급' 이 남아 있다"
  grep -E '^\| 가벼움 \|' "$sk" | grep -qE '\| `haiku`/`max` \|$' || bad "(k) 등급 표 가벼움 행의 구현 열이 haiku/max 가 아니다"
  grep -qF '**가벼움 구현은 `haiku`/`max` 다.**' "$sk" || bad "(k) 등급 절에 가벼움 구현 항목이 없다"
}

# 병합 방식은 0단계가 정하는 한 값이고, 2-8단계와 두 지시문은 그 값을 읽기만 한다. 줄바꿈을 한 칸으로 이어 구절을 찾는다.
joined() { sed 's/^ *//' | tr '\n' ' '; }
item_in() { # <파일> <절 머리 ERE> <항목 첫 줄 ERE> -- 그 절 안의 그 불릿 항목(다음 불릿이나 절 머리 앞까지)
  awk -v s="$2" -v i="$3" '/^## / { in_s = ($0 ~ s); f = 0 } in_s && !f && $0 ~ i { f = 1; print; next } f && /^- \*\*/ { f = 0 } f' "$1"
}
case_merge_method_static() { # 병합 방식: 0단계 우선순위, 상태 블록, 7단계 --closes-body, 재리뷰와 예외 (iii), 8단계 --method, BLOCKED 행, 두 지시문, 용어
  local dir=$SCRIPTS/.. sk ib rb wt dc f sec all
  sk=$dir/SKILL.md ib=$dir/references/implement-brief.md rb=$dir/references/review-brief.md
  wt=$dir/references/watching.md dc=$dir/references/disciplines.md
  local land_item=(
    '- **착륙**: 규칙이 정한 착륙 명령이 하나로 묶여 있으면 그것(`land.sh --via '\''<명령>'\''`), 검사와 병합 전 단계로 나뉘어 있으면'
    '  저장소 명령(`--check '\''<검사 명령>'\''`, `--pre-merge '\''<병합 전 명령>'\''`, push 에만 줄 env 가 있으면 `--push-env K=V`)으로 준다.'
    '  저장소 명령이 있으면 `land.sh` 가 base 를 얹은 착륙 tip 을 만들고(아래 **병합** 이 커밋 보존이면 base 위로 rebase 하고,'
    '  squash 면 base 를 merge 로 합친다) base 가 움직이면 다시 한다. 둘 다 없으면 gh 병합(아래 **병합**'
    '  방식. `Base branch was modified` 로 지면 `LAND_ROUNDS` 번까지 같은 HEAD 로 다시 한다). 착륙 명령이 PR 본문을 고쳐 쓰는지, draft 를 거부하는지, 커밋 메시지에서 `Closes` 를 모으는지 읽어 둔다.'
  )
  local merge_item=(
    '- **병합**: `rebase`, `squash`, `merge` 가운데 하나. 출처 우선순위는 실행 인자 > 저장소 규칙(`CLAUDE.md`/`AGENTS.md`) >'
    '  사용자 상시 선호(전역 `CLAUDE.md`, 메모리) > GitHub 설정(허용된 것 가운데 rebase > squash > merge)이다. 설정은'
    '  `gh repo view <o>/<r> --json rebaseMergeAllowed,squashMergeAllowed,mergeCommitAllowed` 로 읽는다. 정한 방식을 설정이'
    '  허용하지 않으면 쓰기 전에 `AskUserQuestion` 으로 묻는다(조용히 바꾸지 않는다). `--via` 면 방식은 규칙이 정하고, 없으면'
    '  rebase 로 본다. 방식은 둘로 가른다. **커밋 보존**(rebase, merge)은 커밋을 정리해 다시 쓰고 rebase 로 따라잡는다(지금까지의'
    '  동작). **합침**(squash)은 커밋을 위에 쌓고, base 와 충돌하거나 보호 규칙이 최신을 요구하거나 `land.sh` 가 패치가 달라졌다고'
    '  알릴 때만 `git merge origin/<base>` 로 따라잡고 force-push 하지 않는다. 이 값 하나를 구현 지시문(6단계), 리뷰 지시문과'
    '  재리뷰(7단계), `pr-check.sh --closes-body` (7단계 1항), `land.sh --method`(8단계)가 읽는다.'
  )
  local keep_bullet=(
    '  - 커밋 보존: `git log -p -U0 --reverse <mb>..<리뷰한 SHA> | git patch-id --stable` 과'
    '    `git log -p -U0 --reverse <mb'\''>..HEAD | git patch-id --stable` 의 patch-id 열 목록(순서, 개수 포함)이 같다(`<mb>` 는'
    '    `git merge-base <리뷰한 SHA> origin/<base>`, `<mb'\''>` 는 `git merge-base HEAD origin/<base>`). 범위에 merge 커밋이 있거나'
    '    한쪽이 비면 예외가 아니다. `land.sh` 의 커밋 패치 판정과 같은 명령이다.'
  )
  local squash_bullet=(
    '  - 합침(squash): PR 고유 diff 의 patch-id 가 같다:'
    '    `git diff -U0 $(git merge-base <리뷰한 SHA> origin/<base>) <리뷰한 SHA> | git patch-id --stable` 과'
    '    `git diff -U0 $(git merge-base HEAD origin/<base>) HEAD | git patch-id --stable` 의 patch-id 열이 같다. 따라잡기 merge 커밋이'
    '    범위에 있어도 된다. 한쪽이 비면 예외가 아니다. `land.sh` 의 고유 diff 판정과 같은 명령이다.'
  )
  local patch_row='| `BLOCKED ... base 를 얹은 뒤 패치가 달라졌다` | 따라잡기 요청(단계 `따라잡기`). 0단계 `병합` 이 squash 면 요청에 이 판정 줄을 적는다(구현자는 그때 `git merge origin/<base>` 로 따라잡는다). 돌아오면 7단계(재리뷰가 기본) |'
  local squash_header=(
    '#   squash: rebase 하지 않고 git merge --no-ff <base> 로 base 를 합친 tip(rebase 처럼 commit-msg, pre-merge-commit 훅과'
    '#   서명 검사를 거치지 않는다). 고유 diff 판정: <rev> 마다'
    '#   git diff -U0 $(git merge-base <rev> <base>) <rev> | git patch-id --stable 의 patch-id 가 검수한 SHA 와 그 tip 에서 같아야 한다'
    '#   (tip 쪽이 비어도 바뀐 것이다. 범위의 merge 커밋은 괜찮다).'
  )
  local tool_row='| `land.sh` | 기록을 이슈에 남기고, ready, 대상 변경, 병합(저장소 착륙 명령 또는 gh), 스택 앞 층 닫기, 뒷정리. 저장소 명령(검사, 병합 전)이 있으면 착륙 tip(커밋 보존은 rebase 와 커밋 패치 판정, squash 는 base 를 merge 로 합치고 고유 diff 판정), 검사, 병합 전 커밋, base 이동 시 재시도 | 8 |'
  local needs_human_row='| `NEEDS_HUMAN #P ...` | 보호 규칙이 사람의 승인을 요구한다. 단계 `사람 병합 대기`, 9단계로 지켜본다. 저장소 명령으로 넣어 push 했으면(stderr 에 `land: 올린 tip` 줄이 있으면) PR HEAD 는 검수한 SHA 가 아니라 그 tip(사람이 넣을 착륙 tip 과 병합 전 커밋)으로 남는다. 그때는 옛 `--sha` 로 `land.sh` 를 다시 부르지 않는다(`검수한 SHA 와 다르다` 로 멈추고, 그 행의 손 복원이 사람이 넣을 판을 지운다). 그 줄이 없으면(base 가 이미 조상이고 병합 전 커밋이 없었으면) 올린 것이 없어 PR HEAD 는 검수한 SHA 그대로다. 사람이 넣으면 `land.sh --cleanup --repo <o>/<r> --pr <P> --issue <N>` 으로 뒷정리한다 |'
  local merge_fail_row='| `BLOCKED ... base 를 합치지 못했다: <오류>` | squash 고리 모드에서 충돌 없이 base 를 합치는 merge 가 졌다(PR 탓이 아니다). 오류 줄과 stderr 를 읽고 저장소 설정, 훅, 디스크처럼 환경 탓이면 고쳐 같은 명령으로 다시 부르고, 네가 풀 수 없으면 사람에게 넘긴다 |'
  local land_head_line='# LAND_BASE_SHA(round 의 base) LAND_SHA(검수한 SHA, 40자) LAND_HEAD(착륙 tip).'
  # (a) 0단계 착륙, 병합 항목 전체: 고리 모드의 착륙 tip 두 갈래, 출처 우선순위, 허용하지 않으면 묻기, --via, 두 갈래와 합침의 따라잡기 조건
  exact_block '(a) 0단계 착륙 항목' "$(item_in "$sk" '^## 0[.] ' '^- [*][*]착륙[*][*]:')" "${land_item[@]}"
  exact_block '(a) 0단계 병합 항목' "$(item_in "$sk" '^## 0[.] ' '^- [*][*]병합[*][*]:')" "${merge_item[@]}"
  # (b) 상태 블록: 병합 칸이 따로 있고 착륙 칸은 실행 경로만 적는다
  grep -qF ', 병합 <rebase|squash|merge>, ' "$sk" || bad "(b) 상태 블록에 '병합 <rebase|squash|merge>' 칸이 없다"
  grep -F '착륙 <--via' "$sk" | grep -qF 'gh <방식>' && bad "(b) 상태 블록 착륙 칸에 방식(gh <방식>)이 남아 있다"
  # (c) 7단계 1항: --closes-body 와 주는 조건
  sec=$(awk '/^1\. \*\*모양\*\*/ { f = 1 } /^2\. \*\*리뷰어를 띄운다\*\*/ { f = 0 } f' "$sk" | joined)
  for f in '--closes <N> [--closes-body]' '`--closes-body` 는 0단계 `병합` 이 squash 이고 `착륙` 이 `--via` 가 아닐 때 준다'; do
    case $sec in *"$f"*) ;; *) bad "(c) 7단계 1항에 '$f' 가 없다" ;; esac
  done
  # (d) 재리뷰 대상과 예외 (iii): 커밋 보존은 커밋 단위 목록, 합침은 PR 고유 diff 의 patch-id
  sec=$(awk '/^\*\*걸림\*\*/ { f = 1 } /^## 8\./ { f = 0 } f' "$sk")
  all=$(printf '%s\n' "$sec" | joined)
  for f in '구현자가 충돌 없이, 또는 기계적으로 풀었다고 보고한 따라잡기로' \
    '`git diff -U0 $(git merge-base <리뷰한 SHA> origin/<base>) <리뷰한 SHA> | git patch-id --stable` 과 `git diff -U0 $(git merge-base HEAD origin/<base>) HEAD | git patch-id --stable`' \
    '합침(squash)이면 `git diff <리뷰한 SHA>..HEAD` 가 아니라' 'Fix 나 따라잡기 뒤에는 **기본이 재리뷰다**'; do
    case $all in *"$f"*) ;; *) bad "(d) 7단계 걸림에 '$f' 가 없다" ;; esac
  done
  # 두 갈래 불릿 전체: 각 갈래가 land.sh 의 어느 판정(커밋 패치 판정, 고유 diff 판정)과 같은 명령인지
  exact_block '(d) 예외 (iii) 커밋 보존 갈래' "$(printf '%s\n' "$sec" | awk '/^  - 커밋 보존:/ { f = 1 } /^  - 합침\(squash\):/ { f = 0 } f')" "${keep_bullet[@]}"
  exact_block '(d) 예외 (iii) 합침 갈래' "$(printf '%s\n' "$sec" | awk '/^  - 합침\(squash\):/ { f = 1 } /^$/ { f = 0 } f')" "${squash_bullet[@]}"
  # (e) 8단계 호출 틀은 --method 를 늘 넘기고(--via 와 둘 중 하나), 새 BLOCKED 행이 있다
  sec=$(awk '/^2\. 넣는다/ { f = 1 } f && /^3\. / { exit } f' "$sk" | joined)
  for f in '--evidence <기록 파일> (--method <0단계 병합> | --via '\''<착륙 명령>'\'')' '`--method` 는 언제나 0단계 `병합` 값을 준다'; do
    case $sec in *"$f"*) ;; *) bad "(e) 8단계 2항에 '$f' 가 없다" ;; esac
  done
  f=$(grep -E '^\| `BLOCKED \.\.\. 저장소가 <방식> 병합을 허용하지 않는다` \|' "$sk" || true)
  [ -n "$f" ] || bad "(e) 8단계 표에 '저장소가 <방식> 병합을 허용하지 않는다' 행이 없다"
  case $f in *'0단계 `병합`'*'사람에게 묻'*) ;; *) bad "(e) 새 BLOCKED 행의 처리에 0단계 병합 방식 고치기나 사람에게 묻기가 없다: $f" ;; esac
  # 패치가 달라졌다 행은 8단계 표에 하나이고 통째로 같다. 옛 문구와 squash 고리 모드를 사람에게 넘기던 문장은 어디에도 없다
  f=$(awk '/^## / { s = ($0 ~ /^## 8\./) } s' "$sk" | grep -F '| `BLOCKED ... base 를 얹은 뒤 패치가 달라졌다` |' || true)
  [ "$f" = "$patch_row" ] || bad "(e) 8단계 표의 '패치가 달라졌다' 행이 기대한 글 하나가 아니다: $f"
  all=$(cat "$sk" "$dir"/references/*.md "$SCRIPTS/land.sh")
  for f in 'rebase 가 패치를 바꿨다' '고리 모드의 squash 지원은 후속 이슈' 'rebase 된 tip'; do
    case $all in *"$f"*) bad "(e) '$f' 가 남아 있다" ;; esac
  done
  # 착륙 tip 두 갈래: 도구 표 land.sh 행, NEEDS_HUMAN 행, squash 의 합치지 못했다 행은 통째로, land.sh 헤더의 squash 갈래와 LAND_HEAD 줄도 통째로
  f=$(grep -F '| `land.sh` |' "$sk" || true); [ "$f" = "$tool_row" ] || bad "(e) 도구 표의 land.sh 행이 기대한 글 하나가 아니다: $f"
  f=$(awk '/^## / { s = ($0 ~ /^## 8\./) } s' "$sk" | grep -F '| `NEEDS_HUMAN #P ...` |' || true)
  [ "$f" = "$needs_human_row" ] || bad "(e) 8단계 표의 NEEDS_HUMAN 행이 기대한 글 하나가 아니다: $f"
  f=$(awk '/^## / { s = ($0 ~ /^## 8\./) } s' "$sk" | grep -F '| `BLOCKED ... base 를 합치지 못했다: <오류>` |' || true)
  [ "$f" = "$merge_fail_row" ] || bad "(e) 8단계 표의 '합치지 못했다' 행이 기대한 글 하나가 아니다: $f"
  exact_block '(e) land.sh 헤더 squash 갈래' "$(awk '/^#   squash: / { f = 1 } /^# 그다음 검사 명령/ { f = 0 } f' "$SCRIPTS/land.sh")" "${squash_header[@]}"
  grep -qxF -- "$land_head_line" "$SCRIPTS/land.sh" || bad "(e) land.sh 헤더에 LAND_HEAD 를 착륙 tip 으로 적은 줄이 없다"
  # (f) 구현 지시문: 갈래 두 벌(Then 2, Follow-up), 합침 갈래의 문장, 커밋 보존 갈래는 그대로
  [ "$(grep -cF '<커밋 보존(rebase, merge)이면>' "$ib")" = 2 ] || bad "(f) implement-brief 의 커밋 보존 갈래가 두 곳(Then, Follow-up)이 아니다"
  [ "$(grep -cF '<합침(squash)이면>' "$ib")" = 2 ] || bad "(f) implement-brief 의 합침 갈래가 두 곳(Then, Follow-up)이 아니다"
  all=$(joined < "$ib")
  for f in 'Put **`Closes #<N>` in the last commit message** of the last PR' 'Put **`Closes #<N>` in the PR body** of the last PR' \
    'no `--fixup`' 'The PR title follows the repo'\''s commit convention' 'it becomes the commit title on `<base>`' \
    'Merge `origin/<base>` only when it conflicts with your branch, the request says branch protection requires the branch to be up to date, or the request says `land.sh` reported `base 를 얹은 뒤 패치가 달라졌다`; otherwise do not catch up.' \
    'never force-push' 'rebase onto `origin/<base>` (never merge)' '`git push --force-with-lease`' '--autosquash' '**따라잡기**'; do
    case $all in *"$f"*) ;; *) bad "(f) implement-brief 에 '$f' 가 없다" ;; esac
  done
  # (g) 리뷰 지시문의 재리뷰 줄: 합침이면 PR 고유 diff 둘의 비교
  all=$(joined < "$rb")
  for f in '<합침(squash)이면:' 'git diff $(git merge-base <마지막으로 리뷰한 SHA> origin/<base>) <마지막으로 리뷰한 SHA>' 'git diff $(git merge-base HEAD origin/<base>) HEAD' '<커밋 보존(rebase, merge)이면:'; do
    case $all in *"$f"*) ;; *) bad "(g) review-brief 재리뷰 줄에 '$f' 가 없다" ;; esac
  done
  # (h) 용어: 요청 이름과 진행 목록 단계는 따라잡기다
  for f in "$sk" "$ib" "$wt"; do
    all=$(joined < "$f")
    for sec in 'Rebase 요청' '단계 `rebase`' 'Fix/Rebase' 'Fix, Rebase' 'Fix 나 Rebase' '**Rebase**' 'Rebase 를 보낸다' '/ Rebase /' '겹치는 PR 의 rebase' '`수정`, `rebase`'; do
      case $all in *"$sec"*) bad "(h) $(basename "$f") 에 '$sec' 가 남아 있다" ;; esac
    done
  done
  grep -qF '`수정`, `따라잡기`, `다음 PR 대기`' "$sk" || bad "(h) 진행 목록 단계에 '따라잡기' 가 없다"
  grep -qF 'squash 병합을 전제해' "$dc" && bad "(h) disciplines.md 에 'squash 병합을 전제해' 가 남아 있다"
  grep -qF '직접 병합해 `land.sh` 와 부딪힌다' "$dc" || bad "(h) disciplines.md 에 '직접 병합해 \`land.sh\` 와 부딪힌다' 가 없다"
}

# 리뷰 라운드, 되돌림에 숫자 상한이 없고 오케스트레이터가 다음 처리를 판단한다(#87). 구절은 절마다 가둬 찾는다.
case_judgment_static() { # 상한 문구 부재, 판단 문단의 규칙 문장, 등급 절 계기와 올림, 깨끗하다 예외, 상태 블록, 정의, 착륙 기록
  local dir=$SCRIPTS/.. sk f sec all
  sk=$dir/SKILL.md
  # (a) 어디에도 숫자 상한이 없다
  all=$(cat "$sk" "$dir"/references/*.md | joined)
  for f in '되돌림 <n>/2' '리뷰 라운드 <n>/2' '두 라운드' '두 번까지다' '두 번 되돌려도' '보통 상한을' '상한을 넘으면' '되돌림과 리뷰 라운드를 0' '리뷰 라운드는 0 으로'; do
    case $all in *"$f"*) bad "(a) '$f' 가 남아 있다" ;; esac
  done
  for f in '세 (번|라운드)' '(리뷰|되돌림|라운드)[^.]{0,30}번까지' '라운드[^.]{0,20}까지' '<n>/[0-9]' '0 으로'; do
    printf '%s\n' "$all" | grep -qE -- "$f" && bad "(a) 상한 꼴 '$f' 가 되살아났다"
  done
  # (b) 7단계 판단 문단: 규칙 문장을 통째로 찾는다
  sec=$(awk '/^리뷰를 거듭해도 같은 지적이/ { f = 1 } /^## 8\./ { f = 0 } f' "$sk" | joined)
  [ -n "$sec" ] || bad "(b) 7단계에 판단 문단이 없다"
  for f in '리뷰를 거듭해도 같은 지적이 남거나 새 지적이 이어지면, 남은 지적의 크기와 성격을 보고 다음 중 하나를 네가 고른다. 숫자 상한은 두지 않는다.' \
    '- 재리뷰 한 번 더. - **기계 확인**: 남은 지적이 모두 판정 술어(이름 붙은 시험의 빨강->초록, `mutate.sh` 의 SURVIVED->KILLED, 고정 문자열 grep)로 가를 수 있고, 그 술어를 Fix 를 보내기 **전에** 정해 둘 수 있을 때. 이 처리는 위의 닫힌 예외 (i)~(iii) 규칙보다 앞선다. Fix 뒤 그 술어와 1, 3, 4항으로 끝내고, Fix diff 가 지적의 경로에만 닿는지 `pr-check.sh --carry <리뷰한 SHA> --may-touch '\''<지적 경로>'\''` 로 본다.' \
    '- **다음 PR 첫 할 일**: 같은 이슈에 다음 PR 이 있고 남은 지적이 완료 기준을 깨지 않을 때. 계약서의 그 PR 할 일 맨 앞에 재현, 기대, 출처 PR 과 SHA 를 적는다. 한 번 넘긴 지적은 다시 넘기지 않는다. - 한 칸 올림(등급 절, 올림을 아직 쓰지 않았을 때). - 사람에게 넘긴다(위 처리로 풀리지 않는다고 판단했을 때).' \
    '고른 처리로 풀리지 않은 지적에는 같은 처리를 다시 고르지 않는다.' \
    '착륙한다면 착륙 기록에 `판단:` 한 줄(고른 처리, 남은 지적, 근거 재현)과 `리뷰하지 못한 범위` 를 남긴다.'; do
    case $sec in *"$f"*) ;; *) bad "(b) 판단 문단에 '${f:0:50}...' 문장이 없다" ;; esac
  done
  sec=$(awk '/^\*\*걸림\*\*/ { f = 1 } /^리뷰를 거듭해도 같은 지적이/ { f = 0 } f' "$sk" | joined)
  case $sec in *'기본이 재리뷰다'*'(iii) 구현자가'*) ;; *) bad "(b) 걸림 문단에 재리뷰 기본과 예외 (iii) 가 없다" ;; esac
  # (c) 등급 절: 계기와 올림 규칙(올림은 이슈당 한 번)
  sec=$(awk '/^- \*\*한 칸 올려 다시 보낸다\*\*/ { f = 1; print; next } /^- \*\*사람에게 넘긴다\*\*/ { f = 0 } f' "$sk" | joined)
  for f in '완료 기준을 못 채웠다, 검수에서 되돌려도 같은 지적이 풀리지 않는다고 판단했다.' \
    '올림은 이슈당 한 번이다(`올림` 으로 센다). 이미 `올림 1` 이거나 가장 높은 등급이면 더 올리지 않고 `Regression warning` 만 싣고, 걸림 문단 뒤의 판단 문단에서 재리뷰, 기계 확인, 다음 PR 첫 할 일 가운데 고르며, 그것으로 풀리지 않는다고 판단할 때만 사람에게 넘긴다. 리뷰 등급은 그대로다.'; do
    case $sec in *"$f"*) ;; *) bad "(c) 등급 절에 '${f:0:50}...' 문장이 없다" ;; esac
  done
  # (d) 깨끗하다의 예외, 상태 블록, 정의
  sec=$(awk '/^\*\*깨끗하다\*\*/ { f = 1 } f && /^$/ { exit } f' "$sk" | joined)
  case $sec in *'맞다. 단 걸림 문단 뒤의 판단 문단이 **다음 PR 첫 할 일** 로 넘긴 지적은, 착륙 기록에 `판단:` 줄이 있으면 받아들인 `blocker`/`major` 로 치지 않는다. 깨끗하면 8단계로 간다.'*) ;; *) bad "(d) 깨끗하다 정의에 다음 PR 첫 할 일 예외 문장이 없다" ;; esac
  f=$(grep -F '#<z> 수정, ' "$sk" | tail -n 1)
  case $f in *'되돌림 <n>, 리뷰 라운드 <n>, '*) ;; *) bad "(d) 상태 블록 '#<z> 수정' 줄에 '되돌림 <n>, 리뷰 라운드 <n>' 이 없다" ;; esac
  sec=$(awk '/^맡는 이슈는/ { f = 1 } f && /^$/ { exit } f' "$sk" | joined)
  case $sec in *'`되돌림` 과 `리뷰 라운드` 는 정보용으로 센다. `리뷰 라운드` 는 검수에서 네가 띄운 리뷰어의 수(사람이 요청한 Fix 는 세지 않는다)다.'*) ;; *) bad "(d) 진행 목록 문단에 '리뷰 라운드' 정의가 없다" ;; esac
  # (e) 8단계 1항 착륙 기록, 사람이 요청한 Fix
  sec=$(awk '/^1\. \*\*착륙 기록\*\*/ { f = 1 } /^2\. 넣는다/ { f = 0 } f' "$sk" | joined)
  case $sec in *'리뷰하지 못한 범위, 걸림 문단 뒤의 판단 문단에서 고른 처리가 있었으면 `판단:` 한 줄.'*) ;; *) bad "(e) 8단계 1항 착륙 기록에 '판단:' 한 줄 문장이 없다" ;; esac
  grep -qF '되돌림, 리뷰 라운드에 세지 않는다' "$dir/references/watching.md" || bad "(e) watching.md 에 사람이 요청한 Fix 는 세지 않는 문장이 없다"
}

# 시험 범위: 내부 고리는 좁게, 최종 SHA 에서 전체 한 번, 커밋마다 전체는 없다(#80). 규칙이 든 블록은 통째로 같아야 한다(덧붙인 문장, 불릿이 있으면 진다).
exact_block() { # <이름> <실제 글> <기대하는 줄>... -- 같지 않으면 bad
  local what=$1 actual=$2 want
  shift 2
  want=$(printf '%s\n' "$@")
  [ "$actual" = "$want" ] || bad "$what 이 기대한 글과 같지 않다"
}
case_test_scope_static() { # implement-brief Then 2, 3, Follow-up, Report 블록, review-brief 변이 문단, SKILL.md 7단계 3(a), 5항, 5단계 시험 항목, sequence 카드
  local dir=$SCRIPTS/.. sk ib rb dc all rest f
  sk=$dir/SKILL.md ib=$dir/references/implement-brief.md rb=$dir/references/review-brief.md dc=$dir/references/disciplines.md
  local then_block=(
    '2. <커밋 보존(rebase, merge)이면> Tidy the history: fold a fix of your own earlier commit into it (`git commit --fixup=<c>`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash $(git merge-base origin/<base> HEAD)`). Never merge. If the contract or repo rules name a cheap per-commit check (seconds: import, compile, collect, lint), run only that check on each commit with `git rebase -x`.'
    '   <합침(squash)이면> The repo squash-merges, so do not fold fixes: stack each fix as a new commit on top (no `--fixup`, no `rebase -i --autosquash`). The PR title follows the repo'\''s commit convention (for example Conventional Commits): it becomes the commit title on `<base>`. There is no per-commit check.'
    '3. Run the checks the contract and repo rules require on the exact SHA you push. Never skip hooks. Output from another SHA, a run you have not checked at this SHA, or a helper'\''s summary is not a result, except the equal-tree carry-over under Follow-up requests. A background run of your own counts once its log shows the SHA you push.'
    '   - Inner loop (while you fix): run only the failing tests and the tests that touch the files you changed (for example the runner'\''s last-failed option, or the test files of the changed modules).'
    '   - Final run: on the exact SHA you push, run the whole test set the contract and repo rules require, once. Never run the whole test set once per commit.'
    '   - The inner loop runs the whole set too when: a dependency or lock file changed; a test harness or shared fixture changed; the base moved; the repo cannot run selected tests.'
  )
  local follow_block=(
    '**Follow-up requests** come by message after you report:'
    '- **Fix** (review findings or a human'\''s PR feedback, each with evidence), **따라잡기** (base moved and your PR conflicts with it, or branch protection requires the branch to be up to date), **Next PR** (an earlier PR of this issue merged).'
    '- Fix/따라잡기 checks: narrow while you fix, the whole set once on the final SHA, as in Then 3. If `git rev-parse <final SHA>^{tree}` equals the tree of an earlier SHA on which you ran the whole set green, do not rerun it: name that SHA in your report (the orchestrator takes it over with `--carry`).'
    '- <커밋 보존(rebase, merge)이면> Fix/따라잡기: put the PR back to draft (`gh pr ready --undo`) if it is ready; rebase onto `origin/<base>` (never merge), resolving each conflict so both sides survive; fix each item with a test where one can show it; fold fixes into the commit that introduced the problem; run the checks as the Fix/따라잡기 checks bullet says; `git push --force-with-lease`; update the PR body; report what changed (for a rebase: each conflicted file, resolved mechanically or by meaning) and the new SHA.'
    '- <합침(squash)이면> Fix/따라잡기: put the PR back to draft (`gh pr ready --undo`) if it is ready. Fix each item with a test where one can show it, as new commits on top. Merge `origin/<base>` only when it conflicts with your branch, the request says branch protection requires the branch to be up to date, or the request says `land.sh` reported `base 를 얹은 뒤 패치가 달라졌다`; otherwise do not catch up. When you merge, use `git merge origin/<base>` (never rebase), resolving each conflict so both sides survive. Then run the checks as the Fix/따라잡기 checks bullet says; push (never force-push); update the PR body; report what changed (for a merge: each conflicted file, resolved mechanically or by meaning, or that you did not catch up and why) and the new SHA.'
    '- Next PR: start from the current `origin/<base>` in the same worktree and implement that PR'\''s part of the contract as above.'
    '- If you were stopped by a usage limit, or woken because you looked stalled, and told to continue: check whether your background runs finished and reuse their results; stop (`TaskStop`) any wait that can never end; rerun only what has none.'
  )
  local report_block=(
    '## Report'
    ''
    '- PR URL(s) and the tested SHA; confirm it equals the PR HEAD.'
    '- Each completion criterion: met and how you checked it, or **not met** and what is missing (partly met is not met).'
    '- For each check that takes minutes: the log path (in `<scratch>`, outside the worktree) and the verdict line the runner printed with the full 40-char SHA, quoted as printed. Never write or edit a verdict line by hand. Runs meant as evidence happen on a clean tree at the exact SHA you push.'
    '- For the final run: the verdict line with the full 40-char SHA, as the runner printed it. If you did not rerun because the tree matched, give the SHA whose result you carry over.'
    '- For each discipline in this brief: `규율 <id> -> <the choice it changed> (file:line)`, or `규율 <id>: 적용 안 함(<reason>)`.'
    '- Deviations from the contract and why. Out-of-scope bugs with reproductions. `Out-of-scope shapes to reshape: symbol, why`. Boundary notes for sibling issues.'
    '- Tools made: every script you wrote and every command sequence or setup (env, locks, temp worktrees) you ran by hand, as what / path / times run, or "none". Keep scratch scripts in `<scratch>`, outside the worktree.'
  )
  local contract_test=(
    '- **시험**: 결함은 수정 전 빨강, 수정 후 초록. 구조 변경은 회귀를 무엇이 지키는지. 오래 걸리는 시험마다 **이어 받기'
    '  허용 경로**(ERE, 7단계 3항 (c))를 적을 수 있다. diff 를 보기 **전에**, 여기서 정한다. 시험이 읽는 집합을 열거하지 말고'
    '  diff 가 건드려도 결과가 바뀌지 않는 경로를 적는다(과소 선언이 거짓 승인이 되지 않게). 적지 않으면 tree 가 같을 때만'
    '  이어 받는다. 시험 항목 끝에 `커밋별 싼 검사: <명령> 또는 없음` 을 적는다(초 단위 검사만: import, 컴파일, 수집, lint). 안 적으면 계약서는 없음이다(저장소 규칙이 정한 싼 검사는 그대로 따른다).'
  )
  local review_a=(
    '   - (a) **재실행**: 너나 네가 띄운 서브에이전트가 PR HEAD 에서 다시 돌린 결과.'
    '     구현자의 좁힌 실행은 증거가 아니다.'
    '     오래 걸리는 것은 서브에이전트(`haiku`/`max`)에 맡기되'
    '     로그 파일을 worktree 밖에 남기게 하고 판정 줄을 네가 직접 읽는다. 하위 에이전트의 "통과" 요약만으로 받지 않는다.'
    '     그 지시에는 기다림 규칙을 넣는다(implement-brief 의 `**Waiting**` 줄을 그대로 옮긴다): 긴 실행은 그 실행 자체를'
    '     `run_in_background` 로 띄우고 `&`, `nohup`, `setsid`, `( ... & )` 로 떼어 띄우지 않는다. 로그나 다른 task 출력을'
    '     폴링하는 루프를 쓰지 않는다(꼭 써야 하면 `timeout` 으로 묶고 기다리는 실행이 끝나면 루프도 끝나게 한다). 마지막이'
    '     아닌 턴을 끝내며 기다릴 때는 무엇을 기다리고 언제 끝날지 그 실행의 로그 경로와 함께 한 줄로 쓴다. 리포트 전에는 띄운'
    '     백그라운드 실행이 끝나기를 기다리거나 `TaskStop` 하고, 멈춘 것을 리포트에 적어 아무것도 남기지 않는다.'
  )
  local review_5=(
    '5. **주장을 재현한다**: 결과를 좌우하는 주장 하나 이상을 사본에서 직접 재현한다. "수정 전에는 빨강" -> 수정 전 커밋'
    '   사본에서 그 시험을 돌린다. "이 시험이 이 결정을 지킨다" -> `mutate.sh` 로 그 결정을 깨 KILLED 인지 본다.'
    '   재현과 변이는 그 주장에 닿는 시험만 돌려도 된다.'
  )
  local seq_card=(
    ''
    '- **언제**: 여러 PR, sweep, 이주, 비슷한 편집의 반복.'
    '- **규칙**: 일을 검사로 끝나는 작은 단위로 나눈다. 단위마다 알려진 초록 -> 변경 하나 -> 검사 -> 다음이고, 도구가'
    '  편집해도 단위 검사를 돌린다. 증명하는 순서로 낸다: 지는 시험 먼저, 빼기 먼저, 기준선 먼저. 커밋 보존 병합이면 커밋마다 싼 검사가 초록이고, 최종 SHA 에서 전체가 초록이다.'
    '- **자리**: 5단계 PR 나누기와 할 일 순서, 6단계 구현 지시문.'
    '- **출처**: pstack `principle-sequence-verifiable-units`.'
  )
  local mutate_para=(
    '`mutate.sh` checks the text occurs exactly once, runs the test green first, applies the mutant, runs it again and restores the file: `KILLED rc=N` (exit 0) or `SURVIVED` (exit 1). Keep each mutant syntactically valid, or a syntax error kills it for the wrong reason. Confirm a test runner actually ran tests (count passes), since a runner missing its dependencies can exit quietly. The test command of a mutation may be narrowed to the tests that guard that decision; if you narrow it, name those tests in your report. Write any counterexample test out as text in your report; the implementer runs it.'
  )
  # (a) implement-brief: Then 2(커밋 보존의 싼 검사, 합침의 없음)와 Then 3(내부 고리, 최종 실행, 강제 전체 목록)
  exact_block '(a) implement-brief Then 2, 3' "$(awk '/^2\. <커밋 보존/ { f = 1 } /^4\. Push/ { f = 0 } f' "$ib")" "${then_block[@]}"
  # (b) Follow-up 목록 전체
  exact_block '(b) implement-brief Follow-up' "$(awk '/^\*\*Follow-up requests\*\*/ { f = 1 } /^## When to stop/ { f = 0 } f' "$ib")" "${follow_block[@]}"
  # (c) Report 절 전체
  exact_block '(c) implement-brief Report' "$(awk '/^## Report/ { f = 1 } f' "$ib")" "${report_block[@]}"
  # (d) 커밋마다 전체 시험을 요구하는 꼴이 어느 지시문, SKILL.md 에도 없다. rebase -x 는 한 문장에만 있다
  all=$(cat "$sk" "$dir"/references/*.md | joined)
  rest=${all//'Never run the whole test set once per commit.'/}
  for f in '(each|every|per) commit[^.]{0,60}(whole|full|all) (test|check)' '(whole|full|all) (test|check)[^.]{0,40}(each|every|per) commit' '커밋마다[^.,]{0,12}(전체|전부|모든 시험)' '(전체|전부)[^.,]{0,12}커밋마다'; do
    printf '%s\n' "$rest" | grep -qE -- "$f" && bad "(d) 커밋마다 전체를 요구하는 꼴 '$f' 가 있다"
  done
  printf '%s\n' "$all" | grep -qiE 're-?run the checks' && bad "(d) 're-?run the checks' 가 남아 있다"
  [ "$(printf '%s\n' "$all" | grep -oF 'rebase -x' | wc -l)" = 1 ] || bad "(d) 'rebase -x' 가 한 문장에만 있지 않다"
  # (e) review-brief: 변이 문단 전체
  exact_block '(e) review-brief mutate.sh 문단' "$(awk '/^`mutate.sh` checks the text/ { f = 1 } /^Never write to the PR/ { f = 0 } f' "$rb")" "${mutate_para[@]}"
  # (f) SKILL.md 7단계: 3항 (a) 불릿 전체, 5항 전체
  exact_block '(f) 7단계 3항 (a)' "$(awk '/^   - \(a\) \*\*재실행/ { f = 1 } /^   - \(b\)/ { f = 0 } f' "$sk")" "${review_a[@]}"
  exact_block '(f) 7단계 5항' "$(awk '/^5\. \*\*주장을 재현한다\*\*/ { f = 1 } /^6\. / { f = 0 } f' "$sk")" "${review_5[@]}"
  # (g) 5단계 계약서 시험 항목 전체
  exact_block '(g) 5단계 시험 항목' "$(awk '/^- \*\*시험\*\*/ { f = 1 } /^- \*\*PR\*\*/ { f = 0 } f' "$sk")" "${contract_test[@]}"
  # (h) sequence 카드 전체
  exact_block '(h) sequence 카드' "$(awk '$0 == "### sequence" { f = 1; next } /^### measure/ { f = 0 } f' "$dc")" "${seq_card[@]}"
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
  for f in "$WAIT" "$FLIGHT" "$SCRIPTS/land.sh"; do
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

# land.sh 의 BLOCKED 줄(이유)마다 SKILL.md 8단계 결과 표에 다음 행동을 적은 행이 있다. 이유를 변수와 괄호에서 끊은 조각 가운데
# 10바이트 이상인 것이 모두 한 행의 결과 칸(첫 칸)에 글자 그대로 있어야 한다.
blocked_keys() { # <이유> -> 조각(한 줄에 하나)
  printf '%s\n' "$1" | LC_ALL=C awk '{
    gsub(/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|[()]/, "\n"); n = split($0, seg, "\n")
    for (i = 1; i <= n; i++) { s = seg[i]; sub(/^[ :,]+/, "", s); sub(/[ :,]+$/, "", s); if (length(s) >= 10) print s }
  }'
}
result_cells() { # <SKILL.md> -> BLOCKED, NEEDS_HUMAN 행의 결과 칸(한 줄에 하나)
  grep -E '^\| `(BLOCKED|NEEDS_HUMAN) ' "$1" | awk '{ s = substr($0, 3); print substr(s, 1, index(s, " | ") - 1) }'
}
row_has_all() { # <결과 칸> <조각들>
  local k
  while IFS= read -r k; do case $1 in *"$k"*) ;; *) return 1 ;; esac; done <<<"$2"
}
case_land_blocked_rows() {
  local sk=$SCRIPTS/../SKILL.md rows row reason keys found n=0
  rows=$(result_cells "$sk")
  [ -n "$rows" ] || { bad "SKILL.md 에 8단계 결과 표의 BLOCKED 행이 없다"; return; }
  while IFS= read -r reason; do
    n=$((n + 1)); keys=$(blocked_keys "$reason"); found=0
    [ -n "$keys" ] || { bad "'$reason' 에 10바이트 이상인 조각이 없다"; continue; }
    while IFS= read -r row; do row_has_all "$row" "$keys" && { found=1; break; }; done <<<"$rows"
    [ $found = 1 ] || bad "land.sh 의 'BLOCKED #P $reason' 에 맞는 8단계 표 행이 없다(조각: $(printf '%s' "$keys" | tr '\n' '|'))"
  done < <(grep -oE 'BLOCKED #\$pr [^"]*' "$SCRIPTS/land.sh" | sed 's/^BLOCKED #\$pr //' | sort -u)
  [ "$n" -ge 20 ] || bad "land.sh 의 BLOCKED 줄을 $n 개만 읽었다"
}
case_land_blocked_key() { # 검사 자체의 시험: 변수, 괄호, 끝의 콜론에서 끊고 짧은 조각은 버린다
  local r
  r=$(blocked_keys 'base $tbase 를 받지 못했다'); [ "$r" = '를 받지 못했다' ] || bad "조각: '$r'"
  r=$(blocked_keys 'PR HEAD 가 올린 tip ${tip:0:12} 이 되지 않았다(${seen% *})' | tr '\n' '|'); [ "$r" = 'PR HEAD 가 올린 tip|이 되지 않았다|' ] || bad "조각: '$r'"
  r=$(blocked_keys 'PR HEAD 가 검수한 SHA 와 다르다(HEAD ${head:0:12}, 검수 $sha)'); [ "$r" = 'PR HEAD 가 검수한 SHA 와 다르다' ] || bad "조각: '$r'"
  r=$(blocked_keys '검사 실패: $check'); [ "$r" = '검사 실패' ] || bad "조각: '$r'"
  row_has_all '| `ready 로 바꾸지 못했다` |' "$(blocked_keys '대상 브랜치를 $base 로 바꾸지 못했다')" && bad "다른 행의 조각 하나에 맞았다"
  printf '%s\n' '| `BLOCKED ... 착륙 명령이 실패했다` | 저장소 검사 실패면 Fix |' > "$TMP/table.md"
  r=$(result_cells "$TMP/table.md"); [ "$r" = '`BLOCKED ... 착륙 명령이 실패했다`' ] || bad "결과 칸: '$r'"
  row_has_all "$r" "$(blocked_keys '검사 실패: $check')" && bad "행동 칸 글자에 맞았다"
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

case_mutate_meta_inherit() { # 하네스 자신의 안쪽 실행은 바깥 MUTATE 를 물려받지 않는다: 무해한 변이는 SURVIVED, exit 1
  run_self '^case 함수가 없으면 FAIL$' 'in-flight.sh:s/^# in-flight.sh -- /# in-flight.sh - /'
  expect_rc 1; expect_out_has 'MUTANT SURVIVED'
  expect_out_has '1 passed, 0 failed, 0 skipped'
}

# ---- 실행 ----
run_case() { # <표시 이름> <함수> [인자...]
  local label=$1; shift
  CASE=$label BAD=0
  rm -rf "$STUB_DATA"; mkdir -p "$STUB_DATA"   # 앞 경우의 fixture 가 남지 않게
  if declare -F "$1" >/dev/null; then "$@"; else bad "$1 함수가 없다"; fi
  if [ $BAD = 0 ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"; else FAIL=$((FAIL + 1)); fi
}

# CASES 에 적힌 함수가 없으면(오타, 이름 바꾸기, 지운 함수) 그 경우를 FAIL 로 센다. 이 하네스의 복사본에 없는 함수를 끼워 돌려 본다.
case_missing_case_fn() {
  local cp=$STUB_DATA/../self.sh
  sed -e "s|^SCRIPTS=.*|SCRIPTS=$SCRIPTS|" -e "s|^CASES=(\$|&\n  'no such case:case_no_such_fn native'|" "${BASH_SOURCE[0]}" > "$cp"
  run_nested=$(env -u MUTATE -u HARNESS_INNER ONLY='^no such case$' bash "$cp" 2>&1); local rc=$?
  [ "$rc" = 1 ] || bad "exit 1 이어야 하는데 $rc ($run_nested)"
  case $run_nested in *'FAIL no such case: case_no_such_fn 함수가 없다'*) ;; *) bad "FAIL 줄이 없다: $run_nested" ;; esac
  case $run_nested in *'PASS no such case'*) bad "PASS 로 셌다: $run_nested" ;; esac
}

CASES=(
  'case 함수가 없으면 FAIL:case_missing_case_fn native'
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
  'in-flight --agent: 기록이 새것 -> WORKING:case_agent_fresh_log'
  'in-flight --agent: 없는 id -> UNKNOWN:case_agent_unknown'
  'in-flight --agent: 기록에 나온 task 출력이 새것 -> WORKING:case_agent_fresh_output'
  'in-flight --agent: --path 아래 파일이 새것 -> WORKING:case_agent_fresh_path'
  'in-flight --agent: 사고 재연(흔적 모두 낡음, 루프 생존) -> STALLED:case_agent_incident'
  'in-flight --agent: 두 번째 사례(프로세스 없음, 커밋 안 한 수정, 흔적 15분 넘게 그대로) -> STALLED:case_agent_incident2'
  'in-flight --agent: 남의 task 출력만 새것 -> STALLED:case_agent_foreign_output'
  'in-flight --agent: --idle-min 경계와 기본값:case_agent_idle_boundary'
  'in-flight --agent --wait: 정체, 기록 없음이면 끝난다:case_agent_wait_stalled'
  'in-flight --agent --wait: 흔적이 바뀌는 동안은 끝나지 않는다:case_agent_wait_working'
  'in-flight --agent --wait: 기본 간격은 60초:case_agent_wait_default_interval'
  'in-flight --agent --wait --after: 깨운 뒤 다시 건 감시는 그 시각부터 기다린다:case_agent_rearm_after_wake'
  'in-flight --agent --after: 흔적보다 늦으면 그 시각부터 센다:case_agent_after_old'
  'in-flight --agent: 미래 시각 흔적은 판정에서 뺀다:case_agent_future_mtime'
  'in-flight --agent: 줄바꿈 든 파일 이름은 한 흔적 행이다:case_agent_trace_newline'
  'in-flight --agent: 이어진 줄이 숫자뿐이거나 빈 줄이어도 한 흔적 행이다:case_agent_trace_newline_joined'
  'in-flight --agent: - 로 시작하는 --path 도 흔적에 든다:case_agent_trace_dash_path'
  'in-flight --agent: 흔적이 모두 몇 초 미래면 지금으로 깎는다 -> WORKING:case_agent_future_skew'
  'in-flight --agent: 흔적이 모두 먼 미래면 UNKNOWN:case_agent_future_all'
  'in-flight --agent: 미래 시각 허용 오차 300초의 경계:case_agent_future_tolerance'
  'in-flight --agent --after: 허용 오차 안은 지금으로 깎고 넘으면 exit 2:case_agent_after_bounds'
  'in-flight --agent --after: 깨움 뒤 assistant 응답을 근거 줄로:case_agent_wake_reply'
  'in-flight --agent --after: 깨움 뒤 응답의 초 경계:case_agent_wake_reply_boundary'
  'in-flight --agent --after: 못 읽은 timestamp 는 그 줄만 건너뛰고 판정 불가를 낸다:case_agent_wake_reply_unreadable'
  'in-flight --agent: 기록 끝의 API 오류 -> 근거 줄:case_agent_api_error'
  'in-flight --agent: 인자 오류 -> exit 2:case_agent_bad_args'
  'in-flight --agent: --idle-min, --interval 은 6자리까지:case_agent_digit_bounds'
  'in-flight --agent: 감시, 기다림 규칙 정적 검사:case_agent_prose_static'
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
  '지시문, 규율 카드 정적 검사:case_dispatch_prose_static'
  '병합 방식 정적 검사:case_merge_method_static'
  '판단 규칙 정적 검사(숫자 상한 없음):case_judgment_static'
  '시험 범위 정적 검사(내부 고리 좁게, 최종 전체 한 번):case_test_scope_static'
  'in-flight 7 6 -> 0바이트 claim 이 판정을 막지 않는다:case_flight_empty_claim_file'
  'in-flight 7 6 -> 깨진 claim 이 판정을 막지 않는다:case_flight_broken_claim_file'
  'in-flight --claim -> 임시 파일이 남지 않고 새 파일로 바뀐다:case_flight_claim_atomic'
  'in-flight --claim -> 깨진 자기 세션 파일이면 실패하고 아무것도 남기지 않는다:case_flight_claim_broken_self'
  'in-flight --claim -> 0바이트 자기 세션 파일이면 실패하고 아무것도 남기지 않는다:case_flight_claim_empty_self'
  'in-flight --claim -> pid 없는 자기 세션 파일이면 실패하고 아무것도 남기지 않는다:case_flight_claim_nopid_self'
  'in-flight --claim -> 표시 자리가 디렉터리면 실패하고 아무것도 더하지 않는다:case_flight_claim_dir_slot'
  '정적 검사: 빈 배열 펼침 없음:case_static_empty_array'
  '정적 검사: 검사기 자체:case_static_detects'
  '정적 검사: land.sh 의 BLOCKED 줄마다 8단계 표 행:case_land_blocked_rows'
  '정적 검사: BLOCKED 조각 고르기:case_land_blocked_key'
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
  'MUTATE 가 하네스 자신의 안쪽 실행에 새지 않는다:case_mutate_meta_inherit'
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
