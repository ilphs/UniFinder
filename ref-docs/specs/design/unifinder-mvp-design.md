---
id: unifinder-mvp-design
title: UniFinder MVP 설계초안 — Win10 탐색기 스타일 2-Pane 파일 탐색기
type: design
version: 1.0.1
status: approved
scope: macOS용 2-pane 파일 탐색기의 MVP 범위·화면 구성·아키텍처·기술 결정
related: []
updated: 2026-08-13
---

# UniFinder MVP 설계초안

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

- **네트워크 관련 전부**: SMB/AFP/FTP 마운트, 네트워크 위치, 서버 브라우징
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
│ ▾ 즐겨찾기          │  이름 ▲        수정일        종류      크기   │
│    데스크탑         │  📁 docs      2026-08-01    폴더       --    │
│    다운로드         │  📁 src       2026-08-10    폴더       --    │
│    문서            │  📄 README.md 2026-08-13    Markdown  2 KB  │
│ ▾ 홈 (admin)      │  📄 a.swift   2026-08-12    Swift     14 KB │
│   ▸ Desktop       │                                             │
│   ▾ Work          │                                             │
│     ▸ UniFinder ◀ │         (우측: 선택 폴더의 내용)               │
│ ▾ 볼륨             │                                             │
│    Macintosh HD   │                                             │
│  (좌측: 폴더 트리)   │                                             │
├───────────────────┴─────────────────────────────────────────────┤
│ 항목 4개  │  1개 선택됨 (14 KB)                    ← 상태바        │
└─────────────────────────────────────────────────────────────────┘
```

### 2.1 툴바

- **뒤로/앞으로/상위**: 방문 히스토리 스택 기반. 상위(⬆)는 현재 경로의 부모로 이동
- **주소창**: 평상시 breadcrumb (`🏠 › Work › UniFinder`, 각 세그먼트 클릭 시 해당 폴더로 이동), 클릭(빈 영역)/`Cmd+L` 시 편집 가능한 텍스트 경로로 전환 — Win10 동작과 동일
- **새로고침**: 수동 리로드 (자동 감지 실패 대비 escape hatch)

### 2.2 좌측 Pane — 디렉토리 트리

- **폴더만** 표시 (파일 제외) — Win10 탐색기와 동일
- 루트 섹션 3개:
  - **즐겨찾기**: 데스크탑, 다운로드, 문서 (MVP는 고정, 편집은 Phase 2)
  - **홈**: `~` 하위 트리
  - **볼륨**: `/Volumes` 하위 로컬 볼륨 (외장 디스크 포함, 네트워크 볼륨은 필터링)
- **Lazy loading**: 노드 확장 시점에 하위 폴더 1-depth만 로드
- 트리에서 폴더 선택 → 우측 pane 즉시 갱신. 우측에서 폴더 진입 시 트리도 해당 경로 자동 확장·동기화 (Win10의 "열려 있는 폴더로 확장" 기본 ON 동작)

### 2.3 우측 Pane — 폴더 내용

- **상세 목록 뷰** 단일 (Win10 "자세히" 뷰) — 아이콘/타일 뷰는 Phase 2
- 컬럼: **이름 | 수정일 | 종류 | 크기** (컬럼 헤더 클릭으로 정렬 토글, 폴더는 항상 파일보다 위 — Win10 기본 동작)
- 폴더와 파일 함께 표시, 더블클릭: 폴더=진입, 파일=기본 앱으로 열기
- 다중 선택 (Cmd+클릭, Shift+클릭, 드래그 러버밴드, Cmd+A)
- 타입-어헤드: 파일명 타이핑 시 해당 항목으로 점프

### 2.4 상태바

- 좌: 전체 항목 수 / 우: 선택된 항목 수 + 합계 크기

### 2.5 컨텍스트 메뉴 (우클릭)

- 항목 위: 열기, 이름 변경, 복사, 잘라내기, 삭제(휴지통), 정보 보기(M2 — Finder 정보창 위임, 자체 정보창은 Phase 2)
- 빈 영역: 새 폴더, 붙여넣기, 새로고침, 정렬 기준

### 2.6 키보드 (Win10 매핑 + macOS 관례 병행)

| 동작 | 키 |
|------|-----|
| 열기/진입 | `Enter`(Win10식), `Cmd+O`, `Cmd+↓`(Finder식) |
| 이름 변경 | `F2`(Win10식) |
| 상위 폴더 | `Backspace`(히스토리 뒤로 아님, 상위 이동 — Win10식은 Alt+↑이나 Backspace가 관례), `Cmd+↑` |
| 복사/잘라내기/붙여넣기 | `Cmd+C` / `Cmd+X` / `Cmd+V` |
| 삭제(휴지통) | `Delete`, `Cmd+Backspace` |
| 새 폴더 | `Cmd+Shift+N` |
| 주소창 편집 | `Cmd+L` |
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
    let size: Int64?          // 폴더는 nil (MVP는 폴더 크기 미계산)
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

## 6. 에러·엣지 케이스

- **권한 없는 폴더**: 우측 pane에 "접근 권한 없음" 표시 (크래시·빈 화면 금지), FDA 미허용 시 온보딩 안내
- **심볼릭 링크**: 표시(화살표 배지), 더블클릭 시 타겟으로 이동. 순환 링크는 트리 확장 depth 제한으로 방어
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
