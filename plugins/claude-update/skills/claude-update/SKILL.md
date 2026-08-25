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
4. curl 로 직접 받는다 — 총 시간 제한 없이, 120초 넘게 정체한 시도만 끊고
   받아 둔 지점부터 이어받아 재시도한다(진전이 있었던 시도는 재시도 한도를
   소모하지 않는다). 30초마다 진행률·속도·예상 잔여 시간을 한 줄씩 남긴다.
5. SHA256 을 검증한다. 이어받은 파일이 불일치하면 한 번은 처음부터 다시 받아
   보고, 그래도 다르면 지우고 설치하지 않는다.
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

중간 확인이 필요하면 로그 파일을 `tail` 한다 — 30초마다 한 줄씩 쌓인다
(curl 자체 미터는 껐다. `\r` 로 덮어쓰는 한 줄이라 로그에서 못 읽는다).

```
    55%  205MB / 373MB  0.4MB/s  남은 ~7분  경과 450s
```

속도·예상 잔여 시간이 함께 나오므로, 끝날 전송인지 정체된 전송인지를
그 한 줄로 판단한다 — `정체` 가 이어지면 곧 그 시도를 끊고 이어받아
재시도한다.

## Notes

- **중단돼도 이어받는다.** 프록시가 전송을 끊으면 실행 중에 그 지점부터
  이어받아 재시도하고, 스크립트째 죽어도 받다 만 조각이
  `~/.cache/claude-update/` 에 남아 다음 실행이 이어받는다 (릴리스 CDN 이
  Range 지원). 설치가 끝나면 지운다.
- **재시도는 curl 이 아니라 스크립트가 돌린다.** curl 의 `--retry` 는 재시도할 때
  `-C -` 의 이어받기 지점을 다시 계산하지 않아, 이미 받은 300MB 를 버리고 0 부터
  다시 받으며 출력 파일까지 자른다. 그래서 매 시도를 새 curl 로 띄운다.
- **총 시간 제한을 두지 않는다.** 진행 중인 전송을 총 시간으로 끊는 것이 바로
  이 스킬이 우회하려는 실패 방식이다. 대신 120초 동안 1KB/s 미만이면 그 시도만
  끊는다. 굳이 상한이 필요하면 `CLAUDE_UPDATE_MAX_TIME=<초>`.
- **네이티브 설치가 아니면 중단한다.** `claude` 가 심링크가 아니거나,
  레이아웃이 다르면서 `claude doctor` 의 install method 도 `native` 가
  아니면(npm/homebrew 등) 아무것도 하지 않는다 — 해당 패키지 매니저로 갱신해야 한다.
- **체크섬 불일치 시 설치하지 않는다.** manifest 의 SHA256 과 다르면
  `versions/` 에 배치하지 않고 에러로 종료한다. 이어받은 파일이 틀렸을 때는
  (이전 실행분이 상했거나 프록시가 Range 를 무시한 경우) 한 번은 스스로 처음부터
  다시 받아 본 뒤에 판단한다.
- 설치 후에도 **실행 중인 세션은 계속 이전 버전**이다 — 새로 띄우는
  `claude` 부터 적용된다.
- 환경변수: `CLAUDE_UPDATE_MAX_TIME`(0 = 무제한), `CLAUDE_UPDATE_STALL_TIME`(120),
  `CLAUDE_UPDATE_STALL_SPEED`(1024), `CLAUDE_UPDATE_RETRIES`(5 = 진전 없는 시도
  연속 허용 횟수), `CLAUDE_UPDATE_MAX_ATTEMPTS`(30), `CLAUDE_UPDATE_RETRY_DELAY`(5),
  `CLAUDE_UPDATE_PROGRESS_INTERVAL`(30), `CLAUDE_UPDATE_CACHE_DIR`,
  `CLAUDE_UPDATE_FORCE`, `CLAUDE_UPDATE_RELEASES_BASE`.
