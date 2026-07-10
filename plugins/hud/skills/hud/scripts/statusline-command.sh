#!/usr/bin/env bash
# 프롬프트마다 실행되는 렌더러이므로 일부 값 누락 시 빈 statusline보다
# 부분 정보를 표시하는 편이 낫다 — `set -euo pipefail`은 의도적으로 제외.

source "$(dirname "${BASH_SOURCE[0]}")/statusline-tokens.sh"

IFS= read -r -d "" input

# 필드 구분자로 탭(\t) 대신 \x1f(unit separator) 사용 — bash read는 IFS가
# space/tab/newline이면 연속 구분자를 하나로 squeeze해 빈 필드가 사라지므로
# (rate_limits 등 값이 자주 비는 필드에서 뒤 필드들이 앞으로 밀리는 버그 유발),
# @tsv 대신 join으로 직접 구성한다.
IFS=$'\x1f' read -r model cwd used_pct total_tokens session_pct session_resets_at transcript_path session_id < <(printf '%s' "$input" | jq -r '
  (.context_window.current_usage // {}) as $u
  | [
      (.model.display_name // .model.id // "unknown"),
      (.cwd // ""),
      (.context_window.used_percentage // "" | tostring),
      (($u.input_tokens // 0)
        + ($u.cache_read_input_tokens // 0)
        + ($u.cache_creation_input_tokens // 0)
        | if . > 0 then tostring else "" end),
      (.rate_limits.five_hour.used_percentage // "" | tostring),
      (.rate_limits.five_hour.resets_at // "" | tostring),
      (.transcript_path // ""),
      (.session_id // "")
    ]
  | join("\u001f")
')

# 모델 표기 압축: "Opus 4.8 (1M context)" → "Opus 4.8 (1M)" (#1750).
model=${model// context/}

abbrev_home() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~%s' "${1#$HOME}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# 표시 경로 압축: ~/ (또는 /) 이하 세그먼트가 3 을 넘으면 마지막 두 레벨만 .../ 로 (#1750).
compact_path() {
    local p="$1" body tilde='~'
    if [ "${p#"$tilde"/}" != "$p" ]; then
        body="${p#"$tilde"/}"
    elif [ "${p#/}" != "$p" ]; then
        body="${p#/}"
    else
        printf '%s' "$p"
        return
    fi
    local IFS=/
    local -a parts
    read -r -a parts <<<"$body"
    local n=${#parts[@]}
    if [ "$n" -gt 3 ]; then
        printf '.../%s/%s' "${parts[n-2]}" "${parts[n-1]}"
    else
        printf '%s' "$p"
    fi
}

display_cwd=""
git_branch=""
if git_info=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null); then
    git_root=${git_info%%$'\n'*}
    br=${git_info#*$'\n'}
    display_cwd=$(abbrev_home "$git_root")
    # detached HEAD -> "HEAD"; 단일 라인 폴백 시 br==git_root -> 브랜치 미표시(구 symbolic-ref 동작 유지).
    if [ "$br" != "HEAD" ] && [ "$br" != "$git_root" ]; then
        git_branch="$br"
    fi
else
    display_cwd=$(abbrev_home "$cwd")
fi
display_cwd=$(compact_path "$display_cwd")

fmt_tokens() {
    local n=$1
    if [ "$n" -ge 1000 ]; then
        local t=$(( (n * 10 + 500) / 1000 ))
        printf '%d.%dk' "$(( t / 10 ))" "$(( t % 10 ))"
    else
        printf '%s' "$n"
    fi
}

ctx_segment=""
if [ -n "$total_tokens" ] && [ -n "$used_pct" ]; then
    ctx_segment="$(printf '%s/%.0f%%' "$(fmt_tokens "$total_tokens")" "$used_pct")"
elif [ -n "$used_pct" ]; then
    ctx_segment="$(printf '%.0f%%' "$used_pct")"
elif [ -n "$total_tokens" ]; then
    ctx_segment="$(fmt_tokens "$total_tokens")"
fi

RESET="\033[0m"
BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
MAGENTA="\033[35m"
RED="\033[31m"
DIM="\033[2m"

# /usage 의 "Current session"(5시간 한도) 과 동일한 값 — 임계값별 색상 (#1750).
# 접두어는 리셋까지 남은 시간을 표시한다: 1시간 초과면 "3.5h:"(소수 첫째 자리
# 반올림), 1시간 이내면 "59m:"(분 단위 반올림). resets_at(Unix epoch 초)이
# 없거나 이미 지난 값이면 고정 "5h:" 로 폴백한다.
session_segment=""
if [ -n "$session_pct" ]; then
    printf -v session_int '%.0f' "$session_pct"
    if [ "$session_int" -ge 80 ]; then
        session_color="$RED"
    elif [ "$session_int" -ge 50 ]; then
        session_color="$YELLOW"
    else
        session_color="$GREEN"
    fi
    session_prefix="5h"
    if [[ "$session_resets_at" =~ ^[0-9]+$ ]]; then
        remaining=$(( session_resets_at - EPOCHSECONDS ))
        if [ "$remaining" -gt 0 ]; then
            if [ "$remaining" -lt 3600 ]; then
                m=$(( (remaining + 30) / 60 ))
                (( m < 1 )) && m=1
                if (( m >= 60 )); then session_prefix="1.0h"; else session_prefix="${m}m"; fi
            else
                tenths=$(( (remaining * 10 + 1800) / 3600 ))
                session_prefix="$(( tenths / 10 )).$(( tenths % 10 ))h"
            fi
        fi
    fi
    session_segment="$(printf '%s%s:%s%%%s' "$session_color" "$session_prefix" "$session_int" "$RESET")"
fi

# 색으로 각 영역이 구분되므로 구분선(|) 없이 공백으로만 분리 (#1750).
SEP=" "

out=""
out+="${BOLD}${GREEN}${model}${RESET}"
out+="${SEP}"
out+="${BOLD}${CYAN}${display_cwd}${RESET}"
# 브랜치는 별도 구분선 대신 디렉터리 뒤 괄호로 합쳐 압축: "<dir> (<branch>)" (#1750).
if [ -n "$git_branch" ]; then
    out+=" ${DIM}(${RESET}${YELLOW}${git_branch}${RESET}${DIM})${RESET}"
fi
if [ -n "$ctx_segment" ]; then
    out+="${SEP}"
    out+="${MAGENTA}${ctx_segment}${RESET}"
fi
if [ -n "$session_segment" ]; then
    out+="${SEP}"
    out+="${session_segment}"
fi

# 세션 누적 토큰 세그먼트 (#1750) — 헬퍼가 선행 구분자 포함 문자열 반환(transcript 없으면 빈 문자열).
out+="$(_token_segment "$transcript_path" "$session_id")"

printf "%b" "$out"
