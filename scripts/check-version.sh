#!/usr/bin/env bash
# check-version.sh - plugins/<name>/ 를 고친 변경이 그 plugin.json 의 version 을 올렸는지 검사한다.
#
# 사용법: bash scripts/check-version.sh [<rev>]
#   <rev>(기본 origin/main)와 HEAD 의 merge-base 를 base 로 잡고, base 대 워킹트리(추적 파일의 변경과
#   비추적 파일 포함)를 비교한다. 커밋 단위가 아니라 끝점을 비교하므로 version 올림이 나중 커밋이어도 된다.
#   바뀐 플러그인: 변경된 경로가 plugins/<name>/... 인 <name>(개명은 옛 경로와 새 경로를 둘 다 센다).
#   올랐다: 워킹트리의 version 이 x.y.z(숫자) 꼴이고 base 의 version 보다 숫자로 엄격히 크다.
#   면제: base 에 그 plugin.json 이 없다(새 플러그인), 워킹트리에 plugins/<name>/ 아래 파일이 없다(삭제).
#         base 의 plugin.json 이 깨졌거나 version 이 x.y.z 꼴이 아니면 stderr 에 경고 한 줄을 내고 면제한다.
#   exit 0  통과(출력 없음, 경고는 stderr)
#   exit 1  위반. 플러그인마다 stdout 에 한 줄을 모두 낸다:
#             plugins/<name>: version <v> 가 base 와 같다
#             plugins/<name>: version <v> 가 base <b> 보다 낮다
#             plugins/<name>: version [<값>] 이 x.y.z 꼴이 아니다   (필드 없음, 깨진 JSON 은 값이 빈다)
#             plugins/<name>: .claude-plugin/plugin.json 이 없다    (디렉터리는 남았다)
#             plugins/<name>: 디렉터리가 심볼릭 링크다
#   exit 2  인자 오류(usage 를 stderr 에)
#   exit 3  판정할 수 없다(stderr 에 이유 한 줄): 얕은 저장소, <rev> 가 풀리지 않는다(git fetch origin main),
#           merge-base 가 없다, git 저장소가 아니다, jq 가 없다, 읽기 실패(권한, 읽을 수 없는 git 객체,
#           실패한 git diff, git ls-files). 통과로 넘어가는 SKIP 은 없다.
#
# CI 의 pull_request 체크아웃은 merge ref 라 HEAD 가 병합 커밋이고 merge-base 는 그 첫 부모(base 끝)다.
# github.event.pull_request.base.sha 는 이벤트 시점 값이라 낡을 수 있어 쓰지 않는다.

export LC_ALL=C.UTF-8

usage() { echo "usage: bash scripts/check-version.sh [<rev>]" >&2; exit 2; }
undecidable() { echo "check-version: 판정할 수 없다: $1" >&2; exit 3; }

# 경계 1: 인자
case ${1-} in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ "$#" -le 1 ] || usage
if [ "$#" -eq 1 ]; then
  [ -n "$1" ] && [ "${1#-}" = "$1" ] || usage
fi
rev=${1-origin/main}

# 경계 2: 저장소와 base. 이 아래는 풀린 base 커밋 하나만 안다.
command -v jq >/dev/null 2>&1 || undecidable "jq 가 없다"
top=$(git rev-parse --show-toplevel 2>/dev/null) || undecidable "git 저장소가 아니다"
cd "$top" || undecidable "저장소 루트로 옮기지 못했다: $top"
[ "$(git rev-parse --is-shallow-repository)" != true ] || undecidable "얕은 저장소다(fetch-depth: 0 으로 받는다)"
git rev-parse --verify --quiet "$rev^{commit}" >/dev/null ||
  undecidable "$rev 를 커밋으로 풀 수 없다(git fetch origin main 을 먼저 한다)"
base=$(git merge-base HEAD "$rev") || undecidable "HEAD 와 $rev 의 merge-base 가 없다"

