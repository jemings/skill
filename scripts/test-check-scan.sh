#!/usr/bin/env bash
# check-scan.sh 의 시험 하네스. 스캐너는 SKILL_SCANNER 로 가리킨 스텁이라 네트워크가 필요 없다.
#
#   bash scripts/test-check-scan.sh
#   ONLY='exit 3' bash scripts/test-check-scan.sh     라벨이 ERE 에 맞는 경우만 돈다(맞는 것이 없으면 exit 1)
#   SCANNER_BIN=<실제 skill-scanner> bash scripts/test-check-scan.sh
#                                                     실제 스캐너로 2.10.0 커밋(ece1885)과 지금 plugins 를 대조하는 차분 시험도 돈다(없으면 SKIP)
#
# 스텁은 --version 에 STUB_VERSION 을, 그 밖에는 STUB_OUT(또는 STUB_OUT_DIR/<경로 끝 이름>.json)을 그대로 내고
# STUB_RC 로 끝난다. 경우를 더하는 법: t_<이름>() 를 쓰고 CASES 에 적는다.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CHECK=$HERE/check-scan.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0 SKIP=0 BAD=0 SKIPPED=0 CASE= CID=
OUT= ERR= RC= W=

STUB=$TMP/stub-scanner
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
  [ -z "${STUB_VERSION_FAIL:-}" ] || exit 1
  echo "${STUB_VERSION:-skill-scanner 2.3.2}"; exit 0
fi
[ -z "${STUB_ARGS_LOG:-}" ] || echo "$*" >> "$STUB_ARGS_LOG"
f=${STUB_OUT:-}
[ -z "${STUB_OUT_DIR:-}" ] || [ ! -f "$STUB_OUT_DIR/$(basename "$2").json" ] || f=$STUB_OUT_DIR/$(basename "$2").json
cat "$f"
exit "${STUB_RC:-0}"
STUBEOF
chmod 755 "$STUB"

