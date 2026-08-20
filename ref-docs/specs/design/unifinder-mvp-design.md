---
id: unifinder-mvp-design
title: UniFinder MVP 설계초안 — Win10 탐색기 스타일 2-Pane 파일 탐색기
type: design
version: 1.1.1
status: approved
scope: macOS용 2-pane 파일 탐색기의 MVP 범위·화면 구성·아키텍처·기술 결정
related: [unifinder-ui-design, unifinder-followup-impl, unifinder-eject-diskspace-impl]
updated: 2026-08-20
---

# UniFinder MVP 설계초안

> **UI 언어**: 사용자에게 보이는 문자열은 **영어**로 통일한다(2026-08-18 사용자 요청).
> 코드 주석·설계 문서 본문은 한국어를 유지한다. 상세는 UI설계서 참조.

## 1. 개요

**UniFinder** — macOS Finder를 대체하는 파일 탐색기. Windows 10 파일 탐색기의 UX를 기준으로 한다.

| 항목 | 값 |
|------|-----|
| 타겟 OS | macOS 14 (Sonoma) 이상 |
| 기술 스택 | Swift 5.10+, SwiftUI + AppKit 하이브리드 |
| 배포 | Developer ID 서명 + 공증(notarization), 직접 배포 |
| 프로젝트 생성 | XcodeGen (`project.yml` → `.xcodeproj`) |

핵심 원칙: **파일 탐색 자체가 편해야 한다.** 부가 기능보다 탐색(트리 이동, 목록 스캔, 키보드 내비게이션)의 반응성과 예측 가능성을 최우선으로 한다.

### 1.1 목표 (MVP)

- Win10 탐색기와 동일한 2-pane 구조: 좌측 디렉토리 트리 + 우측 폴더 내용
- Finder보다 빠르고 예측 가능한 탐색 (대용량 폴더 포함)
- 기본 파일 조작: 열기, 이름변경, 삭제(휴지통), 복사/잘라내기/붙여넣기, 새 폴더

### 1.2 비목표 (명시적 제외)

- **네트워크 파일시스템 전부**: SMB/AFP/FTP 마운트, 네트워크 위치, 서버 브라우징, 네트워크 볼륨 표시
  - *예외 1건 — 업데이트 확인 (2026-08-19 사용자 승인)*: GitHub Releases API에 HTTPS GET 1회.
    경계 4개: (a) 읽기전용 GET (b) 릴리스 메타데이터만, 다운로드/설치 없음(브라우저 위임)
    (c) 인증 없음 (d) 사용자가 끌 수 있음. Sparkle 등 자동업데이트 프레임워크 미채택.
- 검색 (Phase 2)
- 탭, 듀얼 패널(커맨더 스타일), 파일 미리보기 패널 (Phase 2+)
- 태그, iCloud 통합, 압축/해제, 일괄 이름변경
- Finder 완전 대체(기본 파일 관리자 등록) — MVP는 독립 앱으로 실행

## 2. 화면 구성

Win10 탐색기 레이아웃을 macOS 관례와 충돌하지 않는 선에서 그대로 매핑한다.

```
┌─────────────────────────────────────────────────────────────────┐
│ ⬅ ➡ ⬆   [ 🏠 › Work › UniFinder          ]  ⟳       ← 툴바      │
├───────────────────┬─────────────────────────────────────────────┤
│ ▾ ★ Favorites     │  Name ▲       Date Modified Kind      Size  │
│    Desktop        │  📁 docs      2026-08-01    Folder     --    │
│    Downloads      │  📁 src       2026-08-10    Folder     --    │
│    Documents      │  📄 README.md 2026-08-13    Markdown  2 KB  │
│ ▾ ⌂ Home (admin)  │  📄 a.swift   2026-08-12    Swift     14 KB │
│   ▸ Desktop       │                                             │
│   ▾ Work          │                                             │
│     ▸ UniFinder ◀ │         (우측: 선택 폴더의 내용)               │
│ ▾ ▤ Volumes       │                                             │
│    Macintosh HD   │                                             │
│  (좌측: 폴더 트리)   │                                             │
├───────────────────┴─────────────────────────────────────────────┤
│ 4 items  │  1 selected (14 KB)                   ← 상태바        │
└─────────────────────────────────────────────────────────────────┘
```

### 2.1 툴바

