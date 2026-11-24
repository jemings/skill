#!/usr/bin/env bash
# pr-check.sh -- PR 의 모양을 본다(agent-dispatch 7단계 1항). 시험을 돌리기 전, 리뷰어를 띄우기 전에 돌린다.
# 시험 결과를 PR HEAD 의 증거로 받을 수 있는지도 판정한다(7단계 3항, 걸림).
#
#   pr-check.sh --repo O/R --pr P --worktree W [--base B] [--sha S] [--closes N] [--forbid-trailer ERE]... [--forbid-path ERE]...
#               [--verdict LOG=TEXT]... [--carry SHA [--may-touch ERE]...]...
#
#   --worktree W        그 PR 브랜치의 worktree. HEAD 와 작업 트리를 본다
#   --base B            대상 브랜치(기본: 저장소의 기본 브랜치). stacked PR 의 위층이면 앞 층의 브랜치를 준다
#   --sha S             구현자가 보고한 시험 SHA. PR HEAD 와 같아야 한다
#   --closes N          base 이후 커밋 메시지 가운데 하나에 "Closes #N"(Fixes, Resolves 도)이 있어야 한다
#   --forbid-trailer E  base 이후 커밋 메시지에 E 에 맞는 줄이 있으면 안 된다(예: '^Co-Authored-By:')
#   --forbid-path E     base 이후 바뀐 파일 경로가 E 에 맞으면 안 된다(예: '^CHANGELOG\.md$')
#   --verdict LOG=TEXT  판정 줄(b): 로그 LOG 에 고정 문자열 TEXT 가 든 줄이 있어야 받는다. TEXT 의 {sha} 는
#                       PR HEAD 의 40자 SHA 로 바뀐다. {sha} 가 없거나 줄바꿈이 있으면 인자 오류다. 첫 '=' 에서 가른다
#   --carry SHA         이어 받기(c): git diff --no-renames --name-only SHA HEAD 가 비거나, 경로가 모두 뒤따르는
#                       --may-touch 가운데 하나에 맞으면 받는다. rename 은 옛 경로와 새 경로를 둘 다 본다.
#                       SHA 는 7~40자 소문자 16진수 커밋이어야 한다(대문자, HEAD, 브랜치, HEAD~1 은 인자 오류)
#   --may-touch E       바로 앞 --carry 의 이어 받기 허용 경로 ERE. 여러 번 줄 수 있다. 틀린 ERE, 줄바꿈이 든 값,
#                       빈 경로에도 맞는 ERE(예: '^a$|', '.*')는 인자 오류다
#
# 출력: 검사마다 "OK <검사>" 나 "FAIL <검사>: <근거>", 정보는 "INFO <내용>", 마지막 줄 "SHAPE OK" 나 "SHAPE FAIL".
# 증거 판정은 SHAPE 줄 바로 앞에 "EVIDENCE OK <라벨>: <일치한 줄 | diff --stat 요약>" 이나
# "RERUN <라벨>: <이유 | 벗어난 경로>" 를 낸다. 라벨은 "verdict#<k> <LOG>" 나 "carry#<k> <SHA 12자>" 이고 k 는
# 그 옵션을 준 순번(1부터)이다.
# 이 줄들은 SHAPE 와 exit 에 세지 않는다(증거 부족은 PR 결함이 아니라 "다시 돌려라"다).
# exit 0 = 모두 맞다, 1 = 하나라도 틀렸다, 2 = 인자가 틀렸다.
# mergeable 이 UNKNOWN 이면 PR_CHECK_POLL 초(기본 10) 간격으로 PR_CHECK_TRIES 번(기본 12) 다시 본다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다.
# 필요한 것: bash, git, gh.
set -uo pipefail

