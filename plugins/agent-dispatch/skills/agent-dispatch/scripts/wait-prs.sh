#!/usr/bin/env bash
# wait-prs.sh -- 지켜보는 PR 가운데 하나에 일이 생길 때까지 기다린다(agent-dispatch 9단계).
#
#   wait-prs.sh [--repo [HOST/]OWNER/REPO] [--interval 초] [--timeout 초] [--since <PR>=<시각>]... [--other <PR>]... [<PR>...]
#
#   <PR>          이 실행이 연 PR -- MERGED/CLOSED/CONFLICTING/FEEDBACK 을 본다
#   --other <PR>  지도 안의 이슈를 막고 있는 다른 세션의 PR -- MERGED/CLOSED 만 본다
#   --since <PR>=<시각>  그 PR 의 피드백 커서(UTC, 2026-10-30T09:15:00Z 꼴) -- 이보다 늦은 피드백만 센다.
#                 <PR> 은 위치 인자에 있어야 한다. 주지 않은 PR 은 모든 피드백을 센다
#
# 일(생긴 것만 한 줄씩 낸다):
#   MERGED <PR>               병합됐다
#   CLOSED <PR>               병합되지 않고 닫혔다
#   CONFLICTING <PR>          열려 있지만 base 와 충돌한다 -- rebase 가 필요하다(이 실행의 PR 만)
#   FEEDBACK <PR> <시각>      커서 뒤에 PR 피드백이 달렸다(이 실행의 열린 PR 만) -- 시각은 그 가운데 가장 늦은 것.
#                             PR 피드백: 봇이 아닌 계정의 제출된 리뷰(인라인은 그 리뷰의 제출 시각)와 숨기지 않은 대화 댓글
#   GH_FAILING <PR> <이유>    그 PR 의 조회가 잇달아 실패했다(기본 10회, WAIT_PRS_MAX_FAIL) -- 이유는 gh 의 마지막 오류 한 줄
# 한 차례 조회에 일이 하나라도 있으면 그 차례의 일을 모두 내고 0 으로 끝난다.
# --timeout(기본 0 = 끝없이)이 지나면 TIMEOUT 을 내고 3 으로 끝난다. 인자가 틀리면 2.
# Bash 의 백그라운드 실행(run_in_background)으로 띄운다 -- 끝나면 harness 가 오케스트레이터를 다시 부른다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다 -- 헤더 안에 빈 줄이나 비주석 줄을 두면 거기서 끊긴다.
# 필요한 것: bash 4+, gh. timeout(coreutils)이 있으면 조회 하나를 60초에서 끊는다.
set -uo pipefail

