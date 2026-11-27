#!/usr/bin/env bash
# in-flight.sh -- 이슈가 이미 누군가의 손에 있는지 본다(agent-dispatch 1, 5, 6단계). 저장소 체크아웃 안에서 돌린다.
# --peers 는 같은 저장소에서 일하는 다른 세션을 찾는다(1단계 "저장소 도구를 공용화한다").
# --agent 는 서브에이전트가 정체했는지 본다(6, 7단계 감시). --where 처럼 git, gh, 체크아웃 없이 돈다.
#
#   in-flight.sh [--repo owner/repo] <N>...          판정
#   in-flight.sh --claim [--repo owner/repo] <N>...  이 세션이 맡았다고 표시한다(같은 PC 의 다른 agent-dispatch 가 본다)
#   in-flight.sh --release [--repo owner/repo] <N>... 표시를 거둔다
#   in-flight.sh --peers [--repo owner/repo]         같은 저장소에서 일하는 살아 있는 다른 세션
#   in-flight.sh --where                             이 스크립트가 플러그인에서 도는지, 낡은 사본에서 도는지(0단계)
#   in-flight.sh --agent <id> [--path <p>]... [--idle-min N] [--after T] [--wait [--interval S]]
#                                                    그 서브에이전트가 일하는가, 정체했는가
#
# 판정(이슈마다 한 줄, 근거는 그 아래 들여 쓴 줄):
#   BUSY   살아 있는 다른 세션의 작업 디렉터리(cwd)가 그 이슈의 worktree 이거나, 그 세션이 맡았다고 표시했거나, 열린 PR 이 있다
#   MAYBE  다른 살아 있는 세션이 그 worktree 경로로 명령을 돌렸거나, 그 세션의 사람 지시에 #N 이 나온다 -- 그 세션에 물어 확인한다
#   HELD   이슈 번호가 든 worktree, 브랜치가 남아 있는데 그 자리에서 일하는 세션은 없다 -- 남은 것을 들여다본다
#   FREE   위 어느 것도 없다
#
# --peers(세션마다 한 줄 "이름<TAB>근거", 없으면 "(없음)", exit 0. 자기 세션은 뺀다). 근거는 "; " 로 잇는다:
#   세션 파일 cwd <경로>   세션 파일의 cwd 가 git worktree list 의 경로와 같거나 그 아래다
#   기록 cwd <경로>        세션 기록의 cwd 가 그렇다(그 가운데 마지막 것)
#   claim #N              그 세션이 이 저장소의 #N 을 맡았다고 표시했다
#
# --where(읽기 전용. 인자를 받지 않고 git, gh, repo 없이 돈다. 언제나 exit 0, 인자를 주면 exit 2). 줄 단위로 낸다:
#   WHERE plugin|copy <경로>               이 스킬 디렉터리(심볼릭 링크를 푼 실제 경로)가 설치된 플러그인 안인가
#   INSTALLED <키> <version> <installPath>  $CFG/plugins/installed_plugins.json 의 agent-dispatch@* 항목마다
#   VERDICT <값>                           PLUGIN 플러그인 / SAME 사본이고 SKILL.md 가 설치본과 같다 /
#                                          STALE 사본이고 설치본과 SKILL.md 가 다르다 / NONE 사본이고 설치본이 없다 /
#                                          UNKNOWN JSON 이 깨졌거나 jq 가 없다
#
# --agent(한 줄 "<판정> <id> <분> <가장 늦은 흔적>", 근거는 그 아래 들여 쓴 줄. 판정은 exit 0, 인자 오류는 exit 2).
# 흔적은 셋이다: 그 agent 의 기록 $CFG/projects/<proj>/<세션 id>/subagents/agent-<id>.jsonl, 그 기록에
# "Output is being written to: <경로>.output" 으로 나온 task 출력 파일(그 agent 의 것만, 공용 tasks 디렉터리는 보지 않는다),
# --path 아래 파일(node_modules, .git 은 뺀다). 기록은 `subagents/` 바로 아래 기록만 본다(더 깊은 workflow 기록은 UNKNOWN).
# 경로 속 줄바꿈은 근거 줄에서 \n 두 글자로 보인다. 한계: 이름 속 줄바꿈 바로 뒤가 <숫자><공백><글자> 이면 따로 된 흔적 행으로 읽히고,
# 이름 속 빈 줄과 끝 줄바꿈은 근거 줄에서 사라진다(이름으로 흔적을 위조할 수 있다. 우연한 이름을 위한 처리이고 악의적 이름은 막지 않는다.
# 위조는 정체를 늦게 알릴 뿐 WORKING 을 STALLED 로 바꾸지 않는다).
# 분은 기준 시각에서 지금까지다. 기준 시각은 가장 늦은 흔적의 mtime 이고, --after T(epoch 초, 깨운 시각)가 그보다
# 늦으면 T 다. 그때 흔적 칸은 그대로 가장 늦은 흔적이고 근거 줄에 "기준 시각" 이 나온다.
# 시계 차이 허용 오차는 300초다: mtime 이 지금과 지금+300 사이인 흔적은 지금으로 깎아 쓰고, 그보다 늦은 흔적은 판정에서 뺀다.
#   WORKING  기준 시각이 --idle-min 분(기본 15) 안이다
#   STALLED  흔적이 모두 --idle-min 분 넘게 그대로다(정체. --after 를 주면 그 시각부터도). 살아 있는 프로세스나 기다림 루프가 있어도 정체다
#   UNKNOWN  그 id 의 기록이 없거나, 판정할 흔적이 없다(모두 지금+300 보다 미래). 분과 흔적 자리는 -, 이유는 근거 줄
#   근거 줄(판정을 바꾸지 않는다): 가장 늦은 흔적 <시각> <경로> / 기준 시각 <시각> (--after) / 기록 <경로> /
#     기록이 없다: <경로 꼴> / 판정할 흔적이 없다(...) /
#     출력 파일 <n>개, 가장 늦은 것 <시각> <경로> 또는 출력 파일을 찾지 못했다 / 경로가 없다: <--path> /
#     프로세스 <pid> <경과> <명령>(--path 를 인자에 담은 살아 있는 프로세스, 이 스크립트는 뺀다) /
#     API 오류 <error> <첫 줄>(기록의 마지막 assistant 기록이 API 오류 표식 isApiErrorMessage 일 때) /
#     미래 시각 흔적 <시각> <경로>(지금+300 보다 늦어 판정에서 뺀 흔적) /
#     깨움 뒤 응답 <시각> / 깨움 뒤 응답 없음 / 깨움 뒤 응답 판정 불가(<이유>)(--after 를 줄 때만. 응답은 기록의 type
#     assistant 줄 가운데 timestamp 가 --after 이후인 마지막 것. timestamp 는 줄마다 해석한다. 응답이 없는데 timestamp 를
#     읽지 못한 assistant 기록(없음 포함)이 있거나 기록을 읽지 못하면 판정 불가다. 하네스는 SendMessage 도 기록에
#     type user 줄로 남기므로 기록 mtime 으로는 반응을 가리지 못한다)
#   --wait 는 --interval 초(기본 60)마다 다시 판정해 STALLED 나 UNKNOWN 이 되면 그 판정을 내고 끝난다. WORKING 동안은 내지 않는다.
#   --after 가 지금과 지금+300 사이면 지금으로 깎는다.
#   인자 오류: 숫자만인 id(이슈 번호 꼴), - 로 시작하는 id, 6자리 안의 양의 정수가 아닌 --idle-min, --interval,
#     12자리 안의 양의 정수가 아닌 --after, 지금+300 보다 늦은 --after, --wait 없는 --interval,
#     이슈 번호, --repo, --claim, --release, --peers, --where 와 섞기,
#     --agent 없는 --path, --idle-min, --after, --wait, --interval
#
# 근거: ~/.claude/sessions/<pid>.json(살아 있는 세션 -- pid 와 procStart 로 확인), 그 세션 기록
# ~/.claude/projects/*/<sessionId>.jsonl 의 cwd, 사람 지시, git worktree, 브랜치, gh 의 열린 PR.
# 세션 파일의 cwd 는 기동 디렉터리라 worktree 로 옮겨 간 세션을 가리지 못한다 -- 그래서 기록의 cwd 를 본다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다 -- 헤더 안에 빈 줄이나 비주석 줄을 두면 거기서 끊긴다.
# 필요한 것: bash 4+, jq, git, gh(--agent 는 jq 만).
set -euo pipefail