die() { echo "pr-check: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }
value() { [ -n "${2:-}" ] || die "$1 에 값을 줘라"; }

repo='' pr='' wt='' base='' sha='' closes=''
trailers=() paths=() verdicts=() carries=() nl=$'\n' cr=$'\r'
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
    --verdict) value "$@"; want=${2#*=}
      case $2 in ?*=*) ;; *) die "--verdict 는 <로그>=<글자> 다: '$2'" ;; esac
      case $want in *'{sha}'*) ;; *) die "--verdict 의 <글자> 에 {sha} 가 있어야 한다: '$2'" ;; esac
      case $want in *"$nl"*|*"$cr"*) die "--verdict 의 <글자> 에 줄바꿈이 있으면 안 된다" ;; esac
      verdicts+=("$2"); shift 2 ;;
    --carry) value "$@"; [[ $2 =~ ^[0-9a-f]{7,40}$ ]] || die "--carry 는 7~40자 커밋 SHA 다: '$2'"
      carries+=("$2"); shift 2 ;;
    --may-touch) value "$@"; [ ${#carries[@]} -gt 0 ] || die "--may-touch 는 --carry 뒤에 둔다"
      case $2 in *"$nl"*|*"$cr"*) die "--may-touch 에 줄바꿈이 있으면 안 된다" ;; esac
      grep -E -e "$2" <<<x >/dev/null 2>&1; [ $? -le 1 ] || die "--may-touch 의 ERE 가 틀렸다: '$2'"
      ! grep -qE -e "$2" <<<'' 2>/dev/null || die "--may-touch 가 빈 경로에도 맞아 모든 경로를 허용한다: '$2'"
      i=$((${#carries[@]} - 1)); carries[$i]=${carries[$i]}$nl$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "모르는 인자: $1" ;;
  esac
done
[[ $repo =~ ^([^/]+/)?[^/]+/[^/]+$ ]] || die "--repo 는 [HOST/]OWNER/REPO 다: '$repo'"
[[ $pr =~ ^[0-9]+$ ]] || die "--pr 에 PR 번호를 줘라"
[ -d "$wt" ] || die "--worktree 가 없다: '$wt'"
[ -z "$closes" ] || [[ $closes =~ ^[0-9]+$ ]] || die "--closes 는 번호다: $closes"
for c in ${carries[@]+"${carries[@]}"}; do
  git -C "$wt" rev-parse -q --verify "${c%%"$nl"*}^{commit}" >/dev/null || die "--carry 가 커밋이 아니다: ${c%%"$nl"*}"
done
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

# 증거 판정: 시험 결과를 PR HEAD 의 것으로 받을 수 있나. PR 결함이 아니므로 fails 에 세지 않는다
k=0
for v in ${verdicts[@]+"${verdicts[@]}"}; do
  k=$((k + 1)); log=${v%%=*} want=${v#*=}; want=${want//\{sha\}/$head}; label="verdict#$k $log"
  if [ ! -r "$log" ]; then echo "RERUN $label: 로그를 읽지 못했다"; continue; fi
  hit=$(grep -F -m1 -- "$want" "$log")
  [ -n "$hit" ] && echo "EVIDENCE OK $label: $hit" || echo "RERUN $label: '$want' 가 든 줄이 없다"
done
# carry 의 diff: rename 을 옛 경로와 새 경로로 가르고(--no-renames), 비ASCII 경로를 글자 그대로 낸다
cdiff() { git -C "$wt" -c core.quotePath=false diff --no-renames "$@"; }
k=0
for c in ${carries[@]+"${carries[@]}"}; do
  k=$((k + 1)); from=$(git -C "$wt" rev-parse "${c%%"$nl"*}^{commit}"); label="carry#$k ${from:0:12}"
  eres=()
  case $c in *"$nl"*) while IFS= read -r e; do eres+=(-e "$e"); done <<<"${c#*"$nl"}" ;; esac
  changed=$(cdiff --name-only "$from" HEAD)
  if [ -z "$changed" ]; then echo "EVIDENCE OK $label: tree 가 같다"; continue; fi
  if [ ${#eres[@]} -gt 0 ]; then
    out=$(printf '%s\n' "$changed" | grep -vE "${eres[@]}")
    # 인자 검사가 틀린 ERE 를 이미 막으므로 시험으로는 닿지 않는다. grep 구현 차이에 대비한 방어다
    [ $? -le 1 ] || { echo "RERUN $label: --may-touch 를 대조하지 못했다"; continue; }
  else out=$changed; fi
  if [ -z "$out" ]; then
    stat=$(cdiff --stat "$from" HEAD | tail -1 | sed 's/^ *//')
    echo "EVIDENCE OK $label: $stat"
  else
    n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    more=''; [ "$n" -le 5 ] || more=" 외 $((n - 5))개"
    list=$(printf '%s\n' "$out" | head -5 | tr '\n' ' ')
    echo "RERUN $label: --may-touch 밖 경로 ${list% }$more"
  fi
done

if [ "$fails" = 0 ]; then echo "SHAPE OK"; exit 0; fi
echo "SHAPE FAIL"; exit 1
