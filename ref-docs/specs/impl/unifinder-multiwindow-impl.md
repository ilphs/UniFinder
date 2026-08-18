---
id: unifinder-multiwindow-impl
title: UniFinder 다중 창 구현계획서 — New Window (⌘N · 컨텍스트 메뉴)
type: impl
version: 1.0.0
status: implemented
scope: 단일 Window 씬 → WindowGroup 전환, 창별 AppModel, 앱 전역 상태 분리, 진입점 3종
related: [unifinder-mvp-design, unifinder-ui-design, unifinder-m1-impl, unifinder-m2-impl, unifinder-m3-impl]
updated: 2026-08-18
---

# UniFinder 다중 창 구현계획서 — New Window

## 1. 입력과 목표

- **입력**: MVP(M1·M2·M3) 완료 상태의 실제 코드베이스, `unifinder-m3-impl` §5(후속 과제)
- **목표**: 창을 여러 개 열 수 있게 한다. 창마다 **독립된 탐색·트리·히스토리**를 갖고,
  앱 전역이어야 하는 상태(설정·클립보드·FDA)는 창을 넘어 하나로 유지한다.
- **하지 않는 것**: 탭(macOS 기본 창 탭에 위임), 창 간 상태 복원 정밀화, 창별 설정 분리

### 확정된 사용자 결정

| 항목 | 결정 | 근거 |
|------|------|------|
| ⌘N 초기 폴더 | **현재 창의 폴더** | Win10 탐색기 방식 |
| 숨김 파일 / 정렬 | **즉시 전 창 동기화** | 설정은 앱 전역 1개다 |
| 파일 목록 **빈 영역** 우클릭 | "Open in New Window" **넣지 않음** | 대상이 모호해진다(항목 우클릭만) |
| 마지막 창을 닫았을 때 | 앱 유지(종료하지 않음) | 기존 동작 유지 |

## 2. 뒤집은 전제 — 옛 "단일 창 봉인"의 진짜 이유

M3 리뷰 권장 3은 씬을 `Window` 단일로 못 박고 `SingleWindowSceneTests`로 봉인했다.
그 근거는 "`AppModel`은 윈도우 1개분의 상태인데 `WindowGroup`은 그 **하나를 공유**하는 창을
여러 개 만든다 → 한 창의 `onDisappear` → `model.stop()`이 살아 있는 다른 창의 감시자 4종
(FSEvents·볼륨·클립보드·FDA)까지 전부 해제한다"였다.

즉 결함의 원인은 `WindowGroup`이 아니라 **앱 레벨 `@State`로 만든 `AppModel` 하나**였다.
이번 작업은 그 원인을 없앤다:

- 창마다 `AppModel`이 하나씩 생긴다 (`MainWindowRoot`가 `@State`로 붙든다)
- 앱 전역이어야 하는 것만 `AppEnvironment.shared`가 소유한다
- 공유 감시자의 해제는 **소유자 집합**으로 판정한다 (마지막 소유자가 빠질 때만 해제)

봉인 테스트는 `MultiWindowSceneTests`로 대체했다(불변식 4개 — §7).

## 3. 구조

```
AppEnvironment.shared          앱 전역 1개
├── settings: AppSettings          숨김·정렬·즐겨찾기·폭
├── clipboard: ClipboardModel      창 A ⌘C → 창 B ⌘V
├── fullDiskAccess: FullDiskAccessModel
└── openWindowIDs: [UUID]          열린 창 목록(등록 순서 유지)

WindowGroup(id: "main", for: WindowSeed.self)
└── MainWindowRoot(seed:)      창 1개 = AppModel 1개
    └── MainWindow(model:)
        ├── .focusedSceneValue(model)   → AppCommands가 집어간다
        ├── .fullDiskAccessOnboarding(_:isPresenter:)
        └── .onChange(showHidden / sortDescriptor / favoritePaths) → 창 상태 동기화
```

### 3.1 `WindowSeed`에 UUID가 있는 이유

