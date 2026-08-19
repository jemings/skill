---
name: claude-update
license: Apache-2.0
description: >-
  claude-code 네이티브 자동 업데이트(`claude update` / `claude install`)가
  느린 프록시 등으로 `Download timed out: exceeded the total deadline` 로
  실패할 때, 그 경로를 건너뛰고 릴리스 manifest 의 체크섬을 검증하며 직접
  받아 설치한다. "claude update가 안 돼", "claude 업데이트 타임아웃",
  "claude-code 수동 업데이트", "claude update timeout" 같은 요청에 트리거하라.
allowed-tools: Bash
---

# claude-update — 네이티브 업데이터 우회 설치

## Role

네이티브 설치(`~/.local/share/claude/versions/<version>` + 심링크)의 자동
업데이터는 ~300MB 바이너리를 받는 동안 고정된 total deadline 을 두어서, 느린
프록시에서는 진행률과 무관하게 매번 실패한다. **실패가 확인된 이 경로는
시도하지 않는다.** `scripts/update.sh`는 처음부터 직접 설치한다:

1. 심링크 구조를 확인한다 — 심링크 대상의 basename 이 곧 현재 버전이라
   `claude --version`/`claude doctor` 를 띄우지 않는다 (레이아웃이 예상과
   다를 때만 `claude doctor` 로 되물어 npm/homebrew 설치를 걸러낸다).
2. `.../claude-code-releases/latest` 로 최신 버전을 확인하고, 이미 최신이면
   즉시 끝낸다 (같은 버전 재설치는 `CLAUDE_UPDATE_FORCE=1`).
3. `<version>/manifest.json` 에서 플랫폼별 파일명·SHA256·크기를 읽는다.
4. curl 로 직접 받는다 — 시도당 900초, 5회 재시도, `-C -` 이어받기,
   30초마다 진행률 한 줄.
5. SHA256 을 검증한다. 불일치면 받은 파일을 지우고 설치하지 않는다.
6. `versions/<latest>` 에 원자적으로 배치(임시파일 → `mv`)한 뒤 심링크를
   전환한다 — 실행 중인 프로세스의 바이너리를 덮어쓰지 않는다.

macOS(darwin-arm64/x64) 와 Linux(linux-x64/arm64, musl 자동 감지)를 지원한다.
Windows 는 다루지 않는다.

## Run

**반드시 Bash 도구의 `run_in_background: true` 로 실행한다.** 프록시에서
300MB 는 10분 이상 걸려 포그라운드로 돌리면 도구 타임아웃에 걸린다.
백그라운드로 띄우면 완료 시 알림이 오므로, 그 전까지 성공/실패를 단정하지 않는다.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/claude-update/scripts/update.sh"
```

중간 확인이 필요하면 로그 파일을 `tail` 한다 — 진행률이 30초마다 한 줄씩
쌓인다 (curl 자체 미터는 껐다. `\r` 로 덮어쓰는 한 줄이라 로그에서 못 읽는다).

## Notes

- **중단돼도 이어받는다.** 받다 만 조각은 `~/.cache/claude-update/` 에 남고,
  다시 실행하면 그 지점부터 이어받는다 (릴리스 CDN 이 Range 지원). 설치가
  끝나면 지운다.
- **네이티브 설치가 아니면 중단한다.** `claude` 가 심링크가 아니거나,
  레이아웃이 다르면서 `claude doctor` 의 install method 도 `native` 가
  아니면(npm/homebrew 등) 아무것도 하지 않는다 — 해당 패키지 매니저로 갱신해야 한다.
- **체크섬 불일치 시 설치하지 않는다.** manifest 의 SHA256 과 다르면
  `versions/` 에 배치하지 않고 에러로 종료한다.
- 설치 후에도 **실행 중인 세션은 계속 이전 버전**이다 — 새로 띄우는
  `claude` 부터 적용된다.
- 환경변수: `CLAUDE_UPDATE_MAX_TIME`(900), `CLAUDE_UPDATE_PROGRESS_INTERVAL`(30),
  `CLAUDE_UPDATE_CACHE_DIR`, `CLAUDE_UPDATE_FORCE`, `CLAUDE_UPDATE_RELEASES_BASE`.
