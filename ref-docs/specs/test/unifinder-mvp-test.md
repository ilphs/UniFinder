---
id: unifinder-mvp-test
title: UniFinder MVP 테스트계획서 — M1~M3 검증 전략
type: test
version: 0.1.0
status: draft
scope: MVP 전체(M1~M3)의 테스트 전략·환경·영역별 매트릭스·성능 기준·릴리스 게이트
related: [unifinder-mvp-design, unifinder-ui-design, unifinder-m1-impl, unifinder-m2-impl, unifinder-m3-impl]
updated: 2026-08-13
---

# UniFinder MVP 테스트계획서

## 1. 전략

```
        ┌────────────┐
        │ 수동 게이트   │  릴리스 전 체크리스트 (§6) — UX·시각·상호운용
        ├────────────┤
        │ 성능 테스트   │  10k/100k fixture, signpost 측정 (§5)
        ├────────────┤
        │ 통합 테스트   │  실제 파일시스템(임시 루트) 위 서비스 조합 (§4)
        ├────────────┤
        │ 단위 테스트   │  Services·ViewModels — 가장 두꺼운 층 (§4)
        └────────────┘
```

- **원칙 1 — 파괴적 작업 격리**: 파일을 만들고 지우는 모든 테스트는 `FileManager.temporaryDirectory` 하위 전용 루트에서만 수행. 테스트 베이스 클래스의 셋업에서 경로 prefix를 assert — 위반 시 즉시 실패
- **원칙 2 — 결정성**: fixture는 테스트가 직접 생성(이름·날짜·크기 고정), 실 사용자 폴더 의존 금지
- **원칙 3 — UI 자동화 최소**: XCUITest는 스모크 1본(§4.4)만. AppKit 브릿지의 세부 동작은 수동 게이트에서 검증 (비용 대비 취약한 UI 자동화를 늘리지 않는다)
- **실행**: 로컬 `xcodebuild -scheme UniFinder test` (CI 없음 — 각 마일스톤 게이트에서 증적 필수, `verify` 규칙)

## 2. 환경

| 항목 | 값 |
|------|-----|
| 기준 환경 | macOS 14 (최소 지원) + 최신 macOS — 2개 버전에서 게이트 수행 |
| 테스트 루트 | `$TMPDIR/UniFinderTests/<UUID>/` — 테스트 종료 시 삭제 |
| 대량 fixture | `tests/fixtures/generate.sh` — 10k/100k 항목 (M1 T8과 공유) |
| 볼륨 간 테스트 | 램디스크(`hdiutil attach -nomount ram://`) 또는 DMG 마운트로 제2 볼륨 시뮬레이션 |
| 권한 실패 재현 | `chmod 000` 폴더 fixture (teardown에서 복구 후 삭제) |

## 3. 마일스톤별 진입·통과 기준

| 게이트 | 진입 조건 | 통과 기준 |
|--------|----------|----------|
| M1 게이트 | M1 태스크 전체 구현 | 단위·통합 전체 통과 + M1 수동 체크리스트(m1-impl §4) + 성능 기준(§5) |
| M2 게이트 | M1 게이트 통과 | 상동 + M2 수동 체크리스트(m2-impl §3) + **M1 회귀**(탐색 스모크) |
| M3 게이트 = 릴리스 | M2 게이트 통과 | 상동 + 릴리스 게이트(§6) 전 항목 + 성능 재측정 |

결함 처리: **차단(blocker)** = 데이터 손실·크래시·잘못된 파일 조작(의도와 다른 대상 삭제/덮어쓰기) → 게이트 통과 불가. **주요(major)** = 기능 미동작·성능 미달 → 수정 후 재검. **경미(minor)** = 시각·문구 → 기록 후 통과 가능.

## 4. 영역별 테스트 매트릭스

### 4.1 M1 — 탐색 (단위·통합)

| 대상 | 케이스 |
|------|--------|
| DirectoryLoader | 정렬 4종×2방향, 폴더 우선, 숨김 필터 on/off, 심볼릭 플래그, 권한 에러, 빈 폴더, 한글/이모지/255자 이름, 취소(열거 중 cancel → 결과 미방출) |
| NavigationModel | navigate/back/forward/up 시나리오, forward 클리어, 루트 경계, 동일 경로 재이동(히스토리 미오염) |
| DirectoryModel | 로드 race(빠른 연속 이동 시 마지막 요청만 반영 — 의도적 지연 주입), 200ms 스피너 임계, 에러 상태 전이 |
| TreeModel | lazy 1-depth, reveal 경로 체인, 순환 심볼릭 depth 상한, 접근 불가 노드 |
| 통합 | 이동 4수단(트리/더블클릭/주소창/히스토리) 교차 후 상태 일치(currentURL·트리 선택·breadcrumb) |