- **뒤로/앞으로/상위**: 방문 히스토리 스택 기반. 상위(⬆)는 현재 경로의 부모로 이동
- **주소창**: 평상시 breadcrumb (`🏠 › Work › UniFinder`, 각 세그먼트 클릭 시 해당 폴더로 이동), 클릭(빈 영역)/`Cmd+Shift+G` 시 편집 가능한 텍스트 경로로 전환 — Win10 동작과 동일
- **새로고침**: 수동 리로드 (자동 감지 실패 대비 escape hatch)

### 2.2 좌측 Pane — 디렉토리 트리

- **폴더만** 표시 (파일 제외) — Win10 탐색기와 동일
- 루트 섹션 3개 (각 헤더에 아이콘: 즐겨찾기 `star` / 홈 `house` / 볼륨 `internaldrive`):
  - **즐겨찾기**: 사용자가 등록/해제하는 폴더 목록. 최초 실행 시에만 데스크탑·다운로드·문서로 시딩하고, 이후에는 `UserDefaults`에 저장된 목록을 그대로 쓴다(전부 비운 상태도 유지된다). 등록/해제 진입점은 메뉴바·목록 컨텍스트 메뉴·트리 컨텍스트 메뉴 3곳이며, 대상이 이미 즐겨찾기면 항목이 "해제"로 토글된다. 폴더만 등록할 수 있고, 사라진 경로는 저장소에 남긴 채 표시에서만 제외한다(외장 볼륨 재연결 시 자동 복귀).
    - **해제 ≠ 삭제**: 즐겨찾기 해제는 파일시스템을 건드리지 않는다. 섹션 바로 아래 노드의 rename/삭제를 막는 위험 대상 가드(`TreeModel.isProtectedNode`)와는 무관하게 항상 동작한다.
    - *범위 변경*: 원래 "MVP는 고정 3개, 편집은 Phase 2"였으나 2026-08-18 사용자 요청으로 편집 기능을 MVP로 끌어왔다.
  - **홈**: `~` 하위 트리
  - **볼륨**: `/Volumes` 하위 로컬 볼륨 (외장 디스크 포함, 네트워크 볼륨은 필터링). 볼륨 노드는 공용 폴더 아이콘이 아니라 `NSWorkspace`가 주는 **실제 디스크 아이콘**을 쓴다(2026-08-18).
- **Lazy loading**: 노드 확장 시점에 하위 폴더 1-depth만 로드
- 트리에서 폴더 선택 → 우측 pane 즉시 갱신. 우측에서 폴더 진입 시 트리도 해당 경로 자동 확장·동기화 (Win10의 "열려 있는 폴더로 확장" 기본 ON 동작)

### 2.3 우측 Pane — 폴더 내용

- **상세 목록 뷰** 단일 (Win10 "자세히" 뷰) — 아이콘/타일 뷰는 Phase 2
- 컬럼: **Name | Date Modified | Kind | Size** (컬럼 헤더 클릭으로 정렬 토글, 폴더는 항상 파일보다 위 — Win10 기본 동작)
- 폴더와 파일 함께 표시, 더블클릭: 폴더=진입, 파일=기본 앱으로 열기
- 다중 선택 (Cmd+클릭, Shift+클릭, 드래그 러버밴드, Cmd+A)
- 타입-어헤드: 파일명 타이핑 시 해당 항목으로 점프

### 2.4 상태바

- 좌: 전체 항목 수 / 우: 선택된 항목 수 + 합계 크기

### 2.5 컨텍스트 메뉴 (우클릭)

- 항목 위: 열기, 새 창으로 열기, **다음 프로그램으로 열기(Open With)**, 복사, 잘라내기, 이름 변경,
  삭제(휴지통), **정보 보기(Get Info — 2026-08-19 자체 정보창)**, Finder에서 보기, 즐겨찾기 등록/해제
- 빈 영역: 새 폴더, 붙여넣기, 새로고침, 정렬 기준

> **2026-08-19 정정**: "정보 보기 = Finder 정보창 위임"은 더 이상 사실이 아니다. `Cmd+I`는 자체
> Get Info 창이 갖고, `Show in Finder`는 **단축키 없이** 항목으로 남는다(UI설계 §6·§10 참조).
> 상세 배열·활성 조건은 UI설계 §6이 정본이다.

### 2.6 키보드 (Win10 매핑 + macOS 관례 병행)

