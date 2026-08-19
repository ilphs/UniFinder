---
id: unifinder-ui-design
title: UniFinder UI 상세 설계 — 화면·다이얼로그·인터랙션 세부 스펙
type: design
version: 0.2.0
status: draft
scope: MVP 전체(M1~M3)의 화면 세부 치수·포맷·다이얼로그·에러 표시·인터랙션 규칙
related: [unifinder-mvp-design, unifinder-followup-impl]
updated: 2026-08-19
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

## 6. 컨텍스트 메뉴 (M2 · 2026-08-19 개정)

**항목 위** (다중 선택 시 해당 항목들 대상):

```
Open                    Enter
Open in New Window                    (폴더일 때만 활성)
Open With             ▸               (파일일 때만 활성 — 서브메뉴)
─────────────────────────
Copy                    Cmd+C
Cut                     Cmd+X
Rename                  F2            (다중 선택 시 비활성)
Move to Trash           Cmd+Delete
─────────────────────────
Get Info                Cmd+I         (다중 선택 시 비활성 — Rename과 같은 규칙)
Show in Finder                        (단축키 없음 — Cmd+I는 Get Info가 갖는다)
─────────────────────────
Add to Favorites        Ctrl+Cmd+T    (등록돼 있으면 Remove from Favorites로 토글, 파일은 비활성)
```

| 항목 | key | modifiers | 활성 조건 |
|------|-----|-----------|-----------|
| Open | `\r` | — | 항상 |
| Open in New Window | — | — | 우클릭한 항목이 폴더 |
| Open With ▸ | — | — | 우클릭한 항목이 파일(다중 선택에 폴더가 섞이면 비활성) |
| Copy | `c` | ⌘ | 항상 |
| Cut | `x` | ⌘ | 항상 |
| Rename | `F2` | — | 선택 1개 |
| Move to Trash | `delete` | ⌘ | 항상 |
| Get Info | `i` | ⌘ | 선택 1개 |
| Show in Finder | — | — | 항상 |
| Add to Favorites | `t` | ⌃⌘ | 우클릭한 항목이 폴더 && 선택 1개 |

**그룹 재설계 근거 (구분선 3개)**

기존 구성은 구분선이 4개였고 `Rename`이 "복사/잘라내기" 그룹에, `Show in Finder`가 홀로 한 그룹에
있었다. 항목이 3개 늘면서(Open With · Get Info · Show in Finder 분리) 그 배치는 그룹의 의미를 잃는다.
지금 그룹은 **동사의 성격**으로 나뉜다:

1. **연다** — Open / Open in New Window / Open With: 대상을 "여는" 세 가지 방법이 한자리에 모인다.
2. **바꾼다** — Copy / Cut / Rename / Move to Trash: 파일시스템을 변경하는 조작.
   `Rename`을 여기로 옮긴 이유는 그것이 "변경"이지 "열기"가 아니기 때문이다.
3. **본다** — Get Info / Show in Finder: 대상을 바꾸지 않고 관찰하는 두 항목.
   `Cmd+I` 이관으로 두 항목이 형제가 되었으므로 붙여 둔다.
4. **등록한다** — Add/Remove Favorites: 앱 설정 변경이라 파일 조작과 성격이 다르다.

**Open With 서브메뉴 스펙**

```
Open With ▸  ┌──────────────────────────┐
             │ Preview  (default)       │  ← 기본 앱. 굵게 + "(default)" 접미
             │ Xcode                    │  ← 후보 앱 (LaunchServices 순서 유지)
             │ TextEdit                 │
             │ ──────────────────────── │
             │ Other…                   │  ← NSOpenPanel로 /Applications 선택
             └──────────────────────────┘
```

- 서브메뉴는 **열릴 때 구성한다**(`NSMenuDelegate.menuNeedsUpdate`). 컨텍스트 메뉴를 만들 때마다
  LaunchServices를 조회하면 우클릭 응답이 앱 목록 조회 시간만큼 밀린다.