### 4.2 M2 — 파일 조작 (단위·통합)

핵심 매트릭스 — **연산 × 조건** 전 조합을 단위 테스트로:

| 연산 \ 조건 | 성공 | 충돌: 덮어쓰기 | 충돌: 건너뛰기 | 충돌: 둘 다 유지 | 취소 | 권한 실패 | 볼륨 간 |
|------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| copy | ● | ● | ● | ● (넘버링) | ● (완료분 유지) | ● | ● |
| move | ● | ● | ● | ● | ● | ● | ● (copy+trash 폴백) |
| trash | ● | — | — | — | ● | ● | ● (볼륨별 휴지통) |
| rename | ● | ● (거부) | — | — | — | ● | — |
| createFolder | ● (넘버링) | — | — | — | — | ● | — |

추가: 다중 항목 중 일부 실패 → 나머지 계속+실패 목록, "모두 적용" 상태 전파, 클립보드 copy/cut 의미론·외부 변경 감지, 금지 이름 4종(빈/`/`/`:`/중복), `.` 시작 확인, 폴더 재귀 복사(중첩 3단), 심볼릭 링크 복사(링크 자체 복사 — 타겟 아님)

### 4.3 M3 — 자동 갱신·D&D (단위·통합·수동)

| 대상 | 자동화 | 수동 |
|------|--------|------|
| DirectoryWatcher | debounce 병합, diff 선택 유지, 표시 중 폴더 소실→상위 이동 | 터미널 조작 1초 내 반영, 대량 변경 무프리즈 |
| 볼륨 감시 | — | DMG 마운트/해제, 표시 중 볼륨 해제→홈 이동 |
| D&D | 이동/복사 판정 로직(볼륨·수식키), 자기 하위 거부 | 내부 4경로, Finder 양방향, 커서 배지 |
| QuickLook | — | Space 토글·순회·방향키 동기 |
| 진행률 | 스트림 집계(항목 수 기준 — 바이트는 Phase 2, m3-impl B19), 취소 의미론, 진행률 표시 중 충돌 시트 정상 표시 | 대용량 오버레이·소용량 미표시(1초 지연) |
| FDA | 프로브 3상태 판정(허용/거부/판정불가), "경로 없음 ≠ 미허용"(B22), 딥링크 URL·폴백, [나중에] 보류 영속 | 미허용→허용 왕복, [나중에] 제한 모드 |

**FDA 수동 검증 전제 — 개발 빌드는 매 빌드 재승인이 필요하다 (m3-impl B21)**
`project.yml`이 ad-hoc 서명(`CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: NO`)이고 TCC 승인은 코드 서명 신원에 묶이므로, **재빌드할 때마다 시스템 설정의 전체 디스크 접근 승인이 초기화된다.** 따라서 FDA 수동 시나리오는 다음 절차로 수행한다:

1. 빌드 후 **한 번만** 실행 — 시나리오 도중 재빌드 금지(재빌드하면 승인이 리셋되어 "허용했는데 미허용으로 감지"가 재현된다)
2. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근에서 기존 UniFinder 항목을 **제거(−)한 뒤** 새 빌드를 등록
3. "허용 → 복귀 시 자동 감지·시트 닫힘"이 실패하면 **먼저 위 1·2를 확인**한다(구현 결함이 아니라 서명 전제 문제일 수 있음)
4. Developer ID 서명 + hardened runtime 전환은 **릴리스 직전 별도 작업**이며(m3-impl B21 방침 (b)), 전환 후 이 시나리오를 1회 재수행한다

### 4.4 XCUITest 스모크 (1본)

앱 시작 → 홈 표시 확인 → 트리에서 Documents 선택 → 우측 갱신 확인 → 더블클릭 진입 → breadcrumb 확인 → 뒤로 → 종료. **목적**: 앱이 뜨고 기본 탐색이 되는지의 최후 안전망 (게이트마다 실행)

**구현**: `tests/UITests/NavigationSmokeUITests.swift` / 타깃 `UniFinderUITests`(`bundle.ui-testing`, `project.yml`) / 스킴 `UniFinder`의 test 액션에 등록.
타깃·스킴 등록이 조용히 사라지면 스모크는 안 돌면서 초록불만 남으므로, 등록 자체를 단위 테스트(`UITestSmokeTargetTests`)가 감시한다.