skip() { SKIPPED=1; echo "SKIP $CASE ($*)"; }
fail() { BAD=1; FAIL=$((FAIL + 1)); echo "FAIL $CASE: $*"; }
# 경우마다 작업 디렉터리 $W 를 만들고 스킬 디렉터리 $W/<이름>/SKILL.md 를 둔다
setup() { W=$TMP/$CID; mkdir -p "$W"; local n; for n in "${@:-a}"; do mkdir -p "$W/$n"; : > "$W/$n/SKILL.md"; done; }
# fnd <rule> <severity> <file> <줄 또는 null> : finding 하나
fnd() { printf '{"rule_id":"%s","severity":"%s","title":"t","file_path":"%s","line_number":%s}' "$1" "$2" "$3" "$4"; }
# res <스킬 경로> <true|false> <finding>... : 결과 하나
res() { local p=$1 s=$2 f; shift 2; f=$(IFS=,; echo "$*"); printf '{"skill_name":"x","skill_path":"%s","is_safe":%s,"findings":[%s]}' "$p" "$s" "$f"; }
# doc <결과>... : 최상위 문서
doc() { local r; r=$(IFS=,; echo "$*"); printf '{"summary":{"total_skills_scanned":1},"results":[%s]}\n' "$r"; }
# run <인자>... : $W 에서 스텁(STUB_OUT 은 호출 전에 정한다)으로 돈다
run() {
  OUT=$(cd "$W" && SKILL_SCANNER=${SKILL_SCANNER:-$STUB} bash "$CHECK" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
}
expect() { # <exit> <출력>
  [ "$RC" = "$1" ] || fail "exit $RC, want $1 (out: $OUT) (err: $ERR)"
  [ "$OUT" = "$2" ] || fail "out [$OUT], want [$2]"
}
# serve <본문> : 스텁이 낼 stdout
serve() { printf '%s' "$1" > "$TMP/$CID.out"; export STUB_OUT=$TMP/$CID.out; }
reset_env() { unset STUB_OUT STUB_OUT_DIR STUB_RC STUB_VERSION STUB_VERSION_FAIL STUB_ARGS_LOG SKILL_SCANNER; }

t_all_safe() { setup; serve "$(doc "$(res "$W/a" true)")"; run a; expect 0 ""; }
t_critical_listed() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd COMPOUND_FIND_EXEC CRITICAL scripts/x.sh 130)")")"
  run a; expect 1 "a/scripts/x.sh:130:COMPOUND_FIND_EXEC CRITICAL"
}
t_high_listed() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd HOMOGLYPH_ATTACK HIGH s.sh 7)")")"
  run a; expect 1 "a/s.sh:7:HOMOGLYPH_ATTACK HIGH"
}
t_medium_and_low_not_listed() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd R1 MEDIUM m.sh 1)" "$(fnd R2 HIGH h.sh 2)" "$(fnd R3 LOW l.sh 3)")")"
  run a; expect 1 "a/h.sh:2:R2 HIGH"
}
t_low_only_passes() {
  setup; serve "$(doc "$(res "$W/a" true "$(fnd R LOW l.sh 3)" "$(fnd R MEDIUM m.sh 4)")")"
  run a; expect 0 ""
}
t_null_line_is_dash() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd R CRITICAL SKILL.md null)")")"
  run a; expect 1 "a/SKILL.md:-:R CRITICAL"
}
t_unsafe_without_blocking_finding() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd R LOW l.sh 3)")")"
  run a; expect 1 "a:-:is_safe false"
}
t_path_outside_cwd_stays_absolute() {
  setup; serve "$(doc "$(res "/elsewhere/a" false "$(fnd R HIGH h.sh 2)")")"
  run a; expect 1 "/elsewhere/a/h.sh:2:R HIGH"
}
t_skill_path_is_cwd() {
  setup; serve "$(doc "$(res "$W" false "$(fnd R HIGH h.sh 2)")")"
  run a; expect 1 "./h.sh:2:R HIGH"
}
t_multiple_paths_one_unsafe() {
  setup a b; mkdir -p "$TMP/$CID.d"
  doc "$(res "$W/a" true)" > "$TMP/$CID.d/a.json"
  doc "$(res "$W/b" false "$(fnd R CRITICAL b.sh 5)")" > "$TMP/$CID.d/b.json"
  export STUB_OUT_DIR=$TMP/$CID.d STUB_OUT=$TMP/$CID.d/a.json
  run a b; expect 1 "b/b.sh:5:R CRITICAL"
  run b a; expect 1 "b/b.sh:5:R CRITICAL"
}
t_scan_all_arguments() {
  setup; serve "$(doc "$(res "$W/a" true)")"; export STUB_ARGS_LOG=$TMP/$CID.log
  run a; expect 0 ""
  [ "$(cat "$STUB_ARGS_LOG")" = "scan-all a --recursive --format json" ] || fail "스캐너 인자 [$(cat "$STUB_ARGS_LOG")]"
}
t_scanner_exit_zero_on_unsafe() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd R CRITICAL x.sh 1)")")"; export STUB_RC=0
  run a; expect 1 "a/x.sh:1:R CRITICAL"
}
t_scanner_exit_nonzero_on_safe() {
  setup; serve "$(doc "$(res "$W/a" true)")"; export STUB_RC=1
  run a; expect 0 ""
}

