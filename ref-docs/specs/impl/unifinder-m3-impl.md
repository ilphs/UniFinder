---
id: unifinder-m3-impl
title: UniFinder M3 구현계획서 — 마감 (자동 갱신·D&D·QuickLook·온보딩)
type: impl
version: 0.2.0
status: draft
scope: M3(마감)의 태스크 분해·구현 순서·수용 기준·검증 방법
related: [unifinder-mvp-design, unifinder-ui-design, unifinder-m1-impl, unifinder-m2-impl]
updated: 2026-08-14
---

# UniFinder M3 구현계획서 — 마감

## 1. 입력과 목표

- **입력**: `unifinder-mvp-design` §3.4(변경 감지)·§6(엣지), `unifinder-ui-design` §5(상태바 진행)·§7.4(진행률)·§7.5(FDA 온보딩), **M1+M2 완료 상태의 실제 코드베이스**
- **M3 완료 기준** (설계서 §7): FSEvents 자동 갱신, 드래그앤드롭, QuickLook, 진행률 표시, FDA 온보딩 — **Finder 없이 일상 파일 탐색 대체 가능**
- **M3에서 하지 않는 것**: 검색·탭·미리보기 패널·태그 등 Phase 2 전체 (설계서 §1.2)

> **[architect 재검토 v0.2.0]** v0.1.0은 architect 검토에서 CONDITIONAL(B1~B24) 판정을 받았다. 실제 M1+M2 코드와 대조한 결과 (a) T0이 가정한 "diff 적용·스크롤 유지"용 API가 존재하지 않아 현 구조로는 매 갱신마다 화면 깜빡임+스크롤 점프가 발생하고, (b) T2 D&D가 M2의 안전 경유점(`runOperation`/`applyOperationResult`)을 우회할 수 있으며, (c) T4 진행률을 시트로 만들면 충돌 시트와 중첩해 조작이 멈추는 문제가 확인됐다. 아래는 이를 전부 반영한 개정판이다.
>
> **M2는 3라운드 리뷰를 겪었고 그 교훈은 "즉흥 설계 금지 — 파괴적 경로의 의미론을 계획서가 미리 확정한다"였다.** M3의 T2(D&D)는 같은 파괴적 경로를 재사용하므로 같은 수준의 사전 확정을 적용한다.

## 0. 선처리 — M2 백로그 (T0 착수 전 별도 완료) — B1~B4·B23

M2 리뷰에서 "M2 완료를 막지 않음"으로 백로그 처리된 항목 중, **M3에서 위험도가 올라가는 4건**을 T0보다 먼저 별도로 처리한다. 이 절은 기록용이며, 실제 수정은 M3 태스크 착수 전에 완료한다.

| # | 항목 | M3에서 위험도가 오르는 이유 |
|---|------|------------------------------|
| B1 | `FileOperations.swift` L133 `destinationInsideSource` 가드가 `PathKey` 문자열 비교만 사용 (L187의 강화판 `isSameOrDescendant`와 불일치) | **최우선.** 트리 노드가 심볼릭 링크를 보존하므로(`TreeNode.isSymlink`, `canonicalDirectoryURL`가 symlink를 접지 않음), "폴더 A를 A/sub 별칭 노드에 드롭" = **드래그 한 번으로 무한 재귀 복사/이동** |
| B2 | 같은 파일 L138 `isSameFolder` 판정도 문자열 비교만 | 별칭 경로 드롭 시 T2 수용 기준 "같은 폴더 드롭 = 무동작"이 무너지고 충돌 시트가 뜸 |
| B3 | `ConflictSheetPresenter.swift` L138 `default: return .keepBoth` | T4가 취소 UI를 도입하면 예상 밖 응답 경로가 늘어남. 실패 시 기본값이 "파일 생성"인 것은 안전 기본값이 아님 → `.cancel` |
| B4 | `cancelledIDs` 정리 경로 없음 (정상 종료 후 도착한 취소가 영구 잔류) | M3에서 취소가 상시 동작이 되면 조작 1건당 누적 |

**M3와 무관해 백로그 유지**: `renameChangingCaseOnly` 복구 실패 은닉, `runModal()` 모달 알림, cut 클립보드 소거 타이밍, `beginRename` 진입 실패 오보고.
단, 다음 둘은 **T0 수용 기준의 회귀 항목**으로 포함한다(B23):
- `AppModel` `runModal()` — 앱-모달 런루프 중 FSEvents 콜백이 메인 큐에서 실행되어 모달 뒤에서 목록이 갈아엎히는 경로
- `renameChangingCaseOnly`의 staging 파일(`.unifinder-rename-<UUID>`)이 FSEvents로 순간 노출될 수 있음