die() { echo "in-flight: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SESS=$CFG/sessions
PROJ=$CFG/projects
CLAIMS=$CFG/agent-dispatch/claims
TAIL=${IN_FLIGHT_TAIL:-600}   # 세션 기록에서 "최근"으로 볼 줄 수

mode=check repo=
has_agent=0 agent= paths=() idle_min=15 after=0 wait_mode=0 interval=60 interval_given=0 agent_only=
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:?}; shift 2 ;;
    --agent|--path|--idle-min|--after|--interval)
      [ $# -ge 2 ] || die "$1 에 값을 줘라"
      case $1 in
        --agent) has_agent=1 agent=$2 ;;
        --path) paths+=("$2") agent_only=$1 ;;
        --idle-min) idle_min=$2 agent_only=$1 ;;
        --after) [[ $2 =~ ^[1-9][0-9]{0,11}$ ]] || die "--after 는 12자리 안의 양의 정수(epoch 초)다: '$2'"; after=$2 agent_only=$1 ;;
        --interval) interval=$2 interval_given=1 agent_only=$1 ;;
      esac
      shift 2 ;;
    --wait) wait_mode=1 agent_only=$1; shift ;;
    --claim) mode=claim; shift ;;
    --release) mode=release; shift ;;
    --peers) mode=peers; shift ;;
    --where) mode=where; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "모르는 옵션: $1" ;;
    *) break ;;
  esac
