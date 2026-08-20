---
id: unifinder-eject-diskspace-impl
title: UniFinder 구현계획서 — 볼륨 Eject · 상태바 여유 공간
type: impl
version: 1.0.0
status: implemented
scope: 마운트된 디스크 이미지·외장 볼륨 꺼내기(우클릭)와 상태바 우측 여유 공간 표시
related: [unifinder-mvp-design, unifinder-ui-design, unifinder-m3-impl, unifinder-followup-impl]
updated: 2026-08-20
---

# UniFinder 구현계획서 — 볼륨 Eject · 상태바 여유 공간

## 1. 입력과 목표

- **입력**: MVP·다중 창·후속 4종까지 완료된 코드베이스(747 unit + 1 UI 통과 상태), 2026-08-20 요청 3건 중 2건
- **목표**
  1. **E1** — 마운트된 dmg/외장 볼륨을 **우클릭으로 꺼낸다**(사이드바 트리 + 우측 목록)
  2. **E2** — **현재 폴더가 속한 볼륨의 여유 공간**을 상태바 우측 끝에 표시한다
- **하지 않는 것**: 탭(같은 요청의 3번 항목 — 아키텍처 결정 대기), 툴바 Eject 버튼,
  네트워크 볼륨 마운트 해제, "안전하게 제거" 확인 대화상자(OS가 처리한다), Eject 단축키

### 1.1 이 작업이 기존 결정과 만나는 지점

| 기존 결정 | 이번 작업에서 | 근거 |
|-----------|---------------|------|
| m3-impl T1 — 언마운트 통지 → 트리 갱신 + 홈 이동 | **그대로 재사용**한다. Eject 성공 경로에 후처리를 새로 쓰지 않는다 | 두 경로가 각자 처리하면 어긋나는 순간 이동이 두 번 일어난다 |
| followup T1 — `VolumeService`가 볼륨 열거의 단일 권위 | **범위를 넓힌다**: 열거 + Eject 적격 판정 + 용량 조회 + 볼륨 특정 | 상태바가 용량을 필요로 하면서 `DiskUsageModel`의 조회 규칙이 복제될 상황이 됐다 |
| followup D9 — 용량 창은 열 때 1회 + 수동 Refresh | 상태바는 **명시적 예외**를 둔다(§2 D-E4) | 상시 표시라 같은 규칙이면 값이 영구히 낡는다 |
| m2-impl T0 — 위험 대상 가드(볼륨 루트는 rename/삭제 금지) | Eject는 **별도 술어**를 쓴다 | 가드는 "건드리지 말 것"이고 Eject는 "정상 동작"이다. 볼륨 루트라는 사실만으로는 두 판정이 갈린다 |

## 2. 설계 판정 (D-E1 ~ D-E6)

| # | 쟁점 | 판정 |
|---|------|------|
| D-E1 | 적격 판정 키 | `volumeIsEjectable`이 정본, 없으면 `volumeIsRemovable` 폴백, **둘 다 없으면 `false`**(보수적 — 잘못 표시된 Eject는 파괴적 방향으로 작동한다). 부팅 볼륨 제외는 `volumeIsRootFileSystem`이 정본이고 키가 없으면 경로 `/` 폴백 |
| D-E2 | 판정 시점 | **볼륨 열거 시점**(`TreeModel.rebuildSections()`)에 캐시한다. 우클릭 시점 조회 금지 — 응답 없는 마운트가 하나 끼면 컨텍스트 메뉴가 멈춘다 |
| D-E3 | 언마운트 API | `FileManager.unmountVolume(at:options:)` + **`.allPartitionsAndEjectDisk`**. `NSWorkspace.unmountAndEjectDevice(at:)`는 동기라 메인 블로킹. `.withoutUI`는 주지 않는다(사용 중 안내는 OS가 한다) |
| D-E4 | 상태바 갱신 정책 | 볼륨 변경 → 즉시 / 같은 볼륨 이동 → 10초 스로틀 / ⌘R·조작 완료 → 무조건 / **타이머 폴링 없음**. D9의 명시적 예외이며 근거는 UI설계 §5.1 |
| D-E5 | 표시 실패 처리 | 상태바는 **숨김**(용량 창은 `--`). 한 줄에서 `--`는 정보를 주지 않는다. 조회 실패도 `updatedAt`을 남겨 실패한 볼륨을 매 이동마다 두드리지 않는다 |
| D-E6 | 메뉴 항목 표시 정책 | 대상이 아니면 **항목 자체를 넣지 않는다**(비활성 아님). 다중 선택에도 넣지 않는다 — `Rename`·`Get Info`와 같은 단일 선택 규칙 |

## 3. 태스크