# 스캐너를 쓸 수 없으면 3 이고, 통과와 구분되며 설치 방법이 stderr 에 나온다
needs_hint() { case $ERR in *"cisco-ai-skill-scanner==2.3.2"*SKILL_SCANNER=*) ;; *) fail "stderr 에 설치 방법이 없다: [$ERR]" ;; esac; }
# 판정기(perl)가 실패하면 스캐너 설치 방법이 아니라 perl 안내가 나온다
needs_judge_hint() {
  case $ERR in *"판정하지 못했다"*) ;; *) fail "판정 실패 이유가 없다: [$ERR]" ;; esac
  case $ERR in *"perl"*"JSON::PP"*) ;; *) fail "stderr 에 perl 안내가 없다: [$ERR]" ;; esac
  case $ERR in *"cisco-ai-skill-scanner"*) fail "스캐너는 멀쩡한데 설치 방법을 냈다: [$ERR]" ;; esac
}
needs_reason() { # <이유 글> : 고정된 이유 글이 stderr 에 있는지
  case $ERR in *"스캐너를 쓸 수 없다"*) ;; *) fail "stderr 에 이유 줄이 없다: [$ERR]" ;; esac
  case $ERR in *"$1"*) ;; *) fail "stderr 에 [$1] 가 없다: [$ERR]" ;; esac
}
t_exit3_scanner_missing_file() { setup; export SKILL_SCANNER=$TMP/nope; run a; expect 3 ""; needs_hint; needs_reason "SKILL_SCANNER 가 실행 파일이 아니다"; }
t_exit3_scanner_not_executable() { setup; : > "$TMP/plain"; export SKILL_SCANNER=$TMP/plain; run a; expect 3 ""; needs_hint; needs_reason "SKILL_SCANNER 가 실행 파일이 아니다"; }
t_exit3_scanner_not_on_path() {
  command -v skill-scanner >/dev/null 2>&1 && { skip "PATH 에 실제 스캐너가 있다"; return; }
  setup; OUT=$(cd "$W" && env -u SKILL_SCANNER bash "$CHECK" a 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
  expect 3 ""; needs_hint; needs_reason "PATH 에 skill-scanner 가 없다"
}
t_scanner_found_on_path() {
  setup; serve "$(doc "$(res "$W/a" true)")"; mkdir -p "$TMP/bin"; cp "$STUB" "$TMP/bin/skill-scanner"
  OUT=$(cd "$W" && env -u SKILL_SCANNER PATH="$TMP/bin:$PATH" bash "$CHECK" a 2>"$TMP/err"); RC=$?
  expect 0 ""
}
t_exit3_version_command_fails() { setup; serve "$(doc "$(res "$W/a" true)")"; export STUB_VERSION_FAIL=1; run a; expect 3 ""; needs_hint; needs_reason "--version 이 실패했다"; }
t_exit3_empty_output() { setup; serve ""; run a; expect 3 ""; needs_hint; needs_reason "출력이 비어 있다"; }
t_exit3_not_json() { setup; serve "No skills found to scan."; export STUB_RC=1; run a; expect 3 ""; needs_hint; needs_reason "출력이 JSON 이 아니다"; }
t_exit3_json_with_trailing_text() { setup; serve "$(doc "$(res "$W/a" true)") trailing"; run a; expect 3 ""; needs_reason "출력이 JSON 이 아니다"; }
t_exit3_plain_text_exit1() { setup; serve "Error: boom"; export STUB_RC=1; run a; expect 3 ""; needs_reason "출력이 JSON 이 아니다"; }
t_exit3_top_level_array() { setup; serve '[]'; run a; expect 3 ""; needs_reason "최상위가 객체가 아니다"; }
t_exit3_no_results() { setup; serve '{"summary":{}}'; run a; expect 3 ""; needs_reason "results 가 배열이 아니다"; }
t_exit3_results_not_array() { setup; serve '{"results":{}}'; run a; expect 3 ""; needs_reason "results 가 배열이 아니다"; }
t_exit3_is_safe_not_bool() {
  setup; serve '{"results":[{"skill_path":"/x","is_safe":"true","findings":[]}]}'; run a; expect 3 ""; needs_reason "is_safe 가 불리언이 아니다"
  serve '{"results":[{"skill_path":"/x","is_safe":1,"findings":[]}]}'; run a; expect 3 ""; needs_reason "is_safe 가 불리언이 아니다"
  serve '{"results":[{"skill_path":"/x","findings":[]}]}'; run a; expect 3 ""; needs_reason "is_safe 가 불리언이 아니다"
}
t_exit3_findings_missing() { setup; serve '{"results":[{"skill_path":"/x","is_safe":true}]}'; run a; expect 3 ""; needs_reason "findings 가 배열이 아니다"; }
t_exit3_finding_shape() {
  setup
  serve '{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"severity":"HIGH"}]}]}'; run a; expect 3 ""; needs_reason "finding.rule_id 가 문자열이 아니다"
  serve '{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"rule_id":"R"}]}]}'; run a; expect 3 ""; needs_reason "finding.severity 가 문자열이 아니다"
  serve '{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"rule_id":"R","severity":"HIGH","line_number":"7"}]}]}'; run a; expect 3 ""; needs_reason "finding.line_number 가 정수가 아니다"
  serve '{"results":[{"skill_path":"/x","is_safe":false,"findings":["x"]}]}'; run a; expect 3 ""; needs_reason "finding 이 객체가 아니다"
}
t_exit3_shape_each_check() {
  setup
  local want body
  while IFS='|' read -r want body; do
    serve "$body"; run a; expect 3 ""; needs_reason "$want"
  done <<'SHAPES'
결과가 객체가 아니다|{"results":["x"]}
skill_path 가 문자열이 아니다|{"results":[{"is_safe":true,"findings":[]}]}
skill_path 가 문자열이 아니다|{"results":[{"skill_path":5,"is_safe":true,"findings":[]}]}
finding.rule_id 가 문자열이 아니다|{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"rule_id":5,"severity":"HIGH"}]}]}
finding.severity 가 문자열이 아니다|{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"rule_id":"R","severity":3}]}]}
finding.file_path 가 문자열이 아니다|{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"rule_id":"R","severity":"HIGH","file_path":5}]}]}
finding.line_number 가 정수가 아니다|{"results":[{"skill_path":"/x","is_safe":false,"findings":[{"rule_id":"R","severity":"HIGH","line_number":-3}]}]}
SHAPES
}
t_exit3_judge_reader_fails() {
  setup; serve "$(doc "$(res "$W/a" true)")"; mkdir -p "$TMP/fakebin"
  printf '#!/bin/sh\necho "perl: boom" >&2\nexit 127\n' > "$TMP/fakebin/perl"; chmod 755 "$TMP/fakebin/perl"
  OUT=$(cd "$W" && SKILL_SCANNER=$STUB PATH="$TMP/fakebin:$PATH" bash "$CHECK" a 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
  expect 3 ""; needs_judge_hint
}
t_exit3_judge_dies_with_errno_one() {
  setup; serve "$(doc "$(res "$W/a" true)")"; mkdir -p "$TMP/plib"
  printf '%s\n' 'package DieOne; require Cwd; no warnings "redefine"; *Cwd::getcwd = sub { $! = 1; die "boom\n" }; 1;' > "$TMP/plib/DieOne.pm"
  OUT=$(cd "$W" && SKILL_SCANNER=$STUB PERL5LIB=$TMP/plib PERL5OPT=-MDieOne bash "$CHECK" a 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
  expect 3 ""; needs_judge_hint
}
t_exit3_first_path_unusable_hides_later_findings() {
  setup a b; mkdir -p "$TMP/$CID.d"
  echo oops > "$TMP/$CID.d/a.json"; doc "$(res "$W/b" false "$(fnd R HIGH h.sh 2)")" > "$TMP/$CID.d/b.json"
  export STUB_OUT_DIR=$TMP/$CID.d STUB_OUT=$TMP/$CID.d/a.json
  run a b; expect 3 ""; needs_reason "출력이 JSON 이 아니다"
}
t_scanner_env_has_no_path_fallback() {
  setup; serve "$(doc "$(res "$W/a" true)")"; mkdir -p "$TMP/bin"; cp "$STUB" "$TMP/bin/skill-scanner"
  OUT=$(cd "$W" && SKILL_SCANNER=$TMP/nope PATH="$TMP/bin:$PATH" bash "$CHECK" a 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
  expect 3 ""; needs_reason "SKILL_SCANNER 가 실행 파일이 아니다"
}
t_scanner_env_beats_path() {
  setup; mkdir -p "$TMP/bin"
  doc "$(res "$W/a" true)" > "$TMP/$CID.safe"; doc "$(res "$W/a" false "$(fnd R HIGH h.sh 2)")" > "$TMP/$CID.unsafe"
  sed "s|^f=.*|f=$TMP/$CID.safe|; s|^\[ -z \"\${STUB_OUT_DIR.*||" "$STUB" > "$TMP/bin/skill-scanner"; chmod 755 "$TMP/bin/skill-scanner"
  export STUB_OUT=$TMP/$CID.unsafe
  OUT=$(cd "$W" && SKILL_SCANNER=$STUB PATH="$TMP/bin:$PATH" bash "$CHECK" a 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
  expect 1 "a/h.sh:2:R HIGH"
}
t_exit3_second_path_unusable() {
  setup a b; mkdir -p "$TMP/$CID.d"
  doc "$(res "$W/a" false "$(fnd R HIGH h.sh 2)")" > "$TMP/$CID.d/a.json"; echo oops > "$TMP/$CID.d/b.json"
  export STUB_OUT_DIR=$TMP/$CID.d STUB_OUT=$TMP/$CID.d/a.json
  run a b; expect 3 "a/h.sh:2:R HIGH"; needs_reason "출력이 JSON 이 아니다"
}

t_exit2_no_args() { setup; run; expect 2 ""; }
t_exit2_missing_path() { setup; serve "$(doc "$(res "$W/a" true)")"; run nope; expect 2 ""; }
t_exit2_no_skill_md() { setup; mkdir -p "$W/empty"; serve "$(doc "$(res "$W/a" true)")"; run empty; expect 2 ""; }
t_exit2_one_bad_path_among_good() { setup; serve "$(doc "$(res "$W/a" true)")"; run a nope; expect 2 ""; }
t_exit2_before_scanner_is_looked_up() { setup; export SKILL_SCANNER=$TMP/nope; run nope; expect 2 ""; }
t_exit2_scanner_never_called() {
  setup; mkdir -p "$W/empty"; serve "$(doc "$(res "$W/a" true)")"; export STUB_ARGS_LOG=$TMP/$CID.log
  run empty; expect 2 ""; [ ! -e "$STUB_ARGS_LOG" ] || fail "스캐너를 불렀다"
}

t_version_mismatch_warns_and_continues() {
  setup; serve "$(doc "$(res "$W/a" false "$(fnd R HIGH h.sh 2)")")"; export STUB_VERSION="skill-scanner 9.9.9"
  run a; expect 1 "a/h.sh:2:R HIGH"
  case $ERR in *"skill-scanner 9.9.9"*"skill-scanner 2.3.2"*) ;; *) fail "버전 경고가 없다: [$ERR]" ;; esac
  [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] || fail "경고가 한 줄이 아니다: [$ERR]"
}
t_version_match_is_silent() { setup; serve "$(doc "$(res "$W/a" true)")"; run a; expect 0 ""; [ -z "$ERR" ] || fail "stderr [$ERR]"; }

t_only_invalid_ere() {
  [ -z "${CS_NESTED:-}" ] || { skip "중첩 실행"; return; }
  CS_NESTED=1 ONLY='(' bash "$HERE/test-check-scan.sh" > /dev/null 2>&1; [ $? = 2 ] || fail "ONLY 가 틀린 ERE 인데 exit 2 가 아니다"
}
t_summary_counts_skip() {
  [ -z "${CS_NESTED:-}" ] || { skip "중첩 실행"; return; }
  OUT=$(CS_NESTED=1 ONLY='real scanner differential' SCANNER_BIN= bash "$HERE/test-check-scan.sh" 2>&1 | tail -1)
  [ "$OUT" = "pass 0 fail 0 skip 1" ] || fail "요약이 [$OUT]"
}
t_missing_case_fn() {
  [ -z "${CS_NESTED:-}" ] || { skip "중첩 실행"; return; }
  local cp=$TMP/self.sh
  sed -e "s|^HERE=.*|HERE=$HERE|" -e "s|^CASES='|CASES='no_such_case |" "${BASH_SOURCE[0]}" > "$cp"
  OUT=$(CS_NESTED=1 ONLY='^no such case$' bash "$cp" 2>&1); RC=$?
  [ "$RC" = 1 ] || fail "exit $RC, want 1 (out: $OUT)"
  case $OUT in *'FAIL no such case: t_no_such_case 함수가 없다'*) ;; *) fail "FAIL 줄이 없다: $OUT" ;; esac
}