`WindowGroup(id:for:)`은 presentation value를 **창의 신원**으로 쓴다. 같은 값으로 이미 열린
창이 있으면 새 창을 만들지 않고 그 창을 앞으로 가져온다. ⌘N의 기본 동작이 "현재 창의 폴더"라
시드가 폴더뿐이면 **⌘N을 연타해도 창이 하나만 생긴다.** 그래서 매번 새로 만드는 `id: UUID`를
신원으로 싣고 폴더(`folderPath`)는 부수 정보로 둔다.

### 3.2 런치 창

값 기반 `WindowGroup(for:)`은 런치 창의 시드가 없다. `defaultValue:` 오버로드를 써서
`WindowSeed.launchDefault()`(= 홈)를 시드로 준다. 여기가 무너지면 앱이 창 없이 뜨고
UI 스모크(`NavigationSmokeUITests`)가 첫 단언에서 실패한다.

### 3.3 메뉴 라우팅 — `focusedSceneValue`여야 하는 이유

`AppCommands`는 `@FocusedValue(AppModel.self)`로 **활성 창의 모델**을 집어간다.
게시는 반드시 `focusedSceneValue`다. `focusedValue`는 "포커스된 SwiftUI 뷰"가 있어야 값을
게시하는데, 이 앱의 first responder는 `NSTableView`/`NSOutlineView`(AppKit 브릿지)라
**SwiftUI 포커스 체인에 뷰가 없다** — 값이 영영 `nil`이 되어 File/View/Go 메뉴가 통째로
비활성 상태로 굳는다. `focusedSceneValue`는 활성 **씬** 기준이라 AppKit이 포커스를 쥐고 있어도
게시된다. 되돌리지 말 것.

배포 타깃이 macOS 14이므로 SDK의 Observable 전용 오버로드를 쓴다 —
커스텀 `FocusedValueKey`도 `AppModel: Equatable` 채택도 필요 없다.

### 3.4 Edit 메뉴는 `model == nil`에도 항상 활성

`.pasteboard` 그룹의 Cut/Copy/Paste/Select All 4개는 **활성 창이 없어도 비활성화하지 않는다.**
`.disabled`로 내리면 ⌘X/⌘C/⌘V/⌘A를 달고 있는 메뉴 항목이 하나도 없게 되고, AppKit은 ⌘ 단축키를
responder chain보다 **메인 메뉴에서 먼저** 찾으므로 주소창·인라인 rename·시트의 텍스트 편집
복사/붙여넣기가 통째로 죽는다. 모델이 없을 때는 `NSApp.sendAction`으로 responder chain에 그대로
넘긴다(`AppModel.forwardToTextResponder`의 기본 구현과 같은 경로).

`Move Items Here`(⌥⌘V)만은 예외다 — 텍스트 단축키가 아니라 대상이 없으면 할 일이 없다.

### 3.5 FDA 온보딩 시트의 표시 소유권

`FullDiskAccessModel.isOnboardingPresented`는 공유 인스턴스의 `Bool` **하나**인데
`.sheet(isPresented:)`는 **창마다 붙는 모디파이어**다. 게이팅이 없으면 열린 창 전부가 같은
시트를 동시에 띄운다. `AppEnvironment.onboardingPresenterID`(= 첫 등록 창)를 두고
소유 창에서만 시트를 붙인다. 소유 창이 닫히면 다음 창이 승계한다.

**배너는 시트와 다른 규칙을 쓴다** — 제한 모드는 모든 창에 해당하는 사실이므로 전 창에 띄운다.

여기가 함정이다: `shouldShowBanner`의 원래 구현은 `guard !isOnboardingPresented`로 시작했다.
그 `Bool`이 공유 하나이므로, 소유 창 A에 시트가 뜨는 순간 **창 B는 시트도 배너도 못 본다** —
B 사용자는 제한 모드라는 사실 자체를 알 수 없다. "중복 노출을 피한다"는 원래 의도는
**실제로 시트에 가려지는 창**에만 해당하므로, 판정을 창별로 분기한다:

