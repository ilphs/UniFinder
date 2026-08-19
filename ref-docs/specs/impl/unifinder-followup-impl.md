---
id: unifinder-followup-impl
title: UniFinder 후속 기능 구현계획서 — 업데이트 확인 · Open With · 디스크 용량 · Get Info
type: impl
version: 1.0.0
status: implemented
scope: MVP·다중 창 이후의 신규 기능 4종과 그에 수반되는 버전 소스 단일화·볼륨 서비스 추출
related: [unifinder-mvp-design, unifinder-ui-design, unifinder-m2-impl, unifinder-multiwindow-impl]
updated: 2026-08-19
---

# UniFinder 후속 기능 구현계획서

## 1. 입력과 목표

- **입력**: MVP(M1·M2·M3) + 다중 창까지 완료된 실제 코드베이스, 2026-08-19 사용자 확정 결정
- **목표**: 신규 기능 4종을 넣는다 — ① 업데이트 확인 ② Open With ③ 디스크 용량 창 ④ Get Info 창
- **하지 않는 것**: 자동 다운로드·자동 설치(브라우저 위임), Sparkle 도입, 폴더 on-disk 크기,
  다중 선택 Get Info, 마운트 통지 기반 용량 자동 갱신, 태그 편집

### 1.1 확정된 사용자 결정

| 항목 | 결정 | 근거 |
|------|------|------|
| 업데이트 확인 방식 | GitHub Releases REST API(`/releases/latest`) | 서명·공증이 미완이라 Sparkle의 서명 검증 전제를 못 만족한다 |
| Get Info 폴더 크기 | **자동 계산**(백그라운드·점진 갱신) | 버튼을 눌러야 나오면 "폴더 크기를 알려주는 창"이라는 목적 자체가 반쯤 죽는다 |
| `Cmd+I` | **Get Info로 이관**. `Show in Finder`는 단축키 없이 존치 | 단축키 하나에 항목 둘은 금지(UI설계 §10 불변식) |
| Get Info 창의 "Always Open With" | **포함**. 단, `Change All…`은 확인 alert 필수 | 시스템 전역 설정 변경이라 무심코 눌리면 안 된다 |
| 다중 선택 Get Info | **비활성** (`Rename`과 같은 규칙) | "첫 항목만 보여주기"는 사용자가 고른 대상과 창의 대상이 달라 오해를 만든다 |

### 1.2 B9 결정의 승계 (전제는 참, 결론만 확장)

M2의 `architect B9`는 "Finder 정보창을 여는 공개 API가 없다 → `Show in Finder`로 대체한다"였다.

**그 전제는 지금도 참이다.** Finder의 정보창을 프로그램으로 여는 공개 API는 여전히 없다.
이번 작업이 여는 것은 Finder의 창이 아니라 **UniFinder 자신의 Get Info 창**이므로 전제와
충돌하지 않는다. 따라서 결론만 확장한다:

> **`Show in Finder`는 유지하고, `Cmd+I`만 Get Info로 이관한다.**

`AppModel.revealInFinder`를 비롯한 코드의 `architect B9` 주석은 **지우지 않는다** — 지우면
"왜 Finder 정보창을 안 열었나"라는 질문이 몇 달 뒤 다시 올라온다. 대신 이 절을 가리키게 갱신한다.

## 2. 설계 판정 (D1~D10)

