---
id: unifinder-ui-design
title: UniFinder UI 상세 설계 — 화면·다이얼로그·인터랙션 세부 스펙
type: design
version: 0.1.0
status: draft
scope: MVP 전체(M1~M3)의 화면 세부 치수·포맷·다이얼로그·에러 표시·인터랙션 규칙
related: [unifinder-mvp-design]
updated: 2026-08-13
---

# UniFinder UI 상세 설계

> `unifinder-mvp-design` §2 화면 구성의 세부 스펙. 구현계획서(M1~M3)가 이 문서의 수치·규칙을 참조한다.

> **UI 언어**: 사용자에게 보이는 문자열은 **영어**로 통일한다(2026-08-18 사용자 요청).
> 표준 macOS 용어를 쓰고 직역하지 않는다. 코드 주석·설계 문서 본문은 한국어를 유지한다.

## 1. 윈도우·레이아웃

| 항목 | 값 |
|------|-----|
| 최소 윈도우 크기 | 720 × 480 pt |
| 기본 윈도우 크기 | 1080 × 640 pt (첫 실행) |
| 사이드바(트리) 폭 | 기본 240 pt, 드래그 리사이즈 180~400 pt |
| 상태 저장 | 윈도우 프레임, 사이드바 폭, 정렬 기준/방향, 숨김 표시 여부 — `UserDefaults`, 종료 후 복원 |
| 다크 모드 | 시스템 외관 따름 (전 컴포넌트 시스템 시맨틱 컬러 사용) |
| 언어 | MVP는 한국어 고정. 현지화 프레임(String Catalog)만 잡아두고 번역은 Phase 2 |

## 2. 툴바 상세

배치(좌→우): `[⬅][➡][⬆]  [breadcrumb 주소창(가변폭)]  [⟳]`

### 2.1 내비게이션 버튼

- 뒤로/앞으로: 히스토리 스택 비면 비활성. 길게 누르면 히스토리 드롭다운(Phase 2 — MVP 제외)
- 상위(⬆): 루트(`/`)에서 비활성

### 2.2 Breadcrumb 주소창

- 세그먼트: `🏠 › Work › UniFinder` — 홈 하위 경로는 홈 아이콘부터, 그 외는 볼륨명부터 표시
- 각 세그먼트는 버튼: 클릭 시 해당 폴더로 이동
- **오버플로**: 공간 부족 시 앞쪽 세그먼트부터 `… ›`로 접고, `…` 클릭 시 접힌 경로 메뉴 표시. 현재 폴더 세그먼트는 항상 표시
- **편집 모드 진입**: 빈 영역 클릭 또는 `Cmd+Shift+G`(Go > Go to Folder… — 2026-08-18 Finder 표준에 맞춰 `Cmd+L`에서 변경) → 전체가 텍스트 필드로 전환, 현재 절대 경로가 전체 선택된 상태
- 편집 모드 규칙:
  - `~` 접두 입력 시 홈으로 확장
  - `Enter`: 존재하는 폴더면 이동, 파일이면 부모로 이동+해당 파일 선택, 없으면 필드 테두리 빨강 + 셰이크 애니메이션, 값 유지
  - `Esc` 또는 포커스 이탈: breadcrumb으로 복귀 (입력 폐기)
  - 자동완성: MVP 제외 (Phase 2)

## 3. 좌측 트리 상세

