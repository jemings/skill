#!/usr/bin/env bash
# 세션 누적 토큰 세그먼트 라이브러리 — _token_segment(transcript_path, session_id) 정의만.
# statusline.sh 가 source 후 호출하고, scripts/test-statusline-tokens.sh 가 source 해 단위 테스트한다.
# 로드 시 부수효과 없음(함수 정의뿐). 렌더러 특성상 실패 단계는 빈 문자열/return 으로 나머지 statusline 을 살린다.
#
# 표시값(모두 세션 누적, baseline 차감 후 음수는 0 클램프):
#   total_read = Σ(input + cache_creation + cache_read)
#   cache_read = Σ(cache_read)
#   real_read  = Σ(input + cache_creation)   = total_read − cache_read
#   out        = Σ(output)
# 합산은 message.id 로 디듀프한다 — 트랜스크립트는 한 assistant 메시지를 content
# block 수만큼 같은 usage 로 중복 기록하므로, 디듀프하지 않으면 2~3배 과다 집계된다.

_token_segment() {
  local transcript_path="$1" session_id="$2"
  local cache_dir key cache_file baseline_file mtime
  local s_in s_cc s_cr s_out c_mtime c_in c_cc c_cr c_out sums
  local b_in b_cc b_cr b_out d_in d_cc d_cr d_out
  local total_read cache_read real_read out_tokens f_real f_out ratio
  command -v jq >/dev/null 2>&1 || return
  [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || return

  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
  [ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null

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
    [ -n "${s_out:-}" ] || return
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

  # real_read·out 콤마 포맷 + cache hit ratio. bash 64-bit 정수라 overflow 없음(토큰 규모 << 2^63) — awk fork 제거.
  _comma() { local s=$1 o=; while [ ${#s} -gt 3 ]; do o=",${s: -3}$o"; s=${s:0:${#s}-3}; done; printf '%s%s' "$s" "$o"; }
  f_real=$(_comma "$real_read")
  f_out=$(_comma "$out_tokens")
  ratio=0
  (( total_read > 0 )) && ratio=$(( (cache_read * 100 + total_read / 2) / total_read ))

  RESET='\033[0m'
  GREEN='\033[32m'
  CYAN='\033[36m'
  DIM='\033[2m'

  # real_read 만 표시(↑)하고 cache hit ratio 를 괄호로. ↓ 는 출력 누적.
  # 색: 값=CYAN/GREEN, 비율 괄호=DIM. 선행 공백 한 칸. statusline.sh 가 전체를 printf %b 로 해석.
  printf '%s' " ${CYAN}↑ ${f_real}${RESET}${DIM}(${ratio}%)${RESET} ${GREEN}↓ ${f_out}${RESET}"
}