| # | 쟁점 | 판정 |
|---|------|------|
| D1 | 볼륨 용량 키 | `available = volumeAvailableCapacityForImportantUsage`, 없으면 `volumeAvailableCapacity` 폴백. `total = volumeTotalCapacity`. `used = max(0, total - available)`로 **클램프**(두 키의 기준이 달라 음수가 가능). purgeable 별도 노출 없음 |
| D2 | 다중 선택 Get Info | **비활성**. 메뉴 항목·`Cmd+I` 모두 `selectionCount == 1`에서만 활성 |
| D3 | 심볼릭 링크 | `InfoTarget`은 `AppModel.resolveTarget(of:)`를 **쓰지 않는다**. 링크 자체 메타데이터를 보여주고 `Original:` 행에 해석 경로 병기. `resolveTarget` 독스트링에 예외를 명시하고 `InfoTargetSymlinkTests`로 고정 |
| D4 | 업데이트 확인 프로토콜 | REST(릴리스 노트 표시 필요). 앱 시작 1회 + 24h 스로틀(수동 확인은 스로틀 무시), ETag/`If-None-Match` 304 캐시, timeout 10s/20s, `prerelease`·`draft`는 방어적으로 무시, Skip Version은 **자동 확인만** 침묵, **자동 확인 실패는 완전 침묵**(로그만), 수동 확인 실패만 alert. 버전 비교는 semver 숫자 튜플(`v` 접두 제거, 문자열 비교 금지 — `0.10.0 > 0.9.0`) |
| D5 | Open With 후보 조회 | `NSWorkspace.urlsForApplications(toOpen:)`. 서브메뉴는 `NSMenuDelegate.menuNeedsUpdate`로 **열릴 때** 구성(우클릭 응답 지연 방지). 실행은 `NSWorkspace.open(_:withApplicationAt:configuration:)` |
| D6 | 폴더 크기 계산 | 논리 크기(`.fileSizeKey`)만. 하드링크 중복 계산 허용(의도된 근사). 심볼릭 링크 미추적. 500ms throttle 점진 갱신. `Task.cancel()`로 실제 중단. 접근 불가 하위는 건너뛰고 `(some items couldn't be read)` 표기 |
| D7 | 정보 창의 씬 형태 | `WindowGroup(id: "info", for: InfoTarget.self)`. `InfoTarget`은 **URL 기반 값**(UUID 없음) — 같은 대상이면 창이 재사용된다 |
| D8 | 메뉴 위치 | `Check for Updates…`는 이미 비어 있던 `CommandGroup(replacing: .help) { }`를 채운다. `.appInfo` 그룹은 건드리지 않는다(`Quit` 유실 리스크) |
| D9 | 용량 창 갱신 | 마운트/언마운트 통지 **미구독**. 창을 열 때 1회 + 수동 `[Refresh]`(⌘R) + `Updated HH:mm` 표기 |
| D10 | 업데이트 설정 저장 | `AppSettings`와 분리한 `UpdatePreferences`(`@MainActor @Observable`, `UserDefaults` 주입). `AppEnvironment.update`로 노출. 키: `update.autoCheckEnabled`(기본 true) / `update.lastCheckedAt` / `update.skippedVersion` / `update.cachedETag` / `update.cachedLatestVersion`. **별도 suite를 만들지 않고** `.standard`에 `update.` 접두사만 |

## 3. 태스크

| # | 태스크 | 산출물 | 수용 기준 |
|---|--------|--------|-----------|
| **T0** | 버전 소스 단일화 | `src/Services/AppVersion.swift`, `VersionSourceConsistencyTests` | `project.yml`이 정본. pbxproj·README가 그 값과 일치. 코드에 버전 리터럴 없음 |
| **T1** | `VolumeService` 추출 | `src/Services/VolumeService.swift`, `VolumeServiceTests` | 볼륨 열거 API 직접 호출부가 코드베이스에 **1곳**. 사이드바 기존 테스트 무수정 통과 |
| **T2** | 설계서 개정 | mvp-design 1.1.0, ui-design 0.2.0, 이 문서 | 네트워크 예외 4경계·폴더 크기 불변식·성능 행·§7.6~7.9·§10 반영 |
| **T3** | 업데이트 확인 | `SemanticVersion` · `UpdateChecker` · `UpdatePreferences` · `UpdateCheckModel` · Help 메뉴 항목 | `0.10.0 > 0.9.0`. 자동 확인 실패 시 alert 미게시. 404/타임아웃/403/깨진 JSON 전부 안전 |
| **T4** | Open With 서브메뉴 | `src/Services/OpenWithService.swift`, `FileListBridge` 메뉴, `OpenWithMenuTests` | 컨텍스트 메뉴 최종 배열 일치. 폴더에서 비활성. 서브메뉴는 열릴 때 구성 |
| **T5** | Get Info 창 + ⌘I 이관 | `InfoTarget` · `ItemInfoModel` · `ItemInfoWindow` · 씬/메뉴 배선 | `Cmd+I` 소유자 유일. 다중 선택 비활성. 심볼릭 링크 미해석 |
| **T6** | 폴더 크기 비동기 계산 | `src/Services/DirectorySizeCalculator.swift` | 알려진 fixture 크기 정확 일치. 취소 시 `CancellationError`. 목록 컬럼 무영향 |
| **T7** | Always Open With | `OpenWithService` 확장, §7.8 확인 alert | 취소 시 API 미호출. 확인 시 정확한 UTI/URL 전달. 실패 시 이전 선택 복귀 |
| **T8** | 디스크 용량 창 | `DiskUsageModel` · `DiskUsageWindow` · View 메뉴 항목 | 네트워크 볼륨 제외. 조회 실패는 `--`. 창은 1개(단일 씬) |
| **T9** | 통합 검증 게이트 | — | 빌드 성공·경고 증가 0, 전체 테스트 통과(기존 테스트 삭제 없이 순증), README 단축키 표 갱신 |