- 섹션 헤더: "Favorites", "Home", "Volumes" — **15pt semibold** `secondaryLabelColor`, 행 높이 26pt, 접기/펼치기 가능
  - **섹션 아이콘**(2026-08-18 사용자 요청): 즐겨찾기 `star` / 홈 `house` / 볼륨 `internaldrive` (SF Symbols, 15pt / 17pt 프레임).
    macOS 표준 사이드바 헤더에는 아이콘이 없지만 이 앱은 **Win10 탐색기를 지향**하므로 헤더에도 아이콘을 둔다.
    색·굵기는 라벨과 같은 계열(`secondaryLabelColor`, semibold)로 맞춘다.
  - 아이콘 매핑은 헤더 **문자열이 아니라 `TreeNode.SectionKind`** 기준이다(헤더 문구가 바뀌어도 안전).
  - **헤더가 항목보다 크다**(15pt vs 13pt). macOS 표준(헤더가 더 작음)과 반대이며 **의도된 선택**이다 —
    사용자가 "사이드바 크기를 크게 해달라고 한 건 Favorites/Home/Volumes 자체의 아이콘과 문자열"이라고
    확정했다(2026-08-18). 헤더 심볼(17)도 폴더 아이콘(16)보다 크다. 되돌리지 말 것.
  - **섹션은 `isGroupItem`으로 선언하지 않는다.** `style = .sourceList`의 그룹 행은 AppKit이 셀의
    폰트·심볼 크기를 표준 헤더 크기로 **강제**해서, 헤더 폰트를 24pt로 키워도 화면이 변하지 않는다
    (폰트 세터 차단·그리기 직전 재지정 등 우회 시도는 모두 실패, 2026-08-18 실행 화면 실측).
    그래서 섹션을 일반 행으로 두고 크기를 직접 통제한다. 대신 헤더에 디스클로저 삼각형이 보이며
    이것으로 접기/펼치기를 한다(Win10 탐색기의 섹션과 같은 방식). 선택 불가는 `shouldSelectItem`이 보장한다.
    이 조건은 `SidebarMetricsTests.testSections_areNotGroupRows_soHeaderFontSurvives`가 지킨다.
- 행: 폴더 아이콘(16pt) + 이름(13pt), 행 높이 22pt·인덴트 14pt — **우측 목록(§4.1)과 완전히 동일**
  - 사용자 확정(2026-08-18): "하위 폴더는 오른쪽창과 동일한 크기". 글자·아이콘뿐 아니라 **행 높이까지** 같다.
  - 같은 숫자를 좌우에 따로 적으면 조용히 어긋나므로, 목록 치수를 `FileListMetrics`로 노출하고
    `SidebarMetrics`가 그것을 **참조**한다(`nodeFontSize = FileListMetrics.nameFontSize` 등).
    `FileListBridge.rowHeight`도 같은 상수를 쓴다 — 한쪽만 바꾸는 것이 불가능하다.
  - 치수는 `SidebarMetrics`(src/Bridges/FileListCellViews.swift) 한곳에서만 정의하고, 행 높이는
    `SidebarTreeBridge`가 `outlineView(_:heightOfRowByItem:)`으로 돌려준다(`rowSizeStyle = .custom`).
    `.default`(시스템 고정 높이 = 32pt 실측)로 두면 커진 헤더가 잘리고 폴더 행도 목록과 다른 리듬이 된다.
  - **볼륨 섹션 바로 아래 노드만** 공용 폴더 아이콘 대신 `NSWorkspace.icon(forFile:)`의 실제 디스크 아이콘을 쓴다(2026-08-18).
    디스크 조회 비용이 있으므로 `VolumeIconCache`가 볼륨당 1회만 조회하고, 마운트/언마운트/볼륨 이름 변경으로
    섹션이 다시 만들어질 때(`TreeModel.sectionsRevision`)만 캐시를 버린다.
- 심볼릭 링크 폴더: 아이콘 우하단 화살표 배지
- 접근 불가 폴더: 이름 회색 처리, 선택 시 우측에 권한 에러 표시(트리에서 숨기지 않음)
- 로딩 중 노드: 자식 위치에 회색 "Loading…" placeholder 1행
- 볼륨 섹션: 로컬 볼륨만 (`isRemovable`/`isInternal` 무관, 네트워크 볼륨 필터). 꺼내기 버튼은 Phase 2

## 4. 우측 목록 상세

### 4.1 컬럼

