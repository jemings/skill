# 규율 카드

오케스트레이터가 읽는다. 카드는 일하는 **방법**이지 lifecycle 이 아니다. 단계, 순서, 멈출 곳은 SKILL.md 가 정한다.
카드는 3단계의 "기록된 원칙"이 아니다. 근거와 권고의 이유로만 쓰고, "사람에게 묻는다" 갈래를 "네가 정한다"로 바꾸지
못한다.

쓰는 길: grilling 이 이슈에 맞는 카드 id 를 근거와 함께 제안한다(2단계). 5단계 계약서의 `규율:` 줄에 등급 상한 안에서
id 와 그 이슈에서의 뜻을 적는다. 6단계에서 카드의 **언제**, **규칙** 두 칸을 구현 지시문의 규율 칸에 그대로 옮긴다(구현자는
이 파일을 모른다). 구현자는 규율마다 무엇을 바꿨는지 보고하고, 7단계 4항이 그 보고를 diff 와 대조한다.

출처: pstack(MIT, Lauren Tan) 의 principle 잎을 줄여 이 저장소 어휘로 다시 쓴 것이다. pstack 이 설치돼 있지 않아도
같게 돈다. 잎 파일을 읽게 하지 않는다.

### laziness

- **언제**: 정리, 구조 변경, diff 크기를 정할 때. 추상화, 층, 인자 전달을 더하고 싶을 때.
- **규칙**: 문제를 푸는 가장 작은 변경을 한다. 먼저 빼고(죽은 코드, 남는 검사, 빈 참조) 그다음 더한다. 같은 결정을
  여러 곳에서 되풀이하지 말고 한 곳에 두고 결과를 넘긴다. 관찰된 쓰임이 없는 경우를 위한 추상화, 층, 검사는 더하지
  않는다.
- **자리**: 2단계 권고의 근거, 5단계 할 일, 6단계 구현 지시문.
- **출처**: pstack `principle-laziness-protocol`, `principle-subtract-before-you-add`.

### foundational

- **언제**: 새 상태를 들일 때, 분기가 많은 로직, 여러 파일이 같은 모양을 가정할 때.
- **규칙**: 로직보다 자료 모양과 상태의 주인을 먼저 정한다. 흩어진 조건문이나 함께 맞춰야 하는 불리언 둘 대신 구조(표,
  상태 기계, 타입, 레지스트리)에 담는다. 모양이 뻔하고 국소적이며 자랄 일이 없으면 지루한 코드를 둔다. 분기나 불가능한
  상태를 지우지 못하는 간접층은 의심한다.
- **자리**: 2단계 두 모양 비교, 6단계 구현 지시문.
- **출처**: pstack `principle-foundational-thinking`, `principle-model-the-domain`.

### boundary

- **언제**: 검증, 오류 처리, 어댑터, 외부 데이터(CLI 인자, 설정, 환경 변수, 네트워크, 외부 API), 타입 설계.
- **규칙**: 데이터가 경계를 넘는 곳에서 검사하고 도메인 타입으로 바꾼 뒤, 안쪽은 믿는다(안에서 다시 검사하지 않는다).
  불가능한 상태는 표현할 수 없게 한다: 뜻이 다른 같은 원시형은 타입을 가르고, 변형은 빠짐없이 다루고, 정본 스키마가
  있으면 거기서 유도한다. 업무 로직은 순수 함수로 두고 그것을 부르는 껍데기는 얇게 한다.
- **자리**: 5단계 시험(경계 입력의 경우), 6단계 구현 지시문.
- **출처**: pstack `principle-boundary-discipline`, `principle-type-system-discipline`.

### root-cause

- **언제**: 결함.
- **규칙**: 재현한 뒤 증상을 처음 잘못된 곳까지 거슬러 그 자리에서 고친다. 증상을 낸 상태가 정당하면 깨진 곳에서
  다루고, 생기면 안 되는 상태면 그것을 만든 곳을 고친다(가드, 재시도, 삼킨 오류, 잘라 낸 값은 결함을 숨긴다). 가드는
  그 상태가 정당할 때만 수정이다. 같은 결함의 다른 자리는 grilling 이 찾아 계약서에 넣고, 구현 중에 찾으면 고치지 말고
  보고한다.
