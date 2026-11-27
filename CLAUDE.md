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

## agent-dispatch 스크립트를 고치면 시험 하네스를 돌린다

`plugins/agent-dispatch/skills/agent-dispatch/scripts/` 의 `wait-prs.sh` /
`in-flight.sh` 를 고쳤다면 커밋 전에 하네스를 돌린다. `land.sh` / `pr-check.sh` /
`temp-tree.sh` / `mutate.sh` / `frontier.sh` 는 `test-tools.sh` 가 본다(gh 스텁, 진짜 git,
임시 bare 원격 -- 네트워크 없음, `ONLY='<ERE>'` 로 경우를 고른다):

```bash
bash plugins/agent-dispatch/skills/agent-dispatch/scripts/test-tools.sh
```

`wait-prs.sh` / `in-flight.sh` 의 하네스: `gh` 는 스텁으로 갈음하므로
네트워크가 필요 없고, `bash:3.2` 이미지가 있으면 빈 배열 펼침 같은 하위 bash 회귀도
컨테이너에서 확인한다(없으면 그 경우만 SKIP). 새 배열을 더했다면 정적 검사가
길이 확인 없는 펼침을 잡으니 `${a[@]+"${a[@]}"}` 꼴로 쓴다:

```bash
bash plugins/agent-dispatch/skills/agent-dispatch/scripts/test-scripts.sh
```

`SKILL.md` 와 `references/` 를 고쳐도 `test-scripts.sh` 를 돌린다. 정적 검사가 SKILL.md 의
스크립트 호출과 0단계, 지시문의 정책 문장(draft, ready/병합/PR 댓글 금지, 스킬 기본값보다 앞섬),
pstack 이름과 버전 경로가 없는지, 규율 카드의 칸, 트래커 조회 예시가 본문을 내는지를 본다.

경우 하나를 고쳐 다시 볼 때는 `ONLY='<ERE>'` 로 라벨(`PASS`/`FAIL` 줄의 글)이 맞는
경우만 돌린다(맞는 것이 없으면 exit 1, ERE 가 올바르지 않으면 exit 2). 리뷰의 변이
확인은 손으로 사본을 고치지 말고 `MUTATE='in-flight.sh:s/exit 2/exit 1/'
ONLY='git 밖'` 처럼 쓴다. `$TMP` 의 사본에만 변이를 걸어 원본은 그대로이고, FAIL 이
있으면 `MUTANT KILLED`(exit 0), 없으면 `MUTANT SURVIVED`(exit 1, 거짓 시험)이다.
변이가 틀렸거나 아무것도 안 바꿨거나 돈 경우가 없으면(`MUTATE` 와 함께 `ONLY` 에
맞는 것이 없을 때도) exit 2 다.

## agent-dispatch 는 문장부호를 ASCII 로 쓴다

`agent-dispatch` 의 사내 배포 사본은 원본과 바이트 단위로 같아야 동기화가 쉽다.
그런데 사내 스킬 스캐너는 em dash 하나에도 HIGH finding 을 내고 실패로 판정하므로,
원본에 섞인 문장부호를 사본에서 따로 치환하면 사본이 원본과 달라진다. 그래서
원본부터 ASCII 로 쓴다.

`plugins/agent-dispatch/` 아래에는 한글 말고 non-ASCII 문자를 쓰지 않는다
(가운뎃점, em dash, 화살표, 말줄임표, 이모지 등). 대신 `, ` `/` ` -- ` `->` `...`
를 쓰고 장식 기호는 말로 푼다. 이 디렉터리를 고쳤다면 커밋 전에 반드시 돌린다.
걸리는 문자가 있으면 exit 1 과 함께 `파일:줄:문자 U+XXXX` 로 낸다:

```bash
bash scripts/check-ascii.sh plugins/agent-dispatch
```

## agent-dispatch 의 셸 스크립트를 고치면 따옴표 짝을 검사한다