| 동작 | 키 |
|------|-----|
| 열기/진입 | `Enter`(Win10식), `Cmd+O`, `Cmd+↓`(Finder식) |
| 이름 변경 | `F2`(Win10식) |
| 상위 폴더 | `Backspace`(히스토리 뒤로 아님, 상위 이동 — Win10식은 Alt+↑이나 Backspace가 관례), `Cmd+↑` |
| 복사/잘라내기/붙여넣기 | `Cmd+C` / `Cmd+X` / `Cmd+V` |
| 이동 붙여넣기(Move Items Here) | `Opt+Cmd+V` (2026-08-18 — Finder식. 클립보드 내용을 **무조건 이동**한다) |
| 전체 선택 | `Cmd+A` |
| 삭제(휴지통) | `Delete`, `Cmd+Backspace` |
| 새 폴더 | `Cmd+Shift+N` |
| 주소창 편집 | `Cmd+Shift+G` (2026-08-18 — Finder "Go to Folder…" 표준. 이전 `Cmd+L`) |
| 숨김 파일 토글 | `Cmd+Shift+.` |
| 새로고침 | `Cmd+R`, `F5` |

> `Enter`=열기는 Finder(`Enter`=이름변경)와 다른 Win10 동작이다. 본 프로젝트의 정체성이 "Win10 탐색기 UX"이므로 Win10 동작을 기본으로 하되, 충돌하지 않는 macOS 관례 단축키는 병행 지원한다.

## 3. 아키텍처

### 3.1 레이어 구조

```
┌────────────────────────────────────────────────┐
│ Views (SwiftUI + AppKit 브릿지)                  │
│  MainWindow / Toolbar / SidebarTree / FileList  │
│  StatusBar / ContextMenu                        │
├────────────────────────────────────────────────┤
│ ViewModels (@Observable, MainActor)             │
│  NavigationModel — 현재 경로·히스토리·이동         │
│  TreeModel      — 트리 노드 상태·lazy 확장        │
│  DirectoryModel — 현재 폴더 항목·정렬·선택         │
├────────────────────────────────────────────────┤
│ Services (actor / Sendable)                     │
│  DirectoryLoader — 비동기 디렉토리 열거            │
│  FileOperations  — 복사·이동·삭제·이름변경·새폴더   │
│  DirectoryWatcher— FSEvents 변경 감지            │
│  IconProvider    — NSWorkspace 아이콘 캐시        │
├────────────────────────────────────────────────┤
│ Foundation: FileManager, FSEvents, NSWorkspace  │
└────────────────────────────────────────────────┘
```

의존 방향은 위→아래 단방향. Services는 UI를 모르고, ViewModels가 Services를 조합한다.

### 3.2 핵심 데이터 모델

```swift
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64?          // 폴더는 항상 nil — 목록은 계산 안 함,
                              // Get Info 창에서만 비동기 계산(후속 T6)
    let modifiedAt: Date?
    let typeDescription: String   // UTType 기반 "종류" 컬럼 값
}

@Observable final class NavigationModel {
    var currentURL: URL
    private(set) var backStack: [URL]
    private(set) var forwardStack: [URL]
    func navigate(to: URL) / goBack() / goForward() / goUp()
}
```

- 디렉토리 열거는 `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)`에 필요한 resource key(`.isDirectoryKey`, `.fileSizeKey`, `.contentModificationDateKey`, `.isHiddenKey`, `.contentTypeKey`)를 **한 번에 prefetch** — 항목별 개별 stat 호출 금지 (성능 핵심)

#### 폴더 크기 불변식 (2026-08-19 — Get Info 도입에 따른 정정)

`FileItem.size`는 **목록 컬럼의 값**이고, Get Info 창의 크기는 **그 값이 아니다.** 둘을 섞으면
목록 열거가 하위 트리 순회를 떠안게 되어 §5 성능 목표가 즉시 무너진다.

1. `FileItem.size`는 폴더에 대해 **항상 `nil`**이다. Get Info를 붙여도 이 규칙은 바뀌지 않는다
   (목록 "크기" 컬럼은 폴더에서 계속 `--`).
2. Get Info의 폴더 크기는 창을 연 뒤 **백그라운드에서 재귀 합산**하고 점진적으로 갱신한다.
   창을 닫거나 대상이 바뀌면 즉시 취소한다.