done

# ---- --agent: 서브에이전트가 정체했는가. git, gh 없이 돈다 ----
# 흔적 행은 "<mtime 초> <경로>" 다. GNU stat 은 -c, BSD(macOS) stat 은 -f 를 쓴다
if stat -c %Y / >/dev/null 2>&1; then stat_opt=-c stat_fmt='%Y %n'; else stat_opt=-f stat_fmt='%m %N'; fi
CLOCK_SKEW=300   # 시계 차이 허용 오차(초)
latest_row() { sort -n -k1,1 | tail -n 1; }
stat_rows() { [ $# = 0 ] || stat "$stat_opt" "$stat_fmt" "$@" 2>/dev/null || true; }
# 흔적 행을 지금($1) 기준의 도메인 값으로 바꾼다: 허용 오차 안의 미래는 지금으로 깎고, 그보다 늦은 행은 앞에 "F " 를 단다
clamp_rows() {
  awk -v now="$1" -v skew="$CLOCK_SKEW" 'function flush() { if (have) print out; have = 0 }
    NF == 0 { next }
    !($1 ~ /^[0-9]+$/ && NF >= 2) { if (have) out = out "\\n" $0; next }
    { flush(); have = 1
      if ($1 > now + skew) out = "F " $0
      else if ($1 > now) out = now substr($0, length($1) + 1)
      else out = $0 }
    END { flush() }'
}
usable_rows() { awk 'NF && $1 != "F"'; }
fmt_time() { jq -rn --argjson t "$1" '$t | strflocaltime("%Y-%m-%d %H:%M")'; }
verdict_for_age() { if [ "$1" -lt $(( idle_min * 60 )) ]; then echo WORKING; else echo STALLED; fi; }

# 하네스는 백그라운드 실행마다 기록에 "Output is being written to: <task 출력>.output" 을 남긴다. 있는 파일만 낸다
task_outputs() {
  { grep -oE 'Output is being written to: [^"[:space:]\\]+\.output' "$1" || true; } \
    | sed 's/^Output is being written to: //' | sort -u \
    | while IFS= read -r o; do if [ -f "$o" ]; then printf '%s\n' "$o"; fi; done
}
# --path 아래 파일의 흔적 행(의존성, git 내부는 빼고)
path_rows() {
  local p q
  for p in ${paths[@]+"${paths[@]}"}; do
    [ -e "$p" ] || continue
    case $p in /*) q=$p ;; *) q=./$p ;; esac
    find "$q" \( -name node_modules -o -name .git \) -prune -o -type f -print0 2>/dev/null | xargs -0 stat "$stat_opt" "$stat_fmt" 2>/dev/null || true
  done
}
# --path 를 인자에 담은 살아 있는 프로세스. 감시(이 스크립트) 자신은 뺀다
procs_on_paths() {
  [ ${#paths[@]} -gt 0 ] || return 0
  ps -ax -o pid=,etime=,args= 2>/dev/null | IF_PATHS=$(printf '%s\n' ${paths[@]+"${paths[@]}"}) awk -v self="${0##*/}" '
    function names(s, p,   i, c) {
      while ((i = index(s, p)) > 0) {
        c = substr(s, i + length(p), 1)
        if (c !~ /[A-Za-z0-9._-]/) return 1
        s = substr(s, i + 1)
      }
      return 0
    }
    BEGIN { n = split(ENVIRON["IF_PATHS"], P, "\n") }
    index($0, self) { next }
    {
      for (i = 1; i <= n; i++) if (P[i] != "" && names($0, P[i])) {
        args = $0; sub(/^ *[0-9]+ +[^ ]+ +/, "", args)
        print "프로세스 " $1 " " $2 " " args; next
      }
    }' || true
}
# 기록 끝의 마지막 assistant 기록이 API 오류 표식(isApiErrorMessage)이면 "<error> <첫 줄>"
api_error() {
  tail -n 200 "$1" | jq -R -n -r '[inputs | fromjson? | select(.type == "assistant")] | last
    | select(. != null and .isApiErrorMessage == true)
    | "\(.error // "-") \(.message.content | if type == "array" then (map(.text? // empty) | join(" ")) else tostring end | split("\n")[0])"' \
    2>/dev/null || true
}
# 하네스는 SendMessage 도 그 agent 의 기록에 type user 줄로 남긴다. 그래서 깨운 뒤의 반응은 기록 mtime 이 아니라
# assistant 기록의 timestamp(ISO 8601 UTC, 밀리초가 붙을 수 있다)로 본다. timestamp 는 줄마다 해석한다.
# 출력 "<$2 이후인 마지막 assistant 기록의 epoch 초|-> <timestamp 를 읽지 못한 assistant 기록 수>". 기록을 못 읽으면 exit 0 이 아니다
reply_since() {
  jq -R -n -r --argjson since "$2" '[inputs | fromjson? | objects | select(.type == "assistant") | .timestamp
    | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
      then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end] as $ts
    | "\([$ts[] | numbers | select(. >= $since)] | last // "-") \([$ts[] | nulls] | length)"' "$1"
}