## 2. 태스크 분해

### T0. DirectoryWatcher (FSEvents 자동 갱신) — B5·B6·B7·B8

설계 §3.4 기준: 현재 표시 경로만 감시, 300ms debounce, 재열거 후 갱신(선택·스크롤 위치 유지). 트리 실시간 감시는 제외.

**B5. in-place 갱신 API 신설 (현 구조로는 수용 기준 달성 불가 — 반드시 선행)**
현재 `DirectoryModel.reload()`는 `load(url:preservingSelection:)`을 호출하고, `load`는 시작 시 `items = []`·`selection = []`·`revision &+= 1`을 수행한다. 그러면 `FileListBridge`가 `.directoryChanged`로 판정해 **`reloadData()` + `scrollRowToVisible(0)`** 를 실행하고 선택이 비어 있으면 `selectFirstRowIfNeeded()`까지 돈다. 즉 FSEvents 갱신마다 **빈 화면 깜빡임 + 스크롤 최상단 점프 + 강제 첫 행 선택**이 발생해 수용 기준과 정면 충돌한다.
- `DirectoryModel`에 **in-place 갱신 API** 신설: `items`를 비우지 않고 새 결과로 교체, `selection`은 존재하는 항목만 남김(삭제된 항목만 해제), `pendingSelectionKeys`를 **소비하지 않음**
- `FileListBridge.Coordinator.ReloadReason`에 새 케이스 추가(예: `.contentsUpdated`) — `reloadData()`만 수행하고 `scrollRowToVisible(0)`·`selectFirstRowIfNeeded()`는 하지 않는다. 기존 `.itemsChanged`로는 부족하다(항목 1개 추가 + 1개 삭제 시 `items.count`가 같아 아예 갱신되지 않음)

**B6. `pendingSelectionKeys` 경쟁 조건 해소 (택일해 확정)**
`load()`는 시작 시 `pendingSelectionKeys`를 읽고 즉시 비운다. 붙여넣기 → `reload(selecting: produced)`가 generation N을 시작한 직후, 그 붙여넣기가 유발한 FSEvent(300ms debounce)가 generation N+1을 띄우면 gen N 태스크는 폐기되고 **선택 대상은 이미 소비되어 사라진다**. "diff 멱등성으로 흡수"로는 해결되지 않는 상태 소실이다.
→ **확정: (a) FSEvents 갱신 경로는 `pendingSelectionKeys`를 소비하지 않는 별도 경로(B5의 in-place API)로 구현한다.** 보조로 조작 진행 중(`operationTask != nil`) FSEvent를 억제해도 좋으나, (a)가 1차 방어다.

**B7. FSEvents의 역할 범위 — `applyOperationResult`는 유지 (v0.1.0 문장 철회)**
v0.1.0의 "M2의 조작 후 명시적 reload를 FSEvents 갱신으로 대체"는 **철회한다.** `AppModel.applyOperationResult`는 트리 무효화 단일 경유점이자 "표시 중 폴더 소실 → 상위 이동" 판정 지점이고, FSEvents는 설계 §3.4에 따라 **표시 중 폴더만** 감시하므로 트리·원본 폴더(잘라내기 원본의 부모) 갱신을 대체할 수 없다.
→ **FSEvents는 외부 변경 전용 보조 경로이며, `applyOperationResult`의 갱신 호출은 그대로 유지한다.** 자기 조작으로 인한 이벤트는 in-place diff가 멱등이라 무해하게 흡수된다(중복 갱신 1회).

**B8. Watcher 소유자·수명·감시 기법 확정**
- 소유자: `AppModel`(네비게이션 시점을 아는 유일한 지점). `navigate` 완료 시 이전 경로 unwatch → 새 경로 watch
- **비재귀 감시**: FSEvents(`FSEventStreamCreate`)는 본질적으로 재귀 감시라 깊은 하위 트리의 대량 변경이 그대로 유입되어 "1만 파일 생성 무프리즈" 기준을 위협한다. → **직속 디렉터리 이벤트만 처리하도록 필터링**하거나 `DispatchSource.makeFileSystemObjectSource(fileDescriptor:)` 기반 비재귀 감시를 사용한다. 어느 쪽이든 **표시 중 폴더의 직속 자식 변경만** 갱신을 유발해야 한다
- 300ms debounce는 설계 §3.4대로. 표시 중 폴더 자체가 삭제/이동된 이벤트 → 가장 가까운 존재하는 상위로 자동 이동 + 상태바 안내(모달 없이, UI설계 §8)