의존: T0·T1·T2는 서로 독립. T3은 T0(버전), T8은 T1(볼륨)에 의존. **T5는 T4 완료 후**
(같은 컨텍스트 메뉴 배열을 두 태스크가 건드린다). T6·T7은 T5 완료 후. T9는 전부의 뒤.

## 4. 수용된 트레이드오프

의도적으로 감수한 것들이다. "버그처럼 보이지만 결정이다"를 남기는 것이 이 절의 목적이다.

1. **다중 선택 Get Info 비활성** — Finder는 다중 선택에서 합계 창을 띄우지만, 우리는 띄우지 않는다.
   합계 창은 "N items, 총 X GB"라는 **다른 화면**이고 그 화면을 설계하지 않았다.
   반쯤 맞는 화면(첫 항목만)을 띄우느니 비활성이 정직하다.
2. **폴더 크기는 논리 크기 어림값** — 하드링크를 중복 계산하고 심볼릭 링크를 세지 않으므로
   `du`와도 Finder와도 값이 정확히 일치하지 않을 수 있다. 정확한 회계가 목적이 아니라
   "이 폴더가 대충 얼마나 큰가"에 답하는 것이 목적이다.
3. **용량 창은 자동 갱신하지 않는다** — USB를 뽑아도 창의 행은 남는다. `Updated HH:mm`이
   값의 나이를 드러내고 `[Refresh]`가 최신화 수단이다(D9).
4. **업데이트 확인은 네트워크 비목표의 유일한 예외** — 그래서 경계 4개(읽기전용 GET ·
   메타데이터만 · 인증 없음 · 끌 수 있음)를 설계서에 못 박았다. 이 경계를 넓히려면 설계서를 먼저 고친다.
5. **자동 확인 실패는 사용자에게 알리지 않는다** — 오프라인 사용자가 앱을 켤 때마다 알림을 받는 것은
   파일 탐색기로서 명백한 퇴보다. 대신 수동 확인은 항상 결과를 말한다.
6. **`Show in Finder`가 단축키를 잃는다** — 그 항목을 자주 쓰던 사용자는 이제 메뉴/우클릭을 거쳐야 한다.
   단축키 하나에 소유자 둘을 두는 것보다 낫다(UI설계 §10 불변식).
7. **Open With 서브메뉴는 폴더에서 비활성** — 폴더를 다른 앱으로 여는 사용 사례(예: 에디터로 폴더 열기)를
   포기했다. 다중 선택에 폴더가 섞이면 "무엇을 어디로"가 정의되지 않기 때문이다.

## 5. 검증

- 단위 테스트: `SemanticVersionTests` · `UpdateCheckerTests` · `OpenWithMenuTests` ·
  `OpenWithServiceTests` · `ItemInfoModelTests` · `InfoTargetSymlinkTests` · `GetInfoWindowTests` ·
  `DirectorySizeCalculatorTests` · `DiskUsageModelTests` · `VolumeServiceTests` ·
  `VersionSourceConsistencyTests`
- 회귀 고정: `Cmd+I` 소유자 유일성, 컨텍스트 메뉴 최종 배열, 목록 "크기" 컬럼 불변,
  볼륨 열거 단일 호출부, 씬 타입(`WindowGroup`/`Window`)
- **실제 네트워크·실제 시스템 기본 앱 설정은 테스트에서 절대 건드리지 않는다** —
  `URLProtocol` 스텁과 mock provider만 쓴다(`FullDiskAccessModel.opener` 선례).