- **자리**: 2단계(같은 결함의 다른 자리), 6단계 결함 절차.
- **출처**: pstack `principle-fix-root-causes`.

### sequence

- **언제**: 여러 PR, sweep, 이주, 비슷한 편집의 반복.
- **규칙**: 일을 검사로 끝나는 작은 단위로 나눈다. 단위마다 알려진 초록 -> 변경 하나 -> 검사 -> 다음이고, 도구가
  편집해도 단위 검사를 돌린다. 증명하는 순서로 낸다: 지는 시험 먼저, 빼기 먼저, 기준선 먼저. 커밋마다 홀로 선다.
- **자리**: 5단계 PR 나누기와 할 일 순서, 6단계 구현 지시문.
- **출처**: pstack `principle-sequence-verifiable-units`.

## 이미 있는 것

다시 카드로 제안하지 않는다. 이 스킬의 다른 자리가 맡는다.

| pstack 의 것 | 맡는 곳 |
|---|---|
| `principle-prove-it-works` | 7단계 검수와 PR HEAD 증거(3항 (a)/(b)/(c)). 구현자 자신의 검증은 구현 지시문의 Report 규칙(실행 결과, 판정 줄) |
| `principle-build-the-lever`, `principle-encode-lessons-in-structure` | "확정적인 일은 스크립트로"와 1단계 "저장소 도구를 공용화한다", 정책을 지키는 시험(`pr-check.sh --draft`, 정적 검사) |
| `principle-separate-before-serializing-shared-state` | 병렬은 계약서가 바꾸는 파일이 겹치지 않는 이슈만("실행 전반의 원칙") |
| `principle-guard-the-context-window` | 서브에이전트 위임과 상태 블록 |
| `principle-never-block-on-the-human` | 3단계의 "네가 정한다 / 사람에게 묻는다" 분류 |
| `principle-attack-the-premise` | 등급 절 "한 칸 올려 다시 보낸다"의 실패한 전제, 구현 지시문의 전제 공격 |
| `comment-sicko`(약식) | 구현 지시문의 주석 줄과 리뷰 지시문 축 6. 변명 주석은 이름, 추출, 타입, 구조로 고친다. `-h` 정본 머리 주석은 공개 계약 예외 |

## 쓰지 않는 것

| pstack 의 것 | 이유 |
|---|---|
| `poteto-mode`, 그 `worker.md`, `poteto-agent` | ready PR, PR 댓글 증거, 묻지 않기, 역할별 모델과 effort 상한이 이 스킬의 draft, PR 에 쓰지 않음, 등급 표와 부딪히고, 두 번째 오케스트레이터가 된다 |
| `tdd` | 시험 생략을 허용해 "수정 전 빨강"과 부딪힌다. mattpocock `tdd`/`diagnosing-bugs` 가 맡는다 |
| `arena`, `swarm` 원형 | 다른 벤더, 클라우드 작업자를 전제하고, 직렬 대기를 늘리고, worktree 규칙 밖이다. 약식은 2단계 두 모양 비교와 실험, 구현자의 읽기 전용 도우미 |
| `interrogate` | 다른 벤더를 전제하고 적대적 리뷰와 겹친다 |
| `unslop`, `technical-writing` | 산문 전용이다. PR 본문은 저장소 규칙을 따른다 |
| `no-comments` | 주석 전부 삭제는 하지 않는다. 스크립트 머리 주석은 `-h` 의 정본이고 공개 계약이다 |
| poteto-mode 의 shipping, babysit, autopilot | squash 병합을 전제해 `land.sh` 와 부딪힌다 |
| `show-me-your-work`, `figure-it-out` | 기록은 8단계 착륙 기록에 남긴다 |
| mattpocock `code-review` 를 더 돌리기 | 리뷰 축과 겹치고 직렬 패스를 늘리며, 이름이 내장 code-review 와 겹친다 |
| `principle-redesign-from-first-principles` | laziness 와 부딪힌다. grilling 지시문의 "removes the coupling" 줄이 맡는다 |
