# UniFinder 설치 가이드

로컬 macOS에 UniFinder를 빌드·설치하는 방법. 배포용 서명·공증 절차는 [`ref-docs/specs/impl/unifinder-m3-impl.md` §6](ref-docs/specs/impl/unifinder-m3-impl.md)을 참조한다.

---

## 1. 요구사항

| 항목 | 버전 | 확인 |
|------|------|------|
| macOS | 14.0 (Sonoma) 이상 | `sw_vers -productVersion` |
| Xcode | 16 이상 (검증: 26.6) | `xcodebuild -version` |
| XcodeGen | 2.4x (검증: 2.46.0) | `xcodegen --version` |

XcodeGen 미설치 시:
```bash
brew install xcodegen
```

Command Line Tools만 있고 Xcode.app이 없으면 `xcodebuild`가 거부한다. Xcode 설치 후:
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

---

## 2. 빠른 설치

프로젝트 루트에서 아래를 그대로 실행한다. (스크립트: `scripts/install-local.sh`)

```bash
./scripts/install-local.sh
```

### GitHub Release의 dmg로 받았다면

[Releases](https://github.com/ilphs/UniFinder/releases)에서 받은 `.dmg`는 브라우저가 quarantine 표시를 붙이므로, 더블클릭으로 열어 UniFinder.app을 `/Applications`로 드래그한 뒤 **처음 실행 시 "Apple이 확인할 수 없음" 경고가 뜬다.** 소스 빌드(위 스크립트)에는 없는, dmg 다운로드에만 있는 문제다.

**우클릭 → 열기는 최신 macOS에서 통하지 않는다** — 이 경고 다이얼로그에는 "열기" 버튼 자체가 없다. 터미널에서 quarantine 표시를 지워야 한다:
```bash
xattr -dr com.apple.quarantine /Applications/UniFinder.app
```

---

## 3. 수동 설치 (단계별)

```bash
cd /path/to/UniFinder

# 1) Xcode 프로젝트 생성
xcodegen generate

# 2) Release 빌드 — 서명만 ad-hoc으로 오버라이드
xcodebuild -scheme UniFinder -configuration Release \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  DEVELOPMENT_TEAM="" \
  -derivedDataPath ./build-release \
  build

# 3) /Applications에 설치
rm -rf /Applications/UniFinder.app
cp -R ./build-release/Build/Products/Release/UniFinder.app /Applications/

# 4) 실행
open -a /Applications/UniFinder.app
```

### 왜 서명을 오버라이드하는가

`project.yml`의 Release 구성은 **배포용**이라 `Developer ID Application` 인증서를 요구한다. 인증서가 없는 머신에서는 이렇게 실패한다:

```
error: No signing certificate "Developer ID Application" found
```

로컬 사용 목적이면 서명만 ad-hoc(`-`)으로 바꾸면 된다. 최적화 수준(`-O`)은 Release 그대로 유지된다. **`project.yml`을 수정하지 말 것** — 수정하면 `ReleaseSigningConfigurationTests`가 실패하고, 실제 배포 시 서명이 빠진다.

인증서 보유 여부 확인:
```bash
security find-identity -v -p codesigning
```

---

## 4. FDA(전체 디스크 접근) 권한

파일 탐색기 특성상 홈 밖의 보호 영역을 탐색하려면 이 권한이 필요하다. **없어도 홈 디렉터리 대부분은 정상 동작**하며, 앱이 온보딩 시트로 안내한다([나중에] 선택 시 제한 모드로 계속 사용).

1. **시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근**
2. 목록에서 **UniFinder** 토글을 켠다 (없으면 `+` → `/Applications/UniFinder.app`)
3. **앱을 재시작**한다 — "종료 및 다시 열기" 다이얼로그가 뜨면 그것을 누르면 된다

딥링크로 바로 열기:
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

> ⚠️ **재빌드하면 FDA 승인이 리셋된다.** ad-hoc 서명은 빌드마다 서명 신원이 바뀌는데 macOS TCC 권한은 서명에 묶여 있다. 재설치 후에는 시스템 설정에서 기존 UniFinder 항목을 `−`로 **제거한 뒤 다시 추가**해야 한다.

---

## 5. 제거

```bash
# 앱 종료 후 삭제
osascript -e 'tell application "UniFinder" to quit' 2>/dev/null
rm -rf /Applications/UniFinder.app

# 설정 초기화 (선택 — 윈도우 크기·정렬 기준·숨김 표시 여부 등)
defaults delete com.unifinder.app 2>/dev/null

# 빌드 산출물 정리 (선택)
rm -rf ./build-release
```

시스템 설정 → 전체 디스크 접근에서도 UniFinder 항목을 `−`로 제거한다.

---

## 6. 개발자용

```bash
# Debug 빌드 (ad-hoc 서명이 기본값이라 오버라이드 불필요)
xcodegen generate && xcodebuild -scheme UniFinder build

# 단위·통합 테스트 (747개)
xcodebuild -scheme UniFinder -only-testing:UnitTests test

# UI 스모크 포함 전체
xcodebuild -scheme UniFinder test
```

UI 테스트는 **automation mode 인증**이 필요하다. 미승인 시 `Timed out while enabling automation mode`로 실패한다. Xcode에서 UI 테스트를 1회 실행해 승인하거나, 머신 전역 설정을 바꾸려면:
```bash
sudo automationmodetool enable-automationmode-without-authentication
```
(전역 보안 설정 변경이므로 필요성을 판단한 뒤 실행할 것)

성능 측정용 대량 fixture:
```bash
./tests/fixtures/generate.sh
```

---

## 7. 알려진 제약

| 항목 | 내용 |
|------|------|
| **서명** | ad-hoc. `spctl --assess`는 `rejected`로 나오지만 직접 빌드한 앱은 quarantine 속성이 없어 실행에 지장이 없다. 배포하려면 Developer ID 서명 + 공증이 필요하다 (m3-impl §6) |
| **undo 없음** | 파일 조작 되돌리기는 Phase 2. 복구 수단은 **휴지통 복원뿐**이다 |
| **D&D 수식키** | 같은 볼륨 드래그의 기본 동작은 **이동**이다. Option=복사 / Cmd=이동. 중요한 파일로 시도하기 전에 테스트 폴더에서 동작을 확인할 것 |
| **자동 갱신 범위** | 폴더 안의 파일 추가·삭제·이름변경은 자동 반영되지만, **기존 파일의 내용·크기·수정일 변경은 감지하지 않는다**. `Cmd+R`(또는 `F5`)로 새로고침 |
| **네트워크 볼륨** | MVP 비목표. SMB/AFP 등 네트워크 위치는 지원하지 않는다 |

---

## 8. 문제 해결

**앱이 실행되지 않음**
```bash
# 콘솔 로그 확인
log show --predicate 'process == "UniFinder"' --last 5m --info
```

**"Apple이 확인할 수 없음" / "손상되었기 때문에 열 수 없습니다" 경고**
직접 빌드한 앱에는 보통 발생하지 않는다(quarantine 없음). GitHub Release의 dmg로 받았거나 다른 경로로 복사해 quarantine이 붙은 경우 — §2 참조:
```bash
xattr -dr com.apple.quarantine /Applications/UniFinder.app
```

**빌드 실패 — `xcodebuild requires Xcode`**
Command Line Tools만 설치된 상태다. §1의 `xcode-select --switch`를 수행한다.

**보호된 폴더가 "접근 권한 없음"으로 표시됨**
FDA 권한 문제다. §4를 수행하되, **재빌드했다면 시스템 설정에서 기존 항목을 제거 후 다시 추가**해야 한다.

---

*최종 업데이트: 2026-08-14*