사내 스킬 스캐너(`cisco-ai-skill-scanner` 2.3.2)는 주석을 떼어 낼 때 따옴표 상태를
줄 사이로 이어 간다. `"$(grep -c '..."...' ...)"` 꼴의 한 줄에서 짝이 어긋나면
파일 끝까지 따옴표가 열린 채로 남고, 그 뒤의 한글 주석이 코드로 분석되어
`HOMOGLYPH_ATTACK`(HIGH)이 난다(#38). `check-ascii.sh` 는 한글을 허용해 못 잡는다.

`plugins/agent-dispatch/` 의 셸 스크립트를 고쳤다면 커밋 전에 돌린다. 걸리면
`파일:줄:상태` 가 나오니 그 줄의 `"$( ... '..."...' )"` 꼴을 변수 대입으로 풀어 쓴다.
heredoc 본문의 홀수 따옴표도 스캐너는 어긋남으로 센다(heredoc 을 파싱하지 않는다).
이 도구를 고쳤다면 하네스를 돌린다(`SCANNER_PY` 에 스캐너가 깔린 python 을 주면
스캐너 원함수와 끝 상태를 대조하는 차분 시험도 돈다):

```bash
bash scripts/check-quotes.sh plugins/agent-dispatch
bash scripts/test-check-quotes.sh
```

## plugins/ 를 고치면 스킬 스캐너 게이트를 돌린다

사내 스킬 스캐너(`cisco-ai-skill-scanner` 2.3.2)는 `check-ascii.sh`, `check-quotes.sh` 가
옮겨 놓은 규칙 말고도 많은 것을 CRITICAL, HIGH 로 잡는다(예: `find -exec` 의
`COMPOUND_FIND_EXEC`, #71). `plugins/` 아래를 고쳤다면 커밋 전에 스캐너를 통째로
돌려 `is_safe` 로 판정한다. 통과(exit 0)는 출력이 없고, exit 1 은 `파일:줄:규칙 심각도`
를 낸다:

```bash
bash scripts/check-scan.sh plugins
```

exit 3 은 스캐너를 못 쓴다는 뜻이다(통과가 아니다). stderr 의 안내대로 한 번 깔고
`SKILL_SCANNER` 로 가리킨 뒤 다시 돈다(설치에만 네트워크가 필요하다):

```bash
uv venv <dir> && uv pip install --python <dir>/bin/python cisco-ai-skill-scanner==2.3.2
SKILL_SCANNER=<dir>/bin/skill-scanner bash scripts/check-scan.sh plugins
```

이 도구를 고쳤다면 하네스를 돌린다. `SCANNER_BIN` 에 실제 스캐너를 주면 2.10.0 커밋
(`ece1885`)이 `COMPOUND_FIND_EXEC` 로 걸리는지까지 대조한다:

```bash
bash scripts/test-check-scan.sh
SCANNER_BIN=<dir>/bin/skill-scanner bash scripts/test-check-scan.sh
```

## PR 과 main push 마다 checks 워크플로가 검사를 돈다

`.github/workflows/checks.yml`(job `checks`)이 PR(draft 포함)과 main push 마다 스캐너
게이트(`check-scan.sh plugins`), `check-ascii.sh` / `check-quotes.sh`
(`plugins/agent-dispatch`), 루트 하네스 둘, agent-dispatch `test-tools.sh` /
`test-scripts.sh`, statusline-kit `test-install.sh`, actionlint 를 모두 돈다. 필수
체크는 아니다(첫 초록 실행 뒤 사람이 판단한다). 그리고 위의 커밋 전 검사를 대신하지
않는다. CI 는 늦게 알려 줄 뿐이다.

- `.github/workflows/` 를 고쳤다면 커밋 전에 `actionlint` 를 돌린다.
- 스캐너 버전을 올릴 때는 `git grep -n '<옛 버전>'` 으로 고정한 곳을 모두 찾아 함께 고친다. 동작하는 곳은 워크플로 `env.SCANNER_VERSION`, `scripts/check-scan.sh` 의 `EXPECTED_VERSION`/`INSTALL_HINT`, 하네스 `scripts/test-check-scan.sh`, CLAUDE.md 와 README 의 설치 명령이다. 워크플로와 CLAUDE.md 만 고치면 `check-scan.sh` 는 경고만 내고 CI 는 초록인 채 어긋난다.
- statusline 표식 규칙(워킹트리와 HEAD 비교)은 CI 체크아웃에서 늘 통과한다. 로컬에서 돌린다.