| 컬럼 | 기본 폭 | 최소 폭 | 정렬 기본 | 비고 |
|------|--------|--------|----------|------|
| 이름 | 가변(잔여 전체) | 160 pt | 오름차순 | 아이콘 16pt + 이름, 말줄임 중간(`…`) 아님 — **꼬리 말줄임** |
| 수정일 | 140 pt | 120 pt | — | `yyyy-MM-dd HH:mm` 고정 포맷 |
| 종류 | 120 pt | 80 pt | — | UTType localizedDescription ("폴더", "Swift 소스" 등) |
| 크기 | 90 pt | 70 pt | — | `ByteCountFormatter` (KB/MB/GB), 폴더는 `--` |

- 행 높이 22 pt, 정렬 인디케이터는 헤더 화살표(시스템 기본)
- 헤더 클릭: 같은 컬럼 재클릭 시 방향 토글. 정렬과 무관하게 **폴더 항상 상단** (설계서 §2.3)
- 컬럼 폭 사용자 조정 가능 + `UserDefaults` 저장. 컬럼 순서 변경·추가/제거는 Phase 2

### 4.2 상태 표현

- 잘라내기(cut) 대기 항목: 아이콘+이름 50% 불투명도 (Win10 동일)
- 심볼릭 링크: 화살표 배지
- 숨김 파일(표시 모드일 때): 40% 불투명도
- 빈 폴더: 중앙에 "이 폴더는 비어 있습니다." 회색 안내
- 접근 불가: 중앙에 ⚠️ + "You don't have permission to open this folder." + [How to Grant Access] 버튼(M3 FDA 온보딩으로 연결, M1은 문구만)
- 로딩(200ms 초과 시): 중앙 스피너, 기존 내용은 즉시 클리어(이전 폴더 내용 잔상 금지)

### 4.3 선택·마우스

- 단일 클릭 선택 / `Cmd+클릭` 토글 / `Shift+클릭` 범위 / 빈 영역 드래그 러버밴드 / `Cmd+A` 전체
- 더블클릭: 폴더 진입, 파일은 기본 앱 실행
- 빈 영역 클릭: 선택 해제

## 5. 상태바

- 높이 24 pt, 좌측 정렬 텍스트 2개를 ` | ` 구분
- 평상시: `128 items` (숨김 제외 표시 기준, 1개면 `1 item`)
- 선택 시: `128 items | 3 selected (14.2 MB)` — 크기는 선택된 **파일** 합계, 폴더 포함 시 `(14.2 MB + 2 folders)`
- 파일 조작 중(M2+): 우측 끝에 미니 진행 표시 `Copying… 42%` (클릭 시 진행률 팝오버)

## 6. 컨텍스트 메뉴 (M2)

**항목 위** (다중 선택 시 해당 항목들 대상):

```
Open                    Enter
─────────────────────────
Copy                    Cmd+C
Cut                     Cmd+X
─────────────────────────
Rename                  F2            (다중 선택 시 비활성)
Move to Trash           Delete
─────────────────────────
Show in Finder          Cmd+I         (Finder 정보창 위임 — architect B9)
─────────────────────────
Add to Favorites        Ctrl+Cmd+T    (등록돼 있으면 Remove from Favorites로 토글, 파일은 비활성)
```

**빈 영역**:

```
New Folder              Cmd+Shift+N
─────────────────────────
Paste                   Cmd+V         (클립보드 비면 비활성)
─────────────────────────
Sort By       ▸ Name / Date Modified / Kind / Size · Ascending / Descending
Refresh                 Cmd+R
```

트리 노드 우클릭: Open(우측 표시), Copy, Paste, Rename, Move to Trash, New Folder(하위 생성),
Add to Favorites / Remove from Favorites(2026-08-18 — 위험 대상 가드와 무관하게 항상 활성)

## 7. 다이얼로그 (M2·M3)