judge_agent() {
  local log now out_rows rows row t latest base age verdict mins o p err n
  local -a outs=() ev=()
  log=$(find "$PROJ" -mindepth 4 -maxdepth 4 -path "*/subagents/agent-$agent.jsonl" -print -quit 2>/dev/null || true)
  if [ -z "$log" ]; then
    printf 'UNKNOWN %s - -\n    기록이 없다: %s\n' "$agent" "$PROJ/*/*/subagents/agent-$agent.jsonl"
    return
  fi
  while IFS= read -r o; do outs+=("$o"); done < <(task_outputs "$log")
  now=$(date +%s)
  out_rows=$(stat_rows ${outs[@]+"${outs[@]}"} | clamp_rows "$now")
  rows=$({ stat_rows "$log"; path_rows; } | clamp_rows "$now"; printf '%s\n' "$out_rows")
  row=$(printf '%s\n' "$rows" | usable_rows | latest_row)
  if [ -z "$row" ]; then
    verdict=UNKNOWN mins=- latest=-
    ev+=("판정할 흔적이 없다(지금보다 ${CLOCK_SKEW}초 넘게 미래인 흔적은 뺀다)")
  else
    read -r t latest <<<"$row"
    base=$t
    [ "$after" -le "$t" ] || base=$after
    age=$(( now - base ))
    verdict=$(verdict_for_age "$age") mins=$(( age / 60 ))
    ev+=("가장 늦은 흔적 $(fmt_time "$t") $latest")
    [ "$base" = "$t" ] || ev+=("기준 시각 $(fmt_time "$base") (--after)")
  fi
  ev+=("기록 $log")
  if [ ${#outs[@]} = 0 ]; then ev+=("출력 파일을 찾지 못했다")
  else
    row=$(printf '%s\n' "$out_rows" | usable_rows | latest_row)
    if [ -z "$row" ]; then ev+=("출력 파일 ${#outs[@]}개")
    else read -r t o <<<"$row"; ev+=("출력 파일 ${#outs[@]}개, 가장 늦은 것 $(fmt_time "$t") $o"); fi
  fi
  while read -r _ t o; do ev+=("미래 시각 흔적 $(fmt_time "$t") $o"); done < <(printf '%s\n' "$rows" | awk '$1 == "F"')
  for p in ${paths[@]+"${paths[@]}"}; do [ -e "$p" ] || ev+=("경로가 없다: $p"); done
  while IFS= read -r p; do ev+=("$p"); done < <(procs_on_paths)
  err=$(api_error "$log"); [ -z "$err" ] || ev+=("API 오류 $err")
  if [ "$after" != 0 ]; then
    o=$(reply_since "$log" "$after") || o=
    read -r t n <<<"$o"
    if [ -z "$t" ]; then ev+=("깨움 뒤 응답 판정 불가(기록을 읽지 못했다)")
    elif [ "$t" != - ]; then ev+=("깨움 뒤 응답 $(fmt_time "$t")")
    elif [ "$n" != 0 ]; then ev+=("깨움 뒤 응답 판정 불가(timestamp 를 읽지 못한 assistant 기록 ${n}개)")
    else ev+=("깨움 뒤 응답 없음"); fi
  fi

  printf '%s %s %s %s\n' "$verdict" "$agent" "$mins" "$latest"
  printf '    %s\n' ${ev[@]+"${ev[@]}"}
}

if [ $has_agent = 1 ]; then
  [ "$mode" = check ] && [ -z "$repo" ] && [ $# = 0 ] \
    || die "--agent 는 이슈 번호, --repo, --claim, --release, --peers, --where 와 함께 쓰지 않는다"
  [[ $agent =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] && ! [[ $agent =~ ^[0-9]+$ ]] \
    || die "--agent 에는 agent id 를 준다(이슈 번호 꼴도, - 로 시작하는 옵션도 아니다): '$agent'"
  for v in "$idle_min" "$interval"; do [[ $v =~ ^[1-9][0-9]{0,5}$ ]] || die "--idle-min, --interval 은 6자리 안의 양의 정수다: '$v'"; done
  now=$(date +%s)
  [ "$after" -le $(( now + CLOCK_SKEW )) ] || die "--after 가 지금보다 ${CLOCK_SKEW}초 넘게 늦다: $after"
  [ "$after" -le "$now" ] || after=$now
  [ $interval_given = 0 ] || [ $wait_mode = 1 ] || die "--interval 은 --wait 와 함께 쓴다"
  command -v jq >/dev/null || die "jq 가 필요하다"
  while :; do
    block=$(judge_agent)
    if [ $wait_mode = 0 ] || [ "${block%% *}" != WORKING ]; then printf '%s\n' "$block"; exit 0; fi
    sleep "$interval"
  done
fi
[ -z "$agent_only" ] || die "$agent_only 는 --agent 와 함께 쓴다"

# --where: 이슈, repo, gh, jq 에 기대지 않는 점검이라 다른 검사보다 앞에서 끝낸다
if [ "$mode" = where ]; then
  [ $# = 0 ] && [ -z "$repo" ] || die "--where 는 인자를 받지 않는다: $*"
  D=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
  entries= verdict=
  if [ ! -f "$CFG/plugins/installed_plugins.json" ]; then verdict=NONE
  elif ! command -v jq >/dev/null 2>&1; then verdict=UNKNOWN
  elif entries=$(jq -r '(.plugins // {}) | to_entries[] | select(.key | startswith("agent-dispatch@"))
                        | .key as $k | .value[] | "\($k)\u001f\(.version // "")\u001f\(.installPath // "")"' \
                      "$CFG/plugins/installed_plugins.json" 2>/dev/null); then
    [ -n "$entries" ] || verdict=NONE
  else entries= verdict=UNKNOWN
  fi
  where=copy
  if [ -z "$verdict" ]; then
    verdict=STALE
    # 구분자는 공백류가 아닌 \037 이라야 빈 version 이나 installPath 가 칸을 밀지 않는다
    while IFS=$'\037' read -r k v ip; do
      [ -n "$ip" ] || continue
      P=$(CDPATH= cd -- "$ip/skills/agent-dispatch" 2>/dev/null && pwd -P) || continue
      if [ "$P" = "$D" ]; then where=plugin verdict=PLUGIN; break; fi
      [ "$verdict" = SAME ] || ! cmp -s "$D/SKILL.md" "$P/SKILL.md" 2>/dev/null || verdict=SAME
    done <<<"$entries"
  fi
  echo "WHERE $where $D"
  [ -z "$entries" ] || while IFS=$'\037' read -r k v ip; do echo "INSTALLED $k ${v:--} $ip"; done <<<"$entries"
  echo "VERDICT $verdict"
  exit 0
fi

if [ "$mode" = peers ]; then [ $# = 0 ] || die "--peers 는 이슈 번호를 받지 않는다: $*"
else [ $# -gt 0 ] || { usage >&2; exit 2; }; fi
for n; do [[ $n =~ ^[0-9]+$ ]] || die "이슈 번호가 아니다: $n"; done
command -v jq >/dev/null || die "jq 가 필요하다"
[ -n "$repo" ] || repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "--repo 를 줘라"
key=${repo//\//_}

# 프로세스가 살아 있고, 세션 파일을 쓴 그 프로세스인가(pid 재사용 배제 -- /proc 가 있을 때만 starttime 대조)
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$2" != - ] && [ -r "/proc/$1/stat" ] || return 0
  [ "$(sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}')" = "$2" ]
}

# 이 세션: 조상 프로세스 가운데 세션 파일이 있는 첫 것
self_pid=
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  [ -f "$SESS/$p.json" ] && { self_pid=$p; break; }
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
done

if [ "$mode" = claim ] || [ "$mode" = release ]; then
  [ -n "$self_pid" ] || die "이 프로세스의 Claude Code 세션을 찾지 못했다"
  mkdir -p "$CLAIMS"
  for n; do
    f="$CLAIMS/${key}_$n.json"
    if [ "$mode" = claim ]; then
      # 같은 디렉터리의 임시 파일에 쓴 뒤 rename -- 읽는 쪽이 0바이트나 쓰다 만 파일을 보지 않는다.
      # 점으로 시작해 --peers 의 "${key}_*.json" 과 판정의 "${key}_$n.json" 어느 쪽에도 걸리지 않는다.
      [ ! -d "$f" ] || die "표시 자리가 디렉터리다: $f"
      t=$(mktemp "$CLAIMS/.${key}_$n.XXXXXX")
      # .pid 가 없는 세션 파일(0바이트, {})은 jq 가 exit 0 으로 빈 claim 이나 pid null 을 낸다 -- -e 와 select 로 막는다
      jq -e 'select(.pid != null) | {pid, procStart: (.procStart // "-"), name, sessionId}' "$SESS/$self_pid.json" > "$t" || { rm -f "$t"; die "세션 파일을 읽지 못해 #$n 을 표시하지 못했다: $SESS/$self_pid.json"; }
      mv -f "$t" "$f"
      echo "claimed #$n"
    else
      rm -f "$f"; echo "released #$n"
    fi
  done
  exit 0
fi

command -v git >/dev/null || die "git 이 필요하다"
[ "$mode" = peers ] || git fetch -q --prune origin 2>/dev/null || true

# 살아 있는 다른 세션: 이름, pid, 최근 cwd 목록(세션 파일 .scwd, 기록 .tcwd, 둘을 합친 .cwd), 최근 기록 원문, 사람 지시
# -- 임시 파일에 한 번만 뽑아 둔다
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
names=() pids=()
for f in "$SESS"/*.json; do
  [ -e "$f" ] || continue
  IFS=$'\t' read -r pid pstart name sid < <(jq -r '[.pid, .procStart, .name, .sessionId] | map(if . == null or . == "" then "-" else . end) | @tsv' "$f") || continue
  [ "$pid" = "$self_pid" ] && continue
  alive "$pid" "$pstart" || continue
  i=${#names[@]}; names+=("$name"); pids+=("$pid")
  jq -r '.cwd // empty' "$f" > "$tmp/$i.scwd"
  : > "$tmp/$i.tcwd"
  t=$(find "$PROJ" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null)
  : > "$tmp/$i.cmd"; : > "$tmp/$i.ask"
  if [ -n "$t" ]; then
    tail -n "$TAIL" "$t" > "$tmp/$i.tail"
    jq -R -r 'fromjson? | .cwd // empty' "$tmp/$i.tail" > "$tmp/$i.tcwd"
    # 그 세션이 돌린 도구 입력(명령, 경로). 도구 결과는 넣지 않는다 -- `git worktree list` 같은 출력이 모든 경로를 담는다
    jq -R -r 'fromjson? | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .input | tostring' \
      "$tmp/$i.tail" > "$tmp/$i.cmd" 2>/dev/null || true
    # 사람이 친 지시만: 사이드체인, 도구 결과, 다른 세션의 메시지, 시스템 알림은 뺀다
    jq -R -r 'fromjson? | select(.type == "user" and (.isSidechain | not))
      | .message.content
      | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end
      | select(length > 0 and (startswith("<") | not)
               and (test("^(Another Claude session|\\[SYSTEM NOTIFICATION|\\[Subagent hand-back)") | not))' \
      "$t" > "$tmp/$i.ask" 2>/dev/null || true
  fi
  sort -u "$tmp/$i.scwd" "$tmp/$i.tcwd" > "$tmp/$i.cwd"
done

# $1 파일에 경로 $2 와 같거나 그 아래인 줄이 있나(1193-deps 와 1193-deps-main 을 가른다)
has_path() { awk -v p="$2" '$0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }' "$1"; }
# $1 파일에 경로 $2 가 이름이 끝나는 자리에서 나오나(뒤가 이름 글자가 아니다)
mentions_path() {
  awk -v p="$2" '{
    s = $0
    while ((i = index(s, p)) > 0) {
      c = substr(s, i + length(p), 1)
      if (c !~ /[A-Za-z0-9._-]/) { f = 1; exit }
      s = substr(s, i + 1)
    }
  } END { exit !f }' "$1"
}

# ---- --peers: 같은 저장소의 다른 세션 ----
if [ "$mode" = peers ]; then
  # set -e 아래에서 파이프로 바로 받으면 git 의 실패(128)로 메시지 없이 끝난다 -- 먼저 받아 이유를 낸다
  wt=$(git worktree list --porcelain 2>/dev/null) || die "git 저장소 안에서 돌려라"
  printf '%s\n' "$wt" | awk '/^worktree /{print substr($0,10)}' > "$tmp/wt"
  [ -s "$tmp/wt" ] || die "git 저장소 안에서 돌려라"
  # 경로 파일 $1 에서 worktree 의 경로와 같거나 그 아래인 마지막 줄(없으면 exit 1)
  last_in_repo() {
    awk 'NR == FNR { w[$0]; next } { for (p in w) if ($0 == p || index($0, p "/") == 1) m = $0 }
         END { if (m == "") exit 1; print m }' "$tmp/wt" "$1"
  }
  # 이 저장소의 claim: "pid<TAB>procStart<TAB>N" (다른 저장소 o/r_x 의 o_r_x_9.json 은 N 이 숫자가 아니라 빠진다)
  : > "$tmp/claims"
  for cf in "$CLAIMS/${key}"_*.json; do
    [ -e "$cf" ] || continue
    cn=${cf##*/}; cn=${cn#"${key}"_}; cn=${cn%.json}
    [[ $cn =~ ^[0-9]+$ ]] || continue
    jq -r --arg n "$cn" '[.pid, .procStart, $n] | map(if . == null or . == "" then "-" else . end) | @tsv' "$cf" >> "$tmp/claims" || true
  done
  sort -t $'\t' -k3,3n -o "$tmp/claims" "$tmp/claims"
  found=0
  for i in "${!names[@]}"; do
    ev=()
    if c=$(last_in_repo "$tmp/$i.scwd"); then ev+=("세션 파일 cwd $c"); fi
    if c=$(last_in_repo "$tmp/$i.tcwd"); then ev+=("기록 cwd $c"); fi
    while IFS=$'\t' read -r cpid cstart cn; do
      [ "$cpid" = "${pids[$i]}" ] && alive "$cpid" "$cstart" && ev+=("claim #$cn")
    done < "$tmp/claims"
    [ ${#ev[@]} -gt 0 ] || continue
    found=1 line=
    for e in ${ev[@]+"${ev[@]}"}; do line+=${line:+; }$e; done
    printf '%s\t%s\n' "${names[$i]}" "$line"
  done
  [ $found = 1 ] || echo '(없음)'
  exit 0
fi

verdict=FREE
up() { case "$verdict:$1" in FREE:*|HELD:MAYBE|HELD:BUSY|MAYBE:BUSY) verdict=$1 ;; esac; }

# set -e 아래에서 파이프로 바로 받으면 git 의 실패(128)로 메시지 없이 끝난다 -- 먼저 받아 이유를 낸다
wt=$(git worktree list --porcelain 2>/dev/null) || die "git 저장소 안에서 돌려라"
wt_lines=$(printf '%s\n' "$wt" | awk '/^worktree /{p=substr($0,10)} /^branch /{print p "\t" substr($0,19)} /^detached/{print p "\t-"}')

for n in "$@"; do
  re="(^|[^0-9])$n([^0-9]|\$)"
  verdict=FREE ev=() skip_refs=()

  # 다른 agent-dispatch 세션의 표시
  cf="$CLAIMS/${key}_$n.json"
  if [ -f "$cf" ]; then
    # 0바이트나 깨진 JSON 이면 읽을 줄이 없다 -- 표시를 읽을 수 없다고 적고 판정은 올리지 않는다(파일은 쓰는 중일 수 있어 지우지 않는다)
    if ! IFS=$'\t' read -r cpid cstart cname < <(jq -r '[.pid, .procStart, .name] | map(if . == null or . == "" then "-" else . end) | @tsv' "$cf" 2>/dev/null); then
      ev+=("claim: 읽을 수 없는 표시 $cf")
    elif [ "$cpid" = "$self_pid" ]; then ev+=("claim: 이 세션");
    elif alive "$cpid" "$cstart"; then up BUSY; ev+=("claim: 세션 $cname 이 맡았다")
    else rm -f "$cf"; ev+=("claim: 죽은 세션 $cname 의 표시를 지웠다"); fi
  fi

  # 열린 PR: 제목의 #N, 이슈 번호가 든 브랜치, 본문의 Closes/Fixes/Resolves #N 이면 그 이슈의 작업이다(BUSY).
  # 본문에 Refs #N 만 있으면 곁가지일 수 있다(그 이슈를 하다 찾은 다른 결함 등) -- MAYBE.
  while IFS=$'\t' read -r kind head line; do
    [ -n "$kind" ] || continue
    skip_refs+=("$head" "origin/$head")
    if [ "$kind" = own ]; then up BUSY; ev+=("$line"); else up MAYBE; ev+=("$line -- Refs 만 있다, 그 이슈의 작업인지 확인"); fi
  done < <(gh pr list --repo "$repo" --state open --limit 100 --search "$n" \
             --json number,title,headRefName,body 2>/dev/null \
           | jq -r --arg n "$n" '.[]
             | ((.title | test("#" + $n + "([^0-9]|$)"))
                or (.headRefName | test("(^|[^0-9])" + $n + "([^0-9]|$)"))
                or (.body // "" | test("(?i)(closes|fixes|resolves) #" + $n + "([^0-9]|$)"))) as $own
             | (.body // "" | test("(?i)refs #" + $n + "([^0-9]|$)")) as $refs
             | select($own or $refs)
             | [(if $own then "own" else "refs" end), .headRefName, "열린 PR #\(.number) [\(.headRefName)] \(.title)"] | @tsv')

  # 이슈 번호가 든 worktree -- 그 안에서 일하는 살아 있는 세션
  wts=()
  while IFS=$'\t' read -r path branch; do
    [ -n "$path" ] || continue
    if [[ $(basename "$path") =~ $re ]] || [[ $branch =~ $re ]]; then wts+=("$path"); skip_refs+=("$branch" "origin/$branch"); fi
  done <<< "$wt_lines"
  for path in ${wts[@]+"${wts[@]}"}; do
    held=1
    for i in "${!names[@]}"; do
      if has_path "$tmp/$i.cwd" "$path"; then
        up BUSY; held=0; ev+=("세션 ${names[$i]} 이 worktree $path 에서 일한다")
      elif mentions_path "$tmp/$i.cmd" "$path"; then
        up MAYBE; held=0; ev+=("세션 ${names[$i]} 이 worktree $path 로 명령을 돌렸다 -- 그 세션에 물어 확인")
      fi
    done
    if [ $held = 1 ]; then
      up HELD
      ev+=("worktree $path [$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)] 마지막 커밋 $(git -C "$path" log -1 --format=%cr 2>/dev/null) -- 일하는 세션 없음")
    fi
  done

  # 이슈 번호가 든 브랜치(worktree 에 걸리지 않은 것)
  while IFS='|' read -r ref when; do
    [ -n "$ref" ] || continue
    [[ ${ref#origin/} =~ $re ]] || continue
    [[ " ${skip_refs[*]+${skip_refs[*]}} " == *" $ref "* ]] && continue
    up HELD; ev+=("브랜치 $ref (마지막 커밋 $when)")
  done < <(git for-each-ref --format='%(refname:short)|%(committerdate:relative)' refs/heads refs/remotes/origin 2>/dev/null \
           | grep -v -E '^origin/HEAD\|' || true)

  # 다른 세션의 사람 지시에 #N
  for i in "${!names[@]}"; do
    if grep -q -E "#$n([^0-9]|\$)" "$tmp/$i.ask"; then
      up MAYBE; ev+=("세션 ${names[$i]} 의 사람 지시에 #$n 이 나온다 -- 그 세션에 물어 확인")
    fi
  done

  printf '#%s %s\n' "$n" "$verdict"
  for e in ${ev[@]+"${ev[@]}"}; do printf '    %s\n' "$e"; done
done