**수용 기준**
- [ ] in-place 갱신 시 **스크롤 위치와 선택이 유지됨**(빈 화면 깜빡임 없음, 첫 행 강제 선택 없음) — 단위 테스트 + 수동
- [ ] 항목 1개 추가 + 1개 삭제로 `items.count`가 동일한 경우에도 갱신이 반영됨(`.contentsUpdated` 경로)
- [ ] 단위 테스트: debounce 병합(연속 이벤트 1회 갱신), 삭제된 선택 항목만 해제, 나머지 선택 유지
- [ ] **조작 직후 FSEvent가 결과 선택을 지우지 않음**(B6 회귀 — 붙여넣기 후 `reload(selecting:)`의 선택이 FSEvent 갱신에 살아남는지)
- [ ] `applyOperationResult` 경로가 그대로 동작(트리 무효화·폴더 소실 판정 회귀 없음, B7)
- [ ] 수동: 터미널에서 파일 생성/삭제/이름변경 → 1초 내 자동 반영, 스크롤·선택 유지
- [ ] 대량 변경(1만 파일 생성) 중 UI 프리즈 없음 — 비재귀/필터링이 실제로 동작하는지(B8)
- [ ] 표시 중 폴더 삭제 → 자동 상위 이동 (모달 없이)
- [ ] 회귀(B23): 모달 알림(`runModal`) 표시 중 FSEvent가 도착해도 목록이 모달 뒤에서 갈아엎히지 않음, `.unifinder-rename-<UUID>` staging 파일이 목록에 잔류하지 않음

### T1. 볼륨 자동 갱신

- `NSWorkspace.didMountNotification`/`didUnmountNotification` → 트리 볼륨 섹션 갱신 (설계 §6)
- 표시 중 경로가 언마운트된 볼륨 하위면 홈으로 이동 + 안내
- 옵저버 등록/해제는 `TreeModel`의 기존 `startObservingVolumes`/`stopObservingVolumes` 경로 재사용(M1 백로그의 `stopObservingVolumes` 미호출 건도 이때 정리)

**수용 기준**
- [ ] 외장 디스크(또는 DMG 마운트) 연결/해제 시 트리 즉시 갱신, 표시 중이던 볼륨 해제 시 홈 이동
- [ ] 옵저버가 해제 경로를 실제로 타는지 확인

### T2. 진행률 UI + 취소 — B17·B18·B19·B20 (구 T4, **T3 D&D보다 먼저**)

D&D는 이 위에서 검증되어야 하므로 순서를 앞당긴다(B24).

**B17. 새 소비 지점을 만들지 말 것**
`AsyncStream`은 단일 소비자다. `AppModel.withProgress`가 이미 `FileOperating`의 `AsyncStream<OperationProgress>`를 소비하고 있으므로, T2는 **새 consumer를 붙이는 게 아니라 `withProgress`를 확장**해 진행률 모델을 갱신하는 작업이다. 두 번째 `for await`는 동작하지 않는다.

**B18. 시트가 아니라 비모달 오버레이로 확정**
`ConflictSheetPresenter`·`report()`·`confirmHiddenNameIfNeeded()`가 전부 같은 윈도우에 시트를 단다. 진행률을 시트로 만들어 조작 전체 기간 동안 띄우면 **충돌 알림이 AppKit 시트 큐에 밀려 표시되지 않고 조작이 그 응답을 기다리며 멈춘다.** 계획서 자신의 수용 기준("모달이 탐색을 막지 않음")과도 모순된다.
→ **윈도우 콘텐츠 내부의 비모달 오버레이/패널**로 구현한다. 표시 임계는 "예상 1초 초과"(계산 불가)가 아니라 `DirectoryModel`의 200ms 지연 스피너 패턴을 재사용한 **지연 표시**(작업이 1초 이상 지속되면 나타남)로 정의한다.

**B19. 바이트/속도는 Phase 2로 이관 — 항목 수 기준만 표시**
`OperationProgress`에는 `kind/completed/total/current`만 있고 바이트 필드가 없다. 또한 `FileManager.copyItem`은 단일 대용량 파일 복사 중 콜백이 없어 "수 GB 복사 시 진행 갱신"이 현 구조로 불가능하다(청크 단위 복사 + 사전 크기 스캔 도입은 비용이 크다).
→ **MVP는 항목 수 기준(`128/512 항목`)만 표시**하고 바이트·속도(`34 MB/s`)는 Phase 2로 이관한다. `unifinder-ui-design` §7.4와 `unifinder-mvp-test` §4.3의 해당 문구도 이에 맞춰 수정한다.

