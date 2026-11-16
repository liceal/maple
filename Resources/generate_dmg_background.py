import os
from PIL import Image, ImageDraw, ImageFont

def generate_dmg_background(output_path):
    # Finder 窗口外框设为 560 x 440 pt（扣除顶部 28pt 标题栏后，内部可视区高度为 412 pt）
    # 背景图逻辑尺寸设为 560 x 408 pt，确保背景图与图标均完全处于 412pt 可视区内，零滚动条！
    SCALE = 2
    WIDTH_PT = 560
    HEIGHT_PT = 408
    WIDTH_PX = WIDTH_PT * SCALE
    HEIGHT_PX = HEIGHT_PT * SCALE

    img = Image.new("RGBA", (WIDTH_PX, HEIGHT_PX), (248, 249, 251, 255))
    draw = ImageDraw.Draw(img)

    # 1. 绘制极简纯净微渐变背景 (#F9FAFC -> #EEF1F5)
    for y in range(HEIGHT_PX):
        ratio = y / float(HEIGHT_PX)
        r = int(249 - (249 - 238) * ratio)
        g = int(250 - (250 - 241) * ratio)
        b = int(252 - (252 - 245) * ratio)
        draw.line([(0, y), (WIDTH_PX, y)], fill=(r, g, b, 255))

    # 2. 标题："Maple for Mac"
    title_text = "Maple for Mac"
    try:
        title_font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22 * SCALE)
    except Exception:
        title_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22 * SCALE)

    bbox = draw.textbbox((0, 0), title_text, font=title_font)
    title_w = bbox[2] - bbox[0]
    title_x = (WIDTH_PX - title_w) // 2
    title_y = int(24 * SCALE)
    draw.text((title_x, title_y), title_text, font=title_font, fill=(32, 34, 40, 255))

    # 3. 左右两个贴合 96pt 图标的圆角白色卡片
    # Finder 放置位置为 (140, 150) 与 (420, 150)
    # 96pt 图标的几何中心位于 Y = 137 pt
    CARD_CX_LEFT = int(140 * SCALE)
    CARD_CX_RIGHT = int(420 * SCALE)
    CARD_CY = int(137 * SCALE)
    CARD_W = int(130 * SCALE)
    CARD_H = int(130 * SCALE)
    RADIUS = int(24 * SCALE)

    def draw_card(cx, cy, w, h, r):
        x0 = cx - w // 2
        y0 = cy - h // 2
        x1 = x0 + w
        y1 = y0 + h

        # 柔和多层阴影
        for i in range(int(5 * SCALE), 0, -1):
            alpha = int(3 * (1 - i / float(5 * SCALE)))
            draw.rounded_rectangle(
                [x0 - i, y0 + int(2 * SCALE) - i, x1 + i, y1 + int(2 * SCALE) + i],
                radius=r + i,
                fill=(0, 0, 0, alpha)
            )

        # 纯白卡片底色
        draw.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=(255, 255, 255, 255))

        # 精致浅灰边框
        draw.rounded_rectangle([x0, y0, x1, y1], radius=r, outline=(220, 224, 230, 220), width=int(1.5 * SCALE))

    draw_card(CARD_CX_LEFT, CARD_CY, CARD_W, CARD_H, RADIUS)
    draw_card(CARD_CX_RIGHT, CARD_CY, CARD_W, CARD_H, RADIUS)

    # 4. 中间蓝色导向箭头 (从 X=232 到 X=328, Y=162)
    arrow_start_x = int(232 * SCALE)
    arrow_end_x = int(328 * SCALE)
    arrow_y = CARD_CY

    dash_len = int(8 * SCALE)
    gap_len = int(5 * SCALE)
    cur_x = arrow_start_x
    arrow_color = (55, 135, 250, 180)
    while cur_x < arrow_end_x - int(12 * SCALE):
        next_x = min(cur_x + dash_len, arrow_end_x - int(12 * SCALE))
        draw.line([(cur_x, arrow_y), (next_x, arrow_y)], fill=arrow_color, width=int(3.5 * SCALE))
        cur_x += dash_len + gap_len

    head_size = int(10 * SCALE)
    head_color = (40, 125, 245, 240)
    draw.line([(arrow_end_x - head_size, arrow_y - head_size), (arrow_end_x, arrow_y)], fill=head_color, width=int(3.5 * SCALE))
    draw.line([(arrow_end_x - head_size, arrow_y + head_size), (arrow_end_x, arrow_y)], fill=head_color, width=int(3.5 * SCALE))

    # 箭头下方提示微文
    sub_text = "拖移至右侧安装"
    try:
        sub_font = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", 11 * SCALE)
    except Exception:
        sub_font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 11 * SCALE)

    s_bbox = draw.textbbox((0, 0), sub_text, font=sub_font)
    s_w = s_bbox[2] - s_bbox[0]
    s_x = (WIDTH_PX - s_w) // 2
    s_y = arrow_y + int(14 * SCALE)
    draw.text((s_x, s_y), sub_text, font=sub_font, fill=(75, 135, 235, 220))

    # 5. 输出 144 DPI Retina PNG
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    img.save(output_path, format="PNG", dpi=(144, 144))
    print(f"✓ 成功生成 144 DPI Retina DMG 背景图: {output_path}")


