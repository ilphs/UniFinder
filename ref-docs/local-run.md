# 로컬 수동 구동 가이드

UniFinder(macOS 앱)를 수동으로 빌드/실행하는 방법. 크게 CLI 경로와 Xcode GUI 경로 두 가지가 있다.

## 방법 1: 커맨드라인 (빠른 확인용)

```bash
cd /Users/admin/Work/UniFinder

# 1) project.yml 변경 시에만 재생성 (이미 UniFinder.xcodeproj가 존재하면 생략 가능)
xcodegen generate

# 2) 빌드
xcodebuild -scheme UniFinder -configuration Debug build

# 3) 빌드된 .app 실행
BUILD_DIR=$(xcodebuild -scheme UniFinder -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
open "$BUILD_DIR/UniFinder.app"
```

## 방법 2: Xcode GUI (디버깅하며 실행하고 싶을 때)

```bash
open /Users/admin/Work/UniFinder/UniFinder.xcodeproj
```

연 뒤 상단 스킴이 `UniFinder`인지 확인하고 `⌘R`로 실행. 브레이크포인트/콘솔 로그를 보려면 이 방법이 편하다.

## 참고

- 스킴은 `UniFinder` 하나, 타겟은 `UniFinder`(앱)와 `UnitTests` 두 개.
- 테스트만 수동 실행: `xcodebuild -scheme UniFinder test`
- `src/App/UniFinder.entitlements`에 Desktop/Documents 접근 문구가 들어있어, 첫 실행 시 macOS가 폴더 접근 권한 프롬프트(TCC)를 띄울 수 있다 — 허용해야 트리에 즐겨찾기 폴더가 표시됨.
- `project.yml`을 수정했다면 반드시 `xcodegen generate`를 먼저 실행해야 `.xcodeproj`에 반영된다.
