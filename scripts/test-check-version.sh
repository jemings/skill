#!/usr/bin/env bash
# check-version.sh 의 시험 하네스. 임시 git 저장소만 쓰고 네트워크를 쓰지 않는다.
#
#   bash scripts/test-check-version.sh
#   ONLY='shallow|rev' bash scripts/test-check-version.sh   라벨이 ERE 에 맞는 경우만 돈다(맞는 것이 없으면 exit 1)
#
# 경우를 더하는 법: t_<이름>() 를 쓰고 CASES 에 적는다. 이름의 _ 는 라벨에서 공백이 된다.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK=$HERE/check-version.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
PASS=0 FAIL=0 SKIP=0 BAD=0 SKIPPED=0 CASE= CID=
OUT= ERR= RC= R=

fail() { BAD=1; FAIL=$((FAIL + 1)); echo "FAIL $CASE: $*"; }
g() { git -C "$R" "$@" >/dev/null 2>&1 || fail "git $* 실패"; }
manifest() { printf '{"name":"%s","version":"%s"}\n' "$1" "$2"; }
put() { mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; }
plugin() { put "plugins/$1/.claude-plugin/plugin.json" "$(manifest "$1" "$2")"; put "plugins/$1/skills/$1/SKILL.md" "# $1"; }
# mkrepo : main 에 플러그인 a, b(1.0.0)와 plugins 밖 파일을 커밋하고 origin/main 을 그 끝에 둔 뒤 feat 로 옮긴다
mkrepo() {
  R=$TMP/$CID/r; mkdir -p "$R"
  git -C "$R" init -q -b main || fail "git init 실패"
  plugin a 1.0.0; plugin b 1.0.0; put README.md base
  g add -A; g commit -q -m base
  g update-ref refs/remotes/origin/main HEAD
  g checkout -q -b feat
}
commit() { g add -A; g commit -q -m "${1:-c}"; }
run() { (cd "$R" && bash "$CHECK" "$@") >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); }
expect() { # <exit> <stdout> [<stderr 에 들어 있어야 할 글>]
  [ "$RC" = "$1" ] || fail "exit $RC, want $1 (out: $OUT, err: $ERR)"
  [ "$OUT" = "$2" ] || fail "out [$OUT], want [$2]"
  [ -z "${3:-}" ] || case $ERR in *"$3"*) ;; *) fail "stderr [$ERR] 에 [$3] 이 없다" ;; esac
}
expect_quiet() { expect "$1" "$2"; [ -n "${3:-}" ] || [ -z "$ERR" ] || fail "stderr 가 비어야 한다: [$ERR]"; }

