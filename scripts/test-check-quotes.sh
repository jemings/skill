#!/usr/bin/env bash
# check-quotes.sh 의 시험 하네스. 네트워크를 쓰지 않는다.
#
#   bash scripts/test-check-quotes.sh
#   ONLY='heredoc' bash scripts/test-check-quotes.sh   라벨이 ERE 에 맞는 경우만 돈다(맞는 것이 없으면 exit 1)
#   SCANNER_PY=<cisco-ai-skill-scanner 가 깔린 python> bash scripts/test-check-quotes.sh
#                                                      스캐너 원함수와 끝 상태를 대조하는 차분 시험도 돈다(없으면 SKIP)
#
# 이 파일 자신도 check-quotes.sh 의 검사 대상이다. 그래서 고정물에 따옴표를 글자로 쓰지 않고
# Q(홑따옴표), D(쌍따옴표) 변수로 끼워 넣는다. 경우를 더하는 법: t_<이름>() 를 쓰고 CASES 에 적는다.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CHECK=$HERE/check-quotes.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
Q="'"
D='"'
PASS=0 FAIL=0 SKIP=0 BAD=0 SKIPPED=0 CASE= CID=
OUT= RC=

skip() { SKIPPED=1; echo "SKIP $CASE ($*)"; }
fail() { BAD=1; FAIL=$((FAIL + 1)); echo "FAIL $CASE: $*"; }
# put <파일> <줄>... : 줄마다 개행을 붙여 쓴다
put() { local f=$1; shift; mkdir -p "$(dirname "$f")"; printf '%s\n' "$@" > "$f"; }
run() { OUT=$(bash "$CHECK" "$@" 2>/dev/null); RC=$?; }
expect() { # <exit> <출력>
  [ "$RC" = "$1" ] || fail "exit $RC, want $1 (out: $OUT)"
  [ "$OUT" = "$2" ] || fail "out [$OUT], want [$2]"
}
# one <이름> <기대 exit> <기대 줄:상태 또는 빈 값> <줄>... : 파일 하나를 만들어 돌린다
one() {
  local f=$TMP/$CID/$1.sh want=$3; local rc=$2; shift 3
  put "$f" "$@"; run "$f"
  if [ -n "$want" ]; then expect "$rc" "$f:$want"; else expect "$rc" ""; fi
}

