---
id: unifinder-m2-impl
title: UniFinder M2 구현계획서 — 파일 조작
type: impl
version: 0.2.0
status: draft
scope: M2(파일 조작)의 태스크 분해·구현 순서·수용 기준·검증 방법
related: [unifinder-mvp-design, unifinder-ui-design, unifinder-m1-impl]
updated: 2026-08-14
---

# UniFinder M2 구현계획서 — 파일 조작

## 1. 입력과 목표

- **입력**: `unifinder-mvp-design` §3.1(FileOperations)·§4(결정 3·4)·§6(엣지), `unifinder-ui-design` §6(컨텍스트 메뉴)·§7(다이얼로그), **M1 완료 상태의 실제 코드베이스**(가상이 아님 — `src/App/AppModel.swift`, `src/Bridges/FileListBridge.swift`, `src/Bridges/SidebarTreeBridge.swift`, `src/ViewModels/TreeModel.swift`, `src/ViewModels/DirectoryModel.swift` 등)
- **M2 완료 기준** (설계서 §7): 복사/잘라내기/붙여넣기, 휴지통 삭제, 이름변경, 새 폴더, 컨텍스트 메뉴, 충돌 다이얼로그 — 파일 관리 기본 작업을 UniFinder만으로 수행 가능
- **M2에서 하지 않는 것**: 드래그앤드롭·진행률 UI·FSEvents(M3), undo(Phase 2), 영구 삭제(비목표)

> **[architect 재검토 v0.2.0]** 최초 v0.1.0은 architect 1차 검토에서 CONDITIONAL(B1~B9) 판정을 받았다. 실제 M1 코드와 대조한 결과 "무엇을 만들지"는 정의됐으나 "M1 코드 어디에 어떻게 꽂을지"가 비어 있었고, 삭제 키 매핑·cut 표시 갱신·트리 노드 무효화는 **원안대로면 회귀 또는 동작 불능**이었다. 아래 T0~T8은 B1~B9를 전부 반영한 개정판이다.

## 2. 태스크 분해

### T0. 액션 소유권 + FileOperations 서비스 (B1·B4)

- **소유권 구조 (B1)**: M1의 `AppModel`이 모든 사용자 액션의 단일 진입점이므로(설계 §3.1 의존 방향 유지) M2도 동일 패턴을 따른다.
  - `FileOperations`(actor)·`ClipboardModel`(`@MainActor @Observable`)는 `AppModel`이 소유
  - `AppModel`이 `copy()` / `cut()` / `paste(into:)` / `rename(_:to:)` / `createFolder(in:)` / `trash(_:)`를 노출
  - 브릿지(FileListBridge/SidebarTreeBridge)는 의미 단위 콜백만 추가 노출: `onContextMenu` / `onBeginRename` / `onCommitRename` / `onDelete` (M1의 `onOpen`/`onNavigateUp`과 같은 패턴)
  - `AppModel.init(loader:)`처럼 `operations: any FileOperating = FileOperations.shared` 형태의 **주입 지점**을 만든다(M1 B3와 동일 원칙) — 테스트가 실 파일시스템에 묶이지 않도록
  - Services(FileOperations)는 ViewModel/AppKit을 import하지 않는다(설계 §3.1 재확인)
