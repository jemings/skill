#!/usr/bin/env bash
# land.sh -- 검수를 통과한 PR 을 넣고 뒷정리한다(agent-dispatch 8단계). 저장소 체크아웃 안에서 돌린다.
#
#   land.sh --repo O/R --pr P --sha S [--issue N] [--evidence FILE] [--base B] [--via CMD] [--method rebase|squash|merge] [--close-stack P1,P2] [--keep]
#   land.sh --cleanup --repo O/R --pr P [--close-stack P1,P2]     이미 병합된 PR 의 뒷정리만 한다
#
#   --sha S          리뷰한 PR HEAD. PR HEAD 가 이와 다르면 넣지 않는다(리뷰 뒤 바뀐 것을 넣지 않게)
#   --issue N        그 PR 이 닫는 이슈. --evidence 를 그 이슈 댓글로 남기고, 끝에 이슈 상태를 낸다
#   --evidence FILE  병합 전에 이슈 댓글로 남길 검증 기록(저장소의 착륙 도구가 PR 본문을 고쳐 써도 남는다)
#   --base B         PR 의 대상 브랜치를 B 로 바꾼 뒤 넣는다(stacked PR 의 마지막 층)
#   --via CMD        저장소가 정한 착륙 명령(예: 'sh scripts/push-main.sh'). PR 의 worktree 에서 sh -c 로 돌리고,
#                    끝난 뒤 PR 이 MERGED 인지 gh 로 확인한다. 주지 않으면 gh pr merge 로 넣는다
#   --method M       --via 가 없을 때의 병합 방식. 기본은 저장소 설정에서 rebase > squash > merge 순으로 허용된 것
#   --close-stack L  스택의 앞 층 PR 들. 넣은 뒤 "#P 로 들어갔다" 댓글과 함께 닫고 그 브랜치도 정리한다
#   --keep           worktree, 로컬 브랜치를 남긴다(계약서에 다음 PR 이 남았을 때)
#
# 출력(마지막 줄이 판정):
#   LANDED #P <병합 커밋> [ISSUE #N OPEN|CLOSED]   exit 0
#   BLOCKED #P <이유>                               exit 1  (HEAD 가 바뀜, 충돌, 착륙 명령 실패, 병합 안 됨)
#   NEEDS_HUMAN #P <gh 오류 한 줄>                  exit 3  (보호 규칙이 사람의 승인을 요구한다. PR 은 ready 로 남는다)
#   CLEANED #P                                      exit 0  (--cleanup)
#   인자가 틀리면 exit 2.
# 뒷정리: PR 의 head 브랜치를 체크아웃한 worktree 를 지우고(git worktree remove --force), 로컬 브랜치를 지우고,
# 원격 브랜치가 남아 있으면 지운다. 병합을 gh 로 확인한 뒤에만 지운다(rebase merge 는 SHA 를 바꾸므로 is-ancestor 로 보지 않는다).
# 헤더 규칙: 도움말(-h)은 2행부터 첫 비주석 줄 직전까지 낸다.
# 필요한 것: bash, git, gh, jq.
set -uo pipefail

die() { echo "land: $*" >&2; exit 2; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }
value() { [ -n "${2:-}" ] || die "$1 에 값을 줘라"; }

repo='' pr='' sha='' issue='' evidence='' base='' via='' method='' stack='' keep=0 cleanup=0
POLL=${LAND_POLL:-10} TRIES=${LAND_TRIES:-30}
while [ $# -gt 0 ]; do
  case $1 in
    --repo) value "$@"; repo=$2; shift 2 ;;
    --pr) value "$@"; pr=$2; shift 2 ;;
    --sha) value "$@"; sha=$2; shift 2 ;;
    --issue) value "$@"; issue=$2; shift 2 ;;
    --evidence) value "$@"; evidence=$2; shift 2 ;;
    --base) value "$@"; base=$2; shift 2 ;;
    --via) value "$@"; via=$2; shift 2 ;;
    --method) value "$@"; method=$2; shift 2 ;;
    --close-stack) value "$@"; stack=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --cleanup) cleanup=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "모르는 인자: $1" ;;
  esac
