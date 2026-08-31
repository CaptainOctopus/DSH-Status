#!/usr/bin/env python3
"""生成 DSH Status 应用图标（1024x1024）。

设计：macOS 风格 squircle（连续曲率圆角方形）
  - 深蓝紫垂直渐变背景 + 顶部高光
  - 中央一条发光的「脉冲波形」（活动/监控隐喻）
  - 下方三个绿色状态点（服务 healthy）
输出：icon_1024.png（源图），后续由 iconutil 转 .icns。
"""
from PIL import Image, ImageDraw, ImageFilter

S = 1024
R = 232  # squircle 圆角半径（macOS 图标约 22.6%）

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# ---------- 1. 背景：垂直渐变 squircle ----------
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

top = (99, 110, 225)     # #636EE1 亮靛蓝
mid = (58, 50, 148)      # #3A3294
bottom = (25, 25, 66)    # #191942 深藏青

def bg_color(t):
    if t < 0.5:
        return lerp(top, mid, t / 0.5)
    return lerp(mid, bottom, (t - 0.5) / 0.5)

bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bg)
for y in range(S):
    bd.line([(0, y), (S, y)], fill=bg_color(y / (S - 1)) + (255,))

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=R, fill=255)
img.paste(bg, (0, 0), mask)

# 顶部高光（增强立体感）
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
for y in range(int(S * 0.45)):
    a = int(30 * (1 - y / (S * 0.45)))
    hd.line([(0, y), (S, y)], fill=(255, 255, 255, a))
img.alpha_composite(hl)       # 用 alpha 合成（paste 会盖掉 bg 渐变）

# ---------- 2. 波形：发光青蓝折线 ----------
wave = Image.new("RGBA", (S, S), (0, 0, 0, 0))
wd = ImageDraw.Draw(wave)
pts = [(150, 540), (350, 540), (410, 330), (470, 640), (500, 540),
       (660, 540), (700, 440), (730, 540), (880, 540)]
COLOR = (125, 226, 255)   # #7DE2FF 亮青
wd.line(pts, fill=COLOR + (255,), width=32, joint="curve")

glow = wave.filter(ImageFilter.GaussianBlur(16))
img.alpha_composite(glow)
img.alpha_composite(glow)
img.alpha_composite(wave)

# 发光核心：中心一条更亮的细白线
core = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(core).line(pts, fill=(240, 250, 255, 255), width=10, joint="curve")
img.alpha_composite(core)

# ---------- 3. 三个状态点（绿色，居中偏下）----------
dot = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dd = ImageDraw.Draw(dot)
GREEN = (86, 224, 140)
for cx in (410, 512, 614):
    dd.ellipse([cx - 24, 680 - 24, cx + 24, 680 + 24], fill=GREEN + (255,))
img.alpha_composite(dot)

# 圆点顶部高光
dhl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dh = ImageDraw.Draw(dhl)
for cx in (410, 512, 614):
    dh.ellipse([cx - 9, 680 - 30, cx + 9, 680 - 12], fill=(220, 255, 235, 160))
img.alpha_composite(dhl)

img.save("icon_1024.png")
print("saved icon_1024.png", img.size)
