#!/usr/bin/env bash
#
# 앱 아이콘 생성 — 원본 이미지 → resources/UniFinder.icns
#
# 사용법:
#   ./scripts/make-icon.sh [원본이미지.png]
#   (인자 생략 시 resources/icon-source.png 사용)
#
# 처리 과정:
#   1. 바깥 배경을 투명화 (flood fill — 아이콘 내부의 밝은 색은 보존)
#   2. macOS 표준 그리드로 정규화 (1024 캔버스 안에 824 아이콘, 여백 100)
#   3. 팔레트 보정 + 글리프 평탄화 (NO_TUNE=1로 건너뜀)
#   4. .iconset 10종 생성 → .icns 컴파일 + 에셋 카탈로그 동기화
#
# 배경이 이미 투명한 PNG를 넣으면 1단계는 아무 영향이 없다.

set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-resources/icon-source.png}"
OUT_ICNS="resources/UniFinder.icns"
NORMALIZED="resources/icon-1024.png"
ICONSET="resources/UniFinder.iconset"
APPICONSET="resources/Assets.xcassets/AppIcon.appiconset"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

[ -f "$SRC" ] || fail "원본 이미지를 찾을 수 없습니다: $SRC"
command -v iconutil >/dev/null || fail "iconutil이 필요합니다 (Xcode Command Line Tools)."
python3 -c "import PIL" 2>/dev/null || fail "Pillow가 필요합니다: python3 -m pip install Pillow"

mkdir -p resources

info "배경 투명화 + macOS 그리드 정규화 ($SRC)"
python3 - "$SRC" "$NORMALIZED" <<'PY'
from PIL import Image, ImageDraw
import sys

src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGBA')
w, h = im.size

# 1) 네 모서리에서 flood fill — 바깥에서 연결된 배경만 투명화한다.
#    아이콘 내부의 밝은 영역(네온 등)은 바깥과 연결되지 않아 보존된다.
for seed in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    if im.getpixel(seed)[3] > 0:            # 이미 투명하면 건너뜀
        ImageDraw.floodfill(im, seed, (0, 0, 0, 0), thresh=30)

# 2) 콘텐츠만 크롭 → 정사각 보정 → macOS 표준 그리드에 배치
bbox = im.getbbox()
if bbox is None:
    raise SystemExit('이미지에 불투명 픽셀이 없습니다.')
content = im.crop(bbox)
cw, ch = content.size
side = max(cw, ch)
square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
square.paste(content, ((side - cw) // 2, (side - ch) // 2))

CANVAS, ICON = 1024, 824                     # Apple macOS app icon 그리드
canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
off = (CANVAS - ICON) // 2
canvas.paste(square.resize((ICON, ICON), Image.LANCZOS), (off, off))
canvas.save(dst)

print(f'    콘텐츠 {cw}x{ch} -> 정사각 {side} -> 아이콘 {ICON} @ 캔버스 {CANVAS} (여백 {off})')
PY

# --- 팔레트 보정 (UniNotepad 패밀리 룩) -------------------------------------
# NO_TUNE=1 을 주면 건너뛴다.
if [ "${NO_TUNE:-0}" = "1" ]; then
    info "팔레트 보정 건너뜀 (NO_TUNE=1)"
else
    info "팔레트 보정 — 배경을 검정으로, 네온을 선명하게"
    TUNED="resources/icon-1024-tuned.png"
    python3 scripts/tune-icon-palette.py "$NORMALIZED" "$TUNED" | sed 's/^/  /'
    mv "$TUNED" "$NORMALIZED"

    info "글리프 평탄화 — 네온 외곽선 제거, 'f'를 그라디언트로 채움"
    FLAT="resources/icon-1024-flat.png"
    python3 scripts/flatten-icon-glyph.py "$NORMALIZED" "$FLAT" | sed 's/^/  /'
    mv "$FLAT" "$NORMALIZED"
fi

info "iconset 생성 (10종)"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
sips -z 16   16   "$NORMALIZED" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$NORMALIZED" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$NORMALIZED" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$NORMALIZED" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$NORMALIZED" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$NORMALIZED" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$NORMALIZED" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$NORMALIZED" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$NORMALIZED" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$NORMALIZED" "$ICONSET/icon_512x512@2x.png"

info "icns 컴파일"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

info "에셋 카탈로그 동기화 ($APPICONSET)"
cp "$ICONSET"/icon_*.png "$APPICONSET/"

printf '\033[1;34m==>\033[0m 완료: %s (%s)\n' "$OUT_ICNS" "$(du -h "$OUT_ICNS" | cut -f1)"
echo
echo "    반영하려면 재빌드가 필요합니다:"
echo "      ./scripts/install-local.sh"
echo
echo "    Dock/Finder 아이콘 캐시가 남아 옛 아이콘이 보이면:"
echo "      touch /Applications/UniFinder.app && killall Dock"