**B20. 취소 API 신설**
`AppModel`에 `operationTask`를 취소하는 공개 경로가 없다. `cancelCurrentOperation()`을 추가하고, 충돌 시트 대기 중 취소가 continuation을 재개하는지(`withTaskCancellationHandler` 경로) 회귀 테스트로 고정한다.
- 취소 의미론(UI설계 §7.4): 진행 중 항목 완료 후 중단, 완료분 유지 + 안내(롤백 없음)

**수용 기준**
- [ ] 대량 복사 시 오버레이 표시·항목 수 진행 갱신·취소 동작
- [ ] 소용량 작업에 오버레이 미표시 (1초 지연 표시, 깜빡임 금지)
- [ ] **진행률 표시 중 충돌 시트가 정상적으로 뜨고 응답 가능**(B18 — 시트 중첩으로 조작이 멈추지 않음)
- [ ] 작업 중 탐색 계속 가능(비모달 — 오버레이가 목록·트리 조작을 막지 않음)
- [ ] `cancelCurrentOperation()`으로 취소 시 완료분 유지, 충돌 시트 대기 중 취소해도 행(hang) 없이 종료(B20 회귀 테스트)
- [ ] 스트림 집계는 항목 수 기준으로 정확(B19 — 바이트는 범위 밖)

### T3. 드래그앤드롭 — B9·B10·B11·B12·B13 (구 T2, **최대 위험**)

- **내부**: 목록→목록(폴더 행 위), 목록→트리 노드, 트리→트리
- **외부 상호 운용**: 파일 URL 기반 — Finder→UniFinder 드롭, UniFinder→Finder·타 앱 드래그
- 드롭 대상 강조: 폴더 행/트리 노드 하이라이트, 거부 시 커서 금지 표시

**B9. 드롭 실행 진입점을 `AppModel` 공개 API로 못 박음 (안전 경유점 우회 금지)**
현재 `operations.move/copy`를 호출하는 유일한 경로는 `AppModel.paste(into:)`이고, 그것이 `runOperation`(직렬화) → `applyOperationResult`(트리 무효화 + 폴더 소실 판정 + 결과 선택)를 경유한다. "실행은 FileOperations 재사용"이라고만 두면 브릿지 Coordinator에서 `FileOperations.shared.move(...)`를 직접 호출하는 구현이 나올 수 있고, 그러면 **M2가 3라운드에 걸쳐 세운 가드는 통과하지만 직렬화와 단일 경유점을 통째로 우회한다.**
→ 시그니처 확정: **`AppModel.drop(_ urls: [URL], into destination: URL, operation: FileOperationKind)`**. 내부는 `paste(into:)`와 동일하게 `runOperation` + `applyOperationResult(affectedDirectories: [destination] + sourceParents)`를 경유한다. 브릿지는 이 API만 호출한다.

**B10. UI 레벨 거부는 보조, 서비스 레벨 가드가 권위 + 자동 테스트 필수**
"자기 자신·자기 하위로의 이동 거부"를 D&D UI(드롭 검증)에서만 막고 서비스 레벨을 우회해서는 안 된다. UI 거부는 사용자 피드백(커서 배지)용 보조 수단이고, 최종 권위는 `FileOperations`의 가드다.
→ 다음을 **단위 테스트로** 고정한다(수동 검증만으로는 불충분):
- 자기 자신/자기 하위 드롭 거부
- **별칭(symlink) 경로 경유 하위 드롭 거부** (선처리 B1의 회귀)
- 보호 대상(홈/볼륨 루트) 드래그 이동 거부
- 같은 폴더 드롭 무동작 (선처리 B2의 회귀)
→ 기존 `FileOperationsSafetyTests`/`M2ProtectedTargetTests`에 **드롭 진입점(B9의 API) 케이스를 추가**하는 형태로 작성한다.