```swift
func shouldShowBanner(isPresenter: Bool) -> Bool {
    if isPresenter, isOnboardingPresented { return false }   // 시트에 가려지는 창만 숨긴다
    switch status { case .granted: return false; case .denied, .undetermined: return true }
}
```

인자 없는 `shouldShowBanner` 프로퍼티는 `isPresenter: true`(= 단일 창 시절 의미론)로 남겨 둔다.

### 3.6 소유자 집합 (참조 카운트가 아니라)

`ClipboardModel`/`FullDiskAccessModel`의 감시 등록·해제는 `Set<UUID>`로 소유 창을 기록한다.
`Int` 카운트를 쓰지 않는 이유는 SwiftUI가 뷰 아이덴티티 변화 시 `onAppear`/`onDisappear`를
추가로 호출할 수 있어 값이 드리프트(음수/누수)하기 때문이다. 집합은 중복 호출에 멱등이다.
`AppModel.start()`의 `guard !didStart` 안쪽에서만 증감하는 이중 안전망도 함께 둔다.

인자 없는 `start()`/`stop…()` 호출은 `defaultOwnerID` 고정 토큰을 써서 기존 단일 소유자
의미론(한 번 걸고 한 번 푼다)을 그대로 유지한다 — 기존 수명주기 테스트가 수정 없이 통과한다.

### 3.7 `AppSettings`가 공유여야 하는 이유 — 창별 인스턴스는 데이터를 잃는다

"앱 전역이니까"는 근거가 아니다. 창별 인스턴스가 **실제로 무엇을 깨뜨리는지**가 근거다.

`AppSettings.favoritePaths`는 `didSet`에서 **배열 전체를 `UserDefaults`에 재대입**한다
(`addFavorite`은 append 후 전체 쓰기, `removeFavorite`은 filter 후 전체 쓰기). 인스턴스는
자기 메모리 사본을 권위로 삼고 그것을 통째로 덮어쓰므로, 창마다 인스턴스를 두면:

1. 창 A와 창 B가 각각 시작 시점의 목록 `[X]`를 읽어 든다
2. 창 A에서 `Y`를 추가 → A의 사본은 `[X, Y]`, defaults도 `[X, Y]`
3. 창 B에서 `Z`를 추가 → **B의 사본은 defaults를 다시 읽지 않으므로** `[X, Z]`가 되고
   그대로 defaults를 덮어쓴다 → **`Y`가 소실된다**

즉 "나중에 쓴 쪽이 이긴다"가 아니라 **한 번의 추가로 다른 창의 추가가 통째로 사라진다.**
컬럼 폭처럼 마지막 값만 살아남으면 되는 스칼라(§4.3)와 성질이 다르다.
`showHidden`/`sortDescriptor`도 같은 이유로 공유가 옳고, 부수적으로 사용자 결정
("숨김/정렬은 즉시 전 창 동기화")을 자연스럽게 만족한다.

### 3.8 공유 설정 → 창 상태 동기화는 **단방향**이다

`AppSettings`는 앱 전역 1개지만 `DirectoryModel`/`TreeModel`은 **창마다 자기 사본**을 든다
(정렬된 항목 배열, 트리 섹션·노드 인덱스). 설정 변경이 다른 창의 화면까지 닿으려면 명시적
동기화가 필요하다. `MainWindow`의 `.onChange` 훅 3종이 그 배선이다:

| `.onChange` 대상 | 호출 API | 하는 일 |
|------------------|----------|---------|
| `settings.showHidden` | `syncShowHiddenFromSettings()` | `directory.setShowHidden` + `tree.showHidden` + `rebuildSections` + reveal |
| `settings.sortDescriptor` | `syncSortFromSettings()` | `directory.applySort` |
| `settings.favoritePaths` | `syncFavoritesFromSettings()` | `rebuildSections` + reveal |

