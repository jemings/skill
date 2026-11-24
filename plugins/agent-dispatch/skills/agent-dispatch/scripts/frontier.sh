#!/usr/bin/env bash
# frontier.sh -- 실행 범위의 열린 이슈를 가른다(agent-dispatch 0, 1, 8단계). 범위 질의와 담당 필터를 한 곳에 둔다.
#
#   frontier.sh --repo O/R --map M [--me LOGIN | --anyone]
#   frontier.sh --repo O/R --query 'Q' [--me LOGIN | --anyone]
#
#   --map M      지도 이슈 M 의 sub-issue 가 범위다
#   --query Q    검색 조건 Q(라벨, 작성자, 제목 등. 상태 라벨은 넣지 않는다)에 맞는 열린 이슈가 범위다
#   --me LOGIN   담당 필터의 사용자(기본: gh api user). 담당 = assignee 가 없고 LOGIN 이 등록했거나, LOGIN 이 assignee 다
#   --anyone     담당 필터를 끈다(사람이 조건에 담당을 직접 정했을 때)
#
# 출력(열린 이슈마다 한 줄, 탭으로 나눈다): <종류> #<N> <라벨,라벨> <제목> [<담당 밖이면: 등록 login, assignee login|없음>]
#   READY     담당이고 열린 blocked_by 가 없다 -- frontier 후보(needs-triage, 또는 PR 없는 ready-for-agent)
#   BLOCKED   담당인데 열린 blocked_by 가 있다
#   OTHERS    담당 밖(등록 <login>, assignee <login|없음>) -- 지도 실행의 마지막 보고에 적는다
# 첫 줄은 "# me=<LOGIN>" 이다. exit 0, 조회 실패 1, 인자가 틀리면 2.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다.
# 필요한 것: bash, gh, jq.
set -uo pipefail

die() { echo "frontier: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }

repo='' map='' query='' me='' anyone=0
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:-}; shift 2 ;;
    --map) map=${2:-}; shift 2 ;;
    --query) query=${2:-}; shift 2 ;;
    --me) me=${2:-}; shift 2 ;;
    --anyone) anyone=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "모르는 인자: $1" ;;
  esac
done
[[ $repo =~ ^[^/]+/[^/]+$ ]] || die "--repo 는 OWNER/REPO 다: '$repo'"
{ [ -n "$map" ] || [ -n "$query" ]; } && { [ -z "$map" ] || [ -z "$query" ]; } || die "--map 과 --query 가운데 하나만 줘라"
[ -z "$map" ] || [[ $map =~ ^[0-9]+$ ]] || die "--map 은 번호다: $map"
[ "$anyone" = 0 ] || [ -z "$me" ] || die "--me 와 --anyone 은 함께 줄 수 없다"
if [ "$anyone" = 0 ] && [ -z "$me" ]; then
  me=$(gh api user --jq .login) || { echo "frontier: gh api user 실패" >&2; exit 1; }
fi
echo "# me=${me:-*}"

classify='
  def mine: ($me == "") or (((.assignees|length)==0 and .user.login==$me) or any(.assignees[]; .login==$me));
  select(.state=="open") |
  [ (if mine then (if (.issue_dependencies_summary.blocked_by // 0) > 0 then "BLOCKED" else "READY" end) else "OTHERS" end),
    "#\(.number)", ([.labels[].name]|join(",")), .title ]
  + (if mine then [] else ["등록 \(.user.login), assignee \(if (.assignees|length)==0 then "없음" else ([.assignees[].login]|join(",")) end)"] end)
  | @tsv'

if [ -n "$map" ]; then
  raw=$(gh api --paginate "repos/$repo/issues/$map/sub_issues?per_page=100") || { echo "frontier: sub_issues 조회 실패" >&2; exit 1; }
  printf '%s\n' "$raw" | jq -r --arg me "$me" ".[] | $classify" || { echo "frontier: 응답을 읽지 못했다" >&2; exit 1; }
else
  raw=$(gh api -X GET --paginate search/issues -f q="repo:$repo is:issue is:open $query" -F per_page=100) || { echo "frontier: 검색 실패" >&2; exit 1; }
  printf '%s\n' "$raw" | jq -r --arg me "$me" ".items[] | $classify" || { echo "frontier: 응답을 읽지 못했다" >&2; exit 1; }
fi
