---
name: hud
license: Apache-2.0
description: >-
  현재 환경에 전역으로 설정된 Claude Code statusline(모델 · 작업 디렉터리/git
  브랜치 · 컨텍스트 사용률 · 세션 누적 토큰)을 다른 새 환경에도 동일하게
  설치한다. /hud 또는 "statusline 설치해줘", "새 환경에 statusline 셋업",
  "hud 설치", "statusline 복제/옮겨줘"처럼 statusline 설치·복제를 요청하면
  트리거하라.
allowed-tools: Bash, Read, Write
---

# hud — statusline 빠른 셋업

## Role

이 스킬이 들고 있는 두 스크립트(`scripts/statusline-command.sh`,
`scripts/statusline-tokens.sh`)를 `~/.claude/`에 설치하고
`~/.claude/settings.json`의 `statusLine` 필드를 구성한다. 결과는 모델명 ·
작업 디렉터리(git 브랜치 포함) · 컨텍스트 사용률 · 세션 누적 토큰(↑입력/캐시,
↓출력)을 한 줄로 보여주는 statusline이다.

## Step 1: 사전 확인

- `jq`, `bash` 설치 확인 (`command -v jq bash`). 없으면 설치 안내 후 중단.
- `~/.claude/statusline-command.sh` 또는 `statusline-tokens.sh`가 이미
  존재하고 이 스킬이 설치할 내용과 다르면, 덮어쓰기 전에 `diff`를 보여주고
  진행 여부를 확인받는다 (사용자가 직접 커스터마이즈했을 수 있음).

## Step 2: 스크립트 설치

```bash
cp "${CLAUDE_PLUGIN_ROOT}/skills/hud/scripts/statusline-command.sh" ~/.claude/statusline-command.sh
cp "${CLAUDE_PLUGIN_ROOT}/skills/hud/scripts/statusline-tokens.sh" ~/.claude/statusline-tokens.sh
chmod +x ~/.claude/statusline-command.sh ~/.claude/statusline-tokens.sh
```

두 파일은 반드시 같은 디렉터리에 있어야 한다 — `statusline-command.sh`가
`$(dirname "$0")/statusline-tokens.sh`로 옆 파일을 찾기 때문에, 다른 경로에
설치하면 토큰 세그먼트가 빠진다.

## Step 3: settings.json에 statusLine 등록

`~/.claude/settings.json`의 다른 필드(`hooks`, `theme` 등)는 그대로 두고
`statusLine`만 병합한다:

```bash
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
TMP=$(mktemp) && trap 'rm -f "$TMP"' EXIT
jq '.statusLine = {"type":"command","command":"bash ~/.claude/statusline-command.sh"}' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

## Step 4: 동작 확인

샘플 입력으로 렌더링이 끊기지 않는지 확인한다:

```bash
echo '{"model":{"display_name":"Sonnet 5"},"cwd":"'"$HOME"'","context_window":{"used_percentage":12}}' | bash ~/.claude/statusline-command.sh; echo
```

ANSI 색상이 섞인 한 줄(`Sonnet 5  ~  12%`)이 출력되면 성공. 다음 Claude Code
세션부터(또는 즉시) 하단에 반영된다.

## Notes

- 세션 누적 토큰 세그먼트(↑/↓)는 `~/.cache/claude-statusline/`에
  transcript별 캐시·baseline 파일을 둔다 — 설치 시점에는 생성되지 않고 첫
  실제 렌더에서 자동 생성된다.
- 스크립트는 ANSI 이스케이프만 사용하므로 터미널 테마와 무관하게 동작한다.
- 기존 `statusLine.command`가 이 스킬이 설치한 것과 다른 커스텀 명령이면,
  Step 3에서 덮어쓰기 전에 사용자에게 알리고 확인받는다.
