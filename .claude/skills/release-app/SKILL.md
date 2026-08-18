---
name: release-app
description: UniFinder를 새 버전으로 릴리스한다 — 버전 번호 확정, README.md·INSTALL.md 갱신, 전체 테스트 검증, ad-hoc 서명 Release 빌드, zip 패키징, git 태그, GitHub Release 게시(quarantine/Gatekeeper 안내를 매번 포함)까지 한 파이프라인으로 수행한다. "릴리스해줘", "릴리즈 하고 싶어", "버전 올려줘", "0.x.0 배포", "release 만들어줘", "새 버전 내보내줘" 등 앱을 배포 가능한 형태로 내보내려는 요청에 사용한다. 단순 버전 번호만 바꾸는 요청(project.yml 수정만)이나, 코드 변경 없이 문서만 고치는 요청에는 쓰지 않는다.
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
- 테스트 수가 README/INSTALL.md에 하드코딩돼 있으면, 2단계에서 실측한 값으로 갱신(순서상 이 단계에서는 자리만 표시해 두고 2단계 이후 채워도 된다).

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

**릴리스 노트에 반드시 포함할 것 (매번, 예외 없이):**

1. **버전별 변경 요약** — `git log --oneline <last-tag>..HEAD`를 근거로, 지어내지 않고 실제 변경을 요약.
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
4. **서명 상태 안내** — ad-hoc이면 "Developer ID 인증서 미보유로 서명·공증 미수행" + `m3-impl §6` 링크. 정식 서명이면 그 사실과 공증 여부를 명시.
5. **테스트 결과** — 2단계에서 실측한 정확한 수치(예: "484 unit + 1 UI 테스트 통과, 빌드 경고 0").
6. zip 첨부. GitHub이 자동 생성하는 sha256(`--generate-notes` 등)에 의존하지 말고, 3단계에서 직접 계산한 체크섬을 노트 또는 별도 메시지로 사용자에게 전달.

release는 기본적으로 정식 공개 릴리스로 만든다(`--draft`/`--prerelease` 없음) — 사용자가 명시적으로 draft나 prerelease를 요청한 경우에만 해당 플래그를 쓴다.

### 6단계 — 검증 + 보고

- `gh release view v<VERSION> --json name,tagName,assets,isDraft,isPrerelease`로 게시 상태와 첨부 파일을 확인한다.
- 가능하면 실제로 빌드된 `.app`을 로컬에서 실행해 정상 기동을 확인한다(직접 빌드본은 quarantine이 없으므로 이 확인이 quarantine 문제 자체를 잡지는 못한다 — 그건 안내 문구로 커버한다).
- 사용자에게 보고: 릴리스 URL, 버전, 테스트 결과, 서명 상태, 커밋/태그 목록, **이번에도 quarantine 안내가 릴리스 노트에 들어갔음을 명시**.

## 원칙

- **모든 수치는 실측**. 이전 릴리스나 대화 기록의 테스트 수·버전을 재사용하지 않는다 — 매번 `xcodebuild test`와 `plutil`/`codesign`으로 새로 확인한다.
- **quarantine 안내는 협상 불가 항목**이다. GitHub Release로 배포하는 한, 정식 서명·공증이 완료되기 전까지는 반드시 릴리스 노트에 포함한다. Developer ID 서명 + 공증이 완료된 이후에는(quarantine이 있어도 공증 티켓이 있으면 정상 실행됨) 이 절이 필요 없어지므로, 그 전환 시점에 이 스킬을 갱신해야 한다는 것을 사용자에게 알린다.
- **"우클릭 → 열기"를 쓰지 않는다.** 검증된 유일한 우회는 `xattr -dr com.apple.quarantine`이다. 다른 방법(시스템 설정의 "그래도 열기" 버튼 등)을 안내하려면 실제로 그 macOS 버전에서 동작을 확인한 뒤에만 추가한다.
- **`project.yml`의 Release 서명 설정을 건드리지 않는다.** ad-hoc 오버라이드는 항상 빌드 커맨드 인자로만 준다.
- 빌드 산출물(`build-dist/`, `dist/*.zip`)을 저장소에 커밋하지 않는다.
