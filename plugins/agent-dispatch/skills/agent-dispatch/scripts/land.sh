#!/usr/bin/env bash
# land.sh -- 검수를 통과한 PR 을 넣고 뒷정리한다(agent-dispatch 8단계). 저장소 체크아웃 안에서 돌린다.
#
#   land.sh --repo O/R --pr P --sha S [--issue N] [--evidence FILE] [--base B] [--via CMD] [--method rebase|squash|merge] [--close-stack P1,P2] [--keep]
#   land.sh --repo O/R --pr P --sha S [...] [--check CMD] [--pre-merge CMD] [--push-env K=V]...   저장소 명령으로 고리를 돈다
#   land.sh --cleanup --repo O/R --pr P [--close-stack P1,P2]     이미 병합된 PR 의 뒷정리만 한다
#
#   --sha S          검수한 PR HEAD. PR HEAD 가 이와 다르면 넣지 않는다(검수 뒤 바뀐 것을 넣지 않게)
#   --issue N        그 PR 이 닫는 이슈. --evidence 를 그 이슈 댓글로 남기고, 끝에 이슈 상태를 낸다
#   --evidence FILE  병합 전에 이슈 댓글로 남길 검증 기록(저장소의 착륙 도구가 PR 본문을 고쳐 써도 남는다)
#   --base B         PR 의 대상 브랜치를 B 로 바꾼 뒤 넣는다(stacked PR 의 마지막 층)
#   --via CMD        저장소가 정한 착륙 명령(예: 'sh scripts/push-main.sh'). PR 의 worktree 에서 sh -c 로 돌리고,
#                    끝난 뒤 PR 이 MERGED 인지 gh 로 확인한다. 주지 않으면 gh pr merge 로 넣는다
#   --method M       --via 가 없을 때의 병합 방식. 기본은 저장소 설정에서 rebase > squash > merge 순으로 허용된 것.
#                    설정(gh repo view --json rebaseMergeAllowed,squashMergeAllowed,mergeCommitAllowed)이 M 을 허용하지 않으면
#                    기록, 대상 변경, push, ready 전에 BLOCKED 로 멈춘다
#   --close-stack L  스택의 앞 층 PR 들. 넣은 뒤 "#P 로 들어갔다" 댓글과 함께 닫고 그 브랜치도 정리한다
#   --keep           worktree, 로컬 브랜치를 남긴다(계약서에 다음 PR 이 남았을 때)
#   --check CMD      검사 명령. 0 이 아니면 push 하지 않고 BLOCKED
#   --pre-merge CMD  병합 전 명령. 스스로 커밋한다(0개도 된다). 끝난 뒤 트리가 깨끗하고 HEAD 가 착륙 tip 의 자손이어야 한다
#   --push-env K=V   land.sh 가 PR 브랜치에 하는 push(tip 과 복원)에만 주는 env. 여러 번 준다. 브랜치 삭제 push 에는 주지 않는다
#
# 저장소 명령(--check, --pre-merge)이 하나라도 있으면 round 를 돈다. 없으면 --via 나 gh 병합으로 한 번에 넣는다.
# --via 와 저장소 명령, --push-env 는 함께 주지 않고, --push-env 는 저장소 명령과만 준다.
# round: <remote>/<base> 를 fetch 해 그 SHA 를 round 의 base 로 두고, 검수한 SHA 의 detached 임시 worktree(temp-tree.sh)를
# 만들어 base 가 조상이 아니면 base 를 얹은 착륙 tip 을 만들고 패치를 비교한다. 갈래는 병합 방식이 정한다.
#   커밋 보존(rebase, merge): base 위로 rebase 한 tip. 커밋 패치 판정: mb=$(git merge-base <검수한 SHA> <base>) 로
#   git log -p -U0 --reverse <mb>..<검수한 SHA> | git patch-id --stable 의 patch-id 열 목록이 rebase 한 tip 쪽과 같아야 한다
#   (범위에 merge 커밋이 있거나 rebase 뒤 범위가 비어도 바뀐 것이다).
#   squash: rebase 하지 않고 git merge --no-ff <base> 로 base 를 합친 tip(rebase 처럼 commit-msg, pre-merge-commit 훅과
#   서명 검사를 거치지 않는다). 고유 diff 판정: <rev> 마다
#   git diff -U0 $(git merge-base <rev> <base>) <rev> | git patch-id --stable 의 patch-id 가 검수한 SHA 와 그 tip 에서 같아야 한다
#   (tip 쪽이 비어도 바뀐 것이다. 범위의 merge 커밋은 괜찮다).
# 그다음 검사 명령, 병합 전 명령을 돌리고, tip 이 PR HEAD 와
# 다르면 --force-with-lease=refs/heads/<branch>:<기대 HEAD> 로 push 한다(기대 HEAD 는 처음엔 검수한 SHA, 다음부터는 앞 round 에
# 올린 tip). PR HEAD 가 tip 이 되고 mergeable 이 정해지기를 기다려 draft 면 ready 로 바꾸고 --match-head-commit <tip> 으로 병합한다.
# 병합이 지면 base 를 다시 fetch 한다. 움직였으면 검수한 SHA 에서 새로 round 를 돈다. 그대로인데 gh 가 Base branch was modified 를
# 내면 같은 tip 으로 다시 병합한다(이것도 round 로 센다). 그 밖에는 아래 판정을 따른다. 임시 worktree 는 끝나면 늘 지운다.
# 두 명령은 임시 worktree 루트에서 sh -c 로 돌고, 출력은 stderr 로 간다. env: LAND_REPO LAND_PR LAND_BRANCH LAND_BASE
# LAND_BASE_SHA(round 의 base) LAND_SHA(검수한 SHA, 40자) LAND_HEAD(착륙 tip).
# PR 브랜치에 tip 을 push 하기 직전마다 stderr 에 "land: 올린 tip <40자>" 한 줄을 낸다.
# 복원: push 한 뒤(push 하는 중에 신호를 받았어도) BLOCKED 로 끝나면 PR 브랜치를 --force-with-lease=refs/heads/<branch>:<마지막으로 올린 tip> 으로 검수한 SHA 에
# 되돌린다(실패하면 판정 줄 뒤에 stderr 로 알린다). NEEDS_HUMAN 이면 되돌리지 않는다. gh pr merge 가 0 으로 끝났거나 그 호출 중에
# 신호를 받았으면 병합됐거나 큐에 들었을 수 있으니 되돌리지 않는다. kill -9 처럼 복원이 돌지 못한 중단 뒤에는
# 다음 실행이 "검수한 SHA 와 다르다" 로 멈춘다.
# 남는 경합: 병합 직전 확인과 병합 호출 사이에 base 가 움직이면 막지 못한다. 병합 뒤 병합 커밋(rebase 병합이면 마지막 커밋)의
# 부모 쪽 base 가 round 의 base 가 아니면 stderr 에 경고 한 줄만 낸다.
# env: LAND_ROUNDS round 상한(기본 3. 저장소 명령이 없는 gh 병합에서는 Base branch was modified 로 진 병합을 다시 하는 상한), LAND_TRIES/LAND_POLL mergeable 대기 횟수와 간격(기본 30, 10초).
#
# 출력(마지막 줄이 판정):
#   LANDED #P <병합 커밋> [ISSUE #N OPEN|CLOSED]   exit 0
#   BLOCKED #P <이유>                               exit 1  (HEAD 가 바뀜, 충돌, 착륙 명령 실패, 병합 안 됨)
#     저장소 명령이 있을 때의 이유: base 와 충돌한다 -- 따라잡기가 필요하다 (충돌 파일은 stderr) | base 를 얹은 뒤 패치가 달라졌다
#     | base 를 합치지 못했다: <git 오류 한 줄> (rebase 나 squash 의 merge 가 충돌 파일 없이 졌다. 출력은 stderr)
#     | 검사 실패: <cmd> | 병합 전 명령이 실패했다: <cmd> | base 가 움직여 <N>번 다시 했다 (N 은 LAND_ROUNDS)
#     | PR 브랜치에 push 하지 못했다 (lease 거절이면 검수 뒤 남이 push 했다) | PR HEAD 가 올린 tip <sha> 이 되지 않았다(<HEAD>)
#     | base <b> 를 받지 못했다 | 임시 worktree 를 만들지 못했다 | 임시 디렉터리를 만들지 못했다
#   --via 가 아닐 때의 이유: 저장소가 <방식> 병합을 허용하지 않는다 | 저장소의 병합 방식을 읽지 못했다
#   gh 병합(저장소 명령 없음)의 이유: base 가 움직여 <N>번 다시 했다 (N 은 LAND_ROUNDS) | PR HEAD 가 병합 직전에 바뀌었다: <gh 오류 한 줄> (두 길 모두)
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