**결정성 보완**: "더블클릭 진입"의 대상은 사용자 폴더 내용에 의존할 수 없다(원칙 2). Documents 단계는 **읽기 전용**(트리 선택 → 우측/breadcrumb 갱신 확인)으로 두고, 진입·복귀는 테스트가 **홈 루트에 만든 전용 fixture 폴더**(`~/UniFinderSmoke-<8hex>`)에서 수행한 뒤 tearDown에서 지운다. 앱은 FDA 온보딩 시트가 뜨지 않도록 `-fullDiskAccessOnboardingPostponed YES` 등 launch argument(NSArgumentDomain)로 상태를 고정해 띄운다.

fixture 위치가 홈 루트인 것은 타협이 아니라 **소거법의 결과**다(전부 실측):

| 후보 | 결과 |
|------|------|
| `~/Documents`·`~/Desktop`·`~/Downloads` | 러너가 쓰는 순간 TCC 프롬프트("'UniFinderUITests-Runner.app'이 문서 폴더의 파일에 접근하려고 합니다")가 떠서 **무인 실행이 그대로 멈춘다** |
| `$TMPDIR` / `/private/tmp` | 트리로 닿지 않아 주소창 타이핑이 필요 → XCUITest 합성 타이핑이 부하 시 글자당 200ms를 넘겨(60자 경로 = 13초) 포커스가 흔들리면 주소창이 접혀 반복 실패 |
| **홈 루트** | TCC 보호 대상 아님 + 트리 "홈" 노드 한 번 클릭으로 도달 → 타이핑 0, 프롬프트 0 |

**실행 전제 — automation mode (중요)**

macOS는 XCUITest 실행 전에 시스템 "automation mode"를 켜야 하고, 기본값은 **부팅 세션마다 사용자 인증(암호/Touch ID)** 이다. 인증이 아직 승인되지 않은 상태에서 비대화형 셸(에이전트·CI·SSH)로 실행하면 다음처럼 60초 만에 실패한다 — 실제로 이 저장소에서 첫 시도가 이렇게 실패했고, 인증이 승인된 뒤에는 같은 CLI 명령으로 통과했다:

```
testmanagerd: Test session with pid NNNN requesting automation mode
testmanagerd: Enabling Automation Mode...
[com.apple.dt.automationmode] Writer daemon requires authentication to enable automation mode.
→ Failed to initialize for UI testing: "Timed out while enabling automation mode."
```

상태 확인: `automationmodetool` (출력이 `Automation Mode is disabled. This device requires user authentication...`이면 그대로는 못 돈다)

실행 가능하게 만드는 방법 — **둘 중 하나**:

1. **대화형 1회 인증** — Xcode에서 UI 테스트를 실행하고 뜨는 인증 대화상자를 승인한다. 인증은 부팅 세션 단위로 기억되므로, 재부팅 전까지는 CLI(`xcodebuild test`)에서도 돈다.
2. **머신 1회 설정(CI/자동화 머신용)** — `sudo automationmodetool enable-automationmode-without-authentication`
   automation mode 활성화에 인증을 요구하지 않게 만든다. **합성 입력 이벤트 주입 문턱을 낮추는 머신 전역 보안 설정**이므로, 개발자 개인 머신에서는 1번을 쓰고 이 방법은 전용 검증 머신에서만 쓴다. 되돌리기: `sudo automationmodetool disable-automationmode-without-authentication`

부가 조건: 실행 계정이 `_developer` 그룹에 속해야 하고(`dseditgroup -o checkmember -m $USER _developer`), 테스트를 띄우는 앱(터미널/IDE)에 손쉬운 사용 권한이 있어야 한다.

**스모크 작성 시 지켜야 할 것 (전부 실측으로 얻은 함정)**

