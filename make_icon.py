#!/usr/bin/env python3
"""画 nvpeek 的 App 图标：macOS 风格圆角方块 + GPU 卡片 + 显存条 + 状态点。
生成 AppIcon 母版 1024px，macOS 系统会自动缩放出各尺寸。"""
from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# ---- 1. macOS 圆角方块底座（超椭圆近似），带垂直渐变 ----
def rounded_base(draw_mask_size=SIZE, radius_ratio=0.2237):
    """macOS Big Sur 图标圆角比例约 0.2237"""
    radius = int(draw_mask_size * radius_ratio)
    mask = Image.new("L", (draw_mask_size, draw_mask_size), 0)
    m = ImageDraw.Draw(mask)
    m.rounded_rectangle([0, 0, draw_mask_size - 1, draw_mask_size - 1],
                        radius=radius, fill=255)
    return mask

base_mask = rounded_base()

# 渐变底色：上深蓝黑 -> 下近黑，像深夜机房
grad = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd = ImageDraw.Draw(grad)
top = (30, 36, 52)
bottom = (14, 16, 24)
for y in range(SIZE):
    t = y / SIZE
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    gd.line([(0, y), (SIZE, y)], fill=c + (255,))

img.paste(grad, (0, 0), base_mask)

# ---- 2. 内边高光，营造玻璃质感 ----
d = ImageDraw.Draw(img)
hl = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
r = int(SIZE * 0.2237)
# 顶部内描边高光
hd.rounded_rectangle([10, 10, SIZE - 11, SIZE - 11], radius=r - 6,
                     outline=(255, 255, 255, 60), width=6)
# 底部内描边暗边
hd2 = ImageDraw.Draw(hl)
hd2.rounded_rectangle([10, SIZE - 24, SIZE - 11, SIZE - 14], radius=8,
                      outline=(0, 0, 0, 60), width=6)
img.alpha_composite(hl)

# ---- 3. GPU 卡片主体（居中的大芯片） ----
cx, cy = SIZE // 2, SIZE // 2 + 40
card_w, card_h = 640, 380
card = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
cd = ImageDraw.Draw(card)
cr = 56
# 卡片带轻微渐变：石墨色
card_top = (58, 66, 88)
card_bottom = (38, 44, 62)
card_grad = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
cgd = ImageDraw.Draw(card_grad)
for y in range(card_h):
    t = y / card_h
    c = tuple(int(card_top[i] + (card_bottom[i] - card_top[i]) * t) for i in range(3))
    cgd.line([(0, y), (card_w, y)], fill=c + (255,))
card_mask = Image.new("L", (card_w, card_h), 0)
ImageDraw.Draw(card_mask).rounded_rectangle([0, 0, card_w - 1, card_h - 1],
                                            radius=cr, fill=255)
img.paste(card_grad, (cx - card_w // 2, cy - card_h // 2), card_mask)

# 卡片描边高光
cd.rounded_rectangle([cx - card_w // 2, cy - card_h // 2,
                      cx + card_w // 2 - 1, cy + card_h // 2 - 1],
                     radius=cr, outline=(255, 255, 255, 46), width=5)

# ---- 4. 风扇（两个圆环，斜向渐变青色） ----
def fan(fx, fy, radius, alpha):
    ring = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    # 外圈
    rd.ellipse([fx - radius, fy - radius, fx + radius, fy + radius],
               outline=(120, 220, 232, alpha), width=int(radius * 0.16))
    # 内圈
    ir = radius * 0.45
    rd.ellipse([fx - ir, fy - ir, fx + ir, fy + ir],
               outline=(120, 220, 232, int(alpha * 0.7)), width=int(radius * 0.12))
    # 扇叶：8 根短线
    for i in range(8):
        a = i * math.pi / 4 + 0.4
        x1 = fx + math.cos(a) * ir * 1.35
        y1 = fy + math.sin(a) * ir * 1.35
        x2 = fx + math.cos(a) * radius * 0.82
        y2 = fy + math.sin(a) * radius * 0.82
        rd.line([x1, y1, x2, y2], fill=(150, 230, 240, int(alpha * 0.85)),
                width=int(radius * 0.13))
    img.alpha_composite(ring)

fan_cy = cy - 40
fan(cx - 150, fan_cy, 105, 235)
fan(cx + 150, fan_cy, 105, 235)

# ---- 5. 底部显存条：四格，绿-青-青-红（快满），nvpeek 的核心信息 ----
bar_y = cy + 110
bar_h = 44
bar_w_total = 560
bar_x0 = cx - bar_w_total // 2
gap = 18
seg_w = (bar_w_total - 3 * gap) // 4
colors = [(52, 199, 89, 255), (100, 210, 220, 255),
          (100, 210, 220, 255), (255, 105, 97, 255)]
bd = ImageDraw.Draw(img)
for i, col in enumerate(colors):
    x0 = bar_x0 + i * (seg_w + gap)
    bd.rounded_rectangle([x0, bar_y, x0 + seg_w, bar_y + bar_h],
                         radius=bar_h // 2, fill=(255, 255, 255, 26))
    # 填充比例
    frac = [0.45, 0.62, 0.78, 0.93][i]
    fill_w = int(seg_w * frac)
    if fill_w > bar_h:
        bd.rounded_rectangle([x0, bar_y, x0 + fill_w, bar_y + bar_h],
                             radius=bar_h // 2, fill=col)

# ---- 6. 右上角绿色状态点（呼吸灯） ----
dot_r = 34
dx, dy = cx + card_w // 2 - 60, cy - card_h // 2 + 40
# 光晕
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gld = ImageDraw.Draw(glow)
gld.ellipse([dx - dot_r * 2.2, dy - dot_r * 2.2, dx + dot_r * 2.2, dy + dot_r * 2.2],
            fill=(52, 199, 89, 60))
glow = glow.filter(ImageFilter.GaussianBlur(18))
img.alpha_composite(glow)
bd.ellipse([dx - dot_r, dy - dot_r, dx + dot_r, dy + dot_r], fill=(64, 220, 110, 255))
bd.ellipse([dx - dot_r * 0.45, dy - dot_r * 0.5, dx + dot_r * 0.25, dy - dot_r * 0.1],
           fill=(210, 255, 220, 255))

# ---- 7. 小写 nv 文字（底部，低调） ----
try:
    from PIL import ImageFont
    font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 96)
    bd.text((cx, bar_y + bar_h + 78), "nvpeek", font=font,
            fill=(200, 208, 224, 200), anchor="mm")
except Exception:
    pass

# ---- 输出母版和 .icns 需要的全套尺寸 ----
import os
os.makedirs("Resources/AppIcon.iconset", exist_ok=True)
img.save("Resources/AppIcon_1024.png")
for s in [16, 32, 64, 128, 256, 512, 1024]:
    img.resize((s, s), Image.LANCZOS).save(f"Resources/AppIcon.iconset/icon_{s}x{s}.png")
    if s <= 512:
        img.resize((s * 2, s * 2), Image.LANCZOS).save(
            f"Resources/AppIcon.iconset/icon_{s}x{s}@2x.png")
print("图标生成完成: Resources/AppIcon_1024.png + iconset 全尺寸")
