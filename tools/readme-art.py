#!/usr/bin/env python3
"""Build the README pictures from the raw stand screenshots.

docs/screenshots/*.jpg are full-page captures of different heights (the stand
fixture stand/tests/fixtures/ui/overview-demo.sh). Laid out as they are, a
gallery gets rows of uneven height and wide empty margins. This script crops
every desktop tab to the same content-width frame, puts it into a browser
window, puts the phone captures into phone bezels and writes docs/readme/*.png
(transparent background: they sit on the light and the dark GitHub theme).

    python tools/readme-art.py        # needs Pillow
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "screenshots")
OUT = os.path.join(ROOT, "docs", "readme")

# LuCI centres the page in a 1280 px viewport: the content is x 170..1110
CROP_X = (150, 1130)
TILE_H = 640          # every gallery tile shows the same top part of its tab
BAR_H = 40            # browser title bar
RADIUS = 14
PAGE_BG = (34, 34, 34)
BAR_BG = (52, 52, 54)
SS = 4                # supersampling for smooth corners


def font(size):
    for name in ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def rounded_mask(size, radius):
    w, h = size
    big = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * SS - 1, h * SS - 1), radius * SS, fill=255)
    return big.resize(size, Image.LANCZOS)


def fade_bottom(img, height=90):
    """Fade the cut edge into the page colour: the tab goes on below."""
    w, h = img.size
    grad = Image.new("L", (1, height))
    for y in range(height):
        grad.putpixel((0, y), int(255 * (y / (height - 1)) ** 1.6))
    grad = grad.resize((w, height))
    solid = Image.new("RGB", (w, height), PAGE_BG)
    img.paste(solid, (0, h - height), grad)
    return img


def with_shadow(img, pad=36, blur=18, alpha=110, dy=10):
    w, h = img.size
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = img.split()[3].point(lambda v: v * alpha // 255)
    shadow.paste((0, 0, 0, 255), (pad, pad + dy), a)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(img, (pad, pad))
    return canvas


def browser(shot, height=None, url="192.168.1.1/cgi-bin/luci/admin/services/vpnpool"):
    img = Image.open(os.path.join(SRC, shot)).convert("RGB")
    body = img.crop((CROP_X[0], 0, CROP_X[1], min(img.height, height or img.height)))
    if height and img.height > height:
        body = fade_bottom(body)
    w, h = body.size
    win = Image.new("RGB", (w, h + BAR_H), BAR_BG)
    d = ImageDraw.Draw(win)
    for i, c in enumerate(((255, 95, 87), (254, 188, 46), (40, 200, 64))):
        cx, cy = 22 + i * 20, BAR_H // 2
        d.ellipse((cx - 6, cy - 6, cx + 6, cy + 6), fill=c)
    d.rounded_rectangle((90, 9, w - 90, BAR_H - 9), 11, fill=(36, 36, 38))
    f = font(13)
    tw = d.textlength(url, font=f)
    d.text(((w - tw) / 2, BAR_H / 2), url, fill=(150, 150, 155), font=f, anchor="lm")
    win.paste(body, (0, BAR_H))
    win = win.convert("RGBA")
    win.putalpha(rounded_mask(win.size, RADIUS))
    # 1 px hairline so the dark window keeps its edge on the dark theme
    edge = Image.new("RGBA", win.size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, win.width - 1, win.height - 1), RADIUS,
                                           outline=(90, 90, 95, 255), width=1)
    win.alpha_composite(edge)
    return win


def phone(shot, scale=1.0):
    img = Image.open(os.path.join(SRC, shot)).convert("RGB")
    if scale != 1.0:
        img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    bez, r_out = 12, 46
    w, h = img.width + bez * 2, img.height + bez * 2
    body = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    frame = Image.new("RGBA", (w, h), (18, 18, 20, 255))
    frame.putalpha(rounded_mask((w, h), r_out))
    body.alpha_composite(frame)
    screen = img.convert("RGBA")
    screen.putalpha(rounded_mask(img.size, r_out - bez))
    body.alpha_composite(screen, (bez, bez))
    edge = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, w - 1, h - 1), r_out, outline=(85, 85, 90, 255), width=2)
    body.alpha_composite(edge)
    return body


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    print(f"{name}: {img.width}x{img.height}, {os.path.getsize(path) // 1024} KB")


def main():
    os.makedirs(OUT, exist_ok=True)

    # hero: the Overview window with the phone over its lower right corner
    win = with_shadow(browser("overview.jpg", height=900))
    ph = with_shadow(phone("overview-mobile.jpg", scale=0.8), alpha=150)
    hero = Image.new("RGBA", (win.width + ph.width // 2, max(win.height, ph.height + 120)), (0, 0, 0, 0))
    hero.alpha_composite(win, (0, 0))
    hero.alpha_composite(ph, (hero.width - ph.width, hero.height - ph.height))
    save(hero, "hero.png")

    for tab in ("nodes", "routes", "settings", "diagnostics"):
        save(with_shadow(browser(f"{tab}.jpg", height=TILE_H), pad=24, blur=12), f"{tab}.png")

    phones = [with_shadow(phone(f"{t}-mobile.jpg"), pad=30, blur=14)
              for t in ("overview", "nodes", "settings")]
    gap = 10
    row = Image.new("RGBA", (sum(p.width for p in phones) + gap * 2, phones[0].height), (0, 0, 0, 0))
    x = 0
    for p in phones:
        row.alpha_composite(p, (x, 0))
        x += p.width + gap
    save(row, "phones.png")


if __name__ == "__main__":
    main()
