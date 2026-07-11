---
name: hud
license: Apache-2.0
description: >-
  현재 환경에 설정된 Claude Code statusline을 다른 새 환경에도 동일하게
  설치한다. /hud 또는 "statusline 설치해줘", "새 환경에 statusline 셋업",
  "hud 설치", "statusline 복제/옮겨줘"처럼 statusline 설치·복제를 요청하면
  트리거하라.
allowed-tools: Bash, Read
---

# hud — statusline 빠른 셋업

## Role

`scripts/install.sh`가 두 statusline 스크립트를 `~/.claude/`에 배치하고
`~/.claude/settings.json`의 `statusLine` 필드를 병합한다. 결과는 모델명 ·
작업 디렉터리(git 브랜치 포함) · 컨텍스트 사용률 · 5시간 한도 사용률(`/usage`의
"Current session"과 동일 값, 임계값별 색상) · 세션 누적 토큰(↑입력/캐시,
↓출력)을 한 줄로 보여주는 statusline이다. 5시간 한도 세그먼트의 접두어는 리셋까지
남은 시간을 표시한다 — 1시간 초과면 `3.5h:`(소수 첫째 자리 반올림), 1시간 이내면
`59m:`(분 단위). 이 세그먼트는 claude.ai 구독 계정에만 표시되며, API 키 세션에서는
생략된다.

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/hud/scripts/install.sh"
```

성공·실패 원인과 조치는 stdout/stderr에 그대로 나온다(성공 시 샘플 렌더,
실패 시 원인 메시지). 기존 스크립트가 설치할 내용과 다르면 diff를 경고로
보여준 뒤 덮어쓴다. 단, 소스의 버전 표식(`hud-statusline-version`)이 설치본보다
낮으면 다운그레이드로 판단해 exit 3 으로 차단하고 소스 갱신 방법을 안내한다 —
낡은 플러그인 캐시에서 실행된 경우가 전형이다. 사용자가 명시적으로 원할 때만
`FORCE=1` 로 강제 덮어쓴다.

## Notes

세션 누적 토큰 세그먼트(↑/↓)는 `~/.cache/claude-statusline/`에 transcript별
캐시·baseline 파일을 둔다 — 설치 시점에는 생성되지 않고 첫 실제 렌더에서
자동 생성된다.

다운그레이드 가드는 가드가 포함된 소스(hud 1.1.0+)에서 실행될 때만 동작한다 —
가드 이전 버전이 남아 있는 플러그인 캐시가 install.sh 를 실행하면 여전히
설치본을 되돌릴 수 있으므로, 각 환경에서 한 번은
`claude plugin marketplace update skill && claude plugin update hud@skill` 로
캐시를 갱신해 두어야 가드가 유효하다.
