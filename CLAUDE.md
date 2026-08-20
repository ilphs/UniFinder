# Claude Code 개발 가이드

> 공통 규칙(Agent Delegation, 커밋 정책, Context DB 등)은 글로벌 설정(`~/.claude/CLAUDE.md`)을 따릅니다.
> 글로벌 미설치 시: `curl -fsSL https://raw.githubusercontent.com/leonardo204/dotclaude/main/install.sh | bash`

---

## Slim 정책

이 파일은 **100줄 이하**를 유지한다. 새 지침 추가 시:
1. 매 턴 참조 필요 → 이 파일에 1줄 추가
2. 상세/예시/테이블 → ref-docs/*.md에 작성 후 여기서 참조
3. ref-docs 헤더: `# 제목 — 한 줄 설명` (모델이 첫 줄만 보고 필요 여부 판단)

---

## PROJECT

### 개요

**UniFinder** — macOS Finder를 대체하는 Win10 탐색기 스타일 2-pane 파일 탐색기

| 항목 | 값 |
|------|-----|
| 기술 스택 | macOS 14+, Swift 5.10+, SwiftUI + AppKit 하이브리드 |
| 빌드 방법 | `xcodegen generate && xcodebuild -scheme UniFinder build` |
| 테스트 | `xcodebuild -scheme UniFinder test` |
| 상태 | MVP(M1·M2·M3) + 다중 창 + 후속 4종(업데이트 확인·Open With·디스크 용량·Get Info) + 볼륨 Eject·상태바 여유 공간 완료 — 784 unit + 1 UI 테스트 통과 |
| 미완 | Developer ID 인증서 부재로 **릴리스 서명·공증 미수행** (절차는 m3-impl §6) |

- 설계서: `ref-docs/specs/design/unifinder-mvp-design.md` (approved) · `unifinder-ui-design.md`
- 구현계획: `ref-docs/specs/impl/unifinder-m{1,2,3}-impl.md` (M3 §5 = 후속 과제, §6 = 릴리스 절차)
- 다중 창: `ref-docs/specs/impl/unifinder-multiwindow-impl.md` — 창별 `AppModel` vs 전역 `AppEnvironment`, §4 수용된 트레이드오프(조작 직렬화가 **창 단위**로 축소됨 등)
- 볼륨 Eject·상태바 여유 공간: `ref-docs/specs/impl/unifinder-eject-diskspace-impl.md` — D-E1~D-E6 판정표, §4 수용된 트레이드오프(`.allPartitionsAndEjectDisk`가 같은 디스크의 다른 파티션까지 내림 등)
- 후속 4종: `ref-docs/specs/impl/unifinder-followup-impl.md` — D1~D10 판정표, §1.2 B9 승계(⌘I만 Get Info로 이관), §4 수용된 트레이드오프(다중 선택 Get Info 비활성 등)
- 로컬 설치: `INSTALL.md` (ad-hoc 서명 빌드 → /Applications)
- 네트워크는 **업데이트 확인 1건만 예외**(설계서 §1.2 — 읽기전용 GET·메타데이터만·인증 없음·끌 수 있음).
  검색·탭·undo·미리보기 패널은 Phase 2
- 버전 정본은 `project.yml`의 `MARKETING_VERSION` (README·pbxproj는 `VersionSourceConsistencyTests`가 감시)

### 문서 구조 (소유권 분리)

- **하니스 문서** (`claude/` 하위) — 🔒 dotclaude 소유. `dotclaude-update`가 덮어쓰니 **수정 금지**.
- **프로젝트 스펙** (`specs/` 하위) — 📝 자유롭게 작성. → [SDD 가이드라인](ref-docs/claude/sdd.md) · `/spec-guard`로 정합성 분석

### 하니스 상세 문서 (claude/)

- [Context DB](ref-docs/claude/context-db.md) — SQLite 기반 세션/태스크/결정 저장소
- [Context Monitor](ref-docs/claude/context-monitor.md) — HUD + compaction 감지/복구
- [Hooks](ref-docs/claude/hooks.md) — 5개 자동 실행 Hook 상세
- [컨벤션](ref-docs/claude/conventions.md) — 커밋, 주석, 로깅 규칙
- [셋업](ref-docs/claude/setup.md) — 새 환경 초기 설정
- [Agent Delegation](ref-docs/claude/agent-delegation.md) — 에이전트 위임/파이프라인 상세
- [SDD 가이드라인](ref-docs/claude/sdd.md) — 스펙 문서 작성/관리 규약

> 프로젝트 스펙은 `specs/`에 작성하고, 하니스 문서(`claude/`)는 건드리지 마세요.

### 핵심 규칙

- (프로젝트 고유의 코딩 규칙, 금지 사항 등)

---

*최종 업데이트: 2026-08-20*