# 실제 스캐너: 2.10.0 커밋은 COMPOUND_FIND_EXEC 로 걸리고, 지금 plugins 는 통과한다
t_real_scanner_differential() {
  if [ -z "${SCANNER_BIN:-}" ]; then skip "SCANNER_BIN 없음"; return; fi
  git -C "$REPO" cat-file -e ece1885 2>/dev/null || { skip "ece1885 객체 없음"; return; }
  local d=$TMP/$CID; mkdir -p "$d"
  git -C "$REPO" archive ece1885 plugins/agent-dispatch | tar -x -C "$d"
  OUT=$(cd "$d" && SKILL_SCANNER=$SCANNER_BIN bash "$CHECK" plugins/agent-dispatch 2>"$TMP/err"); RC=$?
  expect 1 "plugins/agent-dispatch/skills/agent-dispatch/scripts/in-flight.sh:130:COMPOUND_FIND_EXEC CRITICAL"
  OUT=$(cd "$REPO" && SKILL_SCANNER=$SCANNER_BIN bash "$CHECK" plugins 2>"$TMP/err"); RC=$?
  expect 0 ""
}

CASES='all_safe critical_listed high_listed medium_and_low_not_listed low_only_passes null_line_is_dash unsafe_without_blocking_finding
path_outside_cwd_stays_absolute skill_path_is_cwd multiple_paths_one_unsafe scan_all_arguments scanner_exit_zero_on_unsafe scanner_exit_nonzero_on_safe
exit3_scanner_missing_file exit3_scanner_not_executable exit3_scanner_not_on_path scanner_found_on_path exit3_version_command_fails
exit3_empty_output exit3_not_json exit3_json_with_trailing_text exit3_plain_text_exit1 exit3_top_level_array exit3_no_results exit3_results_not_array
exit3_is_safe_not_bool exit3_findings_missing exit3_finding_shape exit3_second_path_unusable
exit3_shape_each_check exit3_judge_reader_fails exit3_judge_dies_with_errno_one exit3_first_path_unusable_hides_later_findings scanner_env_has_no_path_fallback scanner_env_beats_path
exit2_no_args exit2_missing_path exit2_no_skill_md exit2_one_bad_path_among_good exit2_before_scanner_is_looked_up exit2_scanner_never_called
version_mismatch_warns_and_continues version_match_is_silent only_invalid_ere summary_counts_skip missing_case_fn real_scanner_differential'
if [ -n "${ONLY:-}" ]; then
  rc=0; printf '' | grep -qE -- "$ONLY" 2>/dev/null || rc=$?
  [ "$rc" != 2 ] || { echo "ONLY='$ONLY' 는 올바른 ERE 가 아니다" >&2; exit 2; }
fi
ran=0
for c in $CASES; do
  label=${c//_/ }
  if [ -n "${ONLY:-}" ] && ! printf '%s\n' "$label" | grep -qE -- "$ONLY"; then continue; fi
  CASE=$label CID=$c BAD=0 SKIPPED=0 ran=$((ran + 1))
  reset_env
  if declare -F "t_$c" >/dev/null; then "t_$c"; else fail "t_$c 함수가 없다"; fi
  if [ $BAD != 0 ]; then :
  elif [ $SKIPPED = 1 ]; then SKIP=$((SKIP + 1))
  else PASS=$((PASS + 1)); echo "PASS $label"; fi
done
[ $ran -gt 0 ] || { echo "ONLY='${ONLY:-}' 에 맞는 경우가 없다" >&2; exit 1; }
echo "pass $PASS fail $FAIL skip $SKIP"
[ $FAIL = 0 ]
