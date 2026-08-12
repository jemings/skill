# CLAUDE.md

Claude Code 스킬을 독립 설치 가능한 플러그인으로 배포하는 마켓플레이스 리포다.
각 플러그인은 `plugins/<name>/` 아래에 있고, 루트 `.claude-plugin/marketplace.json`
이 목록을 정의한다.

## 플러그인을 수정하면 plugin.json 의 version 을 반드시 올린다

`claude plugin update <name>@skill` 은 **`plugins/<name>/.claude-plugin/plugin.json`
의 `version` 필드만** 보고 갱신 여부를 판단한다. 버전이 그대로면 파일이 아무리
바뀌었어도 `already at the latest version` 으로 끝나고, 이미 그 버전을 받아간
사용자에게는 변경이 영원히 전달되지 않는다.

따라서 `plugins/<name>/` 아래 파일을 고쳤다면 **같은 PR 안에서** 그 플러그인의
`plugin.json` version 을 올린다. 문서·주석만 손봤어도 마찬가지다 — 전달되지 않는
문서 수정은 의미가 없다. semver 기준은 동작 변경 없는 정리는 patch, 기능 추가나
사용자에게 보이는 표시 변경은 minor.

새 플러그인을 추가할 때는 루트 `.claude-plugin/marketplace.json` 의 `plugins`
배열에도 등록해야 마켓플레이스에 노출된다.

플러그인 이름을 바꿀 때는 디렉터리·`plugin.json`·`SKILL.md` 개명뿐 아니라
`marketplace.json` 의 `renames` 맵에도 `"옛이름": "새이름"` 항목을 추가해야
한다 — 그래야 이미 옛 이름으로 설치한 사용자가 다음 동기화에서 자동으로
새 이름으로 이전된다. 누락하면 해당 사용자의 설치가 끊긴 채로 남는다.

## statusline-kit statusline 스크립트는 별도 표식을 함께 올린다

`statusline-command.sh` / `statusline-tokens.sh` 는 `install.sh` 의 다운그레이드
가드가 비교하는 `# statusline-kit-version: N` 표식을 각각 갖는다. 이는 plugin.json
의 version 과 **별개의 축**이며 — 전자는 낡은 캐시가 최신 설치본을 되돌리는 것을
막고, 후자는 캐시 자체의 갱신을 트리거한다 — 둘 중 **한 파일이라도 고치면 두 파일
모두 +1** 한다. `scripts/test-install.sh` 가 워킹트리와 HEAD 를 비교해 이 규칙을
강제하므로, statusline-kit 을 수정했다면 커밋 전에 반드시 돌린다:

```bash
bash plugins/statusline-kit/skills/statusline-kit/scripts/test-install.sh
```
