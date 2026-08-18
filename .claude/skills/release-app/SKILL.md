---
name: release-app
description: UniFinder를 새 버전으로 릴리스한다 — 버전 번호 확정, README.md·INSTALL.md 갱신, 전체 테스트 검증, ad-hoc 서명 Release 빌드, zip 패키징, git 태그, GitHub Release 게시(quarantine/Gatekeeper 안내를 매번 포함, 릴리스 노트·README는 개발자가 아닌 일반 사용자 눈높이로 작성)까지 한 파이프라인으로 수행한다. "릴리스해줘", "릴리즈 하고 싶어", "버전 올려줘", "0.x.0 배포", "release 만들어줘", "새 버전 내보내줘" 등 앱을 배포 가능한 형태로 내보내려는 요청에 사용한다. 단순 버전 번호만 바꾸는 요청(project.yml 수정만)이나, 코드 변경 없이 문서만 고치는 요청에는 쓰지 않는다.
---

# release-app — UniFinder 릴리스 파이프라인

당신은 UniFinder의 릴리스 담당자다. 버전 확정부터 GitHub Release 게시까지 **하나의 흐름으로** 수행하고, 매 릴리스마다 반드시 지켜야 하는 것들을 빠뜨리지 않는다.

이 스킬이 존재하는 이유: v0.2.0 첫 릴리스에서 GitHub Release 노트에 "우클릭 → 열기"로 안내했다가 실제로는 최신 macOS에서 그 경로가 막혀 있어(다이얼로그에 "열기" 버튼 자체가 없음) 사용자가 앱을 못 열었다. **같은 실수를 반복하지 않는 것**이 이 스킬의 1차 목적이다.

## 발동 조건

- 명시 요청: "릴리스", "릴리즈", "release", "버전 올려줘", "배포해줘", `/release-app`
- **발동하지 않음**: 단순 `project.yml` 버전 번호만 바꾸는 요청, README만 고치는 문서 작업, 아직 브랜치가 `main`에 머지되지 않은 상태에서의 "배포 준비해줘"(이 경우 먼저 머지 여부를 확인)

## 사전 조건 확인 (반드시 도구로 확인, 추측 금지)

1. `git status -sb` — 워킹 트리가 clean이고 `main`이 `origin/main`과 동기화돼 있는지. 아니면 먼저 정리하거나 사용자에게 확인.
2. `git tag -l` — 기존 태그 목록과 `project.yml`의 현재 `MARKETING_VERSION`을 대조해 다음 버전이 합리적인지 확인(사용자가 명시하지 않았다면 AskUserQuestion으로 patch/minor/major 중 확정).
3. `security find-identity -v -p codesigning`로 Developer ID 인증서 보유 여부를 **매번** 확인한다. 결과가 0개면 ad-hoc 서명임을 사용자에게 미리 알린다(이미 알고 있어도 재확인 — 인증서가 생겼을 수도 있다).

## 파이프라인

### 1단계 — 버전 확정 + 문서 갱신

- `project.yml`의 `MARKETING_VERSION`을 새 버전으로 변경.
- `README.md`의 버전 테이블(버전 필드) 갱신. `git log --oneline <last-tag>..HEAD`로 이번 릴리스에 들어간 변경을 훑어 "기능" 절이 실제와 맞는지 확인 — 어긋나 있으면 사용자에게 갱신 내용을 확인받는다(코드를 보지 않고 지어내지 않는다).
- **기능 절을 갱신할 때는 아래 "독자 기준"을 따른다** — 새 기능은 사용자가 그것으로 무엇을 할 수 있는지, 어떤 메뉴·단축키로 쓰는지로 쓴다. 내부 구조 변경은 기능 절에 넣지 않는다.
- **새 단축키가 생겼으면 README 단축키 표에 반드시 추가한다.** 기능 설명만 넣고 표를 빠뜨리는 실수가 잦다(v0.3.0에서 New Window ⌘N이 표에서 누락됐다).
- 테스트 수가 README/INSTALL.md에 하드코딩돼 있으면, 2단계에서 실측한 값으로 갱신(순서상 이 단계에서는 자리만 표시해 두고 2단계 이후 채워도 된다). 테스트 수·기술 스택 같은 개발자용 수치는 README 상단 요약 테이블이나 개발 섹션에만 두고, 기능 설명 안에 섞지 않는다.

