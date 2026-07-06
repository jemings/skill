#!/usr/bin/env bash
# 세션 누적 토큰 세그먼트 — statusline JSON 을 stdin 으로 받아 transcript 를 합산해
# "↑ <total_read> C <cache_read> R <real_read> │ ↓ <out>" 세그먼트(선행 구분자 포함)를
# 출력한다 (#1750). 자기완결형: jq 외 외부 의존 없음.
#
# 렌더러 특성상 일부 단계 실패 시 빈 문자열을 출력해 나머지 statusline 을 살린다 —
# statusline.sh 와 동일하게 `set -euo pipefail` 은 의도적으로 제외한다.
#
# 표시값(모두 세션 누적, baseline 차감 후 음수는 0 클램프):
#   total_read = Σ(input + cache_creation + cache_read)
#   cache_read = Σ(cache_read)
#   real_read  = Σ(input + cache_creation)   = total_read − cache_read
#   out        = Σ(output)
#
# 합산은 message.id 로 디듀프한다 — 트랜스크립트는 한 assistant 메시지를 content
# block 수만큼 같은 usage 로 중복 기록하므로, 디듀프하지 않으면 2~3배 과다 집계된다.

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

IFS=$'\t' read -r transcript_path session_id < <(
  printf '%s' "$input" | jq -r '[(.transcript_path // ""), (.session_id // "")] | @tsv' 2>/dev/null
)

[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || exit 0

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$cache_dir" 2>/dev/null

# session_id 가 비면 transcript 경로 해시로 폴백 — 캐시/baseline 키 안정성 보장.
key="$session_id"
if [ -z "$key" ]; then
  key=$(printf '%s' "$transcript_path" | (sha1sum || shasum || cksum) 2>/dev/null | tr -cd '[:alnum:]' | cut -c1-16)
fi
cache_file="$cache_dir/tokens-cache-$key"
baseline_file="$cache_dir/tokens-baseline-$key"

# 비음수 정수만 통과시키고 그 외엔 0 으로 강제 (손상된 캐시/baseline 방어).
_uint() { case "$1" in '' | *[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

# transcript mtime (cross-platform: GNU stat → BSD stat 폴백).
mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || stat -f %m "$transcript_path" 2>/dev/null || echo 0)

# mtime-키 캐시 hit 이면 jq 재계산 생략 (같은 턴 내 다중 렌더 대비).
s_in=""
if [ -f "$cache_file" ]; then
  read -r c_mtime c_in c_cc c_cr c_out <"$cache_file" 2>/dev/null
  if [ "$c_mtime" = "$mtime" ] && [ -n "${c_out:-}" ]; then
    s_in=$(_uint "$c_in")
    s_cc=$(_uint "$c_cc")
    s_cr=$(_uint "$c_cr")
    s_out=$(_uint "$c_out")
  fi
fi

# 캐시 miss → 트랜스크립트 스트리밍 합산(reduce inputs, 메모리 안전) + 디듀프.
if [ -z "$s_in" ]; then
  sums=$(jq -nr '
    reduce inputs as $l ({seen: {}, in: 0, cc: 0, cr: 0, out: 0};
      if ($l.type == "assistant")
         and ($l.message.usage != null)
         and ($l.message.id != null)
         and ((.seen[$l.message.id] // false) | not)
      then .seen[$l.message.id] = true
         | .in  += ($l.message.usage.input_tokens // 0)
         | .cc  += ($l.message.usage.cache_creation_input_tokens // 0)
         | .cr  += ($l.message.usage.cache_read_input_tokens // 0)
         | .out += ($l.message.usage.output_tokens // 0)
      else . end)
    | "\(.in)\t\(.cc)\t\(.cr)\t\(.out)"
  ' "$transcript_path" 2>/dev/null)
  IFS=$'\t' read -r s_in s_cc s_cr s_out <<<"$sums"
  [ -n "${s_out:-}" ] || exit 0
  # PID 접미사로 temp 파일을 프로세스별 고유화 — 동시 렌더(다중 pane) 시 공유 temp clobber 방지 (PR #1752 리뷰).
  printf '%s %s %s %s %s\n' "$mtime" "$s_in" "$s_cc" "$s_cr" "$s_out" >"$cache_file.tmp.$$" 2>/dev/null &&
    mv "$cache_file.tmp.$$" "$cache_file" 2>/dev/null
fi

# baseline 차감 (파일 없으면 0 → 세션 시작부터 전체 누적).
b_in=0 b_cc=0 b_cr=0 b_out=0
if [ -f "$baseline_file" ]; then
  read -r b_in b_cc b_cr b_out <"$baseline_file" 2>/dev/null
  b_in=$(_uint "$b_in") b_cc=$(_uint "$b_cc") b_cr=$(_uint "$b_cr") b_out=$(_uint "$b_out")
fi

_delta() {
  local v=$(($1 - $2))
  ((v < 0)) && v=0
  printf '%s' "$v"
}
d_in=$(_delta "$s_in" "$b_in")
d_cc=$(_delta "$s_cc" "$b_cc")
d_cr=$(_delta "$s_cr" "$b_cr")
d_out=$(_delta "$s_out" "$b_out")

total_read=$((d_in + d_cc + d_cr))
cache_read=$d_cr
real_read=$((d_in + d_cc))
out_tokens=$d_out

# real_read·out 콤마 포맷 + cache hit ratio(= cache_read/total_read, 반올림 %).
# 비율은 큰 수 곱(cache_read*100) 의 bash 정수 overflow 회피 위해 awk(double)에서 계산.
IFS=$'\t' read -r f_real f_out ratio < <(
  awk -v c="$real_read" -v d="$out_tokens" -v cr="$cache_read" -v tot="$total_read" '
    function g(n,   s, neg, o) {
      s = sprintf("%d", n); neg = "";
      if (substr(s, 1, 1) == "-") { neg = "-"; s = substr(s, 2) }
      o = "";
      while (length(s) > 3) { o = "," substr(s, length(s) - 2) o; s = substr(s, 1, length(s) - 3) }
      return neg s o
    }
    BEGIN {
      r = (tot > 0) ? int(cr * 100 / tot + 0.5) : 0
      printf "%s\t%s\t%d", g(c), g(d), r
    }
  '
)

RESET='\033[0m'
GREEN='\033[32m'
CYAN='\033[36m'
DIM='\033[2m'

# real_read 만 표시(↑)하고 cache hit ratio 를 괄호로. ↓ 는 출력 누적.
# 색: 값=CYAN/GREEN, 비율 괄호=DIM. 선행 공백 한 칸. statusline.sh 가 전체를 printf %b 로 해석.
printf '%s' " ${CYAN}↑ ${f_real}${RESET}${DIM}(${ratio}%)${RESET} ${GREEN}↓ ${f_out}${RESET}"
