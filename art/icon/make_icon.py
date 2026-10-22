"""BOMBOCUT app icon: the fat blob holding a small clapperboard, lime on black.

    python3 art/icon/make_icon.py        (from the repo root)

Writes the three iOS 18 icons into Bombocut/Assets.xcassets/AppIcon.appiconset:
icon.png (normal), icon-dark.png (dark mode, transparent background), icon-tinted.png (grayscale).
Drawing units: the blob sits in about 0..260 x 146..444; the icon shows 130 +- 160 wide, bottom at 424.
"""
import io, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "memes"))
import numpy as np, cv2, cairosvg
from PIL import Image
from gen import obj, solid, cut, K

LIME = np.array([0xE4, 0xFF, 0x5A], np.float32)
DARK = np.array([0x0D, 0x0E, 0x10], np.float32)
OUT = os.path.join(HERE, "..", "..", "Bombocut", "Assets.xcassets", "AppIcon.appiconset")

SCALE = 3.2                     # drawing units -> 1024 px
CENTER_X, BOTTOM = 130, 424     # what lands in the middle and on the bottom edge


def bars(x, y, w, h, n, slant, color):
    """n slanted bars across a band, with a lime piece at both ends."""
    s, bw = "", w / (2 * n + 1)
    for i in range(n):
        x0 = x + (2 * i + 1) * bw - slant / 2
        s += solid(f'path d="M{x0:.1f} {y + h} L{x0 + bw:.1f} {y + h} L{x0 + bw + slant:.1f} {y} L{x0 + slant:.1f} {y} Z"', color)
    return s


def hand(x, y, r=17):
    return obj(f'circle cx="{x}" cy="{y}" r="{r}"', 9)


def clapper(bx, bw, band_y, band_h, arm_h, arm_w, bottom, angle, gap, stripes):
    """Black board with lime slate lines, a striped band, and a striped arm opened upward."""
    clip_b = f'<clipPath id="band"><rect x="{bx}" y="{band_y}" width="{bw}" height="{band_h}" rx="4"/></clipPath>'
    clip_a = f'<clipPath id="arm"><rect x="{bx}" y="{band_y - gap - arm_h}" width="{arm_w}" height="{arm_h}" rx="5"/></clipPath>'
    s = solid(f'rect x="{bx - gap}" y="{band_y - gap}" width="{bw + 2 * gap}" height="{bottom - band_y + gap}" rx="{8 + gap}"', K)
    s += f'<defs>{clip_b}{clip_a}</defs>'
    s += solid(f'rect x="{bx}" y="{band_y}" width="{bw}" height="{band_h}" rx="4"')
    s += f'<g clip-path="url(#band)">{bars(bx, band_y, bw, band_h, stripes, 10, K)}</g>'
    ly = band_y + band_h + 16
    s += solid(f'rect x="{bx + 14}" y="{ly}" width="{bw - 28}" height="10" rx="5"')
    s += solid(f'rect x="{bx + 14}" y="{ly + 22}" width="{(bw - 28) * 0.55:.1f}" height="10" rx="5"')
    pivot = (bx + 6, band_y - gap / 2)
    arm = (f'<g transform="rotate({angle} {pivot[0]} {pivot[1]})">'
           + obj(f'rect x="{bx}" y="{band_y - gap - arm_h}" width="{arm_w}" height="{arm_h}" rx="5"', gap)
           + f'<g clip-path="url(#arm)">{bars(bx, band_y - gap - arm_h, arm_w, arm_h, stripes, 10, K)}</g>'
           + '</g>')
    return arm + s


BLOB = solid('path d="M130 146 C228 146 258 220 258 300 C258 392 214 444 130 444 C46 444 2 392 2 300 C2 220 32 146 130 146 Z"')
FACE = (cut("M84 198 Q99 187 114 198 M146 198 Q161 187 176 198", 9)
        + cut("M106 224 Q130 244 154 224", 9))
BX, BW = 66, 128
ART = (BLOB + FACE
       + clapper(BX, BW, band_y=328, band_h=24, arm_h=24, arm_w=140, bottom=430, angle=-18, gap=8, stripes=3)
       + hand(BX - 4, 394) + hand(BX + BW + 4, 394))


def mask(px):
    tx, ty = 512 - CENTER_X * SCALE, 1024 - BOTTOM * SCALE
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="#000"/>'
           f'<g transform="translate({tx} {ty}) scale({SCALE})">{ART}</g></svg>')
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)
    return np.array(Image.open(io.BytesIO(png)).convert("L"))


def clean_mask(r=7):
    """Render at 2048, drop lime slivers thinner than about 2r px (at 1024) and hairline black specks."""
    big = (mask(2048) > 127).astype(np.uint8) * 255
    big = cv2.morphologyEx(big, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (4 * r + 1, 4 * r + 1)))
    big = cv2.morphologyEx(big, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
    big = cv2.GaussianBlur(big, (0, 0), 1.2)
    return cv2.resize(big, (1024, 1024), interpolation=cv2.INTER_AREA).astype(np.float32)[..., None] / 255


if __name__ == "__main__":
    a = clean_mask()
    # normal: lime on black, no transparency (App Store requirement)
    Image.fromarray((DARK * (1 - a) + LIME * a).astype(np.uint8), "RGB").save(os.path.join(OUT, "icon.png"))
    # dark mode: lime art on a transparent background, iOS puts its own dark backdrop behind it
    rgba = np.zeros((1024, 1024, 4), np.uint8)
    rgba[..., :3] = LIME.astype(np.uint8)
    rgba[..., 3] = (a[..., 0] * 255).astype(np.uint8)
    Image.fromarray(rgba, "RGBA").save(os.path.join(OUT, "icon-dark.png"))
    # tinted: grayscale, white art on black, iOS colors it
    Image.fromarray((a[..., 0] * 255).astype(np.uint8), "L").save(os.path.join(OUT, "icon-tinted.png"))
    print("wrote icon.png, icon-dark.png, icon-tinted.png to", os.path.normpath(OUT))