t_not_bumped() { mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_bumped() { mkrepo; put plugins/a/skills/a/SKILL.md changed; plugin a 1.0.1; commit; run; expect_quiet 0 ''; }
t_lowered() { mkrepo; put plugins/a/skills/a/SKILL.md changed; plugin a 0.9.9; commit; run; expect_quiet 1 'plugins/a: version 0.9.9 가 base 1.0.0 보다 낮다'; }
t_numeric_not_lexical() {
  mkrepo; plugin a 1.9.0; commit; g update-ref refs/remotes/origin/main HEAD
  put plugins/a/skills/a/SKILL.md changed; plugin a 1.10.0; commit; run; expect_quiet 0 ''
}
t_major_wins() { mkrepo; put plugins/a/skills/a/SKILL.md changed; plugin a 2.0.0; commit; run; expect_quiet 0 ''; }
t_bad_shape() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; plugin a 1.0; commit; run
  expect_quiet 1 'plugins/a: version [1.0] 이 x.y.z 꼴이 아니다'
  plugin a 1.0.1-beta; commit; run; expect_quiet 1 'plugins/a: version [1.0.1-beta] 이 x.y.z 꼴이 아니다'
}
t_version_not_string() { mkrepo; put plugins/a/skills/a/SKILL.md changed; put plugins/a/.claude-plugin/plugin.json '{"version":2}'; commit; run; expect_quiet 1 'plugins/a: version [2] 이 x.y.z 꼴이 아니다'; }
t_missing_field() { mkrepo; put plugins/a/.claude-plugin/plugin.json '{"name":"a"}'; commit; run; expect_quiet 1 'plugins/a: version [] 이 x.y.z 꼴이 아니다'; }
t_broken_json() { mkrepo; put plugins/a/.claude-plugin/plugin.json '{"version": "1.0.1"'; commit; run; expect_quiet 1 'plugins/a: version [] 이 x.y.z 꼴이 아니다'; }
t_untouched_plugin() { mkrepo; put plugins/a/skills/a/SKILL.md changed; plugin a 1.0.1; commit; run; expect_quiet 0 ''; }
t_outside_plugins_only() { mkrepo; put README.md changed; put scripts/x.sh x; put plugins/top.md top; commit; run; expect_quiet 0 ''; }
t_new_plugin() { mkrepo; plugin c 0.1.0; commit; run; expect_quiet 0 ''; }
t_deleted_plugin() { mkrepo; g rm -rq plugins/a; commit; run; expect_quiet 0 ''; }
t_renamed_plugin() { mkrepo; g mv plugins/a plugins/z; commit; run; expect_quiet 0 ''; }
t_dir_left_without_manifest() {
  mkrepo; g rm -q plugins/a/.claude-plugin/plugin.json; commit; run
  expect_quiet 1 'plugins/a: .claude-plugin/plugin.json 이 없다'
}
t_manifest_only_bumped() { mkrepo; plugin a 1.0.1; commit; run; expect_quiet 0 ''; }
t_manifest_only_not_bumped() { mkrepo; put plugins/a/.claude-plugin/plugin.json '{"name":"a","version":"1.0.0","description":"x"}'; commit; run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_several_plugins_partial() {
  mkrepo; put plugins/a/skills/a/SKILL.md x; put plugins/b/skills/b/SKILL.md y; plugin c 0.1.0; plugin b 1.0.1; put plugins/a/skills/a/SKILL.md z
  commit; run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'
  put plugins/b/skills/b/SKILL.md w; plugin b 0.5.0; commit; run
  expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다
plugins/b: version 0.5.0 가 base 1.0.0 보다 낮다'
}
t_two_commits_bump_later() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit fix; plugin a 1.0.1; commit chore; run; expect_quiet 0 ''
}
t_two_commits_bump_then_revert() {
  mkrepo; plugin a 1.0.1; commit chore; plugin a 1.0.0; put plugins/a/skills/a/SKILL.md changed; commit revert; run
  expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'
}
# pull_request 체크아웃의 merge ref: 첫 부모가 base 끝, 둘째 부모가 PR 끝
t_merge_commit_head() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; plugin a 1.0.1; commit
  g checkout -q main; put plugins/b/skills/b/SKILL.md other; commit other; g update-ref refs/remotes/origin/main HEAD
  g checkout -q --detach; g merge -q --no-ff -m merge feat
  run; expect_quiet 0 ''
}
t_merge_commit_head_not_bumped() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit
  g checkout -q main; put plugins/b/skills/b/SKILL.md other; commit other; g update-ref refs/remotes/origin/main HEAD
  g checkout -q --detach; g merge -q --no-ff -m merge feat
  run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'
}
# 같은 줄을 같은 값으로 올린 두 브랜치: 늦은 쪽의 bump 는 병합에서 사라진다
t_same_bump_on_both_branches() {
  mkrepo; put plugins/a/skills/a/extra.md changed; plugin a 1.0.1; commit
  g checkout -q main; plugin a 1.0.1; commit first; g update-ref refs/remotes/origin/main HEAD
  g checkout -q --detach; g merge -q --no-ff -m merge feat
  run; expect_quiet 1 'plugins/a: version 1.0.1 가 base 와 같다'
}
t_untracked_new_file_only() { mkrepo; put plugins/a/skills/a/new.md n; run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_untracked_ignored_file() { mkrepo; put .gitignore 'ignored.md'; commit; g update-ref refs/remotes/origin/main HEAD; put plugins/a/ignored.md n; run; expect_quiet 0 ''; }
t_worktree_edit_uncommitted() { mkrepo; put plugins/a/skills/a/SKILL.md dirty; run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; plugin a 1.0.1; run; expect_quiet 0 ''; }
t_staged_only() { mkrepo; put plugins/a/skills/a/SKILL.md dirty; g add -A; run; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_base_broken_json() {
  mkrepo; put plugins/a/.claude-plugin/plugin.json '{broken'; commit; g update-ref refs/remotes/origin/main HEAD
  put plugins/a/skills/a/SKILL.md changed; commit; run; expect 0 '' 'plugins/a'
  case $ERR in *경고*) ;; *) fail "경고가 없다: [$ERR]" ;; esac
  [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] || fail "경고는 한 줄이어야 한다: [$ERR]"
}
t_base_missing_version() {
  mkrepo; put plugins/a/.claude-plugin/plugin.json '{"name":"a"}'; commit; g update-ref refs/remotes/origin/main HEAD
  put plugins/a/skills/a/SKILL.md changed; commit; run; expect 0 '' '경고'
}
t_base_broken_json_fixed() {
  mkrepo; put plugins/a/.claude-plugin/plugin.json '{broken'; commit; g update-ref refs/remotes/origin/main HEAD
  plugin a 1.0.0; commit; run; expect 0 '' '경고'
}
t_base_equals_head() { mkrepo; g checkout -q main; run; expect_quiet 0 ''; }
t_explicit_rev() { mkrepo; g branch -q other main; put plugins/a/skills/a/SKILL.md changed; commit; run other; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_rev_as_sha() { mkrepo; local sha; sha=$(git -C "$R" rev-parse main); put plugins/a/skills/a/SKILL.md changed; commit; run "$sha"; expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_shallow_clone() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit
  git clone -q --depth 1 "file://$R" "$TMP/$CID/s" 2>/dev/null || fail "clone 실패"
  R=$TMP/$CID/s; run main; expect 3 '' '얕은'
  [ -n "$ERR" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] || fail "stderr 는 한 줄이어야 한다: [$ERR]"
}
t_rev_missing() { mkrepo; run nosuchrev; expect 3 '' 'git fetch origin main'; }
t_default_rev_missing() { mkrepo; g update-ref -d refs/remotes/origin/main; run; expect 3 '' 'git fetch origin main'; }
t_rev_zero_sha() { mkrepo; run 0000000000000000000000000000000000000000; expect 3 '' 'git fetch origin main'; }
t_rev_not_commit() { mkrepo; run 'main:README.md'; expect 3 '' 'git fetch origin main'; }
t_no_merge_base() { mkrepo; g checkout -q --orphan lone; put x.txt x; commit lone; run main; expect 3 '' 'merge-base'; }
t_no_jq() {
  mkrepo; local bin=$TMP/$CID/bin t; mkdir -p "$bin"
  for t in git bash sh cat sed sort find grep tr head dirname mktemp rm wc cut; do ln -s "$(command -v $t)" "$bin/$t" 2>/dev/null; done
  (cd "$R" && PATH=$bin /bin/bash "$CHECK") >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
  expect 3 '' 'jq'
}
t_not_a_repo() { mkrepo; mkdir -p "$TMP/$CID/plain"; R=$TMP/$CID/plain; run; expect 3 '' 'git'; }
t_arg_errors() {
  mkrepo; run a b; expect 2 '' 'usage'
  run -x; expect 2 '' 'usage'
  run ''; expect 2 '' 'usage'
}
t_help() { mkrepo; run -h; [ "$RC" = 0 ] || fail "exit $RC"; case $OUT in *check-version.sh*사용법*) ;; *) fail "머리 주석이 안 나온다: [$OUT]" ;; esac; }
t_run_from_subdir() { mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; R2=$R; (cd "$R/plugins/a" && bash "$CHECK") >"$TMP/out" 2>&1; RC=$?; OUT=$(cat "$TMP/out"); expect 1 'plugins/a: version 1.0.0 가 base 와 같다'; }
t_leading_zero_and_big() {
  mkrepo; plugin a 1.0.9; commit; g update-ref refs/remotes/origin/main HEAD
  put plugins/a/skills/a/SKILL.md c; plugin a 1.0.09; commit; run; expect_quiet 1 'plugins/a: version 1.0.09 가 base 와 같다'
  plugin a 99999999999999999999.0.0; commit; run; expect_quiet 0 ''
}