### 7.1 이름 충돌 (붙여넣기/이동/D&D 시)

시트(sheet) 형태:

```
An item named "README.md" already exists.
  Source:       14 KB · 2026-08-10 09:12
  Destination:  12 KB · 2026-08-01 17:40

☐ Apply to the remaining 3 items

[Keep Both]  [Skip]  [Cancel]  [Replace(기본)]
```

- **Keep Both**: `README 2.md` 규칙 (Finder 관례 — 공백+숫자 증가)
- **Apply to the remaining…** 체크: 이후 충돌에 같은 선택 적용
- `Enter`=Replace, `Esc`=Cancel(전체 작업 중단, 이미 처리분은 유지)

### 7.2 이름 변경 검증

- 인라인 편집(목록 내 텍스트 필드), 확장자 제외 이름부분만 기본 선택
- 금지: 빈 이름, `/` 또는 `:` 포함, 같은 폴더 내 중복 → 필드 셰이크 + 툴팁 사유 표시, 편집 유지
- `.`으로 시작(숨김화) 시 확인 알림 1회

### 7.3 삭제

- 휴지통 이동은 **확인 다이얼로그 없음** (Win10 기본 동작과 동일, 복구는 휴지통에서)
- 휴지통 이동 실패(권한 등) 시에만 에러 알림

### 7.4 진행률 (M3)

- **비모달 오버레이**(시트 아님 — 시트로 만들면 충돌 다이얼로그가 시트 큐에 밀려 조작이 멈춘다, m3-impl B18): 윈도우 콘텐츠 내부에 표시하며 목록·트리 탐색을 막지 않는다
- 작업이 1초 이상 지속되면 나타나는 **지연 표시**(그 전엔 상태바 미니 표시만) — "예상 소요"는 사전 계산이 불가능하므로 실제 경과 기준
- 표시: `Copying…` + 대상 이름 + `128/512 items` + 진행바 + [Cancel]
- **항목 수 기준만 표시.** 바이트 진행·전송 속도(`34 MB/s`)는 Phase 2로 이관 — `FileManager.copyItem`이 단일 대용량 파일 복사 중 콜백을 주지 않아 청크 단위 복사 도입이 필요하다 (m3-impl B19)
- 취소: 진행 중 항목까지 완료 후 중단, 이미 복사된 항목은 유지 (롤백 없음 — 안내 문구 표시)

### 7.5 FDA 온보딩 (M3)

첫 실행(또는 권한 미허용 감지) 시 웰컴 시트:

1. 안내: "UniFinder needs Full Disk Access to browse all of your files"
2. [Open System Settings] → `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` 딥링크
3. 앱 활성화 시점마다 권한 재감지(보호 경로 접근 테스트) → 허용되면 시트 자동 닫힘
4. [Later] 선택 시 접근 가능한 범위로 계속 사용 (홈 대부분은 FDA 없이도 접근 가능)

## 8. 에러 표시 패턴

| 상황 | 패턴 |
|------|------|
| 폴더 접근 불가 (탐색) | 우측 pane 인라인 empty-state (§4.2) — 모달 금지 |
| 파일 조작 실패 (M2) | 알림(alert): 실패 사유 + 항목명. 다중 작업 중 일부 실패 시 끝에 요약 1회("3 items couldn't be copied" + 목록) |
| 경로 이동 실패 | 주소창 셰이크 (§2.2) |
| 표시 중 폴더 소실 | 상위 폴더로 이동 + 상태바에 안내 문구 5초 표시 (모달 금지) |

원칙: **탐색을 막는 모달을 띄우지 않는다.** 모달(알림)은 사용자가 명시적으로 요청한 조작의 실패에만 사용.

## 9. 포커스·키보드 시각화

