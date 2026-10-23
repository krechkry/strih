"""Store screenshot footage: Krystof as a lime figure (meme style) on soft color backgrounds.

    python3 art/store/footage.py talk.jpg stand.jpg jump.jpg      (from the repo root)

talk  = waist-up, facing the camera, pointing up  -> footage/demo1.mp4  1080x1920, 6 s (captions, editor, speed)
stand = full body, standing                       -> footage/demo2.mp4  1080x1920, 4 s (mask: "Tip #1" behind him)
jump  = full body, jumping                        -> footage/demo3.mp4  1920x1080, 5 s (tracking: flies left to right)

The jump matches the tracking samples in EditorView's "track" demo: center x = 0.22 + 0.112 * t, y = 0.55,
size 0.28 x 0.78 of the frame. The photos stay out of the repo, only the clips go in.
Needs: pip install rembg onnxruntime opencv-python pillow numpy, and ffmpeg.
"""
import os, subprocess, sys
import numpy as np, cv2
from PIL import Image, ImageOps, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "footage")
FPS = 30
LIME = np.array([0xE4, 0xFF, 0x5A], np.float32)
INK = np.array([0x0D, 0x0E, 0x10], np.float32)


def cutout(path, model="u2net_human_seg", add=()):
    """RGBA of the person, cropped to them. add: polygons (photo pixels) the model missed, like a blurred foot."""
    from rembg import remove, new_session
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    m = remove(im, session=new_session(model), only_mask=True)
    d = ImageDraw.Draw(m)
    for poly in add:
        d.polygon(poly, fill=255)
    m = cv2.GaussianBlur(np.array(m), (0, 0), 1.2)
    m = np.where(m > 127, 255, 0).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats((m > 0).astype(np.uint8))
    big = st[1:, cv2.CC_STAT_AREA].max()
    m = np.where(np.isin(lab, [i for i in range(1, n) if st[i, cv2.CC_STAT_AREA] > 0.02 * big]), m, 0).astype(np.uint8)
    rgba = np.dstack([np.array(im), m])
    ys, xs = np.nonzero(m)
    return rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def xdog(gray, sigma=1.2, k=1.6, p=22, eps=-0.02, phi=12):
    g = gray.astype(np.float32) / 255
    a = cv2.GaussianBlur(g, (0, 0), sigma); b = cv2.GaussianBlur(g, (0, 0), sigma * k)
    d = (1 + p) * a - p * b
    e = np.where(d >= eps, 1.0, 1 + np.tanh(phi * (d - eps)))
    return e  # 1 = paper, <1 = ink


def lime_figure(rgba, close=0.035, smooth=0.012, line=0.0035, ink_w=1.0, cloth_split=True):
    """Meme style: the figure in lime, its features and the main folds as black lines, a black rim."""
    a = rgba[..., 3]; h, w = a.shape
    inside = a > 127
    inside = cv2.erode(inside.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0   # lose the light fringe
    rgb = np.ascontiguousarray(rgba[..., :3])
    sm = cv2.pyrMeanShiftFiltering(rgb, 14, 36)
    lab = cv2.cvtColor(sm, cv2.COLOR_RGB2LAB).astype(np.float32)
    Lc, A, B = lab[..., 0], lab[..., 1], lab[..., 2]
    warm = inside & (A > 135) & (B > 137)
    kc = max(3, int(h * close)) | 1
    warm_c = cv2.morphologyEx(warm.astype(np.uint8), cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kc, kc))) > 0
    warm_c &= inside
    warm_c = cv2.morphologyEx(warm_c.astype(np.uint8), cv2.MORPH_OPEN, np.ones((7, 7), np.uint8)) > 0
    lw = max(2, int(h * line))
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (lw, lw))
    lines = cv2.morphologyEx(warm_c.astype(np.uint8), cv2.MORPH_GRADIENT, k) > 0
    if cloth_split:
        s = max(2, h * smooth)
        cloth = inside & ~warm_c
        Ls = cv2.GaussianBlur(np.where(cloth, Lc, 0), (0, 0), s) / np.maximum(cv2.GaussianBlur(cloth.astype(np.float32), (0, 0), s), 1e-3)
        thr = np.quantile(Ls[cloth], 0.45) if cloth.any() else 0
        dark = (cloth & (Ls < thr)).astype(np.uint8)
        dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kc, kc)))
        dark = cv2.morphologyEx(dark, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kc, kc)))
        # only the big dark parts (trousers, a sleeve in shadow), not the shirt pattern
        n, lab_, st, _ = cv2.connectedComponentsWithStats(dark)
        big = [i for i in range(1, n) if st[i, cv2.CC_STAT_AREA] > 0.12 * cloth.sum()]
        dark = np.isin(lab_, big).astype(np.uint8)
        holes = dark.copy(); ff = np.zeros((h + 2, w + 2), np.uint8)
        cv2.floodFill(holes, ff, (0, 0), 1)
        dark |= (holes == 0).astype(np.uint8)
        lines |= (cv2.morphologyEx(dark, cv2.MORPH_GRADIENT, k) > 0) & cloth
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    e = xdog(gray, sigma=max(1.0, h * 0.0012 * ink_w))
    inkm = warm_c & (e < 0.45)
    inkm = cv2.morphologyEx(inkm.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)) > 0
    lines |= inkm
    lines &= cv2.erode(inside.astype(np.uint8), k) > 0
    out = np.zeros((h, w, 4), np.uint8)
    fill = np.where(lines[..., None], INK, LIME)
    rim = max(3, int(max(h, w) * 0.008)) | 1
    ring = cv2.dilate(inside.astype(np.uint8) * 255, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (rim, rim)))
    out[..., :3] = INK.astype(np.uint8); out[..., 3] = cv2.GaussianBlur(ring, (0, 0), 1.0)
    out[inside, :3] = fill[inside].astype(np.uint8)
    return out