t_rename_between_plugins() {
  mkrepo; put plugins/a/s/BIG.md "$(seq 1 60)"; commit; g update-ref refs/remotes/origin/main HEAD
  mkdir -p "$R/plugins/b/s"; g mv plugins/a/s/BIG.md plugins/b/s/BIG.md; commit move; run
  expect_quiet 1 'plugins/a: version 1.0.0 가 base 와 같다
plugins/b: version 1.0.0 가 base 와 같다'
}
t_base_blob_missing() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit
  local id; id=$(git -C "$R" rev-parse main:plugins/a/.claude-plugin/plugin.json); rm -f "$R/.git/objects/${id:0:2}/${id:2}"
  run; expect 3 '' 'plugins/a'
}
t_base_tree_missing() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit
  local id; id=$(git -C "$R" rev-parse main:plugins/a/.claude-plugin); rm -f "$R/.git/objects/${id:0:2}/${id:2}"
  run; expect 3 ''
}
t_unreadable_dir() {
  if [ "$(id -u)" = 0 ]; then SKIPPED=1; echo "SKIP $CASE (root 는 chmod 000 을 따르지 않는다)"; return; fi
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; chmod 000 "$R/plugins/a"
  run; chmod 755 "$R/plugins/a"; expect 3 '' 'plugins/a'
}
t_unreadable_manifest() {
  if [ "$(id -u)" = 0 ]; then SKIPPED=1; echo "SKIP $CASE (root 는 chmod 000 을 따르지 않는다)"; return; fi
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; chmod 000 "$R/plugins/a/.claude-plugin/plugin.json"
  run; chmod 644 "$R/plugins/a/.claude-plugin/plugin.json"; expect 3 '' 'plugins/a'
}
t_deleted_plugin_ignored_leftovers() {
  mkrepo; put .gitignore '__pycache__/'; commit; g update-ref refs/remotes/origin/main HEAD
  g rm -rq plugins/a; put plugins/a/__pycache__/x.pyc junk; commit; run; expect_quiet 0 ''
}
t_deleted_plugin_not_staged() { mkrepo; rm -rf "$R/plugins/a"; run; expect_quiet 0 ''; }
t_dir_replaced_by_symlink() {
  mkrepo; g rm -rq plugins/a; ln -s b "$R/plugins/a"; commit; run
  expect_quiet 1 'plugins/a: 디렉터리가 심볼릭 링크다'
}