TMP=$(mktemp -d) || undecidable "임시 디렉터리를 만들지 못했다"
trap 'rm -rf "$TMP"' EXIT
git diff --no-renames --name-only -z "$base" -- plugins >"$TMP/tracked" 2>/dev/null || undecidable "git diff 가 실패했다: $base"
git ls-files --others --exclude-standard -z -- plugins >"$TMP/untracked" 2>/dev/null || undecidable "git ls-files 가 실패했다"
git ls-files -z -c -o --exclude-standard -- plugins >"$TMP/present" 2>/dev/null || undecidable "git ls-files 가 실패했다"
names=$(cat "$TMP/tracked" "$TMP/untracked" | tr '\0' '\n' | sed -n 's|^plugins/\([^/][^/]*\)/.*|\1|p' | sort -u)

is_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# 숫자 문자열 둘의 비교: 앞 0 을 떼고 자릿수, 사전순으로 본다(자리 수에 제한이 없다)
cmp_num() {
  local a=${1#"${1%%[!0]*}"} b=${2#"${2%%[!0]*}"}
  if [ "${#a}" -ne "${#b}" ]; then [ "${#a}" -gt "${#b}" ] && echo 1 || echo -1; return; fi
  if [ "$a" = "$b" ]; then echo 0; elif [[ $a > $b ]]; then echo 1; else echo -1; fi
}
# cmp_version <x.y.z> <x.y.z> : 앞이 크면 1, 같으면 0, 작으면 -1
cmp_version() {
  local IFS=. i c
  local -a p q
  read -r -a p <<<"$1"; read -r -a q <<<"$2"
  for i in 0 1 2; do
    c=$(cmp_num "${p[$i]}" "${q[$i]}")
    [ "$c" = 0 ] || { echo "$c"; return; }
  done
  echo 0
}

# accessible <경로> : 있는 디렉터리는 읽고 열 수 있고, 있는 파일은 읽을 수 있다. 없는 것은 통과한다.
accessible() {
  if [ -d "$1" ]; then [ -r "$1" ] && [ -x "$1" ]; elif [ -e "$1" ]; then [ -r "$1" ]; fi
}

status=0
violation() { echo "$1"; status=1; }
while IFS= read -r name; do
  [ -n "$name" ] || continue
  dir=plugins/$name
  manifest=$dir/.claude-plugin/plugin.json
  accessible "$dir" || undecidable "$dir 를 읽을 수 없다"
  exists=0
  while IFS= read -r -d '' f; do
    case $f in "$dir"|"$dir"/*) ;; *) continue ;; esac
    if [ -e "$f" ] || [ -L "$f" ]; then exists=1; break; fi
  done <"$TMP/present"
  [ "$exists" = 1 ] || continue
  git ls-tree "$base" -- "$manifest" >"$TMP/tree" 2>/dev/null || undecidable "base 의 $manifest 를 읽지 못했다"
  [ -s "$TMP/tree" ] || continue
  git cat-file blob "$base:$manifest" >"$TMP/base.json" 2>/dev/null || undecidable "base 의 $manifest 객체를 읽지 못했다"
  base_version=$(jq -er 'if (.version | type) == "string" then .version else empty end' "$TMP/base.json" 2>/dev/null)
  if ! is_version "$base_version"; then
    echo "check-version: 경고: $dir: base 의 plugin.json 을 읽지 못했거나 version 이 x.y.z 꼴이 아니라 면제한다" >&2
    continue
  fi
  accessible "$dir/.claude-plugin" && accessible "$manifest" || undecidable "$manifest 를 읽을 수 없다"
  if [ -L "$dir" ]; then
    violation "$dir: 디렉터리가 심볼릭 링크다"
    continue
  fi
  if [ ! -f "$manifest" ]; then
    violation "$dir: .claude-plugin/plugin.json 이 없다"
    continue
  fi
  version=$(jq -c '.version // empty | if type == "string" then . else tojson end' "$manifest" 2>/dev/null | head -n 1)
  version=${version#\"}; version=${version%\"}
  if ! is_version "$version"; then
    violation "$dir: version [$version] 이 x.y.z 꼴이 아니다"
    continue
  fi
  case $(cmp_version "$version" "$base_version") in
    1) ;;
    0) violation "$dir: version $version 가 base 와 같다" ;;
    *) violation "$dir: version $version 가 base $base_version 보다 낮다" ;;
  esac
done <<<"$names"
exit "$status"