- 후보가 하나도 없으면 `No Applications Available`을 **비활성 항목**으로 하나 넣는다
  (빈 서브메뉴는 클릭해도 아무 일이 없어 고장처럼 보인다).
- 여기서 고른 앱은 **이번 한 번만** 그 앱으로 연다. 기본 앱 자체를 바꾸는 것은
  Get Info 창의 "Open with:"뿐이다(§7.6 · §7.8) — 메뉴에서 무심코 시스템 기본값이 바뀌면 안 된다.

트리 노드 우클릭: Open(우측 표시), Copy, Paste, Rename, Move to Trash, New Folder(하위 생성),
Add to Favorites / Remove from Favorites(2026-08-18 — 위험 대상 가드와 무관하게 항상 활성).
**트리 메뉴는 이번 개정에서 바뀌지 않는다** — 트리는 폴더만 다루므로 Open With가 의미 없고,
Get Info는 목록 선택을 대상으로 하는 항목이기 때문이다.

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

### 7.6 Get Info 창 (2026-08-19)

시트가 아니라 **독립 창**이다(`WindowGroup(id: "info", for: InfoTarget.self)`). 정보를 띄운 채로
목록을 계속 탐색할 수 있어야 하고, 대상별로 창이 하나씩 열려 비교가 가능해야 하기 때문이다.
같은 URL로 다시 열면 **기존 창이 앞으로 나온다**(`InfoTarget`은 URL 기반 값 — UUID를 넣지 않는다).

```
┌─ report.pdf Info ──────────────────────┐
│  ┌────┐  report.pdf                    │
│  │ 📄 │  PDF Document · 2.4 MB         │
│  └────┘                                │
│ ────────────────────────────────────── │
│  Kind:        PDF Document             │
│  Size:        2.4 MB (2,412,033 bytes) │
│  Size on disk: 2.4 MB                  │
│  Where:       /Users/me/Documents      │
│  Created:     2026-08-01 09:12         │
│  Modified:    2026-08-12 17:40         │
│  Last opened: 2026-08-18 08:03         │
│ ────────────────────────────────────── │
│  Open with:  [ Preview        ▾ ]      │
│              [ Change All… ]           │
│ ────────────────────────────────────── │
│  Type ID:     com.adobe.pdf            │
│  Owner:       me (staff)               │
│  Permissions: rw-r--r--                │
│  Locked:      No                       │
└────────────────────────────────────────┘
```

- **폴더 대상**: `Size:` 행이 `Calculating…` + 소형 스피너로 시작해 500ms 간격으로 갱신되고,
  끝나면 `1.2 GB (3,481 items)`가 된다. 일부를 읽지 못했으면 뒤에
  `(some items couldn't be read)`를 붙인다. 창을 닫으면 계산은 **즉시 취소**된다.
- **심볼릭 링크 대상**: 링크 **자체**의 크기·날짜를 보여주고 `Original:` 행에 해석된 경로를 병기한다
  (설계서 §6 규약 — Get Info는 관찰이라 링크를 해석하지 않는다).
- **폴더에는 `Open with:` 섹션과 `Size on disk:` 행을 표시하지 않는다** — 폴더의 기본 앱 변경은
  이 앱의 범위 밖이고, 폴더의 on-disk 크기는 계산하지 않는다(설계서 §3.2 불변식 3).
- 대상이 사라졌거나 읽을 수 없으면 표 대신 한 줄 안내를 띄운다:
  `This item is no longer available.` / `You don't have permission to read this item.`
- 모든 행의 값은 **선택·복사 가능**(`.textSelection(.enabled)`).

### 7.7 디스크 용량 창 (2026-08-19)

