#!/usr/bin/env python3
"""
아이콘 팔레트 보정 — UniNotepad 패밀리 룩에 맞춘다.

두 아이콘의 색상(Hue)은 이미 거의 일치한다(cyan ~193°, purple ~270°).
결정적 차이는 배경이다:
    UniNotepad  RGB(12,12,14)  매끈한 검정 + 미묘한 테두리
    UniFinder   RGB(88,89,94)  밝은 회색 + 방사형 그라디언트/노이즈

단순히 명도만 낮추면 배경 노이즈가 상대적으로 증폭돼 네온 주변이 지저분해진다.
그래서 **발광 성분만 분리해 새 배경에 합성**한다:

    발광 = clamp(원본 - 배경추정)      ← 네온과 글로우만 남음
    결과 = 새배경(균일한 검정) + 발광   ← additive 합성

배경 추정은 네온 마스크를 제외한 영역을 크게 블러해 방사형 그라디언트까지
따라가게 한다. Hue를 전혀 건드리지 않으므로 패밀리 룩이 유지된다.

사용법:
    python3 scripts/tune-icon-palette.py <입력.png> <출력.png>
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

# --- 목표값 (UniNotepad 실측) ------------------------------------------------
BG_COLOR = np.array([12, 12, 14]) / 255.0   # 새 배경색
EDGE_COLOR = np.array([58, 58, 64]) / 255.0 # 테두리 (형태 인지용)
EDGE_PX = 3                                  # 테두리 두께
NEON_GAIN = 1.15                             # 발광 성분 부스트
GLOW_RADIUS = 55                             # 네온 글로우 반경 (마스크 블러)
SAT_GAIN = 1.10                              # 발광 채도 강화


def smoothstep(x, lo, hi):
    t = np.clip((x - lo) / (hi - lo), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def rgb_to_hsv_np(rgb):
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn
    s = np.where(mx > 0, d / np.maximum(mx, 1e-9), 0.0)
    return s, mx


def main(src, dst):
    im = Image.open(src).convert('RGBA')
    arr = np.asarray(im).astype(np.float64) / 255.0
    rgb, alpha = arr[..., :3], arr[..., 3]
    opaque = alpha > 0.5

    # 1) 네온 마스크 — 채도가 있거나 주변보다 밝은 영역
    sat, val = rgb_to_hsv_np(rgb)
    bg_val = np.median(val[opaque & (sat < 0.12)])
    neon_mask = (sat > 0.15) | (val > bg_val * 1.12)

    # 2) 배경 추정 — 네온을 제외하고 크게 블러해 방사형 그라디언트를 따라감
    filled = rgb.copy()
    bg_flat = np.array([np.median(rgb[..., c][opaque & ~neon_mask]) for c in range(3)])
    filled[neon_mask] = bg_flat
    bg_img = Image.fromarray((np.clip(filled, 0, 1) * 255).astype(np.uint8))
    bg_est = np.asarray(bg_img.filter(ImageFilter.GaussianBlur(48))).astype(np.float64) / 255.0

    # 3) 발광 성분만 분리 (배경보다 밝은 부분)
    glow = np.clip(rgb - bg_est, 0.0, 1.0) * NEON_GAIN

    # 발광의 채도 강화 — 회색기를 빼서 네온을 더 선명하게
    gmax = glow.max(-1, keepdims=True)
    gmin = glow.min(-1, keepdims=True)
    glow = np.clip(gmax - (gmax - glow) * SAT_GAIN, 0.0, 1.0)
    glow = np.where(gmax > 1e-6, glow, 0.0)
    glow = np.clip(glow - gmin * (SAT_GAIN - 1.0) * 0.5, 0.0, 1.0)

    # 배경 잔재 제거 — 원본의 방사형 그라디언트/노이즈가 blur 추정에서 완전히
    # 지워지지 않아 회색 얼룩으로 남는다.
    #
    # 픽셀별 임계값(채도/휘도 컷)으로 걸러내면 원본 노이즈가 컷 경계에 몰려
    # 밴딩(줄무늬)이 생긴다. 그래서 **네온 코어를 마스크로 잡고 크게 블러해
    # 글로우 반경을 정의**한 뒤 그 마스크로 감쇠한다. 마스크가 연속적이라
    # 경계가 부드럽고, 네온에서 먼 배경은 완전히 0이 된다.
    core = ((sat > 0.25) & (val > 0.35)).astype(np.float64)
    core_img = Image.fromarray((core * 255).astype(np.uint8), 'L')
    reach = np.asarray(core_img.filter(ImageFilter.GaussianBlur(GLOW_RADIUS))).astype(np.float64) / 255.0
    reach = np.clip(reach / max(float(reach.max()), 1e-6) * 3.0, 0.0, 1.0)  # 글로우 꼬리까지 살림
    glow = glow * np.maximum(reach, core)[..., None]

    # 4) 새 배경 (균일한 검정) + 테두리로 둥근 사각형 형태를 인지시킴
    shape = (alpha > 0.5).astype(np.uint8) * 255
    shape_img = Image.fromarray(shape, 'L')
    inner = np.asarray(shape_img.filter(ImageFilter.MinFilter(EDGE_PX * 2 + 1))).astype(np.float64) / 255.0
    edge = np.clip((alpha > 0.5).astype(np.float64) - inner, 0.0, 1.0)[..., None]

    base = np.broadcast_to(BG_COLOR, rgb.shape).copy()
    base = base * (1 - edge) + EDGE_COLOR * edge

    # 5) additive 합성
    out_rgb = np.clip(base + glow, 0.0, 1.0)
    out_rgb[~opaque] = 0.0

    out = np.concatenate([out_rgb, alpha[..., None]], -1)
    Image.fromarray((out * 255).round().astype(np.uint8), 'RGBA').save(dst)

    # 검증
    inner_bg = opaque & ~neon_mask & (edge[..., 0] < 0.5)
    print(f"  원본 배경 추정   : {tuple((bg_flat*255).round().astype(int))}")
    print(f"  결과 배경 평균   : {tuple((out_rgb[inner_bg].mean(0)*255).round().astype(int))}")
    nm = opaque & (sat > 0.5) & (val > 0.6)
    if nm.any():
        print(f"  네온 평균 RGB    : {tuple((rgb[nm].mean(0)*255).round().astype(int))}"
              f" -> {tuple((out_rgb[nm].mean(0)*255).round().astype(int))}")
    print(f"  저장             : {dst}")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