def gradient(w, h, c0, c1, c2, t=0.0):
    """Soft three-color background that drifts a little over time."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    u = x / w + 0.04 * np.sin(t * 0.9)
    v = y / h + 0.03 * np.cos(t * 0.7)
    c0, c1, c2 = (np.array(c, np.float32) for c in (c0, c1, c2))
    g1 = np.clip(v, 0, 1)[..., None]
    g2 = np.clip(1 - np.hypot(u - 0.75, v - 0.25) * 1.6, 0, 1)[..., None]
    img = c0 * (1 - g1) + c1 * g1
    return img * (1 - g2) + c2 * g2


def paste(bg, fig, cx, bottom, height, angle=0.0):
    """Figure scaled to height px, centered on cx, its bottom at bottom (can run off the frame)."""
    s = height / fig.shape[0]
    f = cv2.resize(fig, (max(1, int(fig.shape[1] * s)), int(height)), interpolation=cv2.INTER_AREA)
    if angle:   # turn around the bottom center, with room so nothing gets cut off
        fh, fw = f.shape[:2]
        pad = int(max(fh, fw) * 0.25)
        f = cv2.copyMakeBorder(f, pad, 0, pad, pad, cv2.BORDER_CONSTANT, value=(0, 0, 0, 0))
        fh2, fw2 = f.shape[:2]
        M = cv2.getRotationMatrix2D((fw2 / 2, fh2), angle, 1.0)
        f = cv2.warpAffine(f, M, (fw2, fh2), flags=cv2.INTER_LINEAR, borderValue=(0, 0, 0, 0))
    fh, fw = f.shape[:2]
    x0, y0 = int(cx - fw / 2), int(bottom - fh)
    H, W = bg.shape[:2]
    xa, ya, xb, yb = max(0, x0), max(0, y0), min(W, x0 + fw), min(H, y0 + fh)
    if xb <= xa or yb <= ya:
        return bg
    part = f[ya - y0:yb - y0, xa - x0:xb - x0].astype(np.float32)
    al = part[..., 3:4] / 255
    bg[ya:yb, xa:xb] = bg[ya:yb, xa:xb] * (1 - al) + part[..., :3] * al
    return bg


def encode(frame, n, w, h, name):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    p = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
                          "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "24",
                          "-pix_fmt", "yuv420p", "-movflags", "+faststart", path], stdin=subprocess.PIPE)
    for i in range(n):
        p.stdin.write(np.clip(frame(i / FPS), 0, 255).astype(np.uint8).tobytes())
    p.stdin.close()
    p.wait()
    print("wrote", path, os.path.getsize(path) // 1024, "KB")


VIOLET = ((92, 40, 210), (230, 70, 150), (255, 140, 90))
OCEAN = ((20, 110, 200), (20, 30, 90), (40, 200, 190))
SUNSET = ((255, 90, 70), (110, 30, 160), (255, 170, 60))


def talk(fig):
    W, H = 1080, 1920
    def frame(t):
        bg = gradient(W, H, *VIOLET, t=t)
        return paste(bg, fig, W / 2 + 16 * np.sin(t * 0.8), H + 60 + 12 * np.sin(t * 2.2), H * 0.8, angle=1.2 * np.sin(t * 1.1))
    encode(frame, 6 * FPS, W, H, "demo1.mp4")


def stand(fig):
    W, H = 1080, 1920
    def frame(t):
        bg = gradient(W, H, *OCEAN, t=t)
        return paste(bg, fig, W / 2 + 8 * np.sin(t * 1.3), H * 0.95, H * 0.72)
    encode(frame, 4 * FPS, W, H, "demo2.mp4")


def jump(fig):
    W, H = 1920, 1080
    def frame(t):
        bg = gradient(W, H, *SUNSET, t=t)
        bg[int(H * 0.95):] *= 0.7   # floor
        h = H * 0.78
        bottom = H * 0.55 + h / 2 - 18 * np.sin(np.pi * t / 5)
        return paste(bg, fig, W * (0.22 + 0.112 * t), bottom, h, angle=-4 * np.sin(t * 1.4))
    encode(frame, 5 * FPS, W, H, "demo3.mp4")


# the jump photo's left foot is a motion blur the models drop; drawn back in by hand (photo pixels)
JUMP_FOOT = [[(390, 1165), (425, 1162), (480, 1190), (505, 1220), (500, 1260), (480, 1320), (410, 1380), (360, 1420),
              (300, 1400), (295, 1370), (325, 1300), (360, 1220)],
             [(470, 1185), (565, 1175), (565, 1320), (470, 1325)]]

if __name__ == "__main__":
    a, b, c = sys.argv[1:4]
    talk(lime_figure(cutout(a, "isnet-general-use")))
    stand(lime_figure(cutout(b)))
    jump(lime_figure(cutout(c, add=JUMP_FOOT)))