# #38 꼴: 쌍따옴표 안의 $( ) 속에 홑따옴표 안 쌍따옴표가 있어 짝이 어긋난다
t_shape38() { one a 1 '1:single' "x=${D}\$(grep -c ${Q}a ${D}b${Q} f)${D}" '# 끝'; }
t_shape38_unrolled() { one a 0 '' "n=\$(grep -c ${Q}a ${D}b${Q} f)" "x=${D}\$n${D}" '# 끝'; }
t_unterminated_double() { one a 1 '2:double' 'echo ok' "echo ${D}abc" 'echo z'; }
t_legit_multiline_single() { one a 0 '' "echo ${Q}multi" "line${Q} # ok"; }
t_ansi_escaped_quote() { one a 0 '' "echo \$${Q}it\\${Q}s${Q}" '# done'; }
t_ansi_open() { one a 1 '1:ansi_c' "echo \$${Q}abc"; }
t_dollar_dq_opens_double() { one a 1 '1:double' "echo \$${D}abc"; }
t_hash_after_pipe() { one a 0 '' "x=\$(foo)|# it${Q}s" 'echo ok'; }
t_hash_after_dollar_brace() { one a 0 '' "echo \${#x} # it${Q}s"; }
t_hash_comment_quote() { one a 0 '' "echo a # it${Q}s"; }
t_escape_does_not_cross_lines() { one a 0 '' "echo ${Q}a\\${Q}" 'echo b'; }
t_backslash_continues_quote() { one a 1 '2:single' 'echo a \' "  b ${Q}x"; }
t_heredoc_odd() { one a 1 '2:single' "cat <<${Q}EOF${Q}" "don${Q}t" 'EOF'; }
t_heredoc_plain() { one a 0 '' "cat <<${Q}EOF${Q}" 'plain' 'EOF'; }
t_crlf() {
  local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"
  printf 'echo a\r\necho b\r\n' > "$f"; run "$f"; expect 0 ""
  printf 'echo %sa\r\nb%s\r\n' "$Q" "$Q" > "$f"; run "$f"; expect 0 ""
  printf 'echo %sa\r\nb\r\n' "$Q" > "$f"; run "$f"; expect 1 "$f:1:single"
}
t_no_trailing_newline() {
  local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"
  printf 'echo a%sb' "$Q" > "$f"; run "$f"; expect 1 "$f:1:single"
}
t_empty_file() { local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"; : > "$f"; run "$f"; expect 0 ""; }
t_reports_start_line() { one a 1 '3:double' 'echo 1' "echo ${D}ok${D}" "echo ${D}bad" 'echo 4' 'echo 5'; }

t_dir_walk() {
  local d=$TMP/$CID; put "$d/a.sh" "echo ${Q}x"; put "$d/sub/B.BASH" "echo ${Q}y"
  put "$d/note.md" "echo ${Q}z"; put "$d/data.txt" "echo ${Q}z"
  put "$d/bin/tool" '#!/usr/bin/env bash' "echo ${Q}w"
  put "$d/bin/py" '#!/usr/bin/env python3' "print(${Q}w)"
  put "$d/bin/plain" "echo ${Q}w"
  put "$d/.git/h.sh" "echo ${Q}g"
  run "$d"
  expect 1 "$d/a.sh:1:single
$d/bin/tool:2:single
$d/sub/B.BASH:1:single"
}
t_shebang_forms() {
  local d=$TMP/$CID
  put "$d/a" '#!/bin/sh' "echo ${Q}1"
  put "$d/b" '#!/usr/bin/env -S bash -eu' "echo ${Q}2"
  put "$d/c" '#!/bin/zsh' "echo ${Q}3"
  run "$d"
  expect 1 "$d/a:2:single
$d/b:2:single"
}
t_file_arg_any_name() { local f=$TMP/$CID/notes.md; put "$f" "echo ${Q}z"; run "$f"; expect 1 "$f:1:single"; }
t_dir_clean() { local d=$TMP/$CID; put "$d/a.sh" 'echo ok'; run "$d"; expect 0 ""; }
t_two_args() {
  local d=$TMP/$CID; put "$d/x/a.sh" "echo ${Q}a"; put "$d/y/b.sh" "echo ${D}b"
  run "$d/y" "$d/x"
  expect 1 "$d/x/a.sh:1:single
$d/y/b.sh:1:double"
}
t_no_args() { run; expect 2 ""; }
t_missing_path() { run "$TMP/nope"; expect 2 ""; }
t_unreadable() {
  local f=$TMP/$CID/a.sh; put "$f" 'echo ok'; chmod 000 "$f"
  if [ -r "$f" ]; then skip "root 는 못 읽는 파일이 없다"; chmod 644 "$f"; return; fi
  run "$f"; expect 2 ""; chmod 644 "$f"
}

# 줄을 넘는 \ 가림, CRLF, 주석 경계
t_escape_resets_each_line() { one a 1 '2:single' 'a\' "${Q}b"; }
t_escape_end_keeps_boundary_off() { one a 1 '2:single' 'foo\' "# it${Q}s"; }
t_escaped_space_is_not_boundary() { one a 1 '1:single' "echo a\\ # it${Q}s"; }
t_escaped_char_is_not_boundary() { one a 1 '1:single' "echo \\;# it${Q}s"; }
t_crlf_comment_boundary() {
  local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"
  printf 'foo\\\r\n# it%ss\r\n' "$Q" > "$f"; run "$f"; expect 0 ""
  printf 'echo a\r# it%ss\n' "$Q" > "$f"; run "$f"; expect 0 ""
}
t_comment_boundaries() {
  local f=$TMP/$CID/a.sh c; mkdir -p "$TMP/$CID"
  for c in ';' '&' '|' '(' ')' '<' '>' ' ' $'\t' $'\f' $'\v' $'\x1c' $'\x1d' $'\x1e' $'\x1f'; do
    printf 'a%s# it%ss\n' "$c" "$Q" > "$f"; run "$f"
    [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "경계 [$(printf %q "$c")] 뒤의 # 가 주석이 아니다 (out: $OUT)"
  done
}
t_hash_mid_word() { one a 1 '1:single' "echo a#b${Q}c"; }

# 스캐너처럼 읽는다: 앞 BOM 은 벗고, NUL 이나 비UTF-8 파일은 건너뛴다
t_bom_stripped() {
  local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"
  printf '\xef\xbb\xbf# it%ss\n' "$Q" > "$f"; run "$f"; expect 0 ""
  local d=$TMP/$CID/dir; mkdir -p "$d"
  printf '\xef\xbb\xbf#!/bin/bash\necho %sx\n' "$Q" > "$d/tool"; run "$d"; expect 1 "$d/tool:2:single"
}
t_binary_skipped() {
  local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"
  printf 'echo \xff%s\n' "$Q" > "$f"; run "$f"; expect 0 ""
  printf 'echo %sa\0\n' "$Q" > "$f"; run "$f"; expect 0 ""
}
t_dir_ignores_unlisted() {
  local d=$TMP/$CID; put "$d/a.sh" 'echo ok'; put "$d/n.md" "echo ${Q}x"; chmod 000 "$d/n.md"
  if [ -r "$d/n.md" ]; then skip "root 는 못 읽는 파일이 없다"; chmod 644 "$d/n.md"; return; fi
  run "$d"; expect 0 ""
  put "$d/bin/tool" '#!/bin/bash' 'echo ok'; chmod 000 "$d/bin/tool"; run "$d"; expect 2 ""
  chmod 644 "$d/n.md" "$d/bin/tool"
}
t_dir_skips_other_extensions() {
  local d=$TMP/$CID; put "$d/n.md" '#!/bin/bash' "echo ${Q}x"; run "$d"; expect 0 ""
}
t_shebang_must_end_at_word() {
  local d=$TMP/$CID; put "$d/n" '#!/bin/shell' "echo ${Q}x"; run "$d"; expect 0 ""
}

t_utf8_validity() {
  local f=$TMP/$CID/a.sh b; mkdir -p "$TMP/$CID"
  for b in '\xef\xbf\xbf' '\xef\xb7\x90' '\xf4\x8f\xbf\xbf' '\xef\xbf\xbe' '\xf0\x9f\x98\x80'; do
    printf "echo %sa$b\n" "$Q" > "$f"; run "$f"; expect 1 "$f:1:single"
  done
  for b in '\xc0\x80' '\xed\xa0\x80' '\xf4\x90\x80\x80' '\xe0\x80\x80' '\xc3'; do
    printf "echo %sa$b\n" "$Q" > "$f"; run "$f"; expect 0 ""
  done
}
t_double_bom() {
  local f=$TMP/$CID/a.sh; mkdir -p "$TMP/$CID"
  printf '\xef\xbb\xbf\xef\xbb\xbf# it%ss\n' "$Q" > "$f"; run "$f"; expect 1 "$f:1:single"
}
t_shebang_one_line_only() {
  local d=$TMP/$CID; put "$d/a" '#!' "sh -e" "echo ${Q}x"; put "$d/b" '#!/usr/bin/env' 'bash' "echo ${Q}x"; run "$d"; expect 0 ""
}
t_only_invalid_ere() {
  [ -z "${CQ_NESTED:-}" ] || { skip "중첩 실행"; return; }
  CQ_NESTED=1 ONLY='(' bash "$HERE/test-check-quotes.sh" > /dev/null 2>&1; [ $? = 2 ] || fail "ONLY 가 틀린 ERE 인데 exit 2 가 아니다"
}
t_summary_counts_skip() {
  [ -z "${CQ_NESTED:-}" ] || { skip "중첩 실행"; return; }
  OUT=$(CQ_NESTED=1 ONLY='scanner differential' SCANNER_PY= bash "$HERE/test-check-quotes.sh" 2>&1 | tail -1)
  [ "$OUT" = "pass 0 fail 0 skip 1" ] || fail "요약이 [$OUT]"
}

# 역사: #38 을 낸 판은 걸리고, 고친 판과 지금 판은 통과한다. 객체가 없으면(shallow clone) SKIP
HIST=plugins/agent-dispatch/skills/agent-dispatch/scripts/test-scripts.sh
hist() { # <rev> <기대 exit> <기대 출력(파일 이름 자리는 @)>
  git -C "$REPO" cat-file -e "$1:$HIST" 2>/dev/null || { skip "$1 객체 없음"; return; }
  local f=$TMP/$CID/test-scripts.sh; mkdir -p "$TMP/$CID"
  git -C "$REPO" show "$1:$HIST" > "$f"; run "$f"; expect "$2" "${3//@/$f}"
}
t_history_aca90b5() { hist aca90b50b6a1f2848f01bc07c04373e5411faabf 1 '@:792:double'; }
t_history_b225ec5() { hist b225ec50f06e8fc51af358c28691421618637d87 0 ''; }
t_history_head() { hist HEAD 0 ''; }

# 스캐너 차분: 스캐너 원함수의 끝 상태와 check-quotes.sh 의 판정이 같은지 본다
scanner_end() { # <파일>... : 줄마다 `경로 상태` 를 낸다
  "$SCANNER_PY" -I - "$@" <<'PYEOF'
import inspect, sys
from pathlib import Path
from skill_scanner.utils.file_utils import read_text_strict
from skill_scanner.core.static_analysis import comment_stripping as cs
src = inspect.getsource(cs._strip_bash_comments).replace("    return stripped_lines", "    return stripped_lines, quote")
ns = {}
exec(src, ns)
for p in sys.argv[1:]:
    try:
        text = read_text_strict(Path(p))
    except Exception:
        print(p, "none")  # 스캐너는 읽지 않는 파일이다
        continue
    print(p, ns["_strip_bash_comments"](text)[1] or "none")
PYEOF
}
t_scanner_differential() {
  if [ -z "${SCANNER_PY:-}" ]; then skip "SCANNER_PY 없음"; return; fi
  local d=$TMP/$CID n=0 f want got; mkdir -p "$d"
  put "$d/f1.sh" "echo \$${Q}it\\${Q}s${Q}" "echo ${D}\$(grep -c ${Q}a ${D}b${Q} f)${D}" '# 끝'
  put "$d/f2.sh" "x=\$(a)|# it${Q}s" "echo \${#x} # it${Q}s" "cat <<${Q}E${Q}" "don${Q}t" 'E'
  put "$d/f3.sh" 'echo a \' "  b ${Q}x" "echo ${Q}a\\${Q}"
  put "$d/f4.sh" "echo \$${D}x" "echo \$${Q}y\\"
  printf 'echo %sa\r\nb\\\r\nc\r\n' "$Q" > "$d/f5.sh"
  printf 'echo a%sb' "$Q" > "$d/f6.sh"
  put "$d/f7.sh" 'a\ # b' "echo c ${Q}it${D}s${Q} # ${D}"
  put "$d/g0.sh" "echo \;# it${Q}s"
  put "$d/g1.sh" 'a\' "${Q}b"
  put "$d/g2.sh" 'foo\' "# it${Q}s"
  put "$d/g3.sh" "echo a#b${Q}c"
  printf 'foo\\\r\n# it%ss\r\n' "$Q" > "$d/g4.sh"
  printf 'echo a\r# it%ss\n' "$Q" > "$d/g5.sh"
  printf '\xef\xbb\xbf# it%ss\n' "$Q" > "$d/g6.sh"
  printf 'echo \xff%s\n' "$Q" > "$d/g7.sh"
  printf 'echo %sa\0\n' "$Q" > "$d/g8.sh"
  printf '\xef\xbb\xbf\xef\xbb\xbf# it%ss\n' "$Q" > "$d/g9.sh"
  printf 'echo %sa \xed\x95\x9c\xea\xb8\x80 \xf0\x9f\x98\x80\n' "$Q" > "$d/gk.sh"
  printf 'echo %sa\xef\xbf\xbf\n' "$Q" > "$d/gm.sh"
  printf 'echo %sa\xef\xb7\x90\n' "$Q" > "$d/gn.sh"
  printf 'echo %sa\xf4\x8f\xbf\xbf\n' "$Q" > "$d/go.sh"
  printf 'echo %sa\xc0\x80\n' "$Q" > "$d/gp.sh"
  printf 'echo %sa\xed\xa0\x80\n' "$Q" > "$d/gq.sh"
  printf 'echo %sa\xf4\x90\x80\x80\n' "$Q" > "$d/gr.sh"
  # 고정물이 의도한 바이트를 정말 담았는지(글자로 풀려 쓰이지 않았는지) 본다
  [ "$(od -An -tx1 -v "$d/g6.sh" | tr -d ' \n')" = "efbbbf2320697427730a" ] || fail "g6 바이트가 다르다"
  [ "$(od -An -tx1 -v "$d/g7.sh" | tr -d ' \n')" = "6563686f20ff270a" ] || fail "g7 바이트가 다르다"
  [ "$(od -An -tx1 -v "$d/g8.sh" | tr -d ' \n')" = "6563686f202761000a" ] || fail "g8 바이트가 다르다"
  local c k=0
  for c in ';' '&' '|' '(' ')' '<' '>' ' ' $'\t' $'\f' $'\v' $'\x1c' $'\x1d' $'\x1e' $'\x1f'; do
    k=$((k + 1)); printf 'a%s# it%ss\n' "$c" "$Q" > "$d/h$k.sh"
  done
  local files=("$d"/[fgh]*.sh)
  while IFS= read -r f; do files+=("$REPO/$f"); done < <(git -C "$REPO" ls-files '*.sh')
  while IFS=' ' read -r f want; do
    n=$((n + 1)); run "$f"
    if [ "$want" = none ]; then
      { [ -z "$OUT" ] && [ "$RC" = 0 ]; } || fail "$f: 스캐너 none, 여기는 [$OUT]"
    else
      got=${OUT##*:}; { [ "$RC" = 1 ] && [ "$got" = "$want" ]; } || fail "$f: 스캐너 $want, 여기는 [$OUT]"
    fi
  done < <(scanner_end "${files[@]}")
  [ "$n" -gt 0 ] || fail "대조한 파일이 없다"
}

# CASES 에 적힌 이름의 함수가 없으면 그 경우를 FAIL 로 센다. 이 하네스의 복사본에 없는 이름을 끼워 돌려 본다.
t_missing_case_fn() {
  local cp=$TMP/self.sh
  sed -e "s|^HERE=.*|HERE=$HERE|" -e "s|^CASES='|CASES='no_such_case |" "${BASH_SOURCE[0]}" > "$cp"
  OUT=$(ONLY='^no such case$' bash "$cp" 2>&1); RC=$?
  [ "$RC" = 1 ] || fail "exit $RC, want 1 (out: $OUT)"
  case $OUT in *'FAIL no such case: t_no_such_case 함수가 없다'*) ;; *) fail "FAIL 줄이 없다: $OUT" ;; esac
  case $OUT in *'PASS no such case'*) fail "PASS 로 셌다: $OUT" ;; esac
}

CASES='shape38 shape38_unrolled unterminated_double legit_multiline_single ansi_escaped_quote ansi_open dollar_dq_opens_double
hash_after_pipe hash_after_dollar_brace hash_comment_quote escape_does_not_cross_lines backslash_continues_quote
heredoc_odd heredoc_plain crlf no_trailing_newline empty_file reports_start_line
escape_resets_each_line escape_end_keeps_boundary_off escaped_space_is_not_boundary escaped_char_is_not_boundary crlf_comment_boundary comment_boundaries hash_mid_word
bom_stripped binary_skipped dir_ignores_unlisted dir_skips_other_extensions shebang_must_end_at_word
utf8_validity double_bom shebang_one_line_only only_invalid_ere summary_counts_skip
dir_walk shebang_forms file_arg_any_name dir_clean two_args no_args missing_path unreadable
history_aca90b5 history_b225ec5 history_head scanner_differential missing_case_fn'
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
