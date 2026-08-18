---
id: unifinder-m1-impl
title: UniFinder M1 구현계획서 — 읽기 전용 탐색
type: impl
version: 0.3.0
status: draft
scope: M1(읽기 전용 탐색)의 태스크 분해·구현 순서·수용 기준·검증 방법
related: [unifinder-mvp-design, unifinder-ui-design]
updated: 2026-08-14
---

# UniFinder M1 구현계획서 — 읽기 전용 탐색

## 1. 입력과 목표

- **입력**: `unifinder-mvp-design` v1.0.0 (approved) — §2 화면 구성, §3 아키텍처, §5 성능 요구, §7 M1 범위
- **M1 완료 기준** (설계서 §7): 임의 폴더를 마우스·키보드만으로 자유롭게 탐색 가능. 100,000 항목 폴더 첫 표시 < 3s, 스크롤 60fps.
- **M1에서 하지 않는 것**: 모든 파일 조작(M2), FSEvents 자동 갱신·D&D·QuickLook·FDA 온보딩(M3), 컨텍스트 메뉴(M2)

## 2. 프로젝트 구조

```
UniFinder/
├── project.yml                  # XcodeGen 정의
├── src/
│   ├── App/                     # 앱 진입점, 메인 윈도우, 씬
│   ├── Views/                   # SwiftUI 셸 (툴바·상태바·스플릿)
│   ├── Bridges/                 # NSViewRepresentable (FileList, SidebarTree)
│   ├── ViewModels/              # NavigationModel, TreeModel, DirectoryModel
│   ├── Services/                # DirectoryLoader, IconProvider
│   └── Models/                  # FileItem, SortDescriptor 등
├── tests/
│   ├── UnitTests/               # Services·ViewModels 단위 테스트
│   └── fixtures/generate.sh     # 성능 테스트용 대량 파일 생성 스크립트
└── ref-docs/                    # (기존) 스펙·하니스 문서
```