- **연산**: `copy(items:to:)`, `move(items:to:)`, `trash(items:)`, `rename(item:to:)`, `createFolder(in:name:)` — 항목 단위 순회(설계 결정 #4), 진행 상황을 `AsyncStream<OperationProgress>`로 방출 (M2는 상태바 미니 표시만 소비, M3 진행률 시트가 재사용)
- **충돌 질의 (B4 — M1 관례로 재설계)**: "스트림+콜백"이 아니라 M1의 `DirectoryListing` 프로토콜 주입 패턴을 그대로 따른다.
  ```swift
  protocol ConflictResolving: Sendable {
      func resolve(_ conflict: FileConflict) async -> ConflictResolution
  }
  ```
  `@MainActor` 프레젠터가 구현하고 `FileOperations`는 프로토콜만 안다(의존 방향 유지, 테스트는 결정적 mock 주입). "모두 적용" 상태는 **작업 1건 범위**의 로컬 값으로 소유 — 전역 actor 상태로 두지 않는다. 취소 시 대기 중인 continuation은 `withTaskCancellationHandler`로 반드시 재개시킨다(누수·행 방지 — 수용 기준에 포함)
- "둘 다 유지" 이름 규칙: `name 2.ext`, `name 3.ext` … (Finder 관례)
- Task 취소 지원: 진행 중 항목 완료 후 중단, 완료분 유지 (UI 설계 §7.4와 동일 의미론)
- 에러 매핑: 권한 부족, 대상 읽기 전용, 디스크 부족, 소스 소실 → 사용자 문구로 변환 (UI 설계 §8)
- 볼륨 간 `move`는 `FileManager.moveItem` 실패 시(크로스 디바이스) copy 후 원본 trash로 폴백
- `FileOperations` actor 내부에서 `FileManager.default` 공유 대신 **인스턴스를 생성**해 사용(대량 순회 중 delegate/상태 오염 회피)

**파괴적 작업 의미론 확정 (B3 — ralph 즉흥 설계 금지, 전부 명시)**
- **덮어쓰기**: `FileManager.copyItem`은 대상 존재 시 실패하므로, 기존 대상을 **휴지통으로 이동 후 복사**(설계 결정 #3 영구 삭제 금지와 정합) 또는 `replaceItemAt` 사용. 폴더 덮어쓰기는 **병합이 아니라 대체**(Finder 관례) — 재귀 병합 구현 금지
- **자기 자신/자기 하위 대상 거부**: 폴더 A를 A 또는 A의 하위 경로로 복사·이동 금지(무한 재귀 방지). D&D는 M3지만 트리 노드 붙여넣기가 이미 M2에 있으므로 지금 필요
- **대상 URL은 명시 인자**: 붙여넣기 대상은 `currentURL` 암묵 참조 금지 — 호출 시점에 확정해 전달(트리 노드에서 연 컨텍스트 메뉴는 대상이 다름). 조작 대상 항목도 **호출 시점 스냅샷**으로 고정(진행 중 reload/선택 변경이 대상을 바꾸면 안 됨)
- **대소문자만 바꾸는 rename**은 APFS 대소문자 비구분 특성상 자기 자신을 "중복"으로 오판하지 않도록 자기 자신 제외 규칙 적용
- **심볼릭 링크**: 링크 자체를 복사(타겟이 아님, 테스트계획서 §4.2). move 폴백(copy+trash)에서도 동일
- **위험 대상 가드**: 트리 메뉴의 "휴지통으로 이동"/"이름 변경"은 즐겨찾기 섹션 항목·볼륨 루트·홈 루트에서 **비활성**

**수용 기준**
- [ ] `AppModel`이 FileOperations/ClipboardModel을 소유하고, 브릿지는 의미 단위 콜백만 노출(M1 `onOpen` 패턴과 동일 구조인지 코드 리뷰로 확인 가능해야 함)
- [ ] `operations: any FileOperating` 주입 지점 존재 — 테스트에서 mock 주입 가능
- [ ] `ConflictResolving` 프로토콜 + mock으로 충돌 3분기 결정적 테스트
- [ ] 취소 시 대기 중 continuation이 반드시 재개됨(단위 테스트로 행/누수 없음 확인)
- [ ] 단위 테스트 (임시 디렉토리 fixture): 5개 연산 × 성공/충돌 3분기/권한 실패/취소, 볼륨 간 이동 폴백, "둘 다 유지" 넘버링, 다중 항목 중 일부 실패 시 나머지 계속+실패 목록 반환
- [ ] 자기 자신/자기 하위 대상 복사·이동 시도 → 거부 (단위 테스트)
- [ ] 덮어쓰기 시 기존 대상이 휴지통으로 이동 후 교체됨 확인, 폴더 덮어쓰기가 병합이 아니라 대체임을 확인
- [ ] 대소문자만 다른 rename 성공(자기 자신 제외 규칙)
- [ ] 심볼릭 링크 복사 시 링크 자체가 복사됨(타겟 내용 아님)
- [ ] 파괴적 테스트가 임시 디렉토리 밖을 절대 건드리지 않음 (테스트 셋업에서 경로 가드 assert, `TempDirectoryTestCase` 재사용)

### T1. TreeModel 무효화 API (B8 — 신규, T2·T4·T6의 선행 조건)

M1의 `TreeNode.name`/`url`은 `let`이고 `nodeIndex`는 등록(`register`)만 있고 **제거 경로가 없다.** 트리에서 이름 변경·삭제·새 폴더 생성이 일어나면 `nodeIndex`가 옛 경로를 계속 가리켜 이후 `node(for:)`/`reveal`이 조용히 어긋난다(M1이 코드 주석으로 이미 경고한 것과 같은 스테일 시나리오).

- `TreeModel.invalidate(_ url: URL)` 추가: 해당 노드의 서브트리 인덱스 키 전부 제거 + `children = nil` + `revision` 증가 → 브릿지가 재확장하도록 트리거
- 현재 표시 중인 폴더 자체가 rename/이동되면 `NavigationModel.replaceCurrent`(히스토리 미오염)로 전환 — back/forward 스택에 남은 옛 경로 항목은 이동 실패 시 "존재하지 않음" 처리(설계 §6과 일관)
- `SidebarTreeBridge.consumePendingReveal`은 `updateNSView`에서만 소비되므로, 트리 조작 후 `revision` 증가와 reveal 소비 순서를 수용 기준으로 검증

**수용 기준**
- [ ] 단위 테스트: `invalidate(url)` 후 해당 서브트리의 `nodeIndex` 항목이 전부 제거됨, 재확장 시 새 데이터로 채워짐
- [ ] 표시 중 폴더 자체가 rename된 경우 `NavigationModel`이 히스토리를 오염시키지 않고 새 경로로 전환
- [ ] `invalidate` 이후 `reveal` 호출이 스테일 인덱스로 실패하지 않음

### T2. 삭제 키 매핑 확정 + 휴지통 삭제 (B2, 구 T5)

**M1과의 충돌 확정 (B2 — 회귀 방지 최우선)**: `KeyScalar.backspace`(0x7F, Mac `delete`⌫ 키)는 M1이 이미 **상위 폴더 이동**에 할당했다(`FileListBridge.swift`). 계획을 다음으로 확정한다:
- 휴지통 이동 키 = **`Cmd+Backspace`** + **`fn+Delete`**(`KeyScalar.forwardDelete` — M1이 이미 소비 예약해 둔 키)
- 단독 `Backspace`는 **상위 폴더 이동으로 유지**(변경 금지)
- 두 키 모두 브릿지 `handleKeyDown`에서 처리해 M1의 B4 키보드 소유권 경계를 유지한다(현재 `.command` 분기는 방향키만 처리하고 나머지는 `super.keyDown`으로 흘려 비프음이 나므로, `Cmd+Backspace` 분기를 명시적으로 추가)
- `Cmd+C`/`Cmd+X`/`Cmd+V`를 `AppCommands`(앱 메뉴)에 등록할 경우, 메뉴 key equivalent가 responder chain보다 먼저 잡히므로 **주소창 편집 중·인라인 rename 중에는 해당 메뉴 아이템을 `.disabled`**로 내려 텍스트 필드의 기본 복사/붙여넣기가 정상 동작하게 한다

**삭제 동작**
- `FileManager.trashItem` (설계 결정 #3)
- 확인 다이얼로그 없음 (UI 설계 §7.3), 다중 선택 일괄 처리, 일부 실패 시 요약 알림
- 삭제 후 선택은 다음 항목으로 이동 (Win10 동작)
- 즐겨찾기 섹션·볼륨 루트·홈 루트는 트리에서 삭제 메뉴 비활성 (T0 위험 대상 가드)

**수용 기준**
- [ ] `Backspace` 단독 = 여전히 상위 폴더 이동(회귀 테스트로 고정)
- [ ] `Cmd+Backspace` / `fn+Delete` = 휴지통 이동, 둘 다 브릿지 Coordinator에서 처리
- [ ] 주소창 편집/인라인 rename 중 `Cmd+C/X/V` 메뉴가 비활성화되어 필드 기본 편집이 정상 동작
- [ ] 단위 테스트: trash 성공 시 휴지통 존재 확인·원위치 소멸, 권한 실패 매핑
- [ ] 수동: 다중 삭제 후 선택 이동, 외장 볼륨 파일 삭제(볼륨별 휴지통)

### T3. 클립보드 모델 (복사/잘라내기 상태, 구 T1)

- `ClipboardModel`: `copy(items)` / `cut(items)` / `pendingOperation` (copy|cut) 상태
- `NSPasteboard` 연동: 파일 URL을 `.fileURL` 타입으로 기록 → **Finder 등 외부 앱과 복사/붙여넣기 상호 운용**
- cut은 외부에 copy로 노출(파스트보드에 cut 의미론 없음), 내부 붙여넣기 시에만 이동으로 처리
- **외부 변경 감지 (B6)**: `NSPasteboard`에는 변경 알림이 없으므로 **`NSApplication.didBecomeActiveNotification` 시점에 `changeCount` 비교**로 감지한다(상시 폴링 타이머 금지). 내부 cut 소유권 판정도 동일하게 `changeCount` 기준

**수용 기준**
- [ ] 단위 테스트: copy→paste=복사, cut→paste=이동+cut 상태 해제, 앱 재활성화 시 `changeCount` 비교로 외부 변경 감지·cut 표시 해제
- [ ] 수동: Finder에서 Cmd+C한 파일을 UniFinder에 Cmd+V (역방향 포함)

### T4. 붙여넣기 + 충돌 다이얼로그 + cut 시각 표시 (구 T2, B5·B6)

- `Cmd+V`: 클립보드 항목을 현재 폴더로 copy/move 실행 (FileOperations 연결, 대상 URL은 T0 규칙대로 호출 시점 명시 인자)
- 같은 폴더에 copy 붙여넣기 → 충돌 다이얼로그 없이 자동 "둘 다 유지" (`name 2`), cut → 같은 폴더 붙여넣기는 **no-op**(Win10 동작)
- 충돌 시트: UI 설계 §7.1 스펙 그대로 (원본/대상 메타 표시, 모두 적용, 키 매핑)
- 잘라내기 원본이 이미 소실된 경우: 해당 항목 건너뛰기 + 종료 시 요약 알림
- cut 소비 후 클립보드 비우기, 붙여넣은 항목 선택

**조작 후 갱신 (B5 — 신규 API 필요)**
M1의 `DirectoryModel.load()`는 시작 시 `items=[]`·`selection=[]`로 비우고 호출 시점 선택만 복원한다. "붙여넣기 후 그 항목 선택"은 현재 API로 불가능하다.
- `DirectoryModel.reload(selecting: Set<URL>)` (또는 `pendingSelection` 필드) 추가 — `AppModel.selectAfterLoad`의 폴링 방식을 파괴적 작업 경로에 재사용하지 않는다
- **URL 표기 정합 규칙**: `DirectoryLoader.makeItem`이 만드는 폴더 URL은 후행 슬래시가 붙는다. 파스트보드/조작 결과 URL과 직접 비교하지 말고, `TreeModel.indexKey` 수준의 정규화 경로 키로 비교한다는 규칙을 모든 선택/클립보드/cut 비교에 적용

**cut 시각 표시 (B6 — 현재 브릿지 구조로는 갱신 안 됨, 반드시 추가)**
`FileListBridge.updateNSView`는 `revision` 변화 또는 `items.count` 변화 시에만 `reloadData()`한다. 클립보드 상태만 바뀌면 화면이 갱신되지 않는다.
- `FileListBridge`에 `cutURLs: Set<URL>` + `clipboardRevision: Int` 입력 추가, revision 변화 시 `reloadData` 트리거
- `FileNameCellView`의 알파 합성 규칙 확정: 숨김(0.4) × cut(0.5) 동시 적용 시 최종값 = UI설계 §4.2 기준으로 곱연산(0.2)

**수용 기준**
- [ ] 충돌 3분기 + "모두 적용" 동작, `Esc` 취소 시 처리분 유지·잔여 중단
- [ ] 같은 폴더 붙여넣기 자동 넘버링, cut의 같은 폴더 붙여넣기는 no-op
- [ ] `DirectoryModel.reload(selecting:)`로 작업 후 목록 갱신 + 붙여넣은/변경된 항목 선택 (수동 새로고침 없이, FSEvents는 M3)
- [ ] cut 표시가 클립보드 상태 변경 즉시 화면에 반영됨(revision 트리거 단위 테스트 또는 스냅샷)
- [ ] 숨김+cut 동시 적용 시 알파값이 합성 규칙대로 계산됨

### T5. 인라인 이름 변경 (구 T3, B7)

- `F2` / 컨텍스트 메뉴: NSTableView 셀 인라인 편집, 확장자 제외 부분 선택 (UI 설계 §7.2)
- **편집 가능 필드로 전환 (B7)**: `FileNameCellView`의 라벨은 현재 `NSTextField(labelWithString:)`라 편집 불가 — 편집 가능 필드로 교체하고, **셀 재사용 시 편집 상태를 반드시 리셋**한다(리셋 누락 시 스크롤 중 엉뚱한 행이 편집 상태로 재사용되어 잘못된 대상이 rename될 위험)
- **포커스 경계 (B7)**: 편집 중에는 field editor가 firstResponder가 되어 `FocusBroker.currentFocus == nil`이 되므로, M1의 `isAddressEditing`과 대칭되는 **`isRenaming` 상태**를 도입한다. 편집 중에는 refresh/reveal/포커스 강제 이동/앱 단축키를 억제
- 편집 진입 시 **타입-어헤드 버퍼 리셋**(`resetTypeAhead`)
- `Esc`=취소, 포커스 이탈=**커밋**(Finder 관례로 확정 — UI설계 §7.2 원문 미확정 사항 해소)
- 검증: 빈 이름·`/`·`:`·중복 → 셰이크+툴팁, 편집 유지. `.` 시작 시 확인 알림 1회
- 트리 노드에서도 이름 변경 가능 (동일 검증, T1의 `invalidate` 사용)
- 변경 후 위치 재계산은 `resortCurrentItems`(스냅샷 기반) 대신 **T4의 `reload(selecting:)` 경로**를 사용

**수용 기준**
- [ ] 셀 재사용 시 편집 상태가 확실히 리셋됨(스크롤 중 편집 시작 → 다른 행으로 스크롤 후 편집 커밋 시 원래 행에만 적용되는지 테스트)
- [ ] 편집 중 refresh/reveal/앱 단축키가 억제됨(`isRenaming` 가드)
- [ ] 금지 입력 4종 각각 거부·사유 표시, 편집 상태 유지
- [ ] 이름 변경 후 `reload(selecting:)`로 새 정렬 위치에서 선택 상태 유지
- [ ] 다중 선택 시 F2 무동작·메뉴 비활성
- [ ] `Esc`=취소, 포커스 이탈=커밋 동작 확인

### T6. 새 폴더 (구 T4)

- `Cmd+Shift+N` / 빈 영역 컨텍스트 메뉴: "새 폴더", 중복 시 "새 폴더 2" …
- 생성 직후 해당 항목 인라인 이름 변경 모드 자동 진입 (T5 재사용)
- 트리 노드 컨텍스트 메뉴에서 하위 새 폴더 생성 지원 (T1의 `invalidate` 사용)

**수용 기준**
- [ ] 연속 생성 시 넘버링, 생성 후 즉시 rename 진입, `Esc` 시 "새 폴더" 이름 유지
- [ ] 권한 없는 폴더에서 시도 → 에러 알림 (UI 설계 §8)
- [ ] 트리에서 생성 시 `TreeModel.invalidate` 경유로 트리 상태 일관

### T7. 컨텍스트 메뉴 통합 (구 T6, B9)

- 항목/빈 영역/트리 노드 3종 메뉴를 UI 설계 §6 스펙 그대로 구성
- 상태 반영: 클립보드 비면 붙여넣기 비활성, 다중 선택 시 이름 변경 비활성, 정렬 기준 체크 표시, 위험 대상(즐겨찾기·볼륨 루트·홈 루트)은 삭제/이름변경 비활성 (T0 가드)
- **"정보 보기" (B9 — 원안의 API가 존재하지 않음)**: `NSWorkspace`에는 Finder 정보창을 여는 공개 API가 없다. **`NSWorkspace.shared.activateFileViewerSelecting([url])`("Finder에서 보기")로 대체**하고 메뉴 문구도 이에 맞게 변경한다. AppleScript 경유 방식은 채택하지 않는다(M2 범위에서 제외 — 필요 시 Phase 2 재검토)

**수용 기준**
- [ ] 3종 메뉴 항목·단축키 표기·활성 조건이 UI 설계 §6과 일치(단, "정보 보기"는 "Finder에서 보기"로 문구 변경)
- [ ] 메뉴 액션과 단축키 액션이 동일 코드 경로 사용 (중복 구현 금지)
- [ ] `activateFileViewerSelecting`이 실제로 Finder에서 해당 항목을 선택해 보여줌
- [ ] 위험 대상에서 삭제/이름변경 메뉴 비활성 확인

### T8. 통합 검증 게이트 (M2 종료, 구 T7)

- 전체 빌드·단위 테스트 통과 + M1 회귀(탐색 기능 손상 없음 — 특히 `Backspace` 상위 이동 유지)
- 수동 체크리스트: §3

**수용 기준**
- [ ] `xcodebuild build` + `test` 전체 통과 (증적)
- [ ] M1 단위 테스트 63개 전부 회귀 없이 통과
- [ ] §3 체크리스트 전 항목 통과

## 3. 수동 검증 체크리스트

1. 복사→붙여넣기, 잘라내기→붙여넣기 (같은 폴더/다른 폴더/다른 볼륨 × 파일/폴더/다중 혼합)
2. 충돌 시트 3분기 + 모두 적용 + Esc 중단, 같은 폴더 자동 넘버링
3. Finder ↔ UniFinder 클립보드 상호 운용 (양방향)
4. F2 이름 변경: 금지 문자·중복·`.` 시작, 트리에서 변경 시 우측·breadcrumb 동기화, 스크롤 중 편집 시작 시나리오
5. 새 폴더 연속 생성 + 즉시 rename
6. 휴지통 삭제 후 Finder 휴지통에서 복원 → 새로고침 시 재표시
7. 읽기 전용 위치(권한 없는 폴더)에서 조작 시도 → 에러 문구, 앱 상태 정상 유지
8. 잘라내기 표시(50% 불투명) → 앱 재활성화 시 외부 클립보드 변경 감지되어 해제
9. **`Backspace` 단독으로 상위 폴더 이동이 여전히 동작하는지** (M2 회귀 확인 — B2)
10. 즐겨찾기/볼륨 루트/홈 루트에서 삭제·이름변경 메뉴가 비활성인지
11. 컨텍스트 메뉴 "Finder에서 보기" 클릭 시 실제 Finder가 해당 항목을 선택해 보여주는지

## 4. 구현 순서·의존

```
T0 ──▶ T1 ──▶ T3 ──▶ T4 ──▶ T7 ──▶ T8
              │
              └──▶ T5 ──▶ T6     (T5·T6·T2는 T0·T1 완료 후 T3·T4와 병행 가능)
T0 ──▶ T2 ─────────────────────▶ T8
```

- T1(TreeModel 무효화)은 T4(붙여넣기 갱신)·T5(이름변경)·T6(새 폴더)의 트리 경로 전부가 의존하므로 T0 직후 최우선
- T2(삭제 키 확정)는 T0 완료 후 독립적으로 바로 착수 가능(다른 태스크와 충돌 없음)
- 병행 가능: T3+T2 동시, T5+T6 동시 (파이프라인 투입 시 ralph 2개 분담 가능)

## 5. 리스크·주의

| 리스크 | 대응 |
|--------|------|
| 삭제 키가 M1의 상위 이동 키와 충돌해 탐색 기능 회귀 | T2에서 `Cmd+Backspace`+`fn+Delete`로 확정, `Backspace` 단독은 절대 재할당 금지. M1 회귀 테스트를 T8 게이트에 필수 포함 |
| 충돌 질의의 actor↔MainActor 왕복 교착 | `ConflictResolving` 프로토콜 주입(M1 `DirectoryListing` 패턴) — FileOperations가 UI를 직접 호출하지 않음. 취소 시 `withTaskCancellationHandler`로 continuation 강제 재개 |
| 조작 후 목록 갱신 타이밍 (FSEvents 부재) | `DirectoryModel.reload(selecting:)` 명시적 API로 통일. M3에서 FSEvents로 대체 시 이중 갱신 방지 플래그 |
| 트리 노드 조작 후 nodeIndex 스테일화 | T1의 `invalidate(url)`를 모든 트리 조작(T4·T5·T6)이 공통 경유 |
| cut 시각 표시가 브릿지에 반영 안 됨 | `cutURLs`/`clipboardRevision`을 FileListBridge 입력에 추가(T4) |
| 인라인 rename 중 셀 재사용으로 잘못된 대상 편집 | 셀 재사용 시 편집 상태 명시적 리셋(T5), `isRenaming` 가드로 포커스 강탈 방지 |
| 파괴적 테스트의 실 파일 오염 | 모든 테스트는 `FileManager.temporaryDirectory` 하위 전용 루트에서만(`TempDirectoryTestCase` 재사용), 셋업 가드 assert |
| 볼륨 간 이동 테스트 환경 | 테스트계획서 §2의 램디스크(`hdiutil attach -nomount ram://`)를 T0 수용 기준에서 직접 사용 |

## 6. 후속 과제 (M2 범위 밖, 기록만)

- T7 진행 표시: FileOperations의 `AsyncStream<OperationProgress>` 타입은 M2에서 정의하지만, 실제 소비(진행률 시트 UI)는 M3 T4가 담당. M2는 상태바 미니 텍스트 정도만 최소 연결
- "정보 보기" AppleScript 경유 방식(진짜 Finder 정보창)은 Phase 2 재검토 대상
