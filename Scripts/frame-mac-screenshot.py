#!/usr/bin/env python3
"""给 Mac 窗口截图加上 MacBook 外壳。

用法：
    python3 Scripts/frame-mac-screenshot.py docs/assets/screenshots/mac-player.png ...
输出到 docs/assets/screenshots/framed/macbook-<名称>.png（名称去掉 mac- 前缀）。

    python3 Scripts/frame-mac-screenshot.py --frame-only docs/assets/screenshots/mac-player.png
只生成屏幕区域透明的外壳 framed/macbook-frame.png，供网页把录屏视频垫在下面。
需要 Pillow。
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

SS = 2  # 先按 2 倍绘制再缩小，让圆角边缘更平滑

# 以下尺寸为最终输出像素
SCREEN_W = 1440
BEZEL_SIDE = 20
BEZEL_TOP = 28
BEZEL_BOTTOM = 30
LID_RADIUS = 34
SCREEN_RADIUS = 16
BASE_EXTRA = 0.075  # 底座左右各比屏幕外沿多出的比例
BASE_H = 22
BASE_TOP_R = 8  # 底座两端上沿圆角
BASE_BOTTOM_R = 14  # 底座两端下沿圆角
BASE_TAPER = 10  # 底边比顶边每侧内收的像素
LIP_W = 230
LIP_H = 8

OUT_DIR = Path("docs/assets/screenshots/framed")


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return grad.resize((w, h))


def base_outline(w, h, rt, rb, taper, steps=40):
    """底座正面轮廓：两端侧面是一条连续弧线，上沿小圆角，下沿大圆角并向内收。

    每端由两段二次贝塞尔组成，在最外侧点处切线都竖直，所以衔接平滑。
    """
    bulge_y = h * 0.35  # 最外侧点的高度

    def quad(p0, c, p1):
        out = []
        for i in range(steps + 1):
            t = i / steps
            u = 1 - t
            out.append((u * u * p0[0] + 2 * u * t * c[0] + t * t * p1[0],
                        u * u * p0[1] + 2 * u * t * c[1] + t * t * p1[1]))
        return out

    # 右端：顶 -> 最外侧 -> 底
    right = quad((w - rt, 0), (w, 0), (w, bulge_y)) + quad(
        (w, bulge_y), (w, h), (w - taper - rb, h)
    )
    # 左端由右端镜像得到，并按逆向顺序接上
    left = [(w - x, y) for x, y in reversed(right)]
    return right + left


def frame(src: Path, hollow: bool = False) -> Path:
    """hollow=True 时屏幕区域留空（透明），供网页把视频垫在外壳下面。"""
    shot = Image.open(src).convert("RGBA")
    s = SS
    screen_w = SCREEN_W * s
    screen_h = round(shot.height * screen_w / shot.width)

    lid_w = screen_w + 2 * BEZEL_SIDE * s
    lid_h = screen_h + (BEZEL_TOP + BEZEL_BOTTOM) * s
    base_w = round(lid_w * (1 + 2 * BASE_EXTRA))
    base_h = BASE_H * s
    canvas_w = base_w
    canvas_h = lid_h + base_h
    lid_x = (canvas_w - lid_w) // 2

    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)

    # 屏幕外壳：外圈铝边 + 黑色边框
    d.rounded_rectangle(
        (lid_x, 0, lid_x + lid_w - 1, lid_h + LID_RADIUS * s),
        radius=LID_RADIUS * s,
        fill=(170, 172, 177, 255),
    )
    edge = 3 * s
    d.rounded_rectangle(
        (lid_x + edge, edge, lid_x + lid_w - 1 - edge, lid_h + LID_RADIUS * s),
        radius=(LID_RADIUS - 3) * s,
        fill=(12, 12, 14, 255),
    )

    # 摄像头
    cam_r = 4 * s
    cx, cy = canvas_w // 2, (BEZEL_TOP * s) // 2
    d.ellipse((cx - cam_r, cy - cam_r, cx + cam_r, cy + cam_r), fill=(32, 34, 40, 255))
    d.ellipse((cx - cam_r // 2, cy - cam_r // 2, cx + cam_r // 2, cy + cam_r // 2), fill=(52, 60, 80, 255))

    # 屏幕内容：截图本身带透明圆角，先铺黑底
    sx, sy = lid_x + BEZEL_SIDE * s, BEZEL_TOP * s
    screen_mask = Image.new("L", (screen_w, screen_h), 0)
    ImageDraw.Draw(screen_mask).rounded_rectangle(
        (0, 0, screen_w - 1, screen_h + SCREEN_RADIUS * s), radius=SCREEN_RADIUS * s, fill=255
    )
    screen = Image.new("RGBA", (screen_w, screen_h), (0, 0, 0, 255))
    screen.alpha_composite(shot.resize((screen_w, screen_h), Image.LANCZOS))
    canvas.paste(screen, (sx, sy), screen_mask)

    # 底座：正面看是一块两端圆润、底边略内收的铝合金薄板
    body_y = lid_h
    body_h = canvas_h - body_y
    body = vertical_gradient((base_w, body_h), (236, 237, 240, 255), (156, 158, 164, 255))
    # 顶面一道亮边，表现底座上表面
    ImageDraw.Draw(body).rectangle((0, 0, base_w, 2 * s), fill=(250, 250, 252, 255))
    # 下沿一道暗边，表现底部收进去的弧面
    edge_h = 5 * s
    body.alpha_composite(
        vertical_gradient((base_w, edge_h), (120, 122, 128, 0), (98, 100, 106, 255)),
        (0, body_h - edge_h),
    )
    body_mask = Image.new("L", (base_w, body_h), 0)
    ImageDraw.Draw(body_mask).polygon(
        base_outline(base_w, body_h, BASE_TOP_R * s, BASE_BOTTOM_R * s, BASE_TAPER * s), fill=255
    )
    canvas.paste(body, (0, body_y), body_mask)

    # 开盖凹槽
    lip_w, lip_h = LIP_W * s, LIP_H * s
    lx = (canvas_w - lip_w) // 2
    lip = vertical_gradient((lip_w, lip_h), (150, 152, 158, 255), (210, 211, 215, 255))
    lip_mask = Image.new("L", (lip_w, lip_h), 0)
    ImageDraw.Draw(lip_mask).rounded_rectangle(
        (0, -lip_h, lip_w - 1, lip_h - 1), radius=lip_h, fill=255
    )
    canvas.paste(lip, (lx, body_y), lip_mask)

    if hollow:
        canvas.paste((0, 0, 0, 0), (sx, sy, sx + screen_w, sy + screen_h), screen_mask)

    out = canvas.resize((canvas_w // s, canvas_h // s), Image.LANCZOS)
    if hollow:
        dest = OUT_DIR / "macbook-frame.png"
        # 屏幕区域在输出图中的位置，网页按百分比定位视频
        print(f"screen rect: x={sx // s} y={sy // s} w={screen_w // s} h={screen_h // s}"
              f" canvas={out.width}x{out.height}")
    else:
        name = src.stem.removeprefix("mac-")
        dest = OUT_DIR / f"macbook-{name}.png"
    out.save(dest, optimize=True)
    return dest


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    args = sys.argv[1:]
    if args[0] == "--frame-only":
        # 只要外壳：用任一张 Mac 截图确定屏幕比例
        print(frame(Path(args[1]), hollow=True))
    else:
        for arg in args:
            print(frame(Path(arg)))