3. **논리 크기(`.fileSizeKey`)만** 더한다. 이 불변식은 **Get Info의 폴더 크기 계산**
   (`DirectorySizeCalculator`)에 적용된다 — 폴더 크기는 논리 크기만 쓴다(합산 정의가 둘이면
   같은 폴더가 화면마다 다른 크기로 보인다). 개별 파일의 on-disk 크기 표시(Get Info 창의
   "Size on disk" 행)는 이 불변식과 무관하며, 이미 prefetch된 값을 그대로 보여준다.
4. **하드링크는 중복 계산한다.** inode 집합을 들고 다니면 100만 항목에서 메모리가 선형으로 늘고,
   이 값은 정확한 회계가 아니라 어림값이다 — **의도된 근사**임을 코드 주석과 UI 문구로 못 박는다.
5. **심볼릭 링크는 따라가지 않고 크기도 합산하지 않는다.** 따라가면 순환 링크에서 무한 순회하고,
   같은 실체를 여러 번 세게 된다.
6. 읽을 수 없는 하위(권한 등)는 **건너뛰고 계속**한다. 그 경우 결과에 불완전 표기를 붙인다.

### 3.3 주요 흐름: 폴더 이동

```
사용자 액션(트리 선택/더블클릭/주소창/뒤로가기)
  → NavigationModel.navigate(to:)
  → DirectoryModel.load(url)           // 이전 로드 Task cancel
      → DirectoryLoader.list(url)      // actor, 백그라운드 열거
      → 정렬 적용 → items 갱신 (MainActor)
  → DirectoryWatcher.watch(url)        // 이전 경로 unwatch, 새 경로 watch
  → TreeModel.reveal(url)              // 트리 경로 확장·선택 동기화
```

- 연속 이동 시 이전 로드는 즉시 취소(Task cancellation) — 큰 폴더 로딩 중 다른 폴더 클릭해도 UI가 밀리지 않아야 함
- 로딩 200ms 초과 시에만 스피너 표시 (짧은 로드에 깜빡임 방지)

### 3.4 변경 감지

- `DirectoryWatcher`: FSEvents로 **현재 표시 중인 경로만** 감시 (트리 전체 감시 안 함 — 리소스 낭비)
- 이벤트 수신 → 300ms debounce → 해당 디렉토리 재열거 → diff 적용 (선택 상태 유지)
- 트리는 노드 확장 시점 데이터 유지, 새로고침(수동/네비게이션 시) 갱신 — MVP에서는 트리 실시간 감시 제외

## 4. 주요 기술 결정

| # | 결정 | 근거 |
|---|------|------|
| 1 | **파일 목록·트리는 AppKit** (`NSTableView`/`NSOutlineView`를 `NSViewRepresentable`로 브릿지), 셸·툴바·상태바는 SwiftUI | 수만 항목 폴더에서 SwiftUI `List`/`Table`은 성능·타입어헤드·러버밴드 선택·인라인 rename 지원이 미흡. AppKit 테이블은 Finder와 동일한 기반으로 검증됨 |
| 2 | **App Sandbox 비활성** + Full Disk Access 권한 요청 | 파일 탐색기 특성상 전체 파일시스템 접근 필수. App Store 배포 불가 → Developer ID 직접 배포. 첫 실행 시 FDA 온보딩 화면 제공 |
| 3 | **삭제는 휴지통으로만** (`FileManager.trashItem`) | MVP에서 영구 삭제 미제공 — 안전 우선. undo는 Phase 2 |
| 4 | **파일 조작은 자체 구현** (`FileManager` 기반) + 충돌 시 다이얼로그(덮어쓰기/건너뛰기/취소) | 대량 복사 진행률 표시를 위해 항목 단위 순회. Finder 위임(NSWorkspace) 대신 자체 구현으로 UX 통제 |
| 5 | **아이콘은 `NSWorkspace.icon(forFile:)` + NSCache** | 네이티브 앱/파일 타입 아이콘 그대로. 셀 재사용 시 비동기 로드 |
| 6 | Swift Concurrency (async/await, actor) 전면 사용 | GCD 수동 관리 배제. 로드 취소가 Task cancellation으로 자연스럽게 표현됨 |

## 5. 성능 요구사항

