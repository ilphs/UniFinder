#!/usr/bin/env bash
#
# UniFinder 로컬 설치 스크립트
#
# Release 구성(최적화 빌드)으로 빌드하되 서명만 ad-hoc으로 오버라이드해
# /Applications에 설치한다. Developer ID 인증서가 없는 개발 머신에서
# 로컬 사용을 목적으로 할 때 쓴다.
#
# project.yml의 Release 서명 설정은 배포용이므로 건드리지 않는다
# (수정하면 ReleaseSigningConfigurationTests가 실패하고 실제 배포 시 서명이 빠진다).
#
# 배포용 서명·공증 절차: ref-docs/specs/impl/unifinder-m3-impl.md §6
# 상세 안내: INSTALL.md

set -euo pipefail

APP_NAME="UniFinder"
BUNDLE_ID="com.unifinder.app"
BUILD_DIR="./build-release"
INSTALL_DIR="/Applications"
PRODUCT="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

cd "$(dirname "$0")/.."

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

# --- 사전 확인 -------------------------------------------------------------

info "요구사항 확인"

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 미설치. 'brew install xcodegen' 후 다시 실행하세요."

if ! xcodebuild -version >/dev/null 2>&1; then
    fail "xcodebuild를 사용할 수 없습니다. Xcode.app 설치 후 다음을 실행하세요:
    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license accept"
fi

printf '    macOS    %s\n' "$(sw_vers -productVersion)"
printf '    Xcode    %s\n' "$(xcodebuild -version | head -1 | cut -d' ' -f2)"
printf '    xcodegen %s\n' "$(xcodegen --version | awk '{print $NF}')"

# --- 빌드 ------------------------------------------------------------------

info "Xcode 프로젝트 생성"
xcodegen generate >/dev/null

info "Release 빌드 (서명은 ad-hoc으로 오버라이드)"
xcodebuild -scheme "$APP_NAME" -configuration Release \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=NO \
    DEVELOPMENT_TEAM="" \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | tail -1

[ -d "$PRODUCT" ] || fail "빌드 산출물을 찾을 수 없습니다: $PRODUCT"

# --- 설치 ------------------------------------------------------------------

TARGET="${INSTALL_DIR}/${APP_NAME}.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    info "실행 중인 ${APP_NAME} 종료"
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep 2
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

if [ -e "$TARGET" ]; then
    info "기존 설치본 교체: $TARGET"
    REINSTALL=1
    rm -rf "$TARGET"
else
    info "신규 설치: $TARGET"
    REINSTALL=0
fi

cp -R "$PRODUCT" "$INSTALL_DIR/"

info "설치 완료"
printf '    경로   %s\n' "$TARGET"
printf '    크기   %s\n' "$(du -sh "$TARGET" | cut -f1)"
printf '    아키텍처 %s\n' "$(lipo -info "${TARGET}/Contents/MacOS/${APP_NAME}" 2>/dev/null | sed 's/.*are: //')"
printf '    서명   %s\n' "$(codesign -dv "$TARGET" 2>&1 | grep '^Signature' | cut -d= -f2)"

# --- 안내 ------------------------------------------------------------------

echo
info "다음 단계 — 전체 디스크 접근(FDA) 권한"
cat <<'GUIDE'
    파일 탐색기 특성상 홈 밖의 보호 영역을 탐색하려면 FDA 권한이 필요합니다.
    (없어도 홈 디렉터리 대부분은 정상 동작하며, 앱이 온보딩 시트로 안내합니다)

    1. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근
    2. UniFinder 토글을 켬 (목록에 없으면 + 로 /Applications/UniFinder.app 추가)
    3. 앱 재시작 ("종료 및 다시 열기" 다이얼로그가 뜨면 그것을 클릭)

    설정 화면 바로 열기:
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
GUIDE

if [ "$REINSTALL" = "1" ]; then
    echo
    warn "재설치했으므로 FDA 승인이 초기화됩니다."
    warn "ad-hoc 서명은 빌드마다 서명 신원이 바뀌고 TCC 권한은 서명에 묶여 있습니다."
    warn "시스템 설정에서 기존 UniFinder 항목을 '−'로 제거한 뒤 다시 추가하세요."
fi

echo
info "실행: open -a ${APP_NAME}"
