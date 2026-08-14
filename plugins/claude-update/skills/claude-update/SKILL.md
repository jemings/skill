---
name: claude-update
license: Apache-2.0
description: >-
  claude-code 네이티브 자동 업데이트(`claude update` / `claude install`)가
  느린 프록시 등으로 다운로드가 오래 걸려 `Download timed out: exceeded the
  total deadline` 로 반복 실패할 때, 릴리스 manifest 의 체크섬으로 무결성을
  검증하며 직접 받아 설치한다. "claude update가 안 돼", "claude 업데이트
  타임아웃", "claude-code 수동 업데이트", "claude update timeout" 같은 요청에
  트리거하라.
allowed-tools: Bash
---

# claude-update — 네이티브 업데이트 타임아웃 우회

## Role

네이티브 설치(`~/.local/share/claude/versions/<version>` + 심링크)의
자동 업데이터는 릴리스 바이너리(플랫폼별 약 300MB)를 받는 동안 고정된
total deadline 을 두는데, 프록시 등으로 처리량이 낮으면 진행률과 무관하게
이 데드라인에 걸려 실패한다. `scripts/update.sh`는:

1. `claude update`를 먼저 그대로 시도한다 — 성공하면 여기서 끝난다.
2. 실패하면 `downloads.claude.ai/claude-code-releases/latest`로 최신
   버전을, `<version>/manifest.json`으로 플랫폼별 다운로드 URL·SHA256·
   크기를 확인한다.
3. curl로 넉넉한 타임아웃(기본 900초, `CLAUDE_UPDATE_MAX_TIME`로 조절)을
   주고 직접 받는다.
4. 받은 파일의 SHA256이 manifest 와 일치하는지 검증한다 — 불일치하면
   설치하지 않고 중단한다.
5. `versions/<latest>`에 배치하고 실행 비트를 설정한 뒤, `claude` 심링크를
   그쪽으로 전환한다.

macOS(darwin-arm64/x64) 와 Linux(linux-x64/arm64, musl 자동 감지)를
지원한다. Windows 는 다루지 않는다.

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/claude-update/scripts/update.sh"
```

## Notes

- **네이티브 설치가 아니면 중단한다.** `claude doctor`의
  `Config install method`가 `native`가 아니면(npm/homebrew 등) 이 스크립트는
  아무것도 하지 않고 안내만 하고 끝난다 — 해당 패키지 매니저로 갱신해야 한다.
- **심링크 구조가 아니면 중단한다.** `command -v claude`가 가리키는 경로가
  심링크가 아니면(비표준 설치) 실행 파일을 잘못 덮어쓸 위험이 있어 안전하게
  중단한다.
- **체크섬 불일치 시 설치하지 않는다.** manifest 의 SHA256과 다르면 절대
  `versions/`에 배치하지 않고 에러로 종료한다 — 무결성 확인 없이 바이너리를
  교체하지 않는다.
- `claude update`가 실패했는데 latest 버전이 현재 버전과 같다면, 원인이
  다운로드 타임아웃이 아닐 수 있다는 안내와 함께 원본 에러를 다시 보라고
  종료한다 — 이 스크립트가 만능 해결책은 아니다.