```
┌─ Disk Capacity ─────────────────────────────────┐
│                                                 │
│  Macintosh HD                        /          │
│  ████████████████░░░░░░░░  312.4 GB free       │
│  494.4 GB total · 182.0 GB used                 │
│                                                 │
│  Backup Drive                    /Volumes/USB   │
│  ██████████████████████░░  38.1 GB free        │
│  1.0 TB total · 961.9 GB used                   │
│                                                 │
│ ─────────────────────────────────────────────── │
│  Updated 13:42                       [Refresh]  │
└─────────────────────────────────────────────────┘
```

- **창은 앱 전체에 하나뿐**이다(`Window(id:)` — 값 없는 단일 씬). 창마다 열리면 같은 사실이
  여러 벌 뜨는데, 볼륨 용량은 창별 상태가 아니라 **머신의 사실**이다.
- 볼륨 목록은 사이드바와 **같은 `VolumeService`**를 쓴다 — 네트워크 볼륨은 제외된다(설계서 §1.2).
- 여유 공간 = `volumeAvailableCapacityForImportantUsage`. 그 키를 못 읽으면
  `volumeAvailableCapacity`로 폴백한다. 사용량 = `max(0, total - available)`로 **클램프**한다
  (두 키의 기준이 달라 음수가 나올 수 있는데, 음수 사용량은 사용자에게 의미가 없다).
  purgeable(정리 가능) 공간은 **별도로 노출하지 않는다** — Finder도 합쳐 보여주고, 분리하면
  "왜 지웠는데 안 줄어드나" 같은 설명 부담만 생긴다.
- 조회 실패한 볼륨은 행을 없애지 않고 값만 `--`로 둔다(볼륨이 사라진 것처럼 보이면 안 된다).
- 여유 공간이 **10% 미만**이면 막대와 수치를 경고색으로 칠한다.
- **갱신은 창을 열 때 1회 + 수동 [Refresh](⌘R)뿐이다.** 마운트/언마운트 통지를 구독하지 않는다 —
  용량 값은 초 단위로 흔들리는데 자동 갱신은 사용자가 읽는 도중 숫자를 바꿔 놓는다.
  대신 마지막 갱신 시각을 `Updated HH:mm`으로 항상 표시해 값의 나이를 숨기지 않는다.

### 7.8 기본 앱 변경 확인 (2026-08-19)

Get Info의 `Open with:` 팝업에서 앱을 고르면 **그 파일 하나**의 기본 앱이 바뀐다(확인 없음 —
되돌리기가 같은 팝업에서 한 번에 되므로). `[Change All…]`은 **해당 파일 종류 전체**에 적용되므로
시스템 전역 설정을 바꾸는 조작이고, 반드시 확인을 받는다:

```
Change all documents of type "PDF Document" to open with Preview?

This applies to every PDF Document on this Mac, not just "report.pdf".

                                   [Cancel]  [Change All]
```

- `Esc`/[Cancel] = 아무 API도 호출하지 않는다(회귀 테스트로 고정).
- 실패하면 알림으로 사유를 보여주고 팝업 선택을 **이전 값으로 되돌린다** — 실패했는데 UI만
  바뀌어 있으면 사용자는 바뀐 줄 안다.

### 7.9 업데이트 확인 결과 (2026-08-19)

세 가지 결과 모두 **알림(alert)**이다. 사용자가 명시적으로 요청한 조작의 결과이거나(수동 확인)
행동을 요구하는 정보(새 버전)이기 때문이다.

**(a) 새 버전 있음**

```
UniFinder 0.4.0 is available.

You have 0.3.4.

  What's New
  ┌────────────────────────────────────┐
  │ - Get Info window                  │
  │ - Open With submenu                │
  │ - Disk capacity window             │
  └────────────────────────────────────┘

           [Skip This Version]  [Later]  [Download]
```

- 릴리스 노트는 **일반 텍스트**로 보여준다(마크다운 렌더링 없음 — 원문을 그대로 신뢰하고
  스타일 해석을 하지 않는다). 길면 스크롤한다.