1. **질의는 반드시 창(`app.windows.firstMatch`) 하위로 한정한다.** AppKit이 모든 앱의 "도움말" 메뉴에 붙이는 검색 필드·결과 테이블(`_SC_SEARCH_FIELD`/`_SC_RESULTS_TABLE`)이 `app.tables.firstMatch`·`app.textFields.firstMatch`에 먼저 잡힌다. 그러면 "목록이 있다"는 단언은 통과하면서 행은 하나도 못 찾는 **가짜 초록불**이 된다.
2. **테스트 프로세스의 홈을 믿지 않는다.** XCUITest 러너는 기본이 샌드박스라 `homeDirectoryForCurrentUser`가 `~/Library/Containers/<id>/Data`가 된다(첫 실패가 정확히 이것이었다). 러너 entitlements로 샌드박스를 끄고(`tests/UITests/UniFinderUITests.entitlements`), 그와 별개로 홈은 `getpwuid`로 구한다.
3. **셀 텍스트는 `label`이 아니라 `value`에 실린다.** 트리·목록 셀은 `NSTextField(labelWithString:)`이라 `AXValue`에만 문자열이 있고, breadcrumb 버튼은 `AXDescription`에 있다. 질의는 `value/label/title`을 모두 보는 술어로 한다.
4. **갓 빌드한 바이너리는 한 번 예열하고 시작한다.** 첫 실행에 Gatekeeper/XProtect 스캔이 겹치면 앱이 수십 초 응답 지연에 빠지고 XCUITest가 `main thread busy for 30.0s`로 무너진다(같은 코드가 예열 후에는 25초에 통과).
5. **메뉴는 최전면 앱의 것만 그려진다.** 다른 앱이 포커스를 잡으면 메뉴 항목 프레임이 `{{0,1440},{0,0}}`가 되어 `Not hittable` 재시도가 폭주하다 자동화 연결이 끊긴다 → 매 시도 `app.activate()` + hittable 확인 + 재시도. 반대로 `typeKey("l", .command)` 같은 **키 등가물은 합성해도 메뉴 명령으로 처리되지 않는다**(주소창이 열리지 않았다).

**실행 명령**

```
xcodebuild -scheme UniFinder test                      # 단위 + UI 스모크 전체
xcodebuild -scheme UniFinder test -only-testing:UniFinderUITests   # 스모크만
```

automation mode 전제가 갖춰지지 않은 환경에서 게이트를 돌릴 때는, 스모크 결과를 "통과"로 적지 말고 **미실행(환경 사유)** 으로 기록한다 — 실행되지 않은 스모크를 통과로 기록하는 순간 이 안전망의 의미가 사라진다.

## 5. 성능 테스트 (설계 §5 기준)

| 시나리오 | 기준 | 측정 방법 |
|----------|------|----------|
| 10k 폴더 첫 표시 | < 500ms | `os_signpost` navigate→목록 표시, 5회 중앙값 |
| 100k 폴더 첫 표시 | < 3s | 상동 |
| 100k 스크롤 | 60fps | Instruments Core Animation FPS, 끝까지 연속 스크롤 |
| 트리 노드 확장 | < 100ms | signpost, 1k 하위 폴더 fixture |
| 로딩 중 연타 이동 | 프리즈 0 | 100k 로딩 중 10회 연속 이동 — 메인 스레드 행 감지(watchdog 로그) |
| (M3) 대량 변경 중 | 프리즈 0 | 표시 중 폴더에 1만 파일 생성 |

- 측정 환경 고정: 동일 머신·전원 연결·스포트라이트 인덱싱 대기 후. 기준 미달 시 major 결함
- M1 게이트에서 최초 측정 → M2·M3 게이트에서 **재측정** (기능 추가로 인한 회귀 감시)

## 6. 릴리스 게이트 — 수동 체크리스트 (M3 게이트)

각 마일스톤 체크리스트(m1 §4, m2 §3)의 전체 재수행 + 아래 MVP 횡단 시나리오:

1. **1일 사용 시나리오**: Finder 없이 30분간 실제 작업(프로젝트 폴더 탐색·정리·파일 이동) — 막히는 지점 기록
2. 탐색 중 백그라운드 대량 변경(빌드 실행 등) → 자동 갱신·무프리즈
3. Finder 상호 운용 3종: 클립보드 양방향, D&D 양방향, 휴지통 복원 반영
4. 외장 볼륨 전체 흐름: 마운트→탐색→파일 조작→언마운트
5. FDA 미허용 신규 사용자 흐름: 온보딩→[나중에]→제한 탐색→접근 불가 폴더 empty-state의 [권한 설정 안내] 재노출→허용→전체 탐색 (§4.3의 ad-hoc 서명 전제 절차를 따를 것 — 시나리오 중 재빌드 금지, m3-impl B21)
6. 다크/라이트 모드 전환, 윈도우 상태 복원(재시작)
7. 성능 재측정 전 항목 (§5)
8. 30분 사용 후 메모리: 아이콘 캐시 포함 실사용 500MB 이하, 지속 증가(누수 패턴) 없음

## 7. 산출물·증적

- 각 게이트 종료 시: `xcodebuild test` 결과 로그, 성능 측정값 표, 수동 체크리스트 통과 기록을 Context DB(`decision-add` 또는 세션 기록)에 남긴다 — "완료 선언 전 검증 증거 필수" 규칙 준수
- 결함은 게이트 리포트에 심각도와 함께 목록화, blocker 0이어야 게이트 통과
