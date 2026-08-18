#!/usr/bin/env python3
"""
아이콘 글리프 평탄화 — 네온 외곽선을 없애고 'f'를 단색 그라디언트로 채운다.

입력은 tune-icon-palette.py를 거친 아이콘(검정 배경 + 네온 외곽선)이다.
목표는 UniNotepad 아이콘과 **한 패밀리로 보이는 것**이라, 색·그라디언트·획
두께를 모두 그 아이콘 실측값에 맞춘다.

    1. 외곽선(밝은 획) 마스크를 잡고, 바깥에서 flood fill 해 닫힌 내부를 구한다
       → 획 ∪ 내부 = 채워진 'f' 실루엣
    2. 실루엣을 침식해 획을 얇게 만든 뒤, 줄어든 만큼 다시 확대해
       **세로 길이는 유지한 채 획 두께만** STROKE_PX 로 맞춘다
    3. 시안→보라 선형 그라디언트로 채우고, 레퍼런스에서 측정한 감쇠 곡선대로
       네온 글로우를 additive 합성한다 (획 자체는 코어 없이 평탄한 단색)

사용법:
    python3 scripts/flatten-icon-glyph.py <입력.png> <출력.png> [획두께px]
"""
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# --- 배경 (tune-icon-palette.py와 동일) ---------------------------------------
BG_COLOR = np.array([12, 12, 14]) / 255.0
EDGE_COLOR = np.array([58, 58, 64]) / 255.0
EDGE_PX = 3

# --- 글리프 (UniNotepad 아이콘 실측값) ----------------------------------------
COLOR_TOP = np.array([91, 180, 214]) / 255.0     # 시안 — 네온 튜브 몸통 색
COLOR_BOTTOM = np.array([151, 80, 202]) / 255.0  # 보라
STROKE_PX = 48        # 목표 획 두께 (레퍼런스 튜브 35px + 글로우까지의 체감 두께)

# 네온 글로우 — 레퍼런스의 감쇠 프로파일(획 가장자리로부터의 수직거리별 초과
# 휘도)을 3중 가우시안으로 최소제곱 피팅한 값. RMSE 0.0035.
GLOW_SIGMA = (10.0, 14.0, 34.0)
GLOW_WEIGHT = (0.269, 0.635, 0.096)   # 합 1.0
GLOW_GAIN = 1.43      # 획 밝기 대비 가장자리 글로우 세기 (레퍼런스 0.50/0.699)
SCALE = 1.00          # 글리프 전체 배율 (1.0 = 원본 크기)

STROKE_TH = 0.30      # 외곽선으로 볼 휘도 임계값
SMOOTH_PX = 3.2       # 실루엣 윤곽 정리 반경 (임계 노이즈/작은 돌기 제거)
ERODE_STEP = 4        # 침식 1회당 반경 — 큰 반경은 여러 번 나눠 적용


def filled_silhouette(lum):
    """밝은 외곽선을 닫힌 도형으로 채운 bool 마스크."""
    stroke = lum > STROKE_TH
    canvas = Image.fromarray(((~stroke) * 255).astype(np.uint8), 'L').copy()
    ImageDraw.floodfill(canvas, (0, 0), 1)          # 바깥 배경만 1로
    outside = np.asarray(canvas) == 1
    return stroke | ~(stroke | outside)


def erode(mask, radius):
    """원형 커널 침식. 반경이 크면 작은 원반을 반복 적용해 비용을 낮춘다."""
    steps = []
    left = float(radius)
    while left > 1e-6:
        steps.append(min(ERODE_STEP, left))
        left -= steps[-1]

    out = mask
    for r in steps:
        acc = out
        ri = int(np.ceil(r))
        for dy in range(-ri, ri + 1):
            for dx in range(-ri, ri + 1):
                if dx * dx + dy * dy > r * r:
                    continue
                acc = np.minimum(acc, np.roll(np.roll(out, dy, axis=0), dx, axis=1))
        out = acc
    return out


def stroke_width(mask):
    """획 두께 추정 — 가로줄이 한 덩어리로만 잡히는 행(세로 획)의 중앙값."""
    widths = []
    for row in (mask > 0.5):
        d = np.diff(np.concatenate([[0], row.astype(np.int8), [0]]))
        starts, ends = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
        if len(starts) == 1:
            widths.append(ends[0] - starts[0])
    return float(np.median(widths)) if widths else 0.0


