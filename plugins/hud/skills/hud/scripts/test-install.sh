#!/usr/bin/env bash
# scripts/install.sh 의 통합 테스트 — 실제 ~/.claude 는 건드리지 않고
# CLAUDE_HUD_DEST 로 mktemp 디렉터리에 격리해 실행한다.
#
# 실행:
#   bash skills/hud/scripts/test-install.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${SCRIPT_DIR}/install.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_zero() {
  local desc="$1" actual="$2"
  if [[ "$actual" == 0 ]]; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    printf '  ❌ %s — expected rc=0, got %s\n' "$desc" "$actual"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    printf '  ❌ %s — expected %s, got %s\n' "$desc" "$expected" "$actual"
  fi
}

DEST="$(mktemp -d)"
trap 'rm -rf "$DEST"' EXIT

# 최초 설치: 파일 배치 + settings.json 생성 + 샘플 렌더 성공.
CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null
assert_zero "최초 설치 exit=0" $?
assert_zero "statusline-command.sh 배치됨" "$([ -x "$DEST/statusline-command.sh" ]; echo $?)"
assert_zero "statusline-tokens.sh 배치됨" "$([ -x "$DEST/statusline-tokens.sh" ]; echo $?)"
assert_eq "settings.json 에 statusLine 등록" "bash ~/.claude/statusline-command.sh" \
  "$(jq -r '.statusLine.command' "$DEST/settings.json")"

# 기존 settings.json 필드는 보존.
echo '{"theme":"dark","hooks":{"x":1}}' >"$DEST/settings.json"
CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null
assert_eq "기존 theme 보존" "dark" "$(jq -r '.theme' "$DEST/settings.json")"
assert_eq "기존 hooks 보존" "1" "$(jq -r '.hooks.x' "$DEST/settings.json")"

# 재실행(파일 동일) — idempotent, exit=0.
CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null
assert_zero "재실행 idempotent" $?

# 기존 스크립트가 달라도(표식 없음 = v0 → 업그레이드) 경고(stderr diff) 후 덮어씀 — 차단하지 않음.
echo 'echo custom' >"$DEST/statusline-command.sh"
STDERR_OUT="$(CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" 2>&1 1>/dev/null)"
assert_zero "커스터마이즈 있어도 설치 exit=0" $?
assert_zero "덮어쓴 후 원본과 동일" "$(diff -q "$DEST/statusline-command.sh" "$SCRIPT_DIR/statusline-command.sh" >/dev/null; echo $?)"
assert_zero "덮어쓸 때 경고 출력" "$([[ "$STDERR_OUT" == *"경고"* ]]; echo $?)"

# 두 스크립트의 버전 표식은 쌍 단일 버전 규칙에 따라 항상 일치해야 한다.
_marker() { sed -n 's/^# hud-statusline-version: \([0-9][0-9]*\)$/\1/p' "$1" | head -1; }
SRC_VER="$(_marker "$SCRIPT_DIR/statusline-command.sh")"
assert_zero "소스에 버전 표식 존재" "$([[ -n "$SRC_VER" ]]; echo $?)"
assert_eq "두 스크립트 버전 표식 일치" "$SRC_VER" "$(_marker "$SCRIPT_DIR/statusline-tokens.sh")"

# 다운그레이드 차단: 설치본 표식이 소스보다 높으면 exit 3 + 설치본 보존 + settings 미변경.
# command.sh 도 함께 다르게 만들어(표식 없는 커스텀본) 차단 시 앞 파일의
# '덮어씁니다' 경고가 출력되지 않는 것(2패스 분리)까지 검증한다.
sed "s/^# hud-statusline-version: .*/# hud-statusline-version: 999/" \
  "$DEST/statusline-tokens.sh" >"$DEST/statusline-tokens.sh.new" &&
  mv "$DEST/statusline-tokens.sh.new" "$DEST/statusline-tokens.sh"