done
[[ $repo =~ ^([^/]+/)?[^/]+/[^/]+$ ]] || die "--repo 는 [HOST/]OWNER/REPO 다: '$repo'"
[[ $pr =~ ^[0-9]+$ ]] || die "--pr 에 PR 번호를 줘라"
[ -z "$issue" ] || [[ $issue =~ ^[0-9]+$ ]] || die "--issue 는 번호다: $issue"
[ -z "$stack" ] || [[ $stack =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--close-stack 은 1,2 꼴이다: $stack"
case $method in ''|rebase|squash|merge) ;; *) die "--method 는 rebase, squash, merge 가운데 하나다: $method" ;; esac
if [ "$cleanup" = 1 ]; then
  [ -z "$sha$evidence$base$via$method" ] && [ "$keep" = 0 ] || die "--cleanup 에는 --repo, --pr, --close-stack, --issue 만 준다"
else
  [[ $sha =~ ^[0-9a-f]{7,40}$ ]] || die "--sha 에 리뷰한 PR HEAD 를 줘라"
  [ -z "$evidence" ] || [ -f "$evidence" ] || die "--evidence 파일이 없다: $evidence"
  [ -z "$evidence" ] || [ -n "$issue" ] || die "--evidence 에는 --issue 가 있어야 한다"
fi

view() { gh pr view "$1" --repo "$repo" --json "$2" --jq "$3"; }
out() { echo "$*"; }

