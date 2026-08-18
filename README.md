# UniFinder

macOS Finder를 대체하는 **Windows 10 탐색기 스타일 2-pane 파일 탐색기**.

좌측은 폴더 트리, 우측은 상세 목록. Finder의 단일 창 탐색 대신 Win10 탐색기의 조작 감각을 macOS 위에서 재현하는 것이 목표입니다. 메뉴 구조와 단축키는 macOS 표준(Finder)을 따릅니다.

| | |
|---|---|
| **버전** | 0.2.0 |
| **요구 사항** | macOS 14 (Sonoma) 이상 |
| **기술 스택** | Swift 5.10+, SwiftUI + AppKit 하이브리드 |
| **테스트** | 484 unit + 1 UI 스모크 |

---

## 기능

**탐색**
- 2-pane 레이아웃 — 좌측 트리(즐겨찾기 / 홈 / 볼륨), 우측 상세 목록
- 트리는 확장 시점에 1-depth만 로드(lazy). 우측에서 폴더에 진입하면 트리가 자동으로 펼쳐지며 동기화
- 뒤로 / 앞으로 / 상위 폴더, breadcrumb 주소창, 경로 직접 입력
- 타입-어헤드(파일명 타이핑으로 점프), 컬럼 헤더 클릭 정렬(이름 / 수정일 / 종류 / 크기, 폴더 우선)
- 숨김 항목 표시 토글

**파일 조작**
- 복사 / 잘라내기 / 붙여넣기 — Win10식 잘라내기(⌘X, 대상이 50% 불투명으로 표시)와 Finder식 이동(⌘C → ⌥⌘V) 양쪽 지원
- 인라인 이름 변경, 휴지통으로 이동, 새 폴더
- 이름 충돌 시 시트로 해결(대치 / 둘 다 유지 / 건너뛰기 / 취소)
- 드래그앤드롭 — 앱 내부 이동·복사, Finder와 양방향 상호 운용
- 비모달 진행률 오버레이 + 작업 취소

**그 밖에**
- 즐겨찾기 등록 / 해제(⌃⌘T) — 목록·트리 우클릭 메뉴에서도 가능
- QuickLook 미리보기(Space)
- FSEvents 기반 외부 변경 자동 반영, 볼륨 마운트/언마운트 감지
- Full Disk Access 온보딩 — 권한이 없으면 제한 모드로 동작하고 안내를 제공

**비목표** — 네트워크 관련 전부(SMB/AFP/FTP, 서버 브라우징)는 설계 단계에서 제외했습니다. 검색, 탭, undo, 미리보기 패널, 압축/해제, 태그는 Phase 2입니다.

---

## 단축키

메뉴 구조와 단축키는 macOS Finder를 따릅니다.

| 메뉴 | 항목 | 단축키 |
|------|------|--------|
| **File** | New Folder | ⇧⌘N |
| | Open | ⌘O |
| | Show in Finder | ⌘I |
| | Rename | F2 |
| | Add / Remove Favorites | ⌃⌘T |
| | Move to Trash | ⌘⌫ |
| **Edit** | Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| | Move Items Here | ⌥⌘V |
| | Select All | ⌘A |
| **View** | Show / Hide Hidden Items | ⇧⌘. |
| | Refresh | ⌘R |
| **Go** | Back / Forward | ⌘[ / ⌘] |
| | Enclosing Folder | ⌘↑ |
| | Go to Folder… | ⇧⌘G |

Edit 메뉴의 잘라내기·복사·붙여넣기는 포커스에 따라 동작이 갈립니다 — 주소창이나 인라인 이름 편집 중에는 텍스트에, 그 밖에는 파일에 적용됩니다.

---

## 빌드

[XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 프로젝트를 생성합니다.

```bash
brew install xcodegen

xcodegen generate
xcodebuild -scheme UniFinder build
xcodebuild -scheme UniFinder test
```

## 설치

```bash
./scripts/install-local.sh
```

로컬 설치는 ad-hoc 서명으로 빌드해 `/Applications`에 넣습니다. 단계별 절차와 문제 해결은 [INSTALL.md](INSTALL.md)를 참조하세요.

> **배포용 서명은 아직 수행되지 않았습니다.** Release 구성은 Developer ID + hardened runtime + secure timestamp로 이미 분리돼 있지만, 인증서·공증 자격 증명이 준비되지 않아 서명과 공증을 거치지 않았습니다. 절차는 [m3-impl §6](ref-docs/specs/impl/unifinder-m3-impl.md)에 고정해 두었습니다.

---

## 설계 문서

이 프로젝트는 스펙 우선(SDD)으로 진행합니다. 구현 전에 설계서와 구현계획서를 먼저 확정하고, 변경이 생기면 문서를 함께 갱신합니다.

| 문서 | 내용 |
|------|------|
| [unifinder-mvp-design.md](ref-docs/specs/design/unifinder-mvp-design.md) | 전체 설계 — 범위, 비목표, 아키텍처, 설계 결정 |
| [unifinder-ui-design.md](ref-docs/specs/design/unifinder-ui-design.md) | UI 상세 — 레이아웃, 트리/목록 동작, 메뉴바 구조 |
| [unifinder-m1-impl.md](ref-docs/specs/impl/unifinder-m1-impl.md) | M1 — 읽기 전용 탐색 |
| [unifinder-m2-impl.md](ref-docs/specs/impl/unifinder-m2-impl.md) | M2 — 파일 조작 |
| [unifinder-m3-impl.md](ref-docs/specs/impl/unifinder-m3-impl.md) | M3 — 마감(감시·D&D·QuickLook·FDA) 및 릴리스 절차 |
| [unifinder-mvp-test.md](ref-docs/specs/test/unifinder-mvp-test.md) | 테스트 계획 |

---

## 구조

```
src/
  App/          AppModel(단일 조정자), AppCommands(메뉴)
  Views/        SwiftUI 뷰 — 툴바, breadcrumb, 상태바, 시트
  Bridges/      AppKit 브릿지 — NSTableView/NSOutlineView, 인라인 편집, 키 라우팅
  ViewModels/   Navigation, Directory, Tree, Clipboard, Progress, FDA
  Services/     디렉터리 열거, 파일 조작, FSEvents 감시, 아이콘, 설정
  Models/       FileItem, 정렬, 경로 정규화(PathKey), 에러 타입
tests/
  UnitTests/    단위·통합 테스트
  UITests/      XCUITest 스모크
```

목록과 트리는 SwiftUI가 아니라 AppKit(`NSTableView` / `NSOutlineView`)으로 그립니다. 수만 개 항목의 스크롤 성능, 셀 재사용, 원시 키 입력 처리가 SwiftUI만으로는 감당되지 않기 때문입니다. 브릿지 경계와 키 입력 소유권은 `AppCommands.swift`와 각 브릿지 상단 주석에 규정돼 있습니다.

---

## 라이선스

미정.