die() { echo "wait-prs: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }
value() { [ -n "${2:-}" ] || die "$1 에 값을 줘라"; }

repo='' interval=${WAIT_PRS_INTERVAL:-60} limit=0 max_fail=${WAIT_PRS_MAX_FAIL:-10}
others=()
since=()   # PR 번호 -> 피드백 커서. fails 처럼 PR 번호를 키로 하는 indexed 배열이다(bash 3.2 에는 declare -A 가 없다).
stamp='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
while [ $# -gt 0 ]; do
  case $1 in
    --repo) value "$@"; repo=$2; shift 2 ;;
    --interval) value "$@"; interval=$2; shift 2 ;;
    --timeout) value "$@"; limit=$2; shift 2 ;;
    --other) value "$@"; others+=("$2"); shift 2 ;;
    --since)
      value "$@"
      [[ $2 =~ ^([0-9]+)=($stamp)$ ]] || die "--since 는 <PR>=<YYYY-MM-DDTHH:MM:SSZ> 다: $2"
      k=$((10#${BASH_REMATCH[1]}))
      [ -z "${since[k]:-}" ] || die "--since 에 PR $k 를 두 번 줬다"
      since[k]=${BASH_REMATCH[2]}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "모르는 옵션: $1" ;;
    *) break ;;
  esac
done
mine=("$@")
[ $((${#mine[@]} + ${#others[@]})) -gt 0 ] || { usage >&2; exit 2; }
for n in ${mine[@]+"${mine[@]}"} ${others[@]+"${others[@]}"}; do [[ $n =~ ^[0-9]+$ ]] || die "PR 번호가 아니다: $n"; done
for k in "${!since[@]}"; do
  ok=0
  for n in ${mine[@]+"${mine[@]}"}; do [ $((10#$n)) = "$k" ] && ok=1; done
  [ "$ok" = 1 ] || die "--since 의 PR $k 가 위치 인자(이 실행의 PR)에 없다"
done
[[ $interval =~ ^[0-9]+$ && $interval -gt 0 ]] || die "--interval 은 양의 정수다: $interval"
[[ $limit =~ ^[0-9]+$ ]] || die "--timeout 은 0 이상의 정수다: $limit"
[[ $max_fail =~ ^[0-9]+$ && $max_fail -gt 0 ]] || die "WAIT_PRS_MAX_FAIL 은 양의 정수다: $max_fail"
command -v gh >/dev/null || die "gh 가 필요하다"
[ -n "$repo" ] || repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "--repo 를 줘라"
# gh 의 -R 처럼 [HOST/]OWNER/REPO 와 그 URL(https://HOST/OWNER/REPO[.git])을 받는다
repo=${repo#http://}; repo=${repo#https://}; repo=${repo%/}; repo=${repo%.git}
host=() owner=${repo%/*} name=${repo##*/}
case $owner in */*) host=(--hostname "${owner%%/*}"); owner=${owner#*/} ;; esac
[[ $repo == */* && -n $owner && -n $name && $owner != */* ]] || die "--repo 는 [HOST/]OWNER/REPO 다: $repo"

if command -v timeout >/dev/null; then
  query() { timeout 60 gh "$@"; }
else
  query() { gh "$@"; }
fi

err=$(mktemp) || die "임시 파일을 만들지 못했다"
trap 'rm -f "$err"' EXIT

fails=()   # PR 번호 -> 잇단 실패 횟수. 한 PR 의 실패가 다른 PR 의 지켜보기를 끝내지 않게 PR 마다 센다.
events=()

# PR 하나를 한 질의로 본다. gh 는 응답에 errors 가 있으면 0 이 아닌 값으로 끝난다.
# 이 실행의 PR($feedback)이면 피드백 시각도 받는다. 리뷰의 인라인 댓글, 답글은 그 리뷰의 submittedAt 으로 잰다.
# 가장 늦은 것만 쓰므로 마지막 100개면 넉넉하다.
# shellcheck disable=SC2016  # $owner 따위는 GraphQL 변수다
gql='query($owner: String!, $name: String!, $number: Int!, $feedback: Boolean!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    state mergeable
    reviews(last: 100) @include(if: $feedback) { nodes { submittedAt author { __typename } } }
    comments(last: 100) @include(if: $feedback) { nodes { createdAt isMinimized author { __typename } } }
  } }
}'

# jq_program <mine|other> <커서|빈 값> -- gh --jq 에 넘길 프로그램. "<state> <mergeable>[ <가장 늦은 피드백 시각>]" 한 줄을 낸다.
# gh --jq 에는 --arg 가 없어 커서를 프로그램에 박는다(꼴은 인자 검사에서 확인했다). ISO-8601 UTC 는 사전순이 시각순이다.
# 커서가 비면 모든 시각이 "" 보다 크다. author 가 null(지운 계정)이면 .author.__typename 도 null 이라 센다.
# jq 1.7 과 gh 의 gojq 에 공통인 문법만 쓴다.
jq_program() {
  local p='.data.repository.pullRequest | "\(.state) \(.mergeable)"'
  [ "$1" = mine ] || { printf '%s' "$p"; return; }
  printf '%s' "$p"' + ([(.reviews.nodes[] | select(.submittedAt != null and .author.__typename != "Bot") | .submittedAt),
    (.comments.nodes[] | select(.isMinimized == false and .author.__typename != "Bot") | .createdAt)]
    | map(select(. > "'"$2"'")) | max | if . == null then "" else " \(.)" end)'
}

# poll <PR> <mine|other> -- 그 PR 의 일을 events 에 더한다.
poll() {
  local n=$1 kind=$2 line rc=0 state mergeable latest why feedback=false
  [ "$kind" = mine ] && feedback=true
  line=$(query api graphql ${host[@]+"${host[@]}"} -f query="$gql" -f owner="$owner" -f name="$name" -F number="$n" \
    -F feedback="$feedback" --jq "$(jq_program "$kind" "${since[10#$n]:-}")" 2>"$err") || rc=$?
  if [ "$rc" = 0 ]; then
    read -r state mergeable latest <<<"$line"
    [[ -z $latest || $latest =~ ^$stamp$ ]] || state=''
    case $state in
      MERGED|CLOSED) fails[n]=0; events+=("$state $n"); return ;;
      # mergeable 은 GitHub 가 계산하는 동안 UNKNOWN 이다 -- 일이 아니다.
      OPEN)
        fails[n]=0
        [ "$kind" = mine ] || return 0
        [ "$mergeable" = CONFLICTING ] && events+=("CONFLICTING $n")
        [ -n "$latest" ] && events+=("FEEDBACK $n $latest")
        return 0 ;;
      *) echo "알 수 없는 응답: ${line:-빈 줄}" >"$err"; rc=1 ;;
    esac
  fi
  fails[n]=$((${fails[n]:-0} + 1))
  [ "${fails[n]}" -ge "$max_fail" ] || return 0
  why=$(tail -n 1 "$err" | tr -d '\r' | cut -c1-200)
  [ "$rc" = 124 ] && why="60초 안에 답이 없다"
  events+=("GH_FAILING $n ${why:-gh 가 $rc 로 끝났다}")
}

start=$SECONDS
while :; do
  events=()
  for n in ${mine[@]+"${mine[@]}"}; do poll "$n" mine; done
  for n in ${others[@]+"${others[@]}"}; do poll "$n" other; done
  if [ ${#events[@]} -gt 0 ]; then
    printf '%s\n' "${events[@]}"
    exit 0
  fi
  if [ "$limit" -gt 0 ] && [ $((SECONDS - start)) -ge "$limit" ]; then
    echo TIMEOUT
    exit 3
  fi
  sleep "$interval"
done