echo 'echo custom' >"$DEST/statusline-command.sh"
echo '{"theme":"dark"}' >"$DEST/settings.json"
STDERR_OUT="$(CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" 2>&1 1>/dev/null)"
assert_eq "다운그레이드 소스 차단 (exit=3)" 3 $?
assert_eq "차단 시 설치본 보존" 999 "$(_marker "$DEST/statusline-tokens.sh")"
assert_eq "차단 시 다른 파일도 보존" "echo custom" "$(cat "$DEST/statusline-command.sh")"
assert_zero "차단 시 settings.json 미변경" "$([[ "$(cat "$DEST/settings.json")" == '{"theme":"dark"}' ]]; echo $?)"
assert_zero "차단 사유·갱신 방법 안내" "$([[ "$STDERR_OUT" == *"오래된 버전"* && "$STDERR_OUT" == *"marketplace update"* ]]; echo $?)"
assert_zero "차단 시 덮어쓰기 경고 미출력" "$([[ "$STDERR_OUT" != *"덮어씁니다"* ]]; echo $?)"

# FORCE=1 이면 다운그레이드도 덮어씀.
FORCE=1 CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null 2>&1
assert_zero "FORCE=1 강제 설치 exit=0" $?
assert_zero "FORCE=1 후 원본과 동일" "$(diff -q "$DEST/statusline-tokens.sh" "$SCRIPT_DIR/statusline-tokens.sh" >/dev/null; echo $?)"

# int64 초과 표식도 fail-closed: test -lt 였다면 status 2 → false 로 가드가 뚫린다.
sed "s/^# hud-statusline-version: .*/# hud-statusline-version: 99999999999999999999/" \
  "$DEST/statusline-tokens.sh" >"$DEST/statusline-tokens.sh.new" &&
  mv "$DEST/statusline-tokens.sh.new" "$DEST/statusline-tokens.sh"
STDERR_OUT="$(CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" 2>&1 1>/dev/null)"
assert_eq "int64 초과 표식도 차단 (exit=3)" 3 $?
assert_zero "int64 초과 시 오류 없이 안내 출력" "$([[ "$STDERR_OUT" == *"오래된 버전"* && "$STDERR_OUT" != *"integer expression"* ]]; echo $?)"
FORCE=1 CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null 2>&1  # 원상복구

# 같은 표식·다른 내용이면 덮어쓰되 버전 미증가 경고를 낸다.
printf '\n# local tweak\n' >>"$DEST/statusline-command.sh"
STDERR_OUT="$(CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" 2>&1 1>/dev/null)"
assert_zero "동일 표식·다른 내용 설치 exit=0" $?
assert_zero "버전 미증가 경고 출력" "$([[ "$STDERR_OUT" == *"함께 올려야"* ]]; echo $?)"
assert_zero "덮어쓴 후 원본과 동일 (동일 표식)" "$(diff -q "$DEST/statusline-command.sh" "$SCRIPT_DIR/statusline-command.sh" >/dev/null; echo $?)"

# 개발 시점 표식 증가 강제: 워킹트리 스크립트가 HEAD 와 다르면 표식도 커져야 한다.
# 표식 미증가로 배포되면 같은 표식의 낡은 캐시가 신규 설치본을 exit 0 으로 되돌려
# 가드가 무력화되므로, 배포 전에 여기서 잡는다. git 밖(플러그인 캐시 등)이면 skip.
if PREFIX="$(git -C "$SCRIPT_DIR" rev-parse --show-prefix 2>/dev/null)"; then
  for f in statusline-command.sh statusline-tokens.sh; do
    if head_body="$(git -C "$SCRIPT_DIR" show "HEAD:${PREFIX}${f}" 2>/dev/null)"; then
      if ! printf '%s\n' "$head_body" | diff -q - "$SCRIPT_DIR/$f" >/dev/null 2>&1; then
        head_v="$(printf '%s\n' "$head_body" | sed -n 's/^# hud-statusline-version: 0*\([0-9][0-9]*\)$/\1/p' | head -1)"
        cur_v="$(_marker "$SCRIPT_DIR/$f")"
        assert_zero "$f 내용 변경 시 표식 증가 (HEAD v${head_v:-0} → v${cur_v:-0})" \
          "$([ "${cur_v:-0}" -gt "${head_v:-0}" ]; echo $?)"
      fi
    fi
  done
fi

echo ""
echo "── 결과 ───────────────────────────────────────────────────"
echo "  통과: $PASS / 실패: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n실패한 테스트:\n'
  for t in "${FAILED_TESTS[@]}"; do
    printf '  - %s\n' "$t"
  done
  exit 1
fi