| 시나리오 | 목표 |
|----------|------|
| 10,000 항목 폴더 열기 | 첫 표시 < 500ms |
| 100,000 항목 폴더 열기 | 첫 표시 < 3s, 스크롤 60fps 유지 |
| 트리 노드 확장 | < 100ms (1-depth만 로드) |
| 폴더 이동 연타 | 이전 로드 즉시 취소, UI 블로킹 0 |
| Get Info 창 열기 | < 100ms (폴더 크기 계산 제외 — 크기는 비동기로 나중에 채운다) |
| 폴더 크기 계산 (1만 항목) | < 1s, **백그라운드 수행 · 메인스레드 블로킹 0** |
| 폴더 크기 계산 (10만 항목) | 500ms 간격 점진 갱신, 창을 닫거나 대상이 바뀌면 **즉시 취소** |
| 디스크 용량 창 열기 | < 200ms (볼륨 수는 보통 한 자릿수) |
| 업데이트 확인 | 요청 timeout 10s(리소스 20s), **UI 블로킹 0** — 실패해도 앱 동작에 영향 없음 |

## 6. 에러·엣지 케이스

- **권한 없는 폴더**: 우측 pane에 "접근 권한 없음" 표시 (크래시·빈 화면 금지), FDA 미허용 시 온보딩 안내
- **심볼릭 링크**: 표시(화살표 배지), 더블클릭 시 타겟으로 이동. 순환 링크는 트리 확장 depth 제한으로 방어
  - **규약 (2026-08-19)**: `Open`은 **의도**를 다루므로 링크를 해석해 타겟으로 간다.
    `Get Info`는 **관찰**을 다루므로 링크를 해석하지 않고 **링크 자체의 메타데이터**를 보여주고,
    해석된 경로는 `Original:` 행에 병기한다. 즉 `AppModel.resolveTarget(of:)`은 Get Info 경로에서
    쓰지 않는다 — 쓰면 "링크 파일의 크기/수정일"을 물어본 사용자에게 타겟의 값을 답하게 된다.
    폴더 크기 계산도 링크를 따라가지 않는다(§3.2 불변식 5).
- **표시 중 폴더가 삭제/이동됨**: 가장 가까운 존재하는 상위 폴더로 자동 이동 + 알림
- **이름 충돌**: 복사/이동 시 덮어쓰기·건너뛰기·둘 다 유지(`name 2`) 선택 다이얼로그
- **외장 볼륨 마운트/언마운트**: 볼륨 섹션 자동 갱신 (`NSWorkspace` 노티피케이션)

## 7. 마일스톤

| 단계 | 범위 | 완료 기준 |
|------|------|----------|
| **M1 — 읽기 전용 탐색** | 2-pane 레이아웃, 트리 lazy 로딩, 상세 목록+정렬, 툴바(뒤로/앞으로/상위/breadcrumb), 키보드 내비게이션, 숨김 토글, 상태바 | 임의 폴더를 마우스·키보드만으로 자유롭게 탐색 가능. 10만 항목 성능 목표 충족 |
| **M2 — 파일 조작** | 복사/잘라내기/붙여넣기, 휴지통 삭제, 이름변경(F2·인라인), 새 폴더, 컨텍스트 메뉴, 충돌 다이얼로그 | 파일 관리 기본 작업을 UniFinder만으로 수행 가능 |
| **M3 — 마감** | FSEvents 자동 갱신, 드래그앤드롭(내부 이동/복사 + Finder와 상호 D&D), QuickLook(스페이스바), 진행률 표시, FDA 온보딩 | Finder 없이 일상 파일 탐색 대체 가능 |

각 마일스톤의 태스크 분해·수용 기준은 별도 구현계획서(`impl`)에서 작성한다.

## 8. 리스크

| 리스크 | 영향 | 완화 |
|--------|------|------|
| SwiftUI↔AppKit 브릿지 경계 복잡도 (선택 상태·포커스·단축키 라우팅) | M1 지연 | 브릿지 경계를 FileList/Tree 두 곳으로 한정, 상태는 ViewModel 단일 소스 유지 |
| FSEvents 이벤트 폭주 (대량 복사 중) | UI 버벅임 | debounce + 표시 중 경로만 감시 |
| FDA 권한 UX (사용자가 설정 앱에서 수동 허용해야 함) | 첫인상 이탈 | 온보딩 화면에서 설정 딥링크 + 허용 여부 자동 감지 |
| Win10 키 관례와 macOS 관례 충돌 (Enter 등) | 사용자 혼란 | Win10 동작 기본 + macOS 관례 병행, Phase 2에서 키맵 설정 제공 |