repo='' pr='' sha='' issue='' evidence='' base='' via='' method='' stack='' keep=0 cleanup=0 check='' pre_merge=''
push_env=()
POLL=${LAND_POLL:-10} TRIES=${LAND_TRIES:-30} ROUNDS=${LAND_ROUNDS:-3}
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
    --check) value "$@"; [ -z "$check" ] || die "--check 는 한 번만 준다"; check=$2; shift 2 ;;
    --pre-merge) value "$@"; [ -z "$pre_merge" ] || die "--pre-merge 는 한 번만 준다"; pre_merge=$2; shift 2 ;;
    --push-env) value "$@"; [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "--push-env 는 K=V 다: $2"; push_env+=("$2"); shift 2 ;;
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
mode=gh
[ -z "$via" ] || mode=via
if [ -n "$check$pre_merge" ]; then
  [ "$mode" = gh ] || die "--via 와 --check, --pre-merge 는 함께 주지 않는다"
  mode=loop
fi
[ ${#push_env[@]} = 0 ] || [ "$mode" = loop ] || die "--push-env 는 --check 나 --pre-merge 와만 준다"
if [ "$cleanup" = 1 ]; then
  [ -z "$sha$evidence$base$via$method$check$pre_merge" ] && [ "$keep" = 0 ] || die "--cleanup 에는 --repo, --pr, --close-stack, --issue 만 준다"
else
  [[ $sha =~ ^[0-9a-f]{7,40}$ ]] || die "--sha 에 검수한 PR HEAD 를 줘라"
  [ -z "$evidence" ] || [ -f "$evidence" ] || die "--evidence 파일이 없다: $evidence"
  [ -z "$evidence" ] || [ -n "$issue" ] || die "--evidence 에는 --issue 가 있어야 한다"
  [ "$mode" = via ] || [[ $ROUNDS =~ ^[1-9][0-9]*$ ]] || die "LAND_ROUNDS 는 1 이상의 정수다: $ROUNDS"
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

ready_pr() {
  [ "$draft" = true ] || return 0
  gh pr ready "$pr" --repo "$repo" >&2 || { out "BLOCKED #$pr ready 로 바꾸지 못했다"; exit 1; }
  draft=false
}
resolve_method() { # -> method. 허용된 방식은 rebase > squash > merge 순서의 목록이다
  local allowed
  allowed=$(gh repo view "$repo" --json rebaseMergeAllowed,squashMergeAllowed,mergeCommitAllowed \
    --jq '[(select(.rebaseMergeAllowed) | "rebase"), (select(.squashMergeAllowed) | "squash"), (select(.mergeCommitAllowed) | "merge")] | join(" ")') \
    || { out "BLOCKED #$pr 저장소의 병합 방식을 읽지 못했다"; exit 1; }
  if [ -z "$method" ]; then method=${allowed%% *}; method=${method:-merge}; return 0; fi
  case " $allowed " in *" $method "*) ;; *) out "BLOCKED #$pr 저장소가 $method 병합을 허용하지 않는다"; exit 1 ;; esac
}
merge_failed() { # <gh pr merge 의 stderr> -- 판정 줄을 내고 끝낸다
  local line
  line=$(printf '%s\n' "$1" | grep -v '^\s*$' | tail -1)
  case $1 in
    *"Head branch was modified"*)
      out "BLOCKED #$pr PR HEAD 가 병합 직전에 바뀌었다: $line"; exit 1 ;;
    *[Rr]eview*|*approv*|*protected*|*"not authorized"*|*"required status"*)
      out "NEEDS_HUMAN #$pr $line"; exit 3 ;;
  esac
  out "BLOCKED #$pr gh pr merge 실패: $line"; exit 1
}