**규칙 1 — sync는 `settings`에 되쓰지 않는다.** 되쓰면 `.onChange`가 다시 발화해 창들 사이에서
무한 왕복이 된다. 반대 방향(창 → 설정)은 `toggleHiddenItems`/`toggleSort`/`applySort`/
`addFavorite`/`removeFavorite`만 담당한다. 이 단방향 규약을 `AppModelSettingsSyncTests`가 고정한다.

**규칙 2 — sync는 값 비교로 자기 자신을 걸러낸다.** 변경을 일으킨 창에도 `.onChange`가 도착하므로,
가드가 없으면 그 창은 같은 작업을 두 번 한다. `startReveal`은 진행 중이던 `revealTask`를
**취소**하므로 방금 시작한 reveal이 즉시 취소·재시작되고, 창이 N개면 N+1회 돈다.
`showHidden`/`sortDescriptor`는 `directory`의 현재 값과 비교하고, 즐겨찾기는 비교할 캐시가
트리에 없으므로 `AppModel.appliedFavoritePaths` 스냅샷을 따로 둔다.

## 4. 수용된 트레이드오프 (의도된 결정 — 다음 리뷰에서 blocker로 재발견하지 말 것)

### 4.1 파일 조작 직렬화 범위가 **창 단위로 축소**된다

`AppModel.runOperation`의 "동시 2건 금지"는 지금까지 앱 전역 불변식이었다. 창마다 `AppModel`이
생기면서 이 직렬화는 **창 단위**가 된다.

- 창 2개가 같은 폴더로 동시에 복사하면 **충돌 시트가 창마다 뜬다**
- 고유 이름 생성(`untitled folder 2`, `사본` 등)이 서로의 진행 상황을 보지 못한다

**수용한다.** 각 시트가 window-modal이라 사용자는 어느 창의 조작인지 구분할 수 있고,
파괴적 경로의 안전 가드(`destinationInsideSource`, `isSameFolder` — 무한 재귀 복사와
같은 폴더 붙여넣기를 막는다)는 `FileOperations`가 권위로 들고 있어 창 수와 무관하게 성립한다.

> **⚠️ "`FileOperations`가 actor니까 안전하다"로 읽지 말 것.** actor가 보장하는 것은 **한 호출
> 안의 동기 구간**뿐이고, "이름 결정 → 생성"은 그 단위로 묶여 있지 않다. 두 군데가 갈라진다:
>
> - **고유 이름 넘버링** — `FileOperating.createFolder(in:uniqueBaseName:)`은 actor 밖(프로토콜
>   익스텐션)에서 `await createFolder(in:name:)`을 이름을 바꿔가며 반복한다. 매 시도 사이가
>   suspension point다.
> - **충돌 해결** — `FileOperations`는 `await resolver.resolve(...)`로 시트 응답을 기다린다.
>   actor는 `await` 지점에서 **재진입을 허용**하므로 다른 창의 조작이 그 틈에 들어온다.
>
> 그래서 다른 창이 같은 이름을 선점할 수 있다. **다만 손실로는 이어지지 않는다** — 생성/이동은
> `withIntermediateDirectories: false` 계열이라 이미 있으면 덮어쓰지 않고 `nameExists`로 실패하고,
> 넘버링 루프는 그 실패를 받아 다음 번호로 넘어간다. 관측되는 최악은 "`untitled folder 2`가
> 기대와 다른 창에 생긴다" 또는 충돌 시트가 한 번 더 뜨는 정도다.
> **이 구분(경합은 있으나 덮어쓰기 손실은 없다)이 수용의 근거**이며, "actor라서 경합이 없다"는 거짓이다.

전역 직렬화가 필요해지면 `AppEnvironment`에 조작 큐를 올리는 것이 그때의 정답이다.

### 4.2 macOS 창 탭이 자동으로 활성화된다

`WindowGroup`이 되면 macOS가 Window 메뉴에 `Merge All Windows` / `Show Tab Bar`를 자동으로
넣는다. 별도 구현 없이 얻는 기능이라 그대로 둔다(탭은 Phase 2 항목이었는데 OS 기본 동작으로
부분 충족된다). 앱이 그리는 탭이 아니므로 툴바·주소창은 창 단위 그대로다.

