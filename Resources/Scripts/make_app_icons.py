#!/usr/bin/env python3
"""从品牌源图生成 App 图标（全部尺寸）.

源图：`Resources/brand_tequila.png`（1958x1648，用户提供的水彩渐变底 + 白色手写 TequilaDash）

## 三个关键决定

1. **不补边，只裁方** —— 源图背景是四角不同色的高饱和水彩渐变（实测四角
   (253,194,214) / (195,231,255) / (223,189,239) / (249,198,213)），用任一角像素补到
   正方形会在上下或左右留下一条死板色带，比裁掉内容更难看。所以画布边长取
   `min(W, H)`，只在源图内部裁方。
2. **裁剪中心 = 字标中心，不是图像中心** —— 高饱和阈值选不出字标（渐变本身
   sat>90 的地方成片，bbox 会跑到 y=0 的背景上）；实测可靠判据是**白字**：
   `min(RGB)>232 且 max-min<26` → bbox (366,724,1602,996)。
3. **不做透明背景** —— iOS 不允许 App 图标带 alpha（透明区渲染成黑色），输出 RGB PNG。

字标在 1648 画布里占 75% 宽，左右各留 12.5% —— 手写体被 squircle 圆角切掉的是
纯背景，不伤字。尺寸列表从**现有文件名**推导，不写死，避免以后加尺寸漏改。
预览图输出到系统临时目录，不污染仓库。
"""

import glob
import os
import struct
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
RES_DIR = os.path.dirname(HERE)                       # .../Resources
ICON_DIR = RES_DIR                                    # AppIcon*.png 就在 Resources 下
SRC = os.path.join(RES_DIR, "brand_tequila.png")
WHITE_MIN = 232          # 白字判据：三通道最小值下限
WHITE_SAT_MAX = 26       # 白字判据：饱和度上限（排除渐变背景）
TARGET_FILL = 0.75       # 字标宽度 / 画布边长
STEP = 2                 # bbox 探测采样步长（像素）


def existing_sizes():
    """{文件名: 边长} —— 从现有 AppIcon*.png 推导，非正方形跳过."""
    out = {}
    for path in sorted(glob.glob(os.path.join(ICON_DIR, "AppIcon*.png"))):
        with open(path, "rb") as fh:
            head = fh.read(26)
        w, h = struct.unpack(">II", head[16:24])
        if w != h:
            print("  ! %s 不是正方形（%dx%d），跳过" % (os.path.basename(path), w, h))
            continue
        out[os.path.basename(path)] = w
    return out


def wordmark_bbox(im):
    """白字 bbox (left, top, right, bottom) —— 自动探测，换图不用改代码."""
    px = im.load()
    xs, ys = [], []
    for y in range(0, im.height, STEP):
        for x in range(0, im.width, STEP):
            p = px[x, y]
            if min(p) > WHITE_MIN and (max(p) - min(p)) < WHITE_SAT_MAX:
                xs.append(x)
                ys.append(y)
    if len(xs) < 200:
        raise SystemExit("白字像素只有 %d 个 —— 判据或源图不对，拒绝出图" % len(xs))
    return min(xs), min(ys), max(xs), max(ys)


def build_master():
    im = Image.open(SRC).convert("RGB")
    x0, y0, x1, y1 = wordmark_bbox(im)
    cw, ch = x1 - x0, y1 - y0
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    side = min(im.width, im.height)
    left = max(0, min(im.width - side, cx - side // 2))
    top = max(0, min(im.height - side, cy - side // 2))
    box = (left, top, left + side, top + side)
    fill = cw / side
    print("源图 %dx%d  字标 bbox=(%d,%d,%d,%d) w=%d h=%d" % (im.width, im.height, x0, y0, x1, y1, cw, ch))
    print("画布 %d 裁剪框=%s  字标占比 %.3f" % (side, box, fill))
    if fill > 0.80:
        print("  ! 字标占比超过 0.80，squircle 圆角可能吃掉笔画末端")
    return im.crop(box).resize((1024, 1024), Image.LANCZOS)


def main():
    sizes = existing_sizes()
    if not sizes:
        print("没找到现有 AppIcon*.png —— 确认 ICON_DIR=%s" % ICON_DIR)
        return 1

    master = build_master()
    out_dir = tempfile.gettempdir()
    master.save(os.path.join(out_dir, "icon_master.png"))

    for name, size in sizes.items():
        master.resize((size, size), Image.LANCZOS).convert("RGB").save(
            os.path.join(ICON_DIR, name), optimize=True)
        print("  + %-26s %dx%d" % (name, size, size))

    sheet = Image.new("RGB", (1024 + 3 * 190 + 48, 1024 + 32), (255, 255, 255))
    sheet.paste(master, (16, 16))
    xx = 1024 + 26
    for s in (180, 120, 76):
        sheet.paste(master.resize((s, s), Image.LANCZOS), (xx, 16 + (180 - s) // 2))
        xx += s + 12
    preview = os.path.join(out_dir, "icon_preview_sheet.png")
    sheet.save(preview)
    print("共 %d 个尺寸；预览：%s" % (len(sizes), preview))
    return 0


if __name__ == "__main__":
    sys.exit(main())