reviewed='' tbase='' base_sha='' held='' tip='' tree='' tmp_root='' round=0 fetched=''

fetch_base() { # -> fetched
  git fetch -q "$remote" "+refs/heads/$tbase:refs/remotes/$remote/$tbase" >&2 && fetched=$(git rev-parse "refs/remotes/$remote/$tbase")
}
push_pr() { # <기대 HEAD> <커밋> -- PR 브랜치가 기대 HEAD 일 때만 커밋으로 옮긴다
  env ${push_env[@]+"${push_env[@]}"} git push -q --force-with-lease="refs/heads/$branch:$1" "$remote" "$2:refs/heads/$branch" >&2
}
drop_tree() {
  [ -n "$tree" ] || return 0
  bash "$(dirname "$0")/temp-tree.sh" remove "$tree" >/dev/null || echo "land: 임시 worktree 를 지우지 못했다: $tree" >&2
  tree=''
}
on_exit() {
  local rc=$?
  drop_tree
  [ -z "$tmp_root" ] || rm -rf "$tmp_root"
  [ "$rc" = 1 ] && [ -n "$held" ] && [ "$held" != "$reviewed" ] || return 0
  push_pr "$held" "$reviewed" \
    || echo "land: PR 브랜치를 검수한 SHA ${reviewed:0:12} 로 되돌리지 못했다(올린 tip ${held:0:12}). 손으로 되돌려라" >&2
}
# bash 는 신호 trap 을 전경 명령이 끝난 뒤, 그 결과를 보기 전에 돈다. 그래서 명령을 부르기 전에 이룬 뒤의 값을 쥔다.
hold() { # <명령이 이루면 land.sh 가 쥘 PR 브랜치 값, 비면 GitHub 에 넘긴 것> <명령...> -- 명령이 지면 앞 값으로 돌린다
  local was=$held
  held=$1; shift
  "$@" || { held=$was; return 1; }
}
patch_ids() { git log -p -U0 --reverse "$1" | git patch-id --stable | cut -d' ' -f1; }
pr_diff_id() { # <rev> <base SHA> -- rev 의 PR 고유 diff(base 와의 merge-base 부터)의 patch-id. 비면 빈 값
  local mb
  mb=$(git merge-base "$1" "$2") || return 1
  git diff -U0 "$mb" "$1" | git patch-id --stable | cut -d' ' -f1
}
repo_cmd() { # <명령> <착륙 tip>
  ( cd "$tree" && LAND_REPO=$repo LAND_PR=$pr LAND_BRANCH=$branch LAND_BASE=$tbase LAND_BASE_SHA=$base_sha \
      LAND_SHA=$reviewed LAND_HEAD=$2 sh -c "$1" ) >&2
}
base_failed() { # <merge|rebase> -- base 를 얹다 진 git 을 되돌리고, 충돌 파일이 있으면 충돌로, 없으면 git 의 첫 error:/fatal: 원인 줄(없으면 첫 비공백 줄)로 BLOCKED
  local files line
  cat "$tmp_root/base.err" >&2
  files=$(git -C "$tree" diff --name-only --diff-filter=U)
  git -C "$tree" "$1" --abort >&2
  if [ -z "$files" ]; then
    line=$(grep -E '^(error|fatal): ' "$tmp_root/base.err" | head -1)
    [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$tmp_root/base.err" | head -1)
    out "BLOCKED #$pr base 를 합치지 못했다: $line"; exit 1
  fi
  printf '%s\n' "$files" >&2
  out "BLOCKED #$pr base 와 충돌한다 -- 따라잡기가 필요하다"; exit 1
}
build_tip() { # -> base_sha, tip
  local landed=$reviewed mb after
  fetch_base || { out "BLOCKED #$pr base $tbase 를 받지 못했다"; exit 1; }
  base_sha=$fetched
  tree=$(bash "$(dirname "$0")/temp-tree.sh" add "$tmp_root/r$round" "$reviewed" | tail -1) \
    || { out "BLOCKED #$pr 임시 worktree 를 만들지 못했다"; exit 1; }
  if ! git merge-base --is-ancestor "$base_sha" "$reviewed"; then
    case $method in
      squash) # base 를 합친 tip, 고유 diff 판정. --no-ff: PR 이 base 의 조상이어도, merge.ff 설정이 어떻든 merge 커밋을 만든다.
        # rebase 갈래처럼 commit-msg, pre-merge-commit 훅과 서명 검사를 거치지 않는다
        if ! git -C "$tree" -c merge.verifySignatures=false merge --no-verify -q --no-ff --no-edit -m "Merge $tbase into $branch" "$base_sha" \
          >&2 2>"$tmp_root/base.err"; then
          base_failed merge
        fi
        landed=$(git -C "$tree" rev-parse HEAD)
        after=$(pr_diff_id "$landed" "$base_sha")
        [ -n "$after" ] && [ "$after" = "$(pr_diff_id "$reviewed" "$base_sha")" ] || { out "BLOCKED #$pr base 를 얹은 뒤 패치가 달라졌다"; exit 1; } ;;
      *) # rebase 한 tip, 커밋 패치 판정
        mb=$(git merge-base "$reviewed" "$base_sha")
        [ -z "$(git rev-list --merges "$mb..$reviewed")" ] || { out "BLOCKED #$pr base 를 얹은 뒤 패치가 달라졌다"; exit 1; }
        if ! git -C "$tree" rebase -q "$base_sha" >&2 2>"$tmp_root/base.err"; then
          base_failed rebase
        fi
        landed=$(git -C "$tree" rev-parse HEAD)
        after=$(patch_ids "$base_sha..$landed")
        [ -n "$after" ] && [ "$after" = "$(patch_ids "$mb..$reviewed")" ] || { out "BLOCKED #$pr base 를 얹은 뒤 패치가 달라졌다"; exit 1; } ;;
    esac
  fi
  if [ -n "$check" ]; then repo_cmd "$check" "$landed" || { out "BLOCKED #$pr 검사 실패: $check"; exit 1; }; fi
  tip=$landed
  if [ -n "$pre_merge" ]; then
    repo_cmd "$pre_merge" "$landed" && tip=$(git -C "$tree" rev-parse HEAD) && [ -z "$(git -C "$tree" status --porcelain)" ] \
      && git merge-base --is-ancestor "$landed" "$tip" || { out "BLOCKED #$pr 병합 전 명령이 실패했다: $pre_merge"; exit 1; }
  fi
  drop_tree
}
await_tip() {
  local i seen=''
  for i in $(seq 1 "$TRIES"); do
    seen=$(view "$pr" headRefOid,mergeable '.headRefOid + " " + .mergeable') || seen=''
    if [ "${seen% *}" = "$tip" ] && [ "${seen#* }" != UNKNOWN ]; then
      [ "${seen#* }" != CONFLICTING ] || { out "BLOCKED #$pr base 와 충돌한다 -- 따라잡기가 필요하다"; exit 1; }
      return 0
    fi
    [ "$i" = "$TRIES" ] || sleep "$POLL" # GitHub 가 push 와 mergeable 을 반영하는 중이다
  done
  [ "${seen% *}" = "$tip" ] || { out "BLOCKED #$pr PR HEAD 가 올린 tip ${tip:0:12} 이 되지 않았다(${seen% *})"; exit 1; }
  out "BLOCKED #$pr mergeable 이 끝내 UNKNOWN 이다"; exit 1
}
land_loop() {
  local rebuild=1 err
  reviewed=$head tbase=${base:-$prbase} held=$head
  tmp_root=$(mktemp -d) || { out "BLOCKED #$pr 임시 디렉터리를 만들지 못했다"; exit 1; }
  trap on_exit EXIT
  trap 'exit 1' INT TERM HUP
  for round in $(seq 1 "$ROUNDS"); do
    if [ "$rebuild" = 1 ]; then
      build_tip
      if [ "$tip" != "$held" ]; then
        echo "land: 올린 tip $tip" >&2
        hold "$tip" push_pr "$held" "$tip" || { out "BLOCKED #$pr PR 브랜치에 push 하지 못했다"; exit 1; }
      fi
    fi
    await_tip
    ready_pr
    hold '' gh pr merge "$pr" --repo "$repo" "--$method" --match-head-commit "$tip" >/dev/null 2>"$tmp_root/merge.err" && return 0
    err=$(cat "$tmp_root/merge.err")
    fetch_base || { out "BLOCKED #$pr base $tbase 를 받지 못했다"; exit 1; }
    if [ "$fetched" != "$base_sha" ]; then rebuild=1; continue; fi
    case $err in *"Base branch was modified"*) rebuild=0; continue ;; esac
    merge_failed "$err"
  done
  out "BLOCKED #$pr base 가 움직여 ${ROUNDS}번 다시 했다"; exit 1
}
land_gh() {
  local attempt err
  for attempt in $(seq 1 "$ROUNDS"); do
    [ "$attempt" = 1 ] || mergeable=$(view "$pr" mergeable .mergeable) || mergeable=UNKNOWN
    for _ in $(seq 1 "$TRIES"); do
      [ "$mergeable" = UNKNOWN ] || break
      sleep "$POLL" # GitHub 가 mergeable 을 계산하는 중이다
      mergeable=$(view "$pr" mergeable .mergeable) || mergeable=UNKNOWN
    done
    case $mergeable in
      CONFLICTING) out "BLOCKED #$pr base 와 충돌한다 -- 따라잡기가 필요하다"; exit 1 ;;
      UNKNOWN) out "BLOCKED #$pr mergeable 이 끝내 UNKNOWN 이다"; exit 1 ;;
    esac
    err=$(gh pr merge "$pr" --repo "$repo" "--$method" --match-head-commit "$head" 2>&1 >/dev/null) && return 0
    case $err in *"Base branch was modified"*) continue ;; esac
    merge_failed "$err"
  done
  out "BLOCKED #$pr base 가 움직여 ${ROUNDS}번 다시 했다"; exit 1
}
warn_off_base() { # <병합 커밋>
  local parent=''
  fetch_base || return 0
  if [ "$method" = rebase ]; then
    parent=$(git rev-parse -q --verify "$1~$(git rev-list --count "$base_sha..$tip")^{commit}" 2>/dev/null)
  else
    parent=$(git rev-parse -q --verify "$1^1^{commit}" 2>/dev/null)
  fi
  [ "$parent" = "$base_sha" ] \
    || echo "land: 경고: #$pr 이 round 의 base ${base_sha:0:12} 가 아닌 ${parent:-?} 위에 들어갔다(병합 직전 확인 뒤 base 가 움직였다)" >&2
}

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
case $head in "$sha"*) ;; *) out "BLOCKED #$pr PR HEAD 가 검수한 SHA 와 다르다(HEAD ${head:0:12}, 검수 $sha)"; exit 1 ;; esac
[ "$mode" = via ] || resolve_method

