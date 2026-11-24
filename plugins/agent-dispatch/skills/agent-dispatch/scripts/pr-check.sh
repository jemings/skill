#!/usr/bin/env bash
# pr-check.sh -- PR 의 모양을 본다(agent-dispatch 7단계 1항). 시험을 돌리기 전, 리뷰어를 띄우기 전에 돌린다.
#
#   pr-check.sh --repo O/R --pr P --worktree W [--base B] [--sha S] [--closes N] [--forbid-trailer ERE]... [--forbid-path ERE]...
#
#   --worktree W        그 PR 브랜치의 worktree. HEAD 와 작업 트리를 본다
#   --base B            대상 브랜치(기본: 저장소의 기본 브랜치). stacked PR 의 위층이면 앞 층의 브랜치를 준다
#   --sha S             구현자가 보고한 시험 SHA. PR HEAD 와 같아야 한다
#   --closes N          base 이후 커밋 메시지 가운데 하나에 "Closes #N"(Fixes, Resolves 도)이 있어야 한다
#   --forbid-trailer E  base 이후 커밋 메시지에 E 에 맞는 줄이 있으면 안 된다(예: '^Co-Authored-By:')
#   --forbid-path E     base 이후 바뀐 파일 경로가 E 에 맞으면 안 된다(예: '^CHANGELOG\.md$')
#
# 출력: 검사마다 "OK <검사>" 나 "FAIL <검사>: <근거>", 정보는 "INFO <내용>", 마지막 줄 "SHAPE OK" 나 "SHAPE FAIL".
# exit 0 = 모두 맞다, 1 = 하나라도 틀렸다, 2 = 인자가 틀렸다.
# mergeable 이 UNKNOWN 이면 PR_CHECK_POLL 초(기본 10) 간격으로 PR_CHECK_TRIES 번(기본 12) 다시 본다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다.
# 필요한 것: bash, git, gh.
set -uo pipefail

die() { echo "pr-check: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }
value() { [ -n "${2:-}" ] || die "$1 에 값을 줘라"; }

repo='' pr='' wt='' base='' sha='' closes=''
trailers=() paths=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo) value "$@"; repo=$2; shift 2 ;;
    --pr) value "$@"; pr=$2; shift 2 ;;
    --worktree) value "$@"; wt=$2; shift 2 ;;
    --base) value "$@"; base=$2; shift 2 ;;
    --sha) value "$@"; sha=$2; shift 2 ;;
    --closes) value "$@"; closes=$2; shift 2 ;;
    --forbid-trailer) value "$@"; trailers+=("$2"); shift 2 ;;
    --forbid-path) value "$@"; paths+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "모르는 인자: $1" ;;
  esac
done
[[ $repo =~ ^([^/]+/)?[^/]+/[^/]+$ ]] || die "--repo 는 [HOST/]OWNER/REPO 다: '$repo'"
[[ $pr =~ ^[0-9]+$ ]] || die "--pr 에 PR 번호를 줘라"
[ -d "$wt" ] || die "--worktree 가 없다: '$wt'"
[ -z "$closes" ] || [[ $closes =~ ^[0-9]+$ ]] || die "--closes 는 번호다: $closes"
POLL=${PR_CHECK_POLL:-10} TRIES=${PR_CHECK_TRIES:-12}

fails=0
ok() { echo "OK $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

view() { gh pr view "$pr" --repo "$repo" --json "$1" --jq "$2"; }
info=$(view state,headRefOid,baseRefName,mergeable '[.state, .headRefOid, .baseRefName, .mergeable] | join(" ")') \
  || { echo "FAIL gh: PR #$pr 를 읽지 못했다"; echo "SHAPE FAIL"; exit 1; }
read -r state head prbase mergeable <<<"$info"
if [ -z "$base" ]; then
  base=$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name) || die "기본 브랜치를 읽지 못했다"
fi

[ "$state" = OPEN ] && ok "열림" || fail "열림" "PR 이 $state 다"
[ "$prbase" = "$base" ] && ok "대상 $base" || fail "대상" "PR 의 대상이 $prbase 인데 $base 여야 한다"
local_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || local_head=''
[ "$local_head" = "$head" ] && ok "HEAD ${head:0:12}" || fail "HEAD" "PR HEAD ${head:0:12} 와 worktree HEAD ${local_head:0:12} 가 다르다"
if [ -n "$sha" ]; then
  case $head in "$sha"*) ok "보고한 SHA" ;; *) fail "보고한 SHA" "보고 $sha, PR HEAD ${head:0:12}" ;; esac
fi
dirty=$(git -C "$wt" status --porcelain 2>/dev/null | head -5)
[ -z "$dirty" ] && ok "작업 트리 깨끗함" || fail "작업 트리" "$(printf '%s' "$dirty" | tr '\n' ' ')"

for _ in $(seq 1 "$TRIES"); do
  [ "$mergeable" = UNKNOWN ] || break
  sleep "$POLL" # GitHub 가 mergeable 을 계산하는 중이다
  mergeable=$(view mergeable .mergeable) || mergeable=UNKNOWN
done
case $mergeable in
  MERGEABLE) ok "충돌 없음" ;;
  *) fail "충돌" "mergeable=$mergeable" ;;
esac

# base 이후의 범위: 원격의 대상 브랜치가 있으면 그것과의 merge-base
remote_base=''
for r in $(git -C "$wt" remote); do
  if git -C "$wt" rev-parse -q --verify "refs/remotes/$r/$base" >/dev/null; then remote_base=$r/$base; break; fi
done
if [ -z "$remote_base" ]; then
  fail "범위" "원격 추적 브랜치 */$base 가 없다(git fetch 를 먼저)"
else
  mb=$(git -C "$wt" merge-base "$remote_base" HEAD)
  behind=$(git -C "$wt" rev-list --count "HEAD..$remote_base")
  echo "INFO 커밋 $(git -C "$wt" rev-list --count "$mb..HEAD")개, $remote_base 보다 ${behind}개 뒤"
  msgs=$(git -C "$wt" log --format=%B "$mb..HEAD")
  if [ -n "$closes" ]; then
    printf '%s\n' "$msgs" | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) +#$closes\b" \
      && ok "Closes #$closes" || fail "Closes" "커밋 메시지에 'Closes #$closes' 가 없다"
  fi
  for e in ${trailers[@]+"${trailers[@]}"}; do
    hit=$(printf '%s\n' "$msgs" | grep -E "$e" | head -1)
    [ -z "$hit" ] && ok "커밋 메시지에 /$e/ 없음" || fail "커밋 메시지" "/$e/ 에 맞는 줄: $hit"
  done
  if [ ${#paths[@]} -gt 0 ]; then
    changed=$(git -C "$wt" diff --name-only "$mb" HEAD)
    for e in "${paths[@]}"; do
      hit=$(printf '%s\n' "$changed" | grep -E "$e" | head -3 | tr '\n' ' ')
      [ -z "$hit" ] && ok "바뀐 파일에 /$e/ 없음" || fail "바뀐 파일" "/$e/ 에 맞는 파일: $hit"
    done
  fi
fi

if [ "$fails" = 0 ]; then echo "SHAPE OK"; exit 0; fi
echo "SHAPE FAIL"; exit 1