| # | 내용 | 산출물 |
|---|------|--------|
| E1-a | `VolumeService` 확장 — eject 키 3종 추가, `isEjectable(url:attributes:)`, `defaultUnmounter` | `src/Services/VolumeService.swift` |
| E1-b | `TreeModel` — `ejectableVolumeKeys` 캐시 + `isEjectableVolume(_:)` | `src/ViewModels/TreeModel.swift` |
| E1-c | `AppModel` — `canEject` / `eject` / `isEjectInFlight`(연타 가드) / `ejectFailureMessage`, `volumeUnmounter` 주입점, `volumeService` init 인자 | `src/App/AppModel.swift` |
| E1-d | 컨텍스트 메뉴 2곳 — 조건부 `Eject` 항목 + 대상 스냅샷 | `src/Bridges/{SidebarTreeBridge,FileListBridge}.swift`, `src/Views/FileListPane.swift` |
| E2-a | `VolumeService` — `Capacity` / `CapacityReader` / `defaultCapacityReader`(`DiskUsageModel`에서 승격) / `VolumeLocator` | `src/Services/VolumeService.swift`, `src/ViewModels/DiskUsageModel.swift` |
| E2-b | `VolumeCapacityModel` 신규 — 창별, 스로틀 정책, 백그라운드 조회 | `src/ViewModels/VolumeCapacityModel.swift` |
| E2-c | `AppModel` 배선 — `loadCurrent`(.navigation) / `refresh`(.explicit) / `runOperation` 완료(.explicit) | `src/App/AppModel.swift` |
| E2-d | 상태바 — 우측 끝 고정 표시 | `src/Views/StatusBarView.swift` |

## 4. 수용된 트레이드오프

1. **`.allPartitionsAndEjectDisk`는 해당 디스크의 다른 파티션까지 내린다.** 파티션이 여러 개인
   외장 디스크에서 한 파티션을 꺼내면 전부 내려간다 — Finder의 Eject와 같은 동작이라 그대로 둔다.
   빈 옵션(`[]`)은 볼륨만 내리고 **디스크 이미지를 붙잡아 둬서**(2026-08-20 실측) dmg 파일을
   지우거나 옮길 수 없는 상태가 조용히 남는다. 그쪽이 더 나쁘다.
2. **Eject 항목의 활성 상태는 진행 중에도 그대로다.** 메뉴 활성은 뷰 갱신 시점 스냅샷이라
   in-flight를 반영할 수 없다. 그래서 방어선을 `AppModel.pendingEjectKeys`(연타 가드)에 둔다 —
   요청이 끝나면 풀려서 재시도가 가능하다.
3. **상태바 값은 최대 10초 낡을 수 있다**(같은 볼륨 안을 돌아다니는 동안). 폴더를 훑는 내내
   볼륨을 stat하는 비용을 피한 대가이고, 사용자가 변화를 기대하는 시점(⌘R·조작 완료)은
   스로틀을 통과하므로 "복사했는데 안 줄어든다"는 발생하지 않는다.
4. **다중 선택 Eject는 없다.** 실패가 섞였을 때 무엇이 남았는지 한 줄 상태바로 알릴 방법이 없다.
5. **볼륨 목록이 갱신되기 전에는 Eject 항목이 나타나지 않는다.** 판정이 `rebuildSections()`
   시점 캐시라, 마운트 직후 통지가 도착하기 전 찰나에는 항목이 없다. 통지는 즉시 오므로
   실사용에서 관측되지 않고, 반대 설계(우클릭 시점 조회)의 대가는 메뉴 정지다.

## 5. 검증

### 5.1 자동 (신규 37 테스트 — 총 784 unit + 1 UI 통과)

| 파일 | 대상 |
|------|------|
| `tests/UnitTests/ServicesTests/VolumeEjectEligibilityTests.swift` | D-E1 규칙 전부(부팅 볼륨 제외·폴백·키 없음), 볼륨당 속성 조회 1회 |
| `tests/UnitTests/AppTests/VolumeEjectTests.swift` | `canEject` 대상 한정, 실행/실패 문구, 비대상 무동작, 연타 병합 + 가드 해제 |
| `tests/UnitTests/BridgesTests/VolumeEjectMenuTests.swift` | 두 메뉴의 항목 유무·순서·라우팅, 다중 선택·빈 영역·일반 폴더 제외 |
| `tests/UnitTests/ViewModelsTests/VolumeCapacityModelTests.swift` | 표시 문구, 스로틀 정책 4경우, 볼륨 변경/미특정/조회 실패 흐름 |
| `tests/UnitTests/AppTests/StatusBarCapacityTests.swift` | 갱신 시점 배선(이동 = 스로틀, ⌘R = 통과) |

### 5.2 수동 게이트 (2026-08-20 실측 완료)

실제 디스크 이미지(`hdiutil create` 12 MB APFS)로 확인했다:

| 확인 | 결과 |
|------|------|
| 마운트된 dmg의 볼륨 속성 | `ejectable=true removable=true rootFS=false` → Eject 대상 판정 성립 |
| 부팅 볼륨(`/`) 속성 | `ejectable=false rootFS=true` → 제외. 앱에서도 SSD 우클릭에 항목 없음 |
| 사이드바 우클릭 | `Open / Open in New Window / Eject / …` 순서로 표시 |
| Eject 실행 | 볼륨이 트리에서 사라지고 홈으로 이동, `hdiutil info`에서 **이미지까지 완전 detach** |
| 상태바 표시 | 홈(`/`)에서 `196 GB free`, dmg 볼륨 진입 시 `12.1 MB free`로 전환 |

**남은 수동 항목**: 사용 중인 볼륨(파일을 열어 둔 상태)의 Eject 실패 경로 —
OS 대화상자 표시와 상태바 실패 문구 노출을 눈으로 확인해야 한다.