if [ -n "$evidence" ]; then
  gh issue comment "$issue" --repo "$repo" --body-file "$evidence" >&2 || { out "BLOCKED #$pr 검증 기록을 #$issue 에 남기지 못했다"; exit 1; }
fi
if [ -n "$base" ] && [ "$base" != "$prbase" ]; then
  gh api -X PATCH "repos/$repo/pulls/$pr" -f base="$base" >/dev/null || { out "BLOCKED #$pr 대상 브랜치를 $base 로 바꾸지 못했다"; exit 1; }
  mergeable=UNKNOWN
fi
[ "$mode" = loop ] || ready_pr

if [ "$mode" = loop ]; then
  land_loop
elif [ "$mode" = via ]; then
  wt=$(git worktree list --porcelain | awk -v ref="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0=="branch " ref {print w; exit}')
  [ -n "$wt" ] || { out "BLOCKED #$pr --via 를 돌릴 $branch 의 worktree 가 없다"; exit 1; }
  ( cd "$wt" && sh -c "$via" ) >&2 || { out "BLOCKED #$pr 착륙 명령이 실패했다: $via"; exit 1; }
  for _ in $(seq 1 "$TRIES"); do
    state=$(view "$pr" state .state) && [ "$state" = MERGED ] && break
    sleep "$POLL" # 착륙 명령이 끝난 뒤 GitHub 가 병합을 반영하기를 기다린다
  done
  [ "$state" = MERGED ] || { out "BLOCKED #$pr 착륙 명령은 끝났는데 PR 이 $state 다"; exit 1; }
else
  land_gh
fi
if [ "$mode" != via ]; then
  state=$(view "$pr" state .state) || state='?'
  [ "$state" = MERGED ] || { out "BLOCKED #$pr gh pr merge 뒤에도 $state 다"; exit 1; }
fi

merged=$(view "$pr" mergeCommit '.mergeCommit.oid // ""' 2>/dev/null)
[ "$mode" != loop ] || warn_off_base "$merged"
cleanup_branch "$branch"; close_stack
git fetch -q "$remote" 2>/dev/null || true
out "LANDED #$pr ${merged:0:12}$(issue_state)"
