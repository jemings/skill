#!/usr/bin/env bash
# in-flight.sh -- 이슈가 이미 누군가의 손에 있는지 본다(agent-dispatch 1, 5, 6단계). 저장소 체크아웃 안에서 돌린다.
# --peers 는 같은 저장소에서 일하는 다른 세션을 찾는다(1단계 "저장소 도구를 공용화한다").
#
#   in-flight.sh [--repo owner/repo] <N>...          판정
#   in-flight.sh --claim [--repo owner/repo] <N>...  이 세션이 맡았다고 표시한다(같은 PC 의 다른 agent-dispatch 가 본다)
#   in-flight.sh --release [--repo owner/repo] <N>... 표시를 거둔다
#   in-flight.sh --peers [--repo owner/repo]         같은 저장소에서 일하는 살아 있는 다른 세션
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
# 근거: ~/.claude/sessions/<pid>.json(살아 있는 세션 -- pid 와 procStart 로 확인), 그 세션 기록
# ~/.claude/projects/*/<sessionId>.jsonl 의 cwd, 사람 지시, git worktree, 브랜치, gh 의 열린 PR.
# 세션 파일의 cwd 는 기동 디렉터리라 worktree 로 옮겨 간 세션을 가리지 못한다 -- 그래서 기록의 cwd 를 본다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다 -- 헤더 안에 빈 줄이나 비주석 줄을 두면 거기서 끊긴다.
# 필요한 것: bash 4+, jq, git, gh.
set -euo pipefail

die() { echo "in-flight: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SESS=$CFG/sessions
PROJ=$CFG/projects
CLAIMS=$CFG/agent-dispatch/claims
TAIL=${IN_FLIGHT_TAIL:-600}   # 세션 기록에서 "최근"으로 볼 줄 수

mode=check repo=
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:?}; shift 2 ;;
    --claim) mode=claim; shift ;;
    --release) mode=release; shift ;;
    --peers) mode=peers; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "모르는 옵션: $1" ;;
    *) break ;;
  esac
done
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
      jq '{pid, procStart: (.procStart // "-"), name, sessionId}' "$SESS/$self_pid.json" > "$f"
      echo "claimed #$n"
    else
      rm -f "$f"; echo "released #$n"
    fi
  done
  exit 0
fi

[ "$mode" = peers ] || git fetch -q --prune origin 2>/dev/null || true

# 살아 있는 다른 세션: 이름, pid, 최근 cwd 목록(세션 파일 .scwd, 기록 .tcwd, 둘을 합친 .cwd), 최근 기록 원문, 사람 지시
# -- 임시 파일에 한 번만 뽑아 둔다
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
names=() pids=()
for f in "$SESS"/*.json; do
  [ -e "$f" ] || continue
  IFS=$'\t' read -r pid pstart name sid < <(jq -r '[.pid, (.procStart // "-"), (.name // "-"), (.sessionId // "-")] | @tsv' "$f") || continue
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
    jq -r --arg n "$cn" '[.pid, (.procStart // "-"), $n] | @tsv' "$cf" >> "$tmp/claims" || true
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

wt_lines=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{p=substr($0,10)} /^branch /{print p "\t" substr($0,19)} /^detached/{print p "\t-"}')

for n in "$@"; do
  re="(^|[^0-9])$n([^0-9]|\$)"
  verdict=FREE ev=() skip_refs=()

  # 다른 agent-dispatch 세션의 표시
  cf="$CLAIMS/${key}_$n.json"
  if [ -f "$cf" ]; then
    IFS=$'\t' read -r cpid cstart cname < <(jq -r '[.pid, .procStart, .name] | @tsv' "$cf")
    if [ "$cpid" = "$self_pid" ]; then ev+=("claim: 이 세션");
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