# 원격 이름: --repo 의 OWNER/REPO 를 가리키는 remote, 없으면 origin
remote=origin
slug=$repo; [[ $repo == */*/* ]] && slug=${repo#*/}
r=$(git remote -v 2>/dev/null | awk -v want="$slug" '$2 ~ ("[/:]" want "(\\.git)?$") {print $1; exit}')
[ -z "$r" ] || remote=$r

cleanup_branch() { # <브랜치> -- 그 브랜치를 체크아웃한 worktree, 로컬 브랜치, 원격 브랜치를 지운다
  local b=$1 wt
  [ -n "$b" ] || return 0
  if [ "$keep" = 0 ]; then
    wt=$(git worktree list --porcelain | awk -v ref="refs/heads/$b" '/^worktree /{w=substr($0,10)} $0=="branch " ref {print w; exit}')
    if [ -n "$wt" ]; then
      [ "$wt" != "$(git rev-parse --show-toplevel)" ] || { echo "land: $b 이 지금 트리에 체크아웃돼 있어 남긴다: $wt" >&2; wt=''; }
      [ -z "$wt" ] || git worktree remove --force "$wt" >&2 || echo "land: worktree 를 지우지 못했다: $wt" >&2
    fi
    if git show-ref --verify --quiet "refs/heads/$b"; then git branch -D "$b" >&2 || echo "land: 로컬 브랜치를 지우지 못했다: $b" >&2; fi
  fi
  if [ -n "$(git ls-remote --heads "$remote" "$b" 2>/dev/null)" ]; then
    git push -q "$remote" --delete "$b" >&2 || echo "land: 원격 브랜치를 지우지 못했다: $b" >&2
  fi
}

close_stack() {
  local p b st
  [ -n "$stack" ] || return 0
  for p in ${stack//,/ }; do
    st=$(view "$p" state,headRefName '.state + " " + .headRefName') || { echo "land: 스택 PR #$p 를 읽지 못했다" >&2; continue; }
    b=${st#* }
    [ "${st%% *}" != OPEN ] || gh pr close "$p" --repo "$repo" --comment "#$pr 로 들어갔다(스택의 앞 층)." >&2 || echo "land: #$p 를 닫지 못했다" >&2
    cleanup_branch "$b"
  done
}

issue_state() { [ -z "$issue" ] || printf ' ISSUE #%s %s' "$issue" "$(gh issue view "$issue" --repo "$repo" --json state --jq .state 2>/dev/null || echo '?')"; }

info=$(view "$pr" state,isDraft,headRefOid,headRefName,baseRefName,mergeable \
  '[.state, (.isDraft|tostring), .headRefOid, .headRefName, .baseRefName, .mergeable] | join(" ")') \
  || { out "BLOCKED #$pr PR 을 읽지 못했다"; exit 1; }
read -r state draft head branch prbase mergeable <<<"$info"

if [ "$cleanup" = 1 ]; then
  [ "$state" = MERGED ] || { out "BLOCKED #$pr 병합되지 않았다($state) -- 정리하지 않는다"; exit 1; }
  cleanup_branch "$branch"; close_stack
  out "CLEANED #$pr$(issue_state)"; exit 0
fi

[ "$state" = OPEN ] || { out "BLOCKED #$pr PR 이 열려 있지 않다($state)"; exit 1; }
case $head in "$sha"*) ;; *) out "BLOCKED #$pr PR HEAD 가 리뷰한 SHA 와 다르다(HEAD ${head:0:12}, 리뷰 $sha)"; exit 1 ;; esac

if [ -n "$evidence" ]; then
  gh issue comment "$issue" --repo "$repo" --body-file "$evidence" >&2 || { out "BLOCKED #$pr 검증 기록을 #$issue 에 남기지 못했다"; exit 1; }
fi
if [ -n "$base" ] && [ "$base" != "$prbase" ]; then
  gh api -X PATCH "repos/$repo/pulls/$pr" -f base="$base" >/dev/null || { out "BLOCKED #$pr 대상 브랜치를 $base 로 바꾸지 못했다"; exit 1; }
  mergeable=UNKNOWN
fi
if [ "$draft" = true ]; then
  gh pr ready "$pr" --repo "$repo" >&2 || { out "BLOCKED #$pr ready 로 바꾸지 못했다"; exit 1; }
fi

if [ -n "$via" ]; then
  wt=$(git worktree list --porcelain | awk -v ref="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0=="branch " ref {print w; exit}')
  [ -n "$wt" ] || { out "BLOCKED #$pr --via 를 돌릴 $branch 의 worktree 가 없다"; exit 1; }
  ( cd "$wt" && sh -c "$via" ) >&2 || { out "BLOCKED #$pr 착륙 명령이 실패했다: $via"; exit 1; }
  for _ in $(seq 1 "$TRIES"); do
    state=$(view "$pr" state .state) && [ "$state" = MERGED ] && break
    sleep "$POLL" # 착륙 명령이 끝난 뒤 GitHub 가 병합을 반영하기를 기다린다
  done
  [ "$state" = MERGED ] || { out "BLOCKED #$pr 착륙 명령은 끝났는데 PR 이 $state 다"; exit 1; }
else
  for _ in $(seq 1 "$TRIES"); do
    [ "$mergeable" = UNKNOWN ] || break
    sleep "$POLL" # GitHub 가 mergeable 을 계산하는 중이다
    mergeable=$(view "$pr" mergeable .mergeable) || mergeable=UNKNOWN
  done
  case $mergeable in
    CONFLICTING) out "BLOCKED #$pr base 와 충돌한다 -- rebase 가 필요하다"; exit 1 ;;
    UNKNOWN) out "BLOCKED #$pr mergeable 이 끝내 UNKNOWN 이다"; exit 1 ;;
  esac
  if [ -z "$method" ]; then
    method=$(gh api "repos/$repo" --jq 'if .allow_rebase_merge then "rebase" elif .allow_squash_merge then "squash" else "merge" end') \
      || { out "BLOCKED #$pr 저장소의 병합 방식을 읽지 못했다"; exit 1; }
  fi
  if ! err=$(gh pr merge "$pr" --repo "$repo" "--$method" --match-head-commit "$head" 2>&1 >/dev/null); then
    line=$(printf '%s\n' "$err" | grep -v '^\s*$' | tail -1)
    case $err in
      *[Rr]eview*|*approv*|*protected*|*"not authorized"*|*"required status"*)
        out "NEEDS_HUMAN #$pr $line"; exit 3 ;;
    esac
    out "BLOCKED #$pr gh pr merge 실패: $line"; exit 1
  fi
  state=$(view "$pr" state .state) || state='?'
  [ "$state" = MERGED ] || { out "BLOCKED #$pr gh pr merge 뒤에도 $state 다"; exit 1; }
fi

merged=$(view "$pr" mergeCommit '.mergeCommit.oid // ""' 2>/dev/null)
cleanup_branch "$branch"; close_stack
git fetch -q "$remote" 2>/dev/null || true
out "LANDED #$pr ${merged:0:12}$(issue_state)"
