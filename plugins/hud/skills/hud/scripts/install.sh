#!/usr/bin/env bash
# hud 스킬 설치: 두 statusline 스크립트 배치 + settings.json statusLine 병합 + 동작 확인.
# 기존 스크립트가 있고 내용이 다르면 diff 를 경고로 stderr에 출력한 뒤 덮어쓴다.
# 단, 소스의 버전 표식(hud-statusline-version)이 설치본보다 낮으면 다운그레이드로
# 판단해 exit 3 으로 차단한다 — 낡은 플러그인 캐시에서 실행된 경우가 전형.
# FORCE=1 로만 강제 덮어쓸 수 있다.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_HUD_DEST:-$HOME/.claude}"

command -v jq >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || {
  echo "jq/bash 가 필요합니다." >&2
  exit 1
}

# 버전 표식 추출 — 표식이 없는 파일(v1 이전 설치본·소스)은 0 으로 간주.
# 선행 0 은 벗겨 문자열 동등/대소 비교가 수치와 일치하게 한다.
_ver() {
  local v
  v=$(sed -n 's/^# hud-statusline-version: 0*\([0-9][0-9]*\)$/\1/p' "$1" 2>/dev/null | head -1) || true
  printf '%s' "${v:-0}"
}

# 십진수 문자열 비교($1 < $2) — test -lt 는 int64 초과 값에 status 2 를 내
# if 조건에서 false 취급되어 가드가 fail-open 되므로, 자릿수→사전순으로 비교한다.
_num_lt() {
  if [ ${#1} -ne ${#2} ]; then [ ${#1} -lt ${#2} ]; else [[ "$1" < "$2" ]]; fi
}

mkdir -p "$DEST"

# 1패스: 다운그레이드 가드 — 경고·복사 이전에 두 파일 모두 판정한다
# (뒤 파일 차단 시 앞 파일의 '덮어씁니다' 경고가 거짓이 되는 것을 방지).
for f in statusline-command.sh statusline-tokens.sh; do
  [ -f "$DEST/$f" ] || continue
  diff -q "$SRC/$f" "$DEST/$f" >/dev/null 2>&1 && continue
  src_v=$(_ver "$SRC/$f")
  dest_v=$(_ver "$DEST/$f")
  if _num_lt "$src_v" "$dest_v" && [ "${FORCE:-0}" != 1 ]; then
    {
      echo "오류: 설치를 중단합니다 — $f 소스(v$src_v)가 설치본(v$dest_v)보다 오래된 버전입니다. 아무 파일도 덮어쓰지 않았습니다."
      echo "낡은 플러그인 캐시에서 실행됐을 수 있습니다. 소스를 갱신한 뒤 다시 실행하세요:"
      echo "  claude plugin marketplace update skill && claude plugin update hud@skill"
      echo "그래도 이 소스로 덮어쓰려면 FORCE=1 을 붙여 재실행하세요."
    } >&2
    exit 3
  fi
done

# 2패스: 가드를 전부 통과했을 때만 덮어쓰기 경고·diff 를 출력한다.
for f in statusline-command.sh statusline-tokens.sh; do
  [ -f "$DEST/$f" ] || continue
  diff -q "$SRC/$f" "$DEST/$f" >/dev/null 2>&1 && continue
  echo "경고: 기존 $DEST/$f 를 아래 내용으로 덮어씁니다:" >&2
  if [ "$(_ver "$SRC/$f")" = "$(_ver "$DEST/$f")" ]; then
    echo "경고: 버전 표식이 같은데 내용이 다릅니다 — 스크립트 수정 시 두 파일의 hud-statusline-version 을 함께 올려야 다운그레이드 가드가 동작합니다." >&2
  fi
  diff -u "$DEST/$f" "$SRC/$f" >&2 || true
done

cp "$SRC/statusline-command.sh" "$DEST/statusline-command.sh"
cp "$SRC/statusline-tokens.sh" "$DEST/statusline-tokens.sh"
chmod +x "$DEST/statusline-command.sh" "$DEST/statusline-tokens.sh"

SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
if jq '.statusLine = {"type":"command","command":"bash ~/.claude/statusline-command.sh"}' "$SETTINGS" >"$TMP"; then
  mv "$TMP" "$SETTINGS"
else
  echo "settings.json 병합 실패 (원본 보존됨)" >&2
  exit 2
fi

echo '{"model":{"display_name":"Sonnet 5"},"cwd":"'"$HOME"'","context_window":{"used_percentage":12}}' | bash "$DEST/statusline-command.sh"
echo
