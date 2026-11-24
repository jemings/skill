#!/usr/bin/env bash
# temp-tree.sh -- 커밋 하나를 던져 둘 사본(detached worktree)으로 꺼내고, 끝나면 지운다(agent-dispatch 7단계, 리뷰어, 구현자).
# 검수, 변이, 수정 전 커밋의 빨강 확인처럼 남의 worktree 를 건드리지 않고 다른 커밋을 돌려야 할 때 쓴다. 저장소 안에서 돌린다.
#
#   temp-tree.sh add <경로> <커밋> [--link REL]... [--copy SRC:REL]... [--file REL=TEXT]...
#   temp-tree.sh remove <경로>
#
#   --link REL       주 체크아웃의 REL(설치된 의존성: node_modules, .venv 따위)을 사본의 같은 자리에 symlink 로 건다.
#                    사본에서 시험 실행기가 의존성 없이 소리 없이 죽는 것을 막는다
#   --copy SRC:REL   SRC(파일이나 디렉터리)를 사본의 REL 로 복사한다. symlink 를 거절하는 도구(git apply 등)가 읽을 것은 이것으로
#   --file REL=TEXT  사본의 REL 에 TEXT 한 줄을 쓴다(표식 파일)
#
# add 는 마지막 줄에 사본의 절대 경로를 낸다. 경로가 이미 있으면 exit 2. remove 는 --link 로 건 symlink 를 먼저 걷고
# git worktree remove --force 로 지운다(주 체크아웃이나 git 이 모르는 경로면 exit 2). 주 체크아웃은
# git worktree list 의 첫 줄이다.
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다.
# 필요한 것: bash, git.
set -euo pipefail

die() { echo "temp-tree: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case $cmd in -h|--help) usage; exit 0 ;; add|remove) ;; *) die "add 나 remove 다: $cmd" ;; esac
main=$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main" ] || die "git 저장소 안에서 돌려라"
rec() { echo "$(git -C "$1" rev-parse --absolute-git-dir)/temp-tree-links"; }  # 사본의 git 디렉터리 안 -- 작업 트리를 더럽히지 않는다

if [ "$cmd" = remove ]; then
  [ $# = 1 ] || die "remove <경로>"
  p=$(cd "$1" 2>/dev/null && pwd -P) || die "경로가 없다: $1"
  [ "$p" != "$(cd "$main" && pwd -P)" ] || die "주 체크아웃은 지우지 않는다: $p"
  git worktree list --porcelain | grep -qxF "worktree $p" || die "git worktree 가 아니다: $p"
  r=$(rec "$p")
  if [ -f "$r" ]; then
    while IFS= read -r rel; do if [ -L "$p/$rel" ]; then rm -f "$p/$rel"; fi; done < "$r"
  fi
  git worktree remove --force "$p"
  echo "removed $p"; exit 0
fi

[ $# -ge 2 ] || die "add <경로> <커밋> [옵션...]"
path=$1 commit=$2; shift 2
[ ! -e "$path" ] || die "경로가 이미 있다: $path"
links=() copies=() files=()
while [ $# -gt 0 ]; do
  case $1 in
    --link) [ -n "${2:-}" ] || die "--link 에 값을 줘라"; links+=("$2"); shift 2 ;;
    --copy) [[ ${2:-} == ?*:?* ]] || die "--copy 는 SRC:REL 이다"; copies+=("$2"); shift 2 ;;
    --file) [[ ${2:-} == ?*=* ]] || die "--file 은 REL=TEXT 다"; files+=("$2"); shift 2 ;;
    *) die "모르는 인자: $1" ;;
  esac
done
for rel in ${links[@]+"${links[@]}"}; do [ -e "$main/$rel" ] || die "주 체크아웃에 $rel 이 없다"; done
for c in ${copies[@]+"${copies[@]}"}; do [ -e "${c%%:*}" ] || die "--copy 원본이 없다: ${c%%:*}"; done

git worktree add -q --detach "$path" "$commit"
p=$(cd "$path" && pwd -P)
r=$(rec "$p"); : > "$r"
for rel in ${links[@]+"${links[@]}"}; do
  mkdir -p "$(dirname "$p/$rel")"
  [ ! -e "$p/$rel" ] || die "사본에 $rel 이 이미 있다(추적되는 파일이면 --link 로 덮지 않는다)"
  ln -s "$main/$rel" "$p/$rel"; echo "$rel" >> "$r"
done
for c in ${copies[@]+"${copies[@]}"}; do
  rel=${c#*:}; mkdir -p "$(dirname "$p/$rel")"; cp -a "${c%%:*}" "$p/$rel"
done
for f in ${files[@]+"${files[@]}"}; do
  rel=${f%%=*}; mkdir -p "$(dirname "$p/$rel")"; printf '%s\n' "${f#*=}" > "$p/$rel"
done
echo "$p"