### 2단계 — 전체 검증 (실측, 생략 금지)

```bash
xcodegen generate
xcodebuild -scheme UniFinder test
```
- **`TEST SUCCEEDED`와 정확한 통과 테스트 수를 실제 출력에서 확인한다.** 이전 릴리스 노트나 대화 기록의 숫자를 재사용하지 않는다.
- 실패하면 릴리스를 진행하지 않는다. 원인을 보고하고 사용자 판단을 구한다.
- UI 스모크가 첫 실행에 실패하는 것은 이 프로젝트에 알려진 플레이크(ad-hoc 서명 재빌드마다 cdhash가 바뀌어 TCC/Gatekeeper 스캔이 겹침, `NavigationSmokeUITests` 주석 참조)다 — 재실행 1~2회로 안정적으로 통과하면 플레이크로 간주해도 되나, **재실행 결과도 반드시 실제로 확인**하고 그 사실을 보고에 남긴다.

### 3단계 — Release 빌드 + 패키징

```bash
rm -rf build-dist
xcodegen generate
xcodebuild -scheme UniFinder -configuration Release \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  DEVELOPMENT_TEAM="" \
  -derivedDataPath ./build-dist \
  build
```
- `project.yml`을 이 목적으로 수정하지 않는다(`ReleaseSigningConfigurationTests`가 깨지고 실제 배포 서명이 빠진다) — `INSTALL.md` §3 "왜 서명을 오버라이드하는가"와 같은 이유.
- 빌드 산출물에서 버전(`plutil -p .../Info.plist | grep CFBundleShortVersionString`)과 서명(`codesign -dv`, `Signature=adhoc` 예상)을 **실측으로 확인**한다.
- Developer ID 인증서가 사전 조건 확인에서 발견됐다면(사용자에게 물어) 이 단계 대신 정식 서명 + 공증 절차(`ref-docs/specs/impl/unifinder-m3-impl.md` §6)로 전환한다.
- 패키징:
  ```bash
  cd build-dist/Build/Products/Release
  ditto -c -k --sequesterRsrc --keepParent UniFinder.app "UniFinder-<VERSION>-macOS.zip"
  shasum -a 256 "UniFinder-<VERSION>-macOS.zip"
  ```
- 빌드 산출물 디렉터리(`build-dist/`)는 릴리스 완료 후 정리한다(`rm -rf`) — 저장소에 커밋하지 않는다.

### 4단계 — 커밋 + 태그

- 1단계에서 바꾼 버전·문서 변경을 커밋한다. 이 스킬을 호출한 것 자체가 "릴리스해줘"라는 명시적 요청이므로, `[Docs]` 또는 `[Release]` 접두로 커밋해도 된다(전역 "명시 요청 전 커밋 금지" 정책의 예외 — 릴리스 요청이 그 명시적 요청이다). 다만 커밋 대상은 버전·문서 변경으로 한정한다 — 관련 없는 잔여 변경이 워킹 트리에 있으면 사용자에게 확인한다.
- annotated 태그 생성:
  ```bash
  git tag -a v<VERSION> -m "<릴리스 요약>"
  git push origin main
  git push origin v<VERSION>
  ```

### 5단계 — GitHub Release 게시

`gh release create v<VERSION> --title "UniFinder v<VERSION>" --notes "..." <zip경로>`

**릴리스 노트는 앱을 쓰려는 사람이 읽는다.** 아래 "독자 기준"을 먼저 적용한 뒤, 다음 항목을 채운다.

**릴리스 노트에 반드시 포함할 것 (매번, 예외 없이):**

1. **버전별 변경 요약** — `git log --oneline <last-tag>..HEAD`와 실제 코드를 근거로 삼되, **커밋 메시지를 그대로 옮기지 않는다.** 커밋은 개발자에게 쓴 글이고 릴리스 노트는 사용자에게 쓰는 글이다. 각 항목을 "이 버전에서 무엇이 달라지는가"로 다시 쓴다(변환 방법은 "독자 기준" 참조).
2. **설치 옵션 두 가지**:
   - 옵션 A: 소스 빌드(`git clone` + `./scripts/install-local.sh`) — quarantine 문제 없음을 명시.
   - 옵션 B: zip 다운로드 — **아래 quarantine 안내를 그대로 포함**.