| 항목 | 값 |
|------|-----|
| 타겟 | macOS 14.0+ (배포 대상), 개발 환경 Xcode 26.6 / Swift 6.3 |
| Bundle ID | `com.unifinder.app` (가정 — 배포 전 확정 필요) |
| Entitlements | App Sandbox **비활성** (설계 결정 #2) |
| 빌드 | `xcodegen generate && xcodebuild -scheme UniFinder build` |
| 테스트 | `xcodebuild -scheme UniFinder test` |

> **[architect B1]** 개발 환경이 Xcode 26.6이라 기본 언어 모드가 Swift 6(strict concurrency)이다. `@Observable` ViewModel·브릿지 Coordinator·actor 경계에서 진단이 한꺼번에 발생하는 것을 막기 위해, `project.yml`에 다음을 **명시적으로 고정**한다(T0 수용 기준에 포함):
> - `SWIFT_VERSION: 5`
> - `SWIFT_STRICT_CONCURRENCY: targeted`
> - `MACOSX_DEPLOYMENT_TARGET: 14.0`
>
> Swift 6 언어 모드 전면 전환은 M3 이후 별도 태스크로 분리한다(범위 외).

## 3. 태스크 분해

의존 순서대로 나열한다. 각 태스크는 **빌드 통과 + 해당 수용 기준 충족** 시 완료로 본다.

### T0. 프로젝트 스캐폴드

- XcodeGen `project.yml` 작성: 앱 타겟(UniFinder) + 유닛테스트 타겟(UnitTests), sandbox off entitlements, `SWIFT_VERSION: 5`/`SWIFT_STRICT_CONCURRENCY: targeted`/`MACOSX_DEPLOYMENT_TARGET: 14.0` (architect B1)
- §2 폴더 구조 생성, SwiftUI 셸(MainWindow + HSplitView: 사이드바 240pt placeholder + 우측 목록 placeholder) + 빈 앱 실행 확인 — T3‖T4 병행 시 MainWindow 충돌 방지를 위해 셸까지 T0에서 확보
- `.gitignore`에 `*.xcodeproj`, `DerivedData` 추가

**수용 기준**
- [ ] `xcodegen generate && xcodebuild build` 성공 (Swift 5 언어 모드로 빌드됨을 확인)
- [ ] 앱 실행 시 빈 윈도우(사이드바+목록 스플릿 골격 포함) 표시

### T1. 모델 + DirectoryLoader

- `FileItem` (설계 §3.2), `SortKey`(name/date/kind/size) + 정렬 로직(폴더 우선, 이름은 `localizedStandardCompare`)
- `protocol DirectoryListing: Sendable { func list(url: URL, ...) async throws -> [FileItem] }` 도입 (architect B3) — `DirectoryLoader`(actor)가 이를 준수. `DirectoryModel(loader: any DirectoryListing)`으로 주입받아, T3의 race 테스트에서 지연 주입 가능한 테스트 더블(mock)을 꽂을 수 있게 함
- `DirectoryLoader` (actor): resource key 일괄 prefetch로 열거 (설계 §3.2 — 항목별 stat 금지), 숨김 필터 옵션, `Task` 취소 지원(열거 루프 중 `Task.checkCancellation`)
- 권한 없는 폴더 → `DirectoryError.accessDenied` throw

**수용 기준**
- [ ] 단위 테스트: 정렬 4종×오름/내림, 폴더 우선, 숨김 필터, 심볼릭 링크 플래그, 권한 에러
- [ ] 테스트용 임시 디렉토리 fixture로 결정적(deterministic) 테스트
- [ ] `DirectoryListing` 프로토콜 준수 + 지연 주입 가능한 mock 구현체로 T3 race 테스트가 성립함을 확인

### T2. NavigationModel

- `currentURL`, back/forward 스택, `navigate/goBack/goForward/goUp` (설계 §3.2)
- `goUp`은 루트(`/`)에서 no-op. navigate 시 forward 스택 클리어(브라우저 관례)

**수용 기준**
- [ ] 단위 테스트: 이동→뒤로→앞으로 시나리오, 뒤로 후 새 이동 시 forward 클리어, 루트 경계

### T3. DirectoryModel + FileList 브릿지 (우측 pane)

- `DirectoryModel`: `load(url)` — 이전 로드 Task cancel → DirectoryLoader 호출 → 정렬 적용 (설계 §3.3), 200ms 지연 스피너, 에러 상태(접근 불가) 노출
- `FileListBridge` (`NSViewRepresentable` + `NSTableView`): 이름·수정일·종류·크기 4컬럼, 헤더 클릭 정렬 토글, 다중 선택(Cmd/Shift/러버밴드/Cmd+A), 타입-어헤드, 더블클릭(폴더=진입, 파일=`NSWorkspace.open`)
- **키보드 소유권 (architect B4)**: `FileListBridge`의 `Coordinator`가 원시 `keyDown`을 직접 소유한다(방향키·PageUp/Down·Home/End·`Enter`·타입-어헤드 문자 입력 포함). `onOpen` / `onNavigateUp` / `onTypeAhead` 클로저로 상위에 이벤트를 노출하고, T7은 이 클로저들을 앱 레벨 단축키(`Cmd+L`·`Cmd+Shift+.`·`Cmd+R`)·`Tab` 순환·first responder 정책에만 연결한다 — T7이 브릿지 내부 keyDown을 재작성하지 않는다
- **IconProvider (architect B2)**: `NSWorkspace.icon(forFile:)`이 반환하는 `NSImage`는 Sendable이 아니므로 actor로 구현 불가. `@MainActor final class IconProvider { NSCache<NSString, NSImage> }`로 구현, 조회는 동기 캐시 히트 우선 + 미스 시 백그라운드에서 아이콘만 가져와 MainActor로 복귀해 캐시 채움. 셀 재사용 시 가시 행만 요청(스크롤 시 이전 요청 취소)
- `typeDescription`(UTType localizedDescription)은 항목별 재계산 대신 **contentType 식별자 키로 캐시**(100k 항목 열거 시간 보호)
- 파일 크기 포맷 `ByteCountFormatter`, 수정일 포맷은 Finder와 동일한 상대/절대 혼합 대신 **고정 포맷** (`yyyy-MM-dd HH:mm`, MVP 단순화)

**수용 기준**
- [ ] 홈 폴더 열기: 4컬럼 표시, 헤더 정렬 동작, 폴더 더블클릭 진입, 파일 더블클릭 기본 앱 실행
- [ ] 로딩 중 다른 폴더로 이동 시 이전 결과가 화면에 나타나지 않음 (취소 검증 — T1의 `DirectoryListing` mock으로 지연 주입해 race 확인)
- [ ] 권한 없는 폴더: "접근 권한 없음" 표시, 크래시 없음
- [ ] `IconProvider`가 `@MainActor` 클래스로 컴파일 통과(actor 아님), `NSImage` Sendable 경계 위반 없음
- [ ] 10k/100k fixture로 첫 표시 시간 조기 측정(§5 T8 참조 — T8은 튜닝 전용으로 축소)

### T4. TreeModel + SidebarTree 브릿지 (좌측 pane)

- `TreeModel`: 섹션 3개(즐겨찾기: Desktop/Downloads/Documents 고정, 홈, 볼륨: `FileManager.mountedVolumeURLs` 중 로컬만), 노드 lazy 1-depth 확장, `reveal(url)` — 경로 체인 순차 확장+선택
- `SidebarTreeBridge` (`NSOutlineView`): 폴더만 표시, 확장/축소, 선택 → `NavigationModel.navigate`
- 우측에서 폴더 진입 시 `reveal` 호출로 트리 동기화 (설계 §2.2). 순환 심볼릭 링크 방어: reveal 확장 depth 상한 32

**수용 기준**
- [ ] 트리에서 임의 깊이 폴더 선택 → 우측 갱신
- [ ] 우측 더블클릭·주소창 이동 → 트리 자동 확장·선택 동기화
- [ ] 노드 확장 < 100ms (설계 §5)
- [ ] 단위 테스트: lazy 확장(자식 1-depth만 로드), reveal 경로 체인

### T5. 툴바 — 내비게이션 + breadcrumb 주소창

- 뒤로/앞으로/상위 버튼 (NavigationModel 바인딩, 불가 시 비활성)
- breadcrumb: 경로 세그먼트 버튼 나열, 클릭 시 해당 폴더 이동. 공간 부족 시 앞쪽 세그먼트 `…`로 접기
- 빈 영역 클릭 또는 `Cmd+L`(2026-08-18 → `Cmd+Shift+G`, m3-impl §5.2) → 텍스트 필드 전환, Enter로 이동(`~` 확장, 존재하지 않는 경로는 무효 표시 후 유지), Esc로 복귀

**수용 기준**
- [ ] 뒤로→앞으로→상위 이동이 히스토리와 일치, 경계에서 버튼 비활성
- [ ] breadcrumb 세그먼트 클릭 이동, `Cmd+L`(현행 `Cmd+Shift+G`) 편집 왕복
- [ ] 잘못된 경로 입력 시 에러 표시 + 현재 위치 유지

### T6. 상태바 + 숨김 토글 + 새로고침

- 상태바: "항목 N개" / 선택 시 "M개 선택됨 (크기 합)" — 파일만 합산, 폴더 크기 제외(설계 §3.2)
- `Cmd+Shift+.` 숨김 토글(트리·목록 동시 적용, 앱 재시작 시 유지 — `UserDefaults`)
- `Cmd+R`/`F5`/툴바 버튼 새로고침: 현재 폴더 재열거, 선택 유지(URL 기준 재매칭)

**수용 기준**
- [ ] 선택 변경 시 상태바 즉시 갱신
- [ ] 숨김 토글 즉시 반영 + 재시작 후 유지
- [ ] 새로고침 후 기존 선택 항목 유지(삭제된 항목은 선택 해제)
- [ ] 현재 폴더가 외부에서 삭제된 상태에서 새로고침/이동 시 가장 가까운 존재하는 상위 폴더로 이동 (설계 §6)

### T7. 키보드 라우팅 (Win10 매핑)

- **경계 (architect B4)**: 방향키·`Enter`·타입-어헤드 등 목록/트리 내부 원시 `keyDown`은 T3(FileListBridge)·T4(SidebarTreeBridge)의 Coordinator가 이미 소유(각 태스크에서 구현됨). T7은 그 위에 **앱 레벨 단축키**(`Cmd+L`, `Cmd+Shift+.`, `Cmd+R`/`F5`, `Backspace`/`Cmd+↑`=상위, `Cmd+O`/`Cmd+↓`=열기)와 **`Tab` 트리↔목록 순환**, **first responder 정책**만 담당 — 브릿지 내부 keyDown을 재작성하지 않는다
- 포커스 규칙: 앱 시작 시 우측 목록에 포커스. 주소창 편집 중에는 목록 단축키 비활성
- `Space` 충돌 규칙 (UI설계 §9): 타입-어헤드 입력 진행 중(마지막 입력 후 1초 이내)에는 `Space`가 검색 문자열에 포함되도록 T3 Coordinator에 예약만 해두고, M1에서는 QuickLook 토글로 소비하지 않음(M3 T3에서 활성화)
- 구현 위치: SwiftUI `.keyboardShortcut`으로 앱 레벨 단축키 등록 — 브릿지가 포커스를 가진 상태에서의 충돌은 브릿지 우선

**수용 기준**
- [ ] 마우스 없이 키보드만으로: 트리 이동→폴더 진입→상위 이동→주소창 직접 입력 전 과정 수행 가능
- [ ] `F2` 등 M2 키는 무동작(에러 없음)
- [ ] `Space` 입력이 타입-어헤드 진행 중엔 검색 문자열에 포함되고, T3 구현을 재작성하지 않고 T7만으로 앱 단축키가 동작함

### T8. 성능 검증·튜닝

- `tests/fixtures/generate.sh`: 10k / 100k 항목 폴더 생성 (파일·폴더·다양한 확장자 혼합)
- 측정: 폴더 열기→첫 표시 시간 로그(signpost), Instruments로 스크롤 fps 확인
- 예상 튜닝 포인트: 아이콘 로드 배치화, 정렬 백그라운드 수행, NSTableView 셀 재사용 검증

**수용 기준** (설계 §5)
- [ ] 10k 항목 < 500ms, 100k 항목 < 3s (첫 표시)
- [ ] 100k 폴더 스크롤 60fps (Instruments 증적)
- [ ] 로딩 중 폴더 연타 이동 시 UI 프리즈 없음

### T9. 통합 검증 (M1 종료 게이트)

- 전체 빌드·단위 테스트 통과 확인
- 수동 체크리스트 수행: §4 참조
- 발견 결함 수정 후 재검증

**수용 기준**
- [ ] `xcodebuild build` + `xcodebuild test` 전체 통과 (증적 필수)
- [ ] §4 수동 체크리스트 전 항목 통과

## 4. 수동 검증 체크리스트 (T9)

1. 홈/볼륨/즐겨찾기 각 섹션에서 5-depth 이상 탐색
2. 트리 선택 ↔ 우측 진입 ↔ 주소창 입력 ↔ 뒤로/앞으로 — 4가지 이동 수단 교차 사용 시 트리·breadcrumb·목록 상태 일치
3. 권한 없는 폴더(`/private/var/root` 등) 접근 → 에러 표시, 이후 정상 탐색 계속
4. 심볼릭 링크 폴더 더블클릭 → 타겟 이동, 배지 표시
5. 숨김 파일 토글·정렬 4종 왕복·타입-어헤드
6. 한글/이모지/긴 파일명(255자) 표시, 이름 정렬이 Finder와 동일(`localizedStandardCompare`)
7. 외장 볼륨 연결/해제 시 볼륨 섹션 갱신 (M1은 새로고침 시 반영이면 통과 — 자동 갱신은 M3)
8. 표시 중인 폴더를 터미널에서 삭제 → 새로고침 시 가장 가까운 상위 폴더로 이동, 크래시 없음

## 5. 구현 순서·의존

```
T0 ──▶ T1 ──▶ T3 ──▶ T5 ──▶ T6 ──▶ T7 ──▶ T8 ──▶ T9
        │      ▲
        └─▶ T4 ┘ (T4는 T1 완료 후 T3와 병행 가능)
T2 ── T0 직후 언제든 (T3·T5의 선행 조건)
```

- 병행 가능: T1+T2 동시, T3+T4 동시 (파이프라인 투입 시 ralph 2개 분담 가능)
- T8은 T3 완료 시점부터 조기 측정 시작 권장 (막판 성능 문제 발견 방지)

## 6. 리스크·주의 (설계 §8에서 M1 해당분)

| 리스크 | 대응 |
|--------|------|
| SwiftUI↔AppKit 포커스·단축키 라우팅 충돌 | T7에서 라우팅 규칙 단일화(브릿지 우선). T3·T4 구현 시 포커스 처리를 임시로 두지 말고 TODO 주석으로 T7에 위임 명시 |
| NSOutlineView lazy 로딩 중 UI 스레드 블로킹 | 자식 로드도 DirectoryLoader(actor) 경유, 로딩 중 placeholder 노드 표시 |
| 100k 폴더 정렬 비용 | 정렬을 백그라운드에서 수행 후 결과만 MainActor 반영 (T1에서 구조 확보) |
| **[릴리스 전 필수] hardened runtime 비활성 + ad-hoc 서명** | 현재 `project.yml`은 `ENABLE_HARDENED_RUNTIME: NO` + `CODE_SIGN_IDENTITY: "-"`(ad-hoc). **배포 전 반드시 hardened runtime 활성화 + Developer ID 서명 + 공증(notarization)으로 전환**한다. M1 개발 단계에서는 그대로 둔다 — 지금 켜면 로컬 개발 서명이 매 빌드 바뀌어 전체 디스크 접근(FDA) 승인이 반복적으로 깨진다. 전환은 M3(FDA 온보딩)와 함께 처리 |
| 사용자 방문 경로의 로그 노출 | `PerfLog`는 경로를 `privacy: .private`로만 남긴다(통합 로그 평문 기록 금지). 소요 시간·항목 수만 public |
| 즐겨찾기(데스크탑/다운로드/서류) TCC 프롬프트 | `project.yml`에 `NSDesktopFolderUsageDescription` / `NSDocumentsFolderUsageDescription` / `NSDownloadsFolderUsageDescription` 문구 필수. 누락 시 프롬프트 대신 앱이 종료된다 |

## 7. 문서 연계

- 후속: M1 완료 후 `unifinder-m2-impl` (파일 조작) 작성
- 테스트계획서(`test`) 분리 여부: M1은 본 문서 §3 수용 기준 + §4 체크리스트로 갈음. M2부터 파일 조작(파괴적 작업) 테스트계획서 분리 검토