- [Download] = 릴리스 **페이지**를 기본 브라우저로 연다. 앱이 파일을 내려받거나 설치하지 않는다
  (설계서 §1.2 예외 경계 (b)).
- [Skip This Version] = 그 버전은 **자동 확인에서만** 침묵한다. 수동 확인은 언제나 결과를 보여준다.
- [Later] = 아무것도 저장하지 않는다. 다음 자동 확인(24시간 스로틀) 때 다시 안내한다.

**(b) 최신 버전**

```
You're up to date.

UniFinder 0.3.4 is the latest version.

                                              [OK]
```

**(c) 확인 실패 — 수동 확인일 때만 뜬다**

```
Couldn't check for updates.

The request timed out. Check your internet connection and try again.

                                              [OK]
```

- **자동 확인의 실패는 완전히 침묵한다**(로그만). 앱을 켤 때마다 네트워크 오류 알림이 뜨는 것은
  이 앱이 애초에 네트워크 앱이 아니라는 전제(§1.2)와 정면으로 어긋난다.

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
| **File** | New Window `Cmd+N` · New Folder `Cmd+Shift+N` · Open `Cmd+O` · Open Selection `Cmd+↓` · **Get Info `Cmd+I`** · **Show in Finder (단축키 없음)** · Rename `F2` · Add/Remove Favorites `Ctrl+Cmd+T` · Move to Trash `Cmd+Backspace` |
| **Edit** | Cut `Cmd+X` · Copy `Cmd+C` · Paste `Cmd+V` · Move Items Here `Opt+Cmd+V` · Select All `Cmd+A` |
| **View** | Show/Hide Hidden Items `Cmd+Shift+.` · Refresh `Cmd+R` · **Disk Capacity…** |
| **Go** | Back `Cmd+[` · Forward `Cmd+]` · Enclosing Folder `Cmd+↑` · Go to Folder… `Cmd+Shift+G` |
| **Help** | **Check for Updates…** (2026-08-19 신설) |

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
- 중복인 `Open`(`Cmd+O`)/`Open Selection`(`Cmd+↓`)은 현행 유지다.

**`Cmd+I` 소유자 불변식 (2026-08-19)**

- **`Cmd+I`를 단 메뉴 항목은 앱 전체에서 정확히 하나이며, 그것은 `Get Info`다.**
  AppKit은 `Cmd` 단축키를 responder chain보다 메인 메뉴에서 먼저 찾으므로, 같은 단축키를 단
  항목이 둘이면 어느 쪽이 잡히는지가 메뉴 순서라는 우연에 좌우된다.
  `Show in Finder`는 항목으로 남되 **단축키를 갖지 않는다**(회귀 테스트로 고정).
- 이 이관은 옛 `architect B9`("Finder 정보창을 여는 공개 API가 없어 Show in Finder로 대체")의
  **전제를 부정하지 않는다.** 그 전제는 지금도 참이다 — 우리가 여는 것은 Finder의 정보창이 아니라
  **우리 자신의 Get Info 창**이다. 즉 결론만 확장됐다: `Show in Finder`는 유지, `Cmd+I`만 이관.

**`Check for Updates…`가 Help에 있는 이유**

macOS 관례상 이 항목은 앱 메뉴(`UniFinder > Check for Updates…`)에 두는 경우가 많다. 그런데
SwiftUI에서 앱 메뉴 영역은 `CommandGroup(after: .appInfo)`로 건드려야 하고, 그 그룹은
`About`·`Settings`·`Services`·`Quit`가 밀집한 영역이라 **`Quit`(`Cmd+Q`)까지 밀려나거나 사라지는
사고**가 나기 쉽다(같은 부류의 사고를 `.saveItem` 교체에서 이미 겪었다 — 위 배치 규칙 참조).
반면 이 앱의 `Help` 메뉴는 `CommandGroup(replacing: .help) { }`로 **이미 비워 둔 자리**라
새 항목을 넣어도 잃을 것이 없다. 리스크가 0인 자리를 택했다.