3. **quarantine/Gatekeeper 안내 — 고정 문구** (검증된 표현을 그대로 쓴다. "우클릭 → 열기"는 절대 쓰지 않는다 — 최신 macOS에서 그 경로 자체가 없다):
   ```
   처음 실행 시 "Apple이 확인할 수 없음" 경고가 뜬다 — ad-hoc 서명·미공증 앱을 브라우저로
   받으면 macOS가 quarantine 표시를 붙이기 때문. 우클릭 → 열기는 최신 macOS에서 통하지
   않는다. 터미널에서:

       xattr -dr com.apple.quarantine /Applications/UniFinder.app
   ```
4. **서명 상태 안내** — 사용자가 경고를 만나는 이유를 알 수 있게 한 줄로 쓴다(ad-hoc이면 "정식 서명·공증을 하지 않았다"). 내부 스펙 문서(`m3-impl §6`) 링크는 릴리스 노트에 넣지 않는다 — 개발자용이다.
5. zip 첨부와 **SHA256 체크섬**. GitHub이 자동 생성하는 sha256(`--generate-notes` 등)에 의존하지 말고, 3단계에서 직접 계산한 값을 쓴다. 체크섬은 받은 파일이 온전한지 확인하는 용도라 사용자에게도 의미가 있다.

**릴리스 노트에 넣지 않는 것**: 테스트 통과 수치, 빌드 경고 수, 리팩토링·내부 구조 변경, 버그의 내부 원인 설명, 코드 파일·클래스 이름, 내부 스펙 문서 링크. 2단계에서 실측한 테스트 수치는 **사용자에게 보고할 때만** 쓰고(6단계) 릴리스 노트에는 넣지 않는다.

release는 기본적으로 정식 공개 릴리스로 만든다(`--draft`/`--prerelease` 없음) — 사용자가 명시적으로 draft나 prerelease를 요청한 경우에만 해당 플래그를 쓴다.

### 6단계 — 검증 + 보고

- `gh release view v<VERSION> --json name,tagName,assets,isDraft,isPrerelease`로 게시 상태와 첨부 파일을 확인한다.
- 가능하면 실제로 빌드된 `.app`을 로컬에서 실행해 정상 기동을 확인한다(직접 빌드본은 quarantine이 없으므로 이 확인이 quarantine 문제 자체를 잡지는 못한다 — 그건 안내 문구로 커버한다).
- 사용자에게 보고: 릴리스 URL, 버전, 테스트 결과(실측 수치 — 여기서만 쓴다), 서명 상태, 커밋/태그 목록, **이번에도 quarantine 안내가 릴리스 노트에 들어갔음을 명시**.
- 게시 후 릴리스 노트를 **사용자 눈으로 한 번 다시 읽는다.** "독자 기준"의 판단 기준("앱만 쓰는 사람이 이 문장을 읽고 행동이나 기대가 달라지는가")에 걸리는 문장이 남아 있으면 `gh release edit v<VERSION> --notes "..."`로 고친다.

## 독자 기준 — README·릴리스 노트는 개발자가 아니라 **앱을 쓰는 사람**에게 쓴다

릴리스 노트와 README를 쓸 때는 독자를 "UniFinder를 내려받아 파일을 정리하려는 사람"으로 고정한다. 그 사람은 Swift를 모르고, 이 저장소의 코드·테스트·스펙 문서를 볼 일이 없다. **그 사람이 이 릴리스로 무엇을 할 수 있게 되는지, 무엇이 더 이상 불편하지 않은지**만 쓴다.

### 판단 기준

한 문장을 넣을지 말지 고민되면 이렇게 묻는다 — **"앱만 쓰는 사람이 이 문장을 읽고 행동이나 기대가 달라지는가?"** 아니라면 뺀다.

### 변환 규칙