t_deleted_plugin_glob_name() {
  mkrepo; plugin 'x*' 1.0.0; plugin xy 1.0.0; commit; g update-ref refs/remotes/origin/main HEAD
  g --literal-pathspecs rm -rq 'plugins/x*'; commit; run; expect_quiet 0 ''
}
t_dir_not_executable() {
  if [ "$(id -u)" = 0 ]; then SKIPPED=1; echo "SKIP $CASE (root 는 chmod 를 따르지 않는다)"; return; fi
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; chmod 444 "$R/plugins/a"
  run; chmod 755 "$R/plugins/a"; expect 3 '' 'plugins/a'
}
t_dir_not_readable() {
  if [ "$(id -u)" = 0 ]; then SKIPPED=1; echo "SKIP $CASE (root 는 chmod 를 따르지 않는다)"; return; fi
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; chmod 111 "$R/plugins/a"
  run; chmod 755 "$R/plugins/a"; expect 3 '' 'plugins/a'
}
t_manifest_dir_unreadable() {
  if [ "$(id -u)" = 0 ]; then SKIPPED=1; echo "SKIP $CASE (root 는 chmod 를 따르지 않는다)"; return; fi
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; chmod 000 "$R/plugins/a/.claude-plugin"
  run; chmod 755 "$R/plugins/a/.claude-plugin"; expect 3 '' 'plugins/a'
}
t_untracked_file_left_after_removal() {
  mkrepo; g rm -rq plugins/a; put plugins/a/new.md n; run
  expect_quiet 1 'plugins/a: .claude-plugin/plugin.json 이 없다'
}
t_dangling_symlink_left() {
  mkrepo; g rm -rq plugins/a; mkdir -p "$R/plugins/a"; ln -s nowhere "$R/plugins/a/dangling"; run
  expect_quiet 1 'plugins/a: .claude-plugin/plugin.json 이 없다'
}
t_corrupt_index() {
  mkrepo; put plugins/a/skills/a/SKILL.md changed; commit; printf 'garbage' > "$R/.git/index"; run; expect 3 ''
}