### 4.3 컬럼 폭 / 사이드바 폭은 last-writer-wins

`AppSettings.setColumnWidth`/`sidebarWidth`는 앱 전역 1개다. 창 A에서 컬럼을 넓히고 창 B에서
다르게 넓히면 **나중에 쓴 쪽이 저장된다.** 화면은 각 창이 자기 상태를 유지하므로 사용 중에는
어긋나지 않고, 다음 실행에서 마지막 값이 두 창 모두에 적용된다. 창별 폭 저장은 범위 밖이다.

### 4.4 창 상태 복원은 **생성 시점 폴더**로 고정된다

`WindowSeed`는 창이 만들어질 때의 폴더를 싣고, 그 뒤의 탐색은 창 내부 `AppModel`에만 남는다
(시드에 되쓰지 않는다). 그래서 macOS가 창을 복원하면 **종료 시점의 폴더가 아니라 그 창이
처음 열렸던 폴더**로 돌아온다. 시드에 현재 폴더를 계속 되쓰면 presentation value가 바뀌면서
창 신원이 흔들리므로(§3.1) 의도적으로 하지 않는다.

### 4.5 크로스-윈도우 드래그앤드롭은 이미 동작한다

`FileListBridge`가 `draggingSession(_:sourceOperationMaskFor:)`에서 `forLocal: true`에
`[.copy, .move]`를 주고 있어 같은 프로세스의 다른 창으로 끌어다 놓는 경로가 그대로 성립한다.
코드 수정 없음 — **수동 게이트 항목**으로만 기록한다.

### 4.6 조작이 진행 중인 창을 닫으면 진행률만 사라지고 조작은 계속된다

`AppModel.stop()`은 감시자를 정리하고 소유권을 반납하지만 **`operationTask`를 취소하지 않는다.**
그래서 복사 중인 창을 닫으면 진행률 오버레이·상태바·취소 버튼이 화면에서 사라진 채로
복사는 끝까지 진행된다(충돌 시트가 필요해지면 `focusBroker.window`가 사라져 취소로 응답한다).

단일 창 시절에도 있던 성질이지만 그때는 "창을 닫는다 ≒ 앱을 접는다"라 사실상 드러나지 않았다.
다중 창에서는 **배경 창을 닫는 것이 일상 동작**이라 발현 확률이 크게 오른다.

이번 범위에서 고치지 않는 이유: 올바른 처리가 무엇인지가 UX 결정이기 때문이다 —
(a) 조작을 취소한다, (b) 다른 창으로 진행률을 넘긴다(= 조작을 `AppEnvironment` 소유로 올린다),
(c) 창이 닫히지 않게 막는다 중 어느 쪽인지 정해지지 않았다. `stop()`에서 `cancelCurrentOperation()`을
부르는 것은 한 줄이지만 **사용자가 명시적으로 시작한 작업을 창 닫기라는 간접 행위로 취소**하는
것이라 조용히 넣을 변경이 아니다. 후속 과제로 남긴다.

## 5. 태스크 (전부 완료)

| # | 태스크 | 산출물 |
|---|--------|--------|
| T1 | 공유 감시자에 소유자 집합 도입 | `ClipboardModel`, `FullDiskAccessModel` |
| T2 | 앱 전역 상태 소유자 | `src/App/AppEnvironment.swift` (신규) |
| T3 | 창 식별자·환경 주입·설정 동기화 API | `AppModel` |
| T4 | `WindowGroup` 전환 + 창별 모델 경계 | `UniFinderApp`, `src/App/WindowSeed.swift`, `src/Views/MainWindowRoot.swift` (신규), `MainWindow`, `OnboardingSheet` |
| T5 | 씬 회귀 테스트 교체 | `MultiWindowSceneTests` (신규) ← `SingleWindowSceneTests` (삭제) |
| T6a | 메뉴 라우팅을 `@FocusedValue`로 | `AppCommands` |
| T6b | File > New Window (⌘N) | `AppCommands` / `NewWindowButton` |
| T7 | 컨텍스트 메뉴 "Open in New Window" | `SidebarTreeBridge`, `FileListBridge`, `FileListPane`, `SidebarPane` |
| T8 | 스펙 문서 · README/CLAUDE 갱신 | 이 문서 |