- 포커스 영역(트리/목록/주소창) 중 목록·트리는 시스템 포커스 링 없이 **선택 행 강조색**으로 구분: 포커스 보유 시 accent 색, 미보유 시 회색 (macOS 표준 동작)
- `Tab` 순환: 목록 → 트리 → (편집 모드일 때만 주소창) → 목록
- 앱 시작·폴더 이동 후 포커스는 항상 **목록**, 첫 항목 선택
- `Space` 충돌 규칙: 타입-어헤드 입력 진행 중(마지막 입력 후 1초 이내)에는 `Space`가 검색 문자열에 포함되고, 그 외에는 QuickLook 토글 (Finder 동일 규칙 — M1 T7 라우팅에 예약, M3 T3에서 활성화)

## 10. 메뉴바 구조 (2026-08-18)

macOS Finder의 메뉴 구조(`File · Edit · View · Go · Window · Help`)에 맞춘다.
Finder에 없는 `File Actions` 커스텀 메뉴는 **폐지**하고 항목을 File/Edit으로 흩었다.
`Go`만 커스텀 `CommandMenu`로 두는데, SwiftUI 커스텀 메뉴는 View와 Window 사이에 들어가므로
Finder 순서와 자동으로 일치한다.

| 메뉴 | 항목 (순서대로) |
|------|------|
| **File** | New Folder `Cmd+Shift+N` · Open `Cmd+O` · Open Selection `Cmd+↓` · Show in Finder `Cmd+I` · Rename `F2` · Add/Remove Favorites `Ctrl+Cmd+T` · Move to Trash `Cmd+Backspace` |
| **Edit** | Cut `Cmd+X` · Copy `Cmd+C` · Paste `Cmd+V` · Move Items Here `Opt+Cmd+V` · Select All `Cmd+A` |
| **View** | Show/Hide Hidden Items `Cmd+Shift+.` · Refresh `Cmd+R` |
| **Go** | Back `Cmd+[` · Forward `Cmd+]` · Enclosing Folder `Cmd+↑` · Go to Folder… `Cmd+Shift+G` |

**배치 규칙 (실측으로 확정)**

- File 항목은 전부 `CommandGroup(replacing: .newItem)` **한 그룹**에 넣는다. `.saveItem`을 교체하면
  SwiftUI가 그 근처에 넣는 `Close`(`Cmd+W`)까지 함께 사라진다.
- Edit은 `CommandGroup(replacing: .pasteboard)`로 **교체**해 Cut/Copy/Paste를 한 벌만 남긴다.
  같은 `Cmd+C`를 단 항목이 두 벌 있으면 어느 쪽이 먼저 잡히는지가 메뉴 순서에 좌우된다.
- **`.pasteboard` 교체는 표준 `Select All`도 함께 걷어간다**(실측 확인). 목록/트리에는 `selectAll`
  핸들러가 없고 `NSTableView`/`NSOutlineView` 기본 구현에 기대므로, 되살린 항목이
  `selectAll:`을 responder chain으로 흘려보낸다.
- Edit의 Cut/Copy/Paste/Select All은 **`.disabled`로 내리지 않는다**. 내리면 `Cmd+C`를 단 항목이
  메뉴에 하나도 없게 되고, AppKit은 `Cmd` 단축키를 responder chain보다 메인 메뉴에서 먼저 찾으므로
  주소창·인라인 rename의 복사/붙여넣기가 통째로 죽는다. 게다가 메뉴 활성 상태는 SwiftUI가
  뷰 갱신 시점에 계산하는 스냅샷이라 first responder 변화를 따라가지 못한다 —
  항상 활성으로 두고 `AppModel.editActionTarget`이 **동작만** 분기한다.
- `Move Items Here`는 **컨텍스트 메뉴에 넣지 않는다**. Finder도 우클릭에서는 `Opt`를 눌러야
  나타나는 숨은 항목이라 MVP 범위 밖이다.
- 중복인 `Open`(`Cmd+O`)/`Open Selection`(`Cmd+↓`)과 `Show in Finder`의 `Cmd+I`는 현행 유지다.