CASES='not_bumped bumped lowered numeric_not_lexical major_wins bad_shape version_not_string missing_field broken_json
untouched_plugin outside_plugins_only new_plugin deleted_plugin renamed_plugin dir_left_without_manifest
manifest_only_bumped manifest_only_not_bumped several_plugins_partial two_commits_bump_later two_commits_bump_then_revert
merge_commit_head merge_commit_head_not_bumped same_bump_on_both_branches untracked_new_file_only untracked_ignored_file
worktree_edit_uncommitted staged_only base_broken_json base_missing_version base_broken_json_fixed base_equals_head
explicit_rev rev_as_sha shallow_clone rev_missing default_rev_missing rev_zero_sha rev_not_commit no_merge_base no_jq not_a_repo
arg_errors help run_from_subdir leading_zero_and_big
rename_between_plugins base_blob_missing base_tree_missing unreadable_dir unreadable_manifest
deleted_plugin_ignored_leftovers deleted_plugin_not_staged dir_replaced_by_symlink
deleted_plugin_glob_name dir_not_executable dir_not_readable manifest_dir_unreadable untracked_file_left_after_removal dangling_symlink_left corrupt_index'
if [ -n "${ONLY:-}" ]; then
  rc=0; printf '' | grep -qE -- "$ONLY" 2>/dev/null || rc=$?
  [ "$rc" != 2 ] || { echo "ONLY='$ONLY' 는 올바른 ERE 가 아니다" >&2; exit 2; }
fi
ran=0
for c in $CASES; do
  label=${c//_/ }
  if [ -n "${ONLY:-}" ] && ! printf '%s\n' "$label" | grep -qE -- "$ONLY"; then continue; fi
  CASE=$label CID=$c BAD=0 SKIPPED=0 ran=$((ran + 1))
  if declare -F "t_$c" >/dev/null; then "t_$c"; else fail "t_$c 함수가 없다"; fi
  if [ $BAD != 0 ]; then :
  elif [ $SKIPPED = 1 ]; then SKIP=$((SKIP + 1))
  else PASS=$((PASS + 1)); echo "PASS $label"; fi
done
[ $ran -gt 0 ] || { echo "ONLY='${ONLY:-}' 에 맞는 경우가 없다" >&2; exit 1; }
echo "pass $PASS fail $FAIL skip $SKIP"
[ $FAIL = 0 ]