> T4와 T6a는 **분리 불가**다. 씬을 `WindowGroup`으로 바꾸는 순간 `AppCommands(model:)`에 넘길
> 앱 레벨 모델이 사라져 컴파일이 되지 않는다.

## 6. 진입점

| 진입점 | 시작 폴더 | 비고 |
|--------|-----------|------|
| File > New Window (⌘N) | **현재 창의 폴더** | 활성 창이 없으면 홈 |
| 트리 노드 우클릭 > Open in New Window | 그 노드 | `Open` 바로 아래. 트리 노드는 전부 폴더 |
| 파일 목록 **항목** 우클릭 > Open in New Window | 그 항목 | **폴더일 때만 활성**. 심볼릭 링크는 `AppModel.resolveTarget`로 타겟 해석 |

`AppCommands`는 `CommandGroup(replacing: .newItem)`을 **유지**한다. `WindowGroup`이 자동으로
넣는 "New Window"(⌘N)를 이 그룹이 교체하므로 중복이 없다 — `after:`로 바꾸면 자동 항목이
살아남아 **⌘N이 두 개**가 된다.

## 7. 테스트 전략

### 7.1 핵심 회귀 불변식 (`MultiWindowSceneTests`)

1. 메인 씬이 `WindowGroup`이다
2. 창마다 `AppModel`이 **다른 인스턴스**다 (navigation·directory·tree 전부)
3. 설정·클립보드·FDA는 창을 넘어 **같은 인스턴스**다
4. 한 창의 `stop()`이 **다른 창의 감시자를 끊지 않는다** (옛 봉인이 막으려던 결함)
5. 같은 폴더 시드가 서로 다른 값이다 (⌘N 연타로 창이 늘어난다)
6. 시드가 `nil`인 런치 창이 홈으로 폴백한다
7. 소유자 등록/해제가 멱등이다
8. FDA 온보딩 시트 소유 창이 하나뿐이고 닫히면 승계된다
9. 사라진 폴더를 가리키는 시드는 가장 가까운 상위로 폴백한다 (§4.4의 복원 경로 — 설계서 §6)
10. 즐겨찾기 동기화가 **변경을 일으킨 창에서는 무동작**이다 (§3.8 규칙 2)

### 7.2 신규 테스트 파일

| 파일 | 고정하는 것 |
|------|-------------|
| `AppTests/MultiWindowSceneTests` | §7.1의 불변식 10개 |
| `AppTests/AppEnvironmentTests` | `register`/`unregister` 멱등성·순서, `onboardingPresenterID` 승계, `hasOpenWindows` 전이, 주입 인스턴스 간 독립성 |
| `AppTests/WindowIsolationLifecycleTests` | 창별 `AppModel`의 수명주기 격리 — 한 창의 `start`/`stop`이 다른 창의 상태·감시자에 새지 않는다 |
| `AppTests/AppModelSettingsSyncTests` | §3.8의 단방향 규약 — sync가 `settings`에 되쓰지 않고, 값이 같으면 무동작 |
| `BridgesTests/OpenInNewWindowMenuTests` | 두 컨텍스트 메뉴의 항목 위치·활성 조건(폴더만)·클릭 시점 대상 스냅샷 |

### 7.3 변경된 기존 테스트