**B11. 러버밴드 충돌 — v0.1.0의 "훅 예약" 서술은 사실이 아님**
`FileListBridge`에는 `mouseDown` 오버라이드도, 히트 테스트 훅도, 러버밴드 구현도 없다(M1은 `NSTableView` 기본 드래그 선택에 의존). 실제 메커니즘으로 대체한다:
- `tableView(_:pasteboardWriterForRow:)`는 **행에서 시작한 드래그에만** 호출되므로 빈 영역 드래그는 자동으로 기본 선택 동작에 남는다
- `tableView(_:canDragRowsWith:at:)`로 명시 제어할지 여부는 구현 시 결정하되, 결정 근거를 코드 주석에 남긴다

**B12. 조작 진행 중 드롭 규칙**
`runOperation`은 진행 중이면 상태바 문구만 띄우고 무시한다. 이 상태에서 `acceptDrop`이 `true`를 반환하면 사용자에겐 "드롭 성공 후 아무 일 없음"으로 보인다.
→ **`validateDrop`에서 `[]`(거부)를 반환**해 드롭 자체를 받지 않는다.

**B13. 이동/복사 기본값 판정 + 위험도 인정**
- 기본: 같은 볼륨=이동, 다른 볼륨=복사 (Win10·Finder 공통 관례). **판정은 경로 접두사가 아니라 `URLResourceValues.volumeIdentifier` 비교**로 한다(firmlink·마운트 포인트 때문)
- 수식키: `Option`=복사 강제, `Cmd`=이동 강제, 드래그 중 커서 배지로 동작 표시. 수식키 판정은 M2에서 확립한 `KeyScalar.userModifiers(of:)`(합성 플래그 제거)를 재사용
- **위험도 인정**: Finder→UniFinder 드롭이 기본 이동이고 undo는 Phase 2(설계 결정 #3)이므로, 오조작 시 되돌릴 수단이 휴지통 복원뿐이다. M3 범위에서 undo를 추가하지는 않되 이 사실을 릴리스 노트/온보딩에 반영할지 T5에서 검토한다

**수용 기준**
- [ ] **단위 테스트(B10)**: 자기 하위 드롭 거부, 별칭 경로 경유 하위 드롭 거부, 보호 대상 드래그 이동 거부, 같은 폴더 드롭 무동작
- [ ] 드롭 실행이 `AppModel.drop(...)` → `runOperation` → `applyOperationResult`를 경유함을 코드로 확인(B9 — 브릿지가 `FileOperations`를 직접 호출하지 않음)
- [ ] 내부 4경로(목록→목록/목록→트리/트리→트리/같은폴더=무동작) + 수식키 2종
- [ ] 조작 진행 중에는 드롭이 거부됨(B12)
- [ ] 볼륨 판정이 `volumeIdentifier` 기준(B13) — 별칭 경로에서도 올바른 기본값
- [ ] Finder 양방향 D&D, 드롭 후 양쪽 갱신(FSEvents)
- [ ] 다중 항목 드래그 시 개수 배지
- [ ] 빈 영역 드래그가 여전히 기본 선택으로 동작(B11 회귀)

### T4. QuickLook — B14·B15·B16 (구 T3)

**B14. Space 키 분기 구조를 바꾸지 말 것**
`FileListBridge`의 keyDown은 타입-어헤드 진행 중이 아닐 때 Space를 **이미 소비하고 무동작**으로 두고 있다(주석에 "M3 QuickLook 예약"). 우선순위 규칙(진행 중이면 검색 문자열, 아니면 QL)은 코드가 이미 정확히 구현하므로, T4는 **그 자리에 `onQuickLook` 콜백을 꽂는 작업**이다. 분기 구조 재작성 금지.

**B15. 패널 제어 지점을 실제 구조에 맞게 확정**
이 앱은 SwiftUI `WindowGroup`이라 `NSWindowController`가 없고, `Coordinator`는 `NSObject`라 responder chain에 없다. `QLPreviewPanel`은 responder chain의 `acceptsPreviewPanelControl(_:)`/`beginPreviewPanelControl(_:)`/`endPreviewPanelControl(_:)`을 요구한다.
→ **`KeyRoutingTableView`(실제 first responder)가 이 3개를 구현하고 datasource/delegate를 Coordinator로 위임**하는 구조로 확정. 방향키 동기는 `QLPreviewPanelDelegate.previewPanel(_:handle:)`로 테이블에 이벤트를 되돌리는 방식.

**B16. 편집 상태와의 상호작용**
인라인 편집 중에는 field editor가 first responder라 Space가 브릿지에 도달하지 않으므로 진입은 안전하다. 그러나 **QL 패널이 열린 상태에서 rename/주소창 편집이 시작되면 패널이 key window를 유지해 키 입력을 가로챈다.**
→ `isTextEditing`(또는 `isRenaming`)이 true가 되면 **패널을 닫는다.**

**수용 기준**
- [ ] Space 토글, 다중 선택 순회, 방향키 동기, 폴더 선택 시 폴더 미리보기
- [ ] 타입-어헤드 진행 중 Space는 검색 문자열에 포함(B14 회귀 — 기존 1초 규칙 유지)
- [ ] 패널 열린 상태에서 Enter(열기) 등 기존 단축키 정상 동작
- [ ] 패널 열린 상태에서 rename/주소창 편집 시작 → 패널 자동 닫힘(B16)

### T5. FDA 온보딩 — B21·B22

- UI 설계 §7.5 흐름: 첫 실행/미허용 감지 → 웰컴 시트 → 설정 딥링크 → 활성화 시 재감지 → 자동 닫힘
- [나중에] 시 제한 모드로 계속, 접근 불가 폴더 empty-state의 [권한 설정 안내] 버튼(M1에 문구만 있던 것)을 온보딩 시트로 연결

**B21. 코드 서명 전제조건**
`project.yml`은 현재 `CODE_SIGN_IDENTITY: "-"`(ad-hoc), `ENABLE_HARDENED_RUNTIME: NO`이고, 파일 주석이 "지금 켜면 FDA 승인이 빌드마다 초기화된다"고 적고 있다. TCC FDA 권한은 코드 서명에 묶이므로 ad-hoc 상태에서는 **수용 기준("허용 → 복귀 시 자동 감지")이 매 빌드마다 리셋**된다.
→ M3는 릴리스 마일스톤이므로 다음 중 하나를 확정한다: (a) T5에 "Developer ID 서명 + hardened runtime 전환"을 선행 작업으로 포함, 또는 (b) 개발 빌드에서는 매 빌드 재승인이 필요함을 검증 절차에 명시하고 서명 전환은 릴리스 직전 별도 작업으로 분리. **권장은 (b)** — 서명 전환이 개발 반복을 느리게 하므로.

**B22. 권한 감지 프로브 규칙 구체화**
`~/Library/Mail`은 Mail 미사용 사용자에게 **존재하지 않아** `NSFileReadNoSuchFileError`가 난다. "없음"과 "거부"를 구분하지 않으면 오탐이다.
→ 프로브 경로 후보를 복수로 두고(`~/Library/Mail`, `~/Library/Safari` 등), **"존재하지 않음 ≠ 미허용"** 규칙을 적용한다: 프로브가 `NSFileReadNoSuchFileError`면 판정 불가로 처리하고 다음 후보를 시도, 전부 판정 불가면 **미허용으로 단정하지 않고** 온화한 배너만 표시(설계 §8 리스크 표와 일관).
→ 재감지 시점은 `ClipboardModel`이 이미 쓰는 `NSApplication.didBecomeActiveNotification` 패턴을 재사용한다. 설정 딥링크 pane id는 macOS 14+ 기준으로 확인한다.

**수용 기준**
- [ ] FDA 미허용 상태에서 안내 표시 → 설정에서 허용 → 앱 복귀 시 자동 감지·시트 닫힘
- [ ] [나중에] 후 정상 탐색, 보호 폴더 진입 시 안내 재노출
- [ ] 프로브 경로가 존재하지 않는 경우 "미허용"으로 오판하지 않음(B22 — 단위 테스트로 판정 로직 고정)
- [ ] 개발 빌드에서 매 빌드 재승인이 필요하다는 점이 검증 절차에 명시됨(B21)

### T6. 통합 검증 게이트 (M3 종료 = MVP 완료)

- 전체 빌드·단위 테스트 + M1·M2 회귀
- MVP 전체 수동 회귀는 테스트계획서(`unifinder-mvp-test`)의 릴리스 게이트 체크리스트로 수행

**수용 기준**
- [ ] `xcodebuild build` + `test` 전체 통과 (증적)
- [ ] M1+M2 기존 테스트 전부 회귀 없이 통과
- [ ] **M2 파괴적 안전성 테스트(`FileOperationsSafetyTests`, `M2ProtectedTargetTests`)의 드롭 진입점 확장판 통과**(T3 B10)
- [ ] 테스트계획서 릴리스 게이트 전 항목 통과
- [ ] 성능 목표(설계 §5) 재측정 통과 — FSEvents·아이콘 로드 추가 후 회귀 확인

## 3. 구현 순서·의존 — B24

v0.1.0의 "ralph A(T0→T1) / B(T2→T4) / C(T3, T5) 3분담"은 **성립하지 않는다.** T0(ReloadReason 추가), T3(드래그 delegate), T4(keyDown + 테이블뷰 서브클래스)이 **모두 `FileListBridge.swift`와 `AppModel.swift`를 동시 수정**하기 때문이다. 또한 v0.1.0의 `T2 ──▶ T4`(D&D→진행률) 의존은 잘못이다 — 진행률은 M2 `withProgress`에만 의존하므로 D&D와 무관하며, 오히려 **먼저** 하는 것이 안전하다(D&D가 진행률·취소 UI 위에서 검증되므로).

```
[선처리 B1~B4]  ──▶  T0 ──▶ T1
                      │
                      └──▶ T2(진행률·취소) ──▶ T3(D&D) ──▶ T4(QuickLook) ──▶ T6
T5(FDA) — 완전 독립, 언제든 병행 가능
```

- **파일 기준 파티션**: T5만 독립적으로 병행 가능(다른 파일). T0/T2/T3/T4는 `FileListBridge.swift`·`AppModel.swift`를 공유하므로 **순차 진행**
- T1은 T0 완료 후 독립적으로 착수 가능

## 4. 리스크·주의

| 리스크 | 대응 |
|--------|------|
| **D&D가 M2 안전 경유점을 우회** | `AppModel.drop(...)` 단일 진입점 확정(B9), 서비스 레벨 가드가 권위(B10), 자동 테스트 필수 |
| **별칭 경로로 자기 하위 드롭 → 재귀 복사** | 선처리 B1(`isSameOrDescendant` 이중검사 통일)로 차단 후 착수. 회귀 테스트 필수 |
| FSEvents 갱신이 스크롤·선택을 날림 | in-place 갱신 API + `.contentsUpdated` ReloadReason 신설(B5). 기존 `load()` 경로 재사용 금지 |
| 조작 결과 선택이 FSEvent에 지워짐 | FSEvents 경로는 `pendingSelectionKeys`를 소비하지 않음(B6) |
| FSEvents가 `applyOperationResult`를 대체한다는 오해 | FSEvents는 외부 변경 전용 보조 경로임을 명시(B7) — 트리 갱신·폴더 소실 판정은 기존 경로 유지 |
| 대량 변경 시 UI 프리즈 | 비재귀 감시 또는 직속 자식 필터링(B8) + 300ms debounce |
| 진행률 시트와 충돌 시트 중첩으로 조작 정지 | 진행률은 비모달 오버레이로 구현(B18) |
| 진행률 바이트/속도 표시가 현 구조로 불가능 | 항목 수 기준만 표시, 바이트·속도는 Phase 2 이관(B19) + UI설계·테스트계획 문구 수정 |
| QLPreviewPanel 포커스 스틸 | `KeyRoutingTableView`가 패널 제어를 소유(B15), 편집 시작 시 패널 자동 닫힘(B16) |
| FDA 감지 오탐(경로 부재 vs 거부) | 복수 프로브 + "존재하지 않음 ≠ 미허용" 규칙(B22), 판정 불가 시 온화한 배너 |
| ad-hoc 서명으로 FDA 승인이 매 빌드 리셋 | 검증 절차에 명시(B21) — 서명 전환은 릴리스 직전 별도 작업 |
| 오조작 D&D의 되돌림 수단 부재 | undo는 Phase 2. 휴지통 복원이 유일한 복구 수단임을 인지(B13) |

## 5. 후속 과제 (M3 범위 밖, 기록)

- 진행률의 **바이트·속도 표시**(청크 단위 복사 + 사전 크기 스캔 필요) — Phase 2
- **undo** — Phase 2 (설계 결정 #3)
- M2 백로그 잔여 4건: `renameChangingCaseOnly` 복구 실패 보고, `runModal()` → 시트 전환, cut 클립보드 소거 타이밍, `beginRename` 진입 실패 오보고
- ~~Developer ID 서명 + hardened runtime 전환 (릴리스 직전 필수, B21)~~ → **§6으로 정식화**(빌드 구성 분리 완료, 남은 것은 인증서·공증 자격 증명 준비와 실제 수행)

## 6. 릴리스 절차 — 서명 → 공증 → stapler (B21 마무리)

**빌드 구성은 이미 분리돼 있다.** `project.yml`의 `settings.configs`에서 Debug는 ad-hoc(개발 중 FDA 승인 유지 목적, B21 방침 (b)), Release는 Developer ID + hardened runtime + secure timestamp다. 되돌아가지 않도록 `ReleaseSigningConfigurationTests`가 자동으로 감시한다.

| 구성 | CODE_SIGN_IDENTITY | ENABLE_HARDENED_RUNTIME | OTHER_CODE_SIGN_FLAGS |
|------|--------------------|--------------------------|------------------------|
| Debug | `-` (ad-hoc) | NO | — |
| Release | `Developer ID Application` | YES | `--timestamp` |

> **Developer ID 서명만으로는 Gatekeeper를 통과하지 못한다.** 공증(notarization)과 stapler까지 끝나야 다른 macOS에서 경고 없이 열린다. 실제 릴리스에서 가장 흔히 빠뜨리는 단계라 아래에 절차를 고정한다.

### 6.1 사전 준비 (머신당 1회)

- Apple Developer Program 멤버십 + **Developer ID Application** 인증서를 로그인 키체인에 설치
  - 확인: `security find-identity -v -p codesigning` — 결과가 0개면 Release 빌드는 반드시 실패한다
- `project.yml`의 `DEVELOPMENT_TEAM`을 실제 팀 ID로 채운다(현재 빈 값 — 인증서가 여러 개일 때 신원이 모호해진다)
- 공증 자격 증명 저장(앱 전용 암호 방식):
  ```
  xcrun notarytool store-credentials "UniFinderNotary" \
      --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <app-specific password>
  ```
  App Store Connect API 키를 쓰면 `--key/--key-id/--issuer`로 대체한다.

### 6.2 빌드·서명

```
xcodegen generate
xcodebuild -scheme UniFinder -configuration Release -derivedDataPath build/release build
APP=build/release/Build/Products/Release/UniFinder.app
```

서명은 빌드 단계에서 위 표의 설정으로 수행된다. 검증:

```
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv --entitlements :- "$APP"      # flags에 runtime, 그리고 app-sandbox=false 확인
```

App Sandbox는 설계 결정 #2로 **비활성**이다 → Mac App Store 배포 경로는 애초에 없고 Developer ID 직접 배포 전용이다.

### 6.3 공증 (notarytool)

```
ditto -c -k --keepParent "$APP" UniFinder.zip
xcrun notarytool submit UniFinder.zip --keychain-profile "UniFinderNotary" --wait
```

거절되면 사유를 반드시 로그로 확인한다:

```
xcrun notarytool log <submission-id> --keychain-profile "UniFinderNotary"
```

자주 걸리는 사유: hardened runtime 미적용, secure timestamp 누락, 중첩 바이너리 미서명, 배포 금지 entitlement.

### 6.4 stapler + 최종 게이트

```
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"     # → accepted, source=Notarized Developer ID
```

배포물(zip/dmg)은 **stapler 이후에 다시 묶는다.** 공증 전에 만든 압축본을 배포하면 티켓이 빠진다.

### 6.5 전환 직후 1회 재검증

- 테스트계획 §4.3의 FDA 수동 시나리오를 **서명 전환본에서 1회 재수행**(B21 방침 (b)의 마지막 단계)
- 서명 신원이 안정되면 TCC 승인이 더 이상 빌드마다 리셋되지 않는다 — "허용했는데 미허용으로 감지"가 사라지는지 확인

### 6.6 인증서가 없는 개발 머신에서의 Release 빌드 (실측)

구성 분리 직후 이 저장소에서 실제로 확인한 결과다. **둘 다 정상이며, 설정을 ad-hoc으로 되돌리는 것은 오답이다** (되돌리면 `ReleaseSigningConfigurationTests`가 실패한다).

1. `DEVELOPMENT_TEAM`이 빈 값일 때:
   ```
   error: Signing for "UniFinder" requires selecting either a development team or a provisioning profile.
   ```
2. 팀 ID를 넣었지만 인증서가 없을 때(`xcodebuild ... DEVELOPMENT_TEAM=<TEAMID>`):
   ```
   error: No signing certificate "Developer ID Application" found:
          No "Developer ID Application" signing certificate matching team ID "<TEAMID>" with a private key was found.
   ```

즉 Release 빌드에 남은 것은 **인증서·팀 ID 준비뿐**이고 빌드 구성 자체는 완료돼 있다. 팀 ID는 `project.yml`의 `DEVELOPMENT_TEAM`에 넣거나 빌드 명령에 `DEVELOPMENT_TEAM=<TEAMID>`로 넘긴다. 개발은 Debug 구성으로 계속한다(`xcodebuild -scheme UniFinder build`의 기본값).
