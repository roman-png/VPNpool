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
    """An iPhone: titanium rim, side buttons, status bar and the Dynamic Island."""
    img = Image.open(os.path.join(SRC, shot)).convert("RGB")
    k = scale
    if k != 1.0:
        img = img.resize((round(img.width * k), round(img.height * k)), Image.LANCZOS)
    u = lambda v: round(v * k)
    sw, sh = img.size
    sb = u(50)                     # status bar above the page, like on the phone
    bez, rim, btn, r_out = u(13), max(2, u(3)), max(2, u(3)), u(58)
    bw, bh = sw + bez * 2, sh + bez * 2
    W, H = bw + btn * 2, bh

    # rim, black glass and the side buttons, drawn big for smooth edges
    big = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    s = lambda *v: [round(x * SS) for x in v]
    metal = (74, 74, 80, 255)
    for x0, y0, y1 in ((0, 118, 150), (0, 178, 232), (0, 246, 300)):          # action, volume
        d.rounded_rectangle(s(x0, u(y0), btn + rim * 2, u(y1)), u(2) * SS, fill=metal)
    d.rounded_rectangle(s(W - btn - rim * 2, u(196), W - 1, u(286)), u(2) * SS, fill=metal)  # power
    d.rounded_rectangle(s(btn, 0, btn + bw - 1, bh - 1), r_out * SS, fill=metal)
    d.rounded_rectangle(s(btn + rim, rim, btn + bw - 1 - rim, bh - 1 - rim), (r_out - rim) * SS,
                        fill=(8, 8, 10, 255))
    body = big.resize((W, H), Image.LANCZOS)

    # the screen: a status bar strip on top, the page below it
    bg = img.getpixel((2, sh - 2))
    screen = Image.new("RGB", (sw, sh), bg)
    screen.paste(img.crop((0, 0, sw, sh - sb)), (0, sb))
    screen = screen.convert("RGBA")
    screen.putalpha(rounded_mask((sw, sh), r_out - bez))
    body.alpha_composite(screen, (btn + bez, bez))

    # status bar and the island
    ov = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    x0, y0 = btn + bez, bez
    cy = y0 + u(26)
    iw, ih = u(112), u(33)
    d.rounded_rectangle(s(x0 + (sw - iw) / 2, cy - ih / 2, x0 + (sw + iw) / 2, cy + ih / 2),
                        ih / 2 * SS, fill=(0, 0, 0, 255))
    white = (245, 245, 247, 255)
    try:
        tf = ImageFont.truetype("seguisb.ttf", u(16) * SS)
    except OSError:
        tf = font(u(16) * SS)
    d.text(s(x0 + u(52), cy), "9:41", fill=white, font=tf, anchor="mm")
    rx = x0 + sw - u(26)                                        # battery
    d.rounded_rectangle(s(rx - u(25), cy - u(6), rx - u(2), cy + u(6)), u(3.5) * SS,
                        outline=(245, 245, 247, 150), width=max(1, round(1.2 * k * SS)))
    d.rounded_rectangle(s(rx - u(23), cy - u(4), rx - u(7), cy + u(4)), u(2) * SS, fill=white)
    d.rounded_rectangle(s(rx, cy - u(2.5), rx + u(1.8), cy + u(2.5)), u(1) * SS, fill=(245, 245, 247, 150))
    wx = rx - u(40)                                             # wi-fi
    for r, a in ((u(11), 255), (u(7.5), 255), (u(4), 255)):
        d.pieslice(s(wx - r, cy + u(5) - r, wx + r, cy + u(5) + r), 225, 315, fill=(245, 245, 247, a))
        d.pieslice(s(wx - r + u(2.2), cy + u(5) - r + u(2.2), wx + r - u(2.2), cy + u(5) + r - u(2.2)),
                   225, 315, fill=(0, 0, 0, 0))
    d.pieslice(s(wx - u(3), cy + u(2), wx + u(3), cy + u(8)), 225, 315, fill=white)
    sx = wx - u(36)                                             # signal
    for n in range(4):
        hgt = u(4 + n * 2.6)
        d.rounded_rectangle(s(sx + n * u(5), cy + u(5) - hgt, sx + n * u(5) + u(3.2), cy + u(5)), u(1) * SS,
                            fill=white)
    body.alpha_composite(ov.resize((W, H), Image.LANCZOS))
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