| 파일 | 변경 이유 |
|------|-----------|
| `AppTests/SingleWindowSceneTests` | **삭제** — 봉인의 원인을 없앴다(§2). `MultiWindowSceneTests`가 대체 |
| `BridgesTests/M2BridgeSmokeTests` | 컨텍스트 메뉴에 "Open in New Window"가 끼면서 항목 배열이 밀렸다 |
| `ViewModelsTests/ClipboardModelTests` | `startObservingPasteboard(owner:)` 소유자 집합 계약 추가 |
| `ViewModelsTests/FullDiskAccessModelTests` | 소유자 집합 계약 + `shouldShowBanner(isPresenter:)` 창별 게이팅(§3.5) |
| `AppTests/AppModelEditMenuRoutingTests` | Edit 메뉴가 `model == nil`에서도 살아 있어야 한다(§3.4) |
| `AppTests/AppModelLifecycleRestartTests` | QuickLook 공유 패널의 **소유권 검사** — 배경 창을 닫아도 남의 미리보기를 끄지 않는다 |
| `UITests/NavigationSmokeUITests` | `-favoritePaths`로 즐겨찾기 고정 — 아래 §7.4 참조 |

### 7.4 테스트 격리 규약 (반드시 지킬 것)

- **`AppEnvironment.shared`를 테스트에서 인스턴스화하지 않는다.** 접근하는 순간
  `AppSettings(defaults: .standard)`가 만들어지고, `AppSettings.init`의 "키 부재 → 기본 3개 시딩
  + **standard 도메인 쓰기**" 경로가 **개발 머신의 실제 앱 설정을 건드린다.**
  검증하려는 성질(독립성)은 주입 인스턴스 2개를 비교하면 그대로 확인된다.
- **`AppModel(environment: nil)`은 격리된 새 환경을 만든다.** 이것이 `environment` 파라미터의
  기본값을 `.shared`로 두지 않은 이유다 — 기존 61개 호출부가 `UserDefaults.standard`와
  `NSPasteboard.general`을 공유하게 되면 테스트끼리 오염된다.
- 설정은 `UserDefaults(suiteName:)`, 클립보드는 전용 `NSPasteboard(name:)`, FDA는 주입 프로브.
- **UI 스모크도 같은 원칙을 따른다.** 즐겨찾기가 v0.2.0부터 사용자 편집 대상이 되면서
  "트리에 Documents가 있다"는 전제가 개발 머신 상태에 좌우됐다(실제로 그 때문에 실패했다).
  `-favoritePaths`를 argument domain으로 고정한다 — 값이 파싱되므로 `AppSettings`가 "키 부재"
  시딩 경로를 타지 않아 **사용자의 실제 설정을 덮어쓰지 않는다.**

## 8. 검증

```
xcodegen generate && xcodebuild -scheme UniFinder build
xcodebuild -scheme UniFinder test
```

- 단위/통합: 535 tests, 0 failures
- UI 스모크: 1 test, 0 failures (**`WindowGroup` 런치 창이 실제로 뜨는지의 유일한 자동 증거**)

### 수동 게이트

게이트 #6·#7은 자동 테스트로 **경계 조건까지는** 고정했지만(공유 QuickLook 패널의 소유권 검사,
`shouldShowBanner(isPresenter:)`), "실제로 화면에 남아 있는가"는 헤드리스에서 확인할 수 없으므로
수동 게이트로 유지한다.

| # | 시나리오 | 기대 |
|---|----------|------|
| 1 | ⌘N을 3회 연타 | 창이 3개 늘어난다(같은 폴더여도) |
| 2 | 창 A에서 ⌘C → 창 B에서 ⌘V | 창 B의 폴더에 붙여넣어진다 |
| 3 | 창 A에서 ⇧⌘.(숨김 토글) | 창 B의 목록·트리도 즉시 바뀐다 |
| 4 | 창 A의 항목을 창 B로 드래그 | 복사/이동된다(§4.5) |
| 5 | 창 2개 중 하나를 닫고 남은 창에서 탐색/붙여넣기 | 정상 동작(감시자가 살아 있다) |
| 6 | 창 A에서 QuickLook(Space) 후 창 B를 닫음 | A의 미리보기 패널이 닫히지 않는다 |
| 7 | FDA 미허용 상태로 창 2개 | 시트는 한 창에만 뜨고 배너는 두 창 모두 |
| 8 | Window > Merge All Windows | 창 탭으로 합쳐진다(§4.2) |
