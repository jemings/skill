#!/usr/bin/env bash
# frontier.sh -- 실행 범위의 열린 이슈를 가른다(agent-dispatch 1, 9단계). 범위 질의와 담당 필터를 한 곳에 둔다.
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
#   READY     담당이고 열린 blocked_by 링크도, 열린 본문 선행도 없다 -- frontier 후보(needs-triage, 또는 PR 없는 ready-for-agent)
#   BLOCKED   담당인데 열린 blocked_by 링크가 있거나, 본문 맨 앞의 선행 줄이 가리키는 이슈가 열려 있다
#             본문 선행이면 5열에 사유를 쓴다: "선행 #N(본문)", 여럿이면 "선행 #1 #2(본문)", 다른 저장소는 o/r#N.
#             blocked_by 링크가 하나도 없으면 사유 뒤에 ", 링크 없음" 이 붙는다. 링크로만 막힌 행은 4열이다
#   OTHERS    담당 밖(등록 <login>, assignee <login|없음>) -- 지도 실행의 마지막 보고에 적는다
# 첫 줄은 "# me=<LOGIN>" 이다. exit 0, 조회 실패 1, 인자가 틀리면 2.
#
# 본문 선행: 열려 있고 담당인 이슈의 본문만 본다(OTHERS, 닫힌 이슈는 보지 않는다). 본문의 첫 비어 있지 않은 5줄 가운데
# 앞의 비문자 접두(장식 기호, -, >, ** 등)를 건너뛴 뒤 "선행" 또는 "Blocked by"(b/B)로 시작하고 ":" 가 따르는 줄에서
# #N 과 owner/repo#N 을 모두 모은다(여러 줄이면 합집합, 자기 번호는 뺀다. "선행: 없음"(또는 none, 대소문자 무관)으로 시작하는 줄은 뒤에 #N 이 있어도 빈 집합).
# 참조마다 gh issue view 로 상태를 한 번씩 묻고 OPEN 인 것만 막는다(CLOSED, MERGED 는 풀림).
# 저장소 이름은 대소문자를 가리지 않고(O/R#1 과 #1 은 같다), 나열은 저장소, 번호(숫자) 순이다.
# 다른 저장소 참조는 소문자로 내고 조회도 소문자 저장소로 한다(GitHub 은 대소문자를 가리지 않는다).
# 같은 줄의 다른 #N 도 모두 선행으로 모은다(단 "없음"/none 으로 시작하는 줄은 예외다).
# 하나라도 조회가 실패하면 "frontier: 선행 #N 조회 실패" 를 stderr 에 내고 exit 1 이다.
# 지원하지 않는 것: 6번째 줄 이후의 선행, "선행:" 다음 줄의 목록형(- #1), URL 참조, docs/a.md#5 처럼 슬래시가 든 경로 조각도 저장소 참조로 읽어 조회 실패면 exit 1, 코드 펜스 구분(펜스 안의 "선행:" 도 5줄 안이면 읽는다), 선행의 선행(transitive),
# 순환(서로 선행이면 영원히 BLOCKED).
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

if [ -n "$map" ]; then
  raw=$(gh api --paginate "repos/$repo/issues/$map/sub_issues?per_page=100") || { echo "frontier: sub_issues 조회 실패" >&2; exit 1; }
  sel='.[]'
else
  raw=$(gh api -X GET --paginate search/issues -f q="repo:$repo is:issue is:open $query" -F per_page=100) || { echo "frontier: 검색 실패" >&2; exit 1; }
  sel='.items[]'
fi

defs='
  def mine: ($me == "") or (((.assignees|length)==0 and .user.login==$me) or any(.assignees[]; .login==$me));
  def prereqs: . as $i | ($repo|ascii_downcase) as $me_repo
    | [ (.body // "") | split("\n")[] | select(test("\\S")) ] | .[:5]
    | [ .[] | select(test("^[^\\p{L}\\p{N}]*(선행|[Bb]locked [Bb]y)[*_\\s]*:"))
        | select(test("^[^\\p{L}\\p{N}]*(선행|[Bb]locked [Bb]y)[*_\\s]*:[*_\\s]*(없음|[Nn][Oo][Nn][Ee])(?![\\p{L}\\p{N}])") | not) | scan("(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+")
        | index("#") as $h | { r: (.[:$h] | if . == "" then $me_repo else ascii_downcase end), n: (.[$h+1:] | tonumber) } ]
    | map(select(.r != $me_repo or .n != $i.number)) | unique_by([.r, .n]) | map("\(.r)#\(.n)");'

# 본문 선행 참조(owner/repo#N)를 모아 상태를 한 번씩 묻는다
refs=$(printf '%s\n' "$raw" | jq -r --arg me "$me" --arg repo "$repo" "$defs $sel | select(.state==\"open\" and mine) | prereqs[]" | sort -u) || { echo "frontier: 응답을 읽지 못했다" >&2; exit 1; }
states='{}'
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  st=$(gh issue view "${ref##*#}" --repo "${ref%#*}" --json state --jq .state 2>/dev/null) && [ -n "$st" ] || { echo "frontier: 선행 #${ref##*#} 조회 실패" >&2; exit 1; }
  states=$(jq -c --arg k "$ref" --arg v "$st" '. + {($k): $v}' <<< "$states")
done <<< "$refs"

classify='
  select(.state=="open") | (.issue_dependencies_summary.blocked_by // 0) as $links
  | (if mine then [prereqs[] | select($st[.] == "OPEN")] else [] end) as $open
  | [ (if mine then (if $links > 0 or ($open|length) > 0 then "BLOCKED" else "READY" end) else "OTHERS" end),
    "#\(.number)", ([.labels[].name]|join(",")), .title ]
  + (if mine then [] else ["등록 \(.user.login), assignee \(if (.assignees|length)==0 then "없음" else ([.assignees[].login]|join(",")) end)"] end)
  + (if ($open|length) > 0 then ["선행 \($open | map(if startswith(($repo|ascii_downcase) + "#") then .[($repo|length):] else . end) | join(" "))(본문)\(if $links == 0 then ", 링크 없음" else "" end)"] else [] end)
  | @tsv'

printf '%s\n' "$raw" | jq -r --arg me "$me" --arg repo "$repo" --argjson st "$states" "$defs $sel | $classify" || { echo "frontier: 응답을 읽지 못했다" >&2; exit 1; }