def place(mask, scale, box):
    """mask 를 scale 배 하고, 원래 bbox 중심에 다시 맞춰 놓는다."""
    h, w = mask.shape
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).round().astype(np.uint8), 'L')
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    small = np.asarray(img.resize((nw, nh), Image.LANCZOS)).astype(np.float64) / 255.0

    ys, xs = np.nonzero(small > 0.5)
    cx, cy = (xs.min() + xs.max()) / 2.0, (ys.min() + ys.max()) / 2.0
    tx, ty = (box[0] + box[2] - 1) / 2.0, (box[1] + box[3] - 1) / 2.0

    out = np.zeros((h, w))
    ox, oy = int(round(tx - cx)), int(round(ty - cy))
    sx0, sy0 = max(0, -ox), max(0, -oy)
    dx0, dy0 = max(0, ox), max(0, oy)
    cw, ch = min(nw - sx0, w - dx0), min(nh - sy0, h - dy0)
    out[dy0:dy0 + ch, dx0:dx0 + cw] = small[sy0:sy0 + ch, sx0:sx0 + cw]
    return out


def main(src, dst, target_stroke):
    im = Image.open(src).convert('RGBA')
    arr = np.asarray(im).astype(np.float64) / 255.0
    rgb, alpha = arr[..., :3], arr[..., 3]
    h, w = alpha.shape

    glyph = filled_silhouette(rgb.mean(-1))
    ys, xs = np.nonzero(glyph)
    box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    height0 = box[3] - box[1]

    # 임계값 노이즈로 생긴 들쭉날쭉한 윤곽을 다듬는다
    soft = Image.fromarray((glyph * 255).astype(np.uint8), 'L').filter(
        ImageFilter.GaussianBlur(SMOOTH_PX))
    soft = np.clip((np.asarray(soft).astype(np.float64) / 255.0 - 0.5)
                   * (2.4 * SMOOTH_PX) + 0.5, 0, 1)
    stroke0 = stroke_width(soft)

    # 침식으로 얇게 → 줄어든 세로 길이만큼 재확대 = 두께만 목표치로 바뀐다
    #   (T0-2r)*H0/(H0-2r) = T*  =>  r = H0(T0-T*) / (2(H0-T*))
    radius = height0 * (stroke0 - target_stroke) / (2 * (height0 - target_stroke))
    radius = max(0.0, radius)
    regrow = height0 / max(height0 - 2 * radius, 1.0)
    mask = place(erode(soft, radius), regrow * SCALE, box)

    # 그라디언트 — 글리프 세로 범위에 시안→보라 선형 보간
    ys2, xs2 = np.nonzero(mask > 0.5)
    top, bottom = ys2.min(), ys2.max()
    t = np.clip((np.arange(h) - top) / max(bottom - top, 1), 0.0, 1.0)[:, None, None]
    fill = COLOR_TOP + (COLOR_BOTTOM - COLOR_TOP) * t

    base = np.broadcast_to(BG_COLOR, rgb.shape).copy()
    shape = Image.fromarray(((alpha > 0.5) * 255).astype(np.uint8), 'L')
    inner = np.asarray(shape.filter(ImageFilter.MinFilter(EDGE_PX * 2 + 1))).astype(np.float64) / 255.0
    edge = np.clip((alpha > 0.5).astype(np.float64) - inner, 0.0, 1.0)[..., None]
    base = base * (1 - edge) + EDGE_COLOR * edge

    # 글로우 — 색이 곱해진 글리프를 여러 반경으로 흐려 additive 합성
    m = (mask * (alpha > 0.5))[..., None]
    premult = fill * m
    glow = np.zeros_like(premult)
    for sigma, weight in zip(GLOW_SIGMA, GLOW_WEIGHT):
        blurred = Image.fromarray((np.clip(premult, 0, 1) * 255).round().astype(np.uint8), 'RGB')
        blurred = blurred.filter(ImageFilter.GaussianBlur(sigma))
        glow += weight * np.asarray(blurred).astype(np.float64) / 255.0
    glow *= GLOW_GAIN

    out_rgb = np.clip(base + glow, 0.0, 1.0)
    out_rgb = np.clip(out_rgb * (1 - m) + fill * m, 0.0, 1.0)
    out_rgb[alpha <= 0.5] = 0.0

    out = np.concatenate([out_rgb, alpha[..., None]], -1)
    Image.fromarray((out * 255).round().astype(np.uint8), 'RGBA').save(dst)

    print(f"  획 두께          : {stroke0:.0f}px -> {stroke_width(mask):.0f}px "
          f"(목표 {target_stroke}, 침식 {radius:.1f} + 재확대 x{regrow:.3f})")
    print(f"  글리프 박스      : {box[2]-box[0]}x{height0} -> "
          f"{xs2.max()-xs2.min()+1}x{bottom-top+1}")
    print(f"  그라디언트       : {tuple((COLOR_TOP*255).round().astype(int))} -> "
          f"{tuple((COLOR_BOTTOM*255).round().astype(int))}")
    print(f"  글로우           : sigma {GLOW_SIGMA} 가중 {GLOW_WEIGHT} x{GLOW_GAIN}")
    print(f"  저장             : {dst}")


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2],
         float(sys.argv[3]) if len(sys.argv) == 4 else STROKE_PX)