def generate_small_helper_icons(script_dir):
    """
    生成两个视觉尺寸小巧精致（约占 96pt 格子的 37%，即 ~36pt）且紧贴底部文字标签的自定义文件图标：
    1. helper_fix_icon.png -> 用于「首次打开修复.command」
    2. helper_doc_icon.png -> 用于「安装说明.html」
    """
    SIZE = 512
    # 图标主体仅 192x192 px (在 Finder 96pt 格子里视觉大小约 36pt)，靠下放置使图标紧贴下方文件名
    BOX_W = 192
    BOX_H = 192
    CX = SIZE // 2
    CY = 372  # 靠下对齐，紧贴 Finder 文件名标签
    R = 46

    def make_base_card():
        im = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        x0 = CX - BOX_W // 2
        y0 = CY - BOX_H // 2
        x1 = x0 + BOX_W
        y1 = y0 + BOX_H

        # 柔和投影
        for i in range(12, 0, -1):
            alpha = int(5 * (1 - i / 12.0))
            d.rounded_rectangle([x0 - i, y0 + 5 - i, x1 + i, y1 + 5 + i], radius=R + i, fill=(20, 30, 50, alpha))

        # 纯白圆角底板 + 细边框
        d.rounded_rectangle([x0, y0, x1, y1], radius=R, fill=(255, 255, 255, 255))
        d.rounded_rectangle([x0, y0, x1, y1], radius=R, outline=(215, 222, 232, 255), width=4)
        return im, d, x0, y0, x1, y1

    # 图标 1：首次打开修复（精致蓝绿圆章 + 对勾）
    im1, d1, x0, y0, x1, y1 = make_base_card()
    inner_r = 54
    d1.ellipse([CX - inner_r, CY - inner_r, CX + inner_r, CY + inner_r], fill=(235, 245, 255, 255))
    d1.ellipse([CX - inner_r, CY - inner_r, CX + inner_r, CY + inner_r], outline=(60, 135, 245, 220), width=4)
    pts = [(CX - 22, CY + 2), (CX - 5, CY + 19), (CX + 25, CY - 15)]
    d1.line([pts[0], pts[1]], fill=(35, 118, 240, 255), width=10)
    d1.line([pts[1], pts[2]], fill=(35, 118, 240, 255), width=10)
    d1.ellipse([pts[1][0] - 4, pts[1][1] - 4, pts[1][0] + 4, pts[1][1] + 4], fill=(35, 118, 240, 255))

    fix_icon_path = os.path.join(script_dir, "helper_fix_icon.png")
    im1.save(fix_icon_path, format="PNG")

    # 图标 2：安装说明（精致暖橙文档线条）
    im2, d2, x0, y0, x1, y1 = make_base_card()
    inner_r = 54
    d2.ellipse([CX - inner_r, CY - inner_r, CX + inner_r, CY + inner_r], fill=(255, 244, 232, 255))
    d2.ellipse([CX - inner_r, CY - inner_r, CX + inner_r, CY + inner_r], outline=(225, 120, 45, 220), width=4)
    for idx, w_half in enumerate([22, 22, 13]):
        ly = CY - 15 + idx * 15
        lx0 = CX - 22
        lx1 = CX + w_half
        d2.rounded_rectangle([lx0, ly - 3.5, lx1, ly + 3.5], radius=3, fill=(215, 105, 30, 255))

    doc_icon_path = os.path.join(script_dir, "helper_doc_icon.png")
    im2.save(doc_icon_path, format="PNG")
    print(f"✓ 成功生成小尺寸辅助图标: {fix_icon_path}, {doc_icon_path}")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(script_dir, "dmg_background.png")
    generate_dmg_background(target)
    generate_small_helper_icons(script_dir)
