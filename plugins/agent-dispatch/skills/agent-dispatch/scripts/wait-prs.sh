#!/usr/bin/env bash
# wait-prs.sh — 지켜보는 PR 가운데 하나에 일이 생길 때까지 기다린다(agent-dispatch 9단계).
#
#   wait-prs.sh [--repo owner/repo] [--interval 초] [--timeout 초] [--other <PR>]... [<PR>...]
#
#   <PR>          이 실행이 연 PR — MERGED·CLOSED·CONFLICTING 을 본다
#   --other <PR>  지도 안의 이슈를 막고 있는 다른 세션의 PR — MERGED·CLOSED 만 본다
#
# 일(생긴 것만 한 줄씩 낸다):
#   MERGED <PR>               병합됐다
#   CLOSED <PR>               병합되지 않고 닫혔다
#   CONFLICTING <PR>          열려 있지만 base 와 충돌한다 — rebase 가 필요하다(이 실행의 PR 만)
#   GH_FAILING <PR> <이유>    그 PR 의 조회가 잇달아 실패했다(기본 10회, WAIT_PRS_MAX_FAIL) — 이유는 gh 의 마지막 오류 한 줄
# 한 회차에 일이 하나라도 있으면 그 회차의 일을 모두 내고 0 으로 끝난다.
# --timeout(기본 0 = 끝없이)이 지나면 TIMEOUT 을 내고 3 으로 끝난다. 인자가 틀리면 2.
# Bash 의 백그라운드 실행(run_in_background)으로 띄운다 — 끝나면 harness 가 오케스트레이터를 다시 부른다.
# 필요한 것: bash 4.4+, gh. timeout(coreutils)이 있으면 조회 하나를 60초에서 끊는다.
set -uo pipefail

die() { echo "wait-prs: $*" >&2; exit 2; }
usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
value() { [ -n "${2:-}" ] || die "$1 에 값을 줘라"; }

repo='' interval=${WAIT_PRS_INTERVAL:-60} limit=0 max_fail=${WAIT_PRS_MAX_FAIL:-10}
others=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo) value "$@"; repo=$2; shift 2 ;;
    --interval) value "$@"; interval=$2; shift 2 ;;
    --timeout) value "$@"; limit=$2; shift 2 ;;
    --other) value "$@"; others+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) die "모르는 옵션: $1" ;;
    *) break ;;
  esac
done
mine=("$@")
[ $((${#mine[@]} + ${#others[@]})) -gt 0 ] || usage
for n in "${mine[@]}" "${others[@]}"; do [[ $n =~ ^[0-9]+$ ]] || die "PR 번호가 아니다: $n"; done
[[ $interval =~ ^[0-9]+$ && $interval -gt 0 ]] || die "--interval 은 양의 정수다: $interval"
[[ $limit =~ ^[0-9]+$ ]] || die "--timeout 은 0 이상의 정수다: $limit"
[[ $max_fail =~ ^[0-9]+$ && $max_fail -gt 0 ]] || die "WAIT_PRS_MAX_FAIL 은 양의 정수다: $max_fail"
command -v gh >/dev/null || die "gh 가 필요하다"
[ -n "$repo" ] || repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "--repo 를 줘라"

if command -v timeout >/dev/null; then
  query() { timeout 60 gh "$@"; }
else
  query() { gh "$@"; }
fi

err=$(mktemp) || die "임시 파일을 만들지 못했다"
trap 'rm -f "$err"' EXIT

fails=()   # PR 번호 → 잇단 실패 횟수. 한 PR 의 실패가 다른 PR 의 지켜보기를 끝내지 않게 PR 마다 센다.
events=()

# poll <PR> <mine|other> — 그 PR 의 일을 events 에 더한다.
poll() {
  local n=$1 kind=$2 line rc=0 state mergeable why
  line=$(query pr view "$n" -R "$repo" --json state,mergeable --jq '"\(.state) \(.mergeable)"' 2>"$err") || rc=$?
  if [ "$rc" = 0 ]; then
    read -r state mergeable <<<"$line"
    case $state in
      MERGED|CLOSED) fails[n]=0; events+=("$state $n"); return ;;
      # mergeable 은 GitHub 가 계산하는 동안 UNKNOWN 이다 — 일이 아니다.
      OPEN) fails[n]=0; [ "$kind" = mine ] && [ "$mergeable" = CONFLICTING ] && events+=("CONFLICTING $n"); return ;;
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
  for n in "${mine[@]}"; do poll "$n" mine; done
  for n in "${others[@]}"; do poll "$n" other; done
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