| 개발자 언어 (쓰지 않는다) | 사용자 언어 (이렇게 쓴다) |
|---|---|
| 새 기능의 **구현 방식** — "`Window` 단일 씬을 `WindowGroup`으로 전환, 창별 `AppModel` + 전역 `AppEnvironment`" | 사용자가 **하는 일** — "File > New Window(⌘N)로 창을 여러 개 열 수 있습니다. 창마다 다른 폴더를 보면서 파일을 옮길 수 있습니다" |
| 버그의 **내부 원인** — "폴더 판정과 열거가 서로 다른 심볼릭 링크 규칙을 써서 ENOTDIR 발생" | 사용자가 **겪던 증상** — "Dropbox 폴더를 왼쪽 트리에서 선택하면 열리지 않던 문제를 고쳤습니다" |
| **수치·내부 이름** — "565 unit + 1 UI 통과", "`FileListMetrics` 신설", "`isGroupItem`을 false로" | 눈에 보이는 결과 — "사이드바 폴더 항목이 오른쪽 목록과 같은 크기가 됐습니다" |
| **리팩토링·구조 변경** — 상수 정리, 테스트 추가, 문서 갱신 | 아예 쓰지 않는다. 사용자 눈에 아무것도 달라지지 않는다 |

### 그래도 남기는 것

사용자에게 **영향이 있는** 제약은 남긴다. 단, 원인이 아니라 **겪게 될 상황**으로 쓴다.

- ✅ "두 창에서 같은 폴더로 동시에 복사하면 확인 창이 창마다 각각 뜹니다"
- ❌ "파일 조작 직렬화 범위가 앱 전역에서 창 단위로 축소됐습니다"

설치 방법의 소스 빌드 옵션(`git clone` + `install-local.sh`)은 개발자용처럼 보이지만 **quarantine 경고를 피하는 유일한 방법**이므로 남긴다 — 다만 "이렇게 하면 경고가 뜨지 않는다"는 이유를 함께 적어 왜 이 길을 택하는지 알 수 있게 한다.

### README의 경우

README는 GitHub 첫 화면이라 개발자도 보지만, **위에서부터 사용자용**으로 배치한다. 소개 → 기능 → 설치 → 단축키가 먼저 오고, 기술 스택·빌드 방법·테스트 수·디렉터리 구조·스펙 문서 링크는 아래쪽 개발자 섹션에 모은다. 기능 설명 안에 내부 용어를 섞지 않는다.

## 원칙

- **모든 수치는 실측**. 이전 릴리스나 대화 기록의 테스트 수·버전을 재사용하지 않는다 — 매번 `xcodebuild test`와 `plutil`/`codesign`으로 새로 확인한다.
- **quarantine 안내는 협상 불가 항목**이다. GitHub Release로 배포하는 한, 정식 서명·공증이 완료되기 전까지는 반드시 릴리스 노트에 포함한다. Developer ID 서명 + 공증이 완료된 이후에는(quarantine이 있어도 공증 티켓이 있으면 정상 실행됨) 이 절이 필요 없어지므로, 그 전환 시점에 이 스킬을 갱신해야 한다는 것을 사용자에게 알린다.
- **"우클릭 → 열기"를 쓰지 않는다.** 검증된 유일한 우회는 `xattr -dr com.apple.quarantine`이다. 다른 방법(시스템 설정의 "그래도 열기" 버튼 등)을 안내하려면 실제로 그 macOS 버전에서 동작을 확인한 뒤에만 추가한다.
- **`project.yml`의 Release 서명 설정을 건드리지 않는다.** ad-hoc 오버라이드는 항상 빌드 커맨드 인자로만 준다.
- 빌드 산출물(`build-dist/`, `dist/*.zip`)을 저장소에 커밋하지 않는다.
- **릴리스 노트와 README는 사용자용, 커밋 메시지와 스펙 문서는 개발자용.** 두 글은 독자가 다르므로 내용을 서로 옮기지 않는다 — 커밋 메시지에 쓴 구현 근거를 릴리스 노트에 복사하지 말고, 릴리스 노트에 쓸 사용자 관점 설명을 위해 커밋 메시지의 기술적 근거를 희석하지도 않는다. 상세 기준은 "독자 기준" 절 참조.
