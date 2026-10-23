"""Store screenshot footage: Krystof as a simplified flat figure on soft color backgrounds.

    python3 art/store/footage.py talk.jpg stand.jpg walk.jpg      (from the repo root)

talk  = waist-up, facing the camera   -> footage/demo1.mp4  1080x1920, 6 s (captions, editor, speed)
stand = full body, standing           -> footage/demo2.mp4  1080x1920, 4 s (mask: "Tip #1" behind the figure)
walk  = full body from the side       -> footage/demo3.mp4  1920x1080, 5 s (tracking: walks left to right)

The figure keeps the real outline and face so the app's own person mask still finds it. The walk matches
the tracking samples in EditorView's "track" demo: center x = 0.22 + 0.112 * t, y = 0.55, height 0.78.
Needs: pip install rembg onnxruntime opencv-python pillow numpy, and ffmpeg.
"""
import os, subprocess, sys, tempfile
import numpy as np, cv2
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "footage")
FPS = 30


def cutout(path):
    """RGBA of the person, cropped to them."""
    from rembg import remove, new_session
    img = Image.open(path)
    try:
        from PIL import ImageOps
        img = ImageOps.exif_transpose(img)
    except Exception:
        pass
    img = img.convert("RGB")
    if max(img.size) > 2000:
        img.thumbnail((2000, 2000), Image.LANCZOS)
    rgba = np.array(remove(img, session=new_session("u2net_human_seg"), post_process_mask=True))
    a = rgba[..., 3]
    a = cv2.morphologyEx(a, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats((a > 127).astype(np.uint8))
    if n > 1:   # keep the biggest piece only
        keep = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        a = np.where(lab == keep, a, 0).astype(np.uint8)
    rgba[..., 3] = a
    ys, xs = np.nonzero(a > 20)
    return rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


PALETTE = None  # set by stylize() callers if wanted


def stylize(rgba, levels=5, outline=0.012):
    """Flat figure: smoothed, a handful of flat colors, a dark outline around the body."""
    rgb = rgba[..., :3].copy()
    a = rgba[..., 3]
    h, w = a.shape
    rgb = cv2.bilateralFilter(rgb, 9, 60, 9)
    rgb = cv2.bilateralFilter(rgb, 9, 60, 9)
    inside = a > 127
    px = rgb[inside].reshape(-1, 3).astype(np.float32)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1.0)
    _, lab, cen = cv2.kmeans(px, levels, None, crit, 3, cv2.KMEANS_PP_CENTERS)
    flat = rgb.copy()
    flat[inside] = cen[lab.ravel()].astype(np.uint8)
    flat = cv2.medianBlur(flat, 7)
    # inner lines: edges between the flat colors, thin and dark
    edges = cv2.Canny(cv2.cvtColor(flat, cv2.COLOR_RGB2GRAY), 30, 90)
    edges = cv2.dilate(edges, np.ones((2, 2), np.uint8))
    flat[(edges > 0) & inside] = (flat[(edges > 0) & inside] * 0.35).astype(np.uint8)
    # outer outline
    k = max(3, int(max(h, w) * outline)) | 1
    ring = cv2.dilate((a > 127).astype(np.uint8) * 255, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    out = np.zeros((h, w, 4), np.uint8)
    out[..., :3] = (18, 18, 22)
    out[..., 3] = cv2.GaussianBlur(ring, (0, 0), 1.0)
    m = inside
    out[m, :3] = flat[m]
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
    img = img * (1 - g2) + c2 * g2
    return img


def paste(bg, fig, cx, bottom, height):
    """Figure scaled to `height` px, centered on cx, its bottom at `bottom` (can run off the frame)."""
    s = height / fig.shape[0]
    f = cv2.resize(fig, (max(1, int(fig.shape[1] * s)), int(height)), interpolation=cv2.INTER_AREA)
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


def encode(frames_fn, n, w, h, name):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    p = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
                          "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "24",
                          "-pix_fmt", "yuv420p", "-movflags", "+faststart", path], stdin=subprocess.PIPE)
    for i in range(n):
        p.stdin.write(np.clip(frames_fn(i / FPS), 0, 255).astype(np.uint8).tobytes())
    p.stdin.close()
    p.wait()
    print("wrote", path, os.path.getsize(path) // 1024, "KB")


WARM = ((255, 120, 70), (120, 50, 230), (255, 205, 90))
COOL = ((30, 160, 220), (35, 40, 120), (60, 225, 180))
DUSK = ((255, 80, 140), (60, 30, 200), (255, 210, 80))


def talk(fig):
    W, H = 1080, 1920
    def frame(t):
        bg = gradient(W, H, *WARM, t=t)
        bob = 10 * np.sin(t * 2.2)
        return paste(bg, fig, W / 2 + 14 * np.sin(t * 0.8), H + 40 + bob, H * 0.72)
    encode(frame, 6 * FPS, W, H, "demo1.mp4")


def stand(fig):
    W, H = 1080, 1920
    def frame(t):
        bg = gradient(W, H, *COOL, t=t)
        return paste(bg, fig, W / 2 + 8 * np.sin(t * 1.3), H * 0.94, H * 0.74)
    encode(frame, 4 * FPS, W, H, "demo2.mp4")


def walk(fig):
    W, H = 1920, 1080
    def frame(t):
        bg = gradient(W, H, *DUSK, t=t)
        bg[int(H * 0.94):] *= 0.75   # ground
        cx = W * (0.22 + 0.112 * t)
        h = H * 0.78
        bottom = H * 0.55 + h / 2 - abs(np.sin(t * 5.5)) * 10
        return paste(bg, fig, cx, bottom, h)
    encode(frame, 5 * FPS, W, H, "demo3.mp4")


if __name__ == "__main__":
    a, b, c = sys.argv[1:4]
    talk(stylize(cutout(a)))
    stand(stylize(cutout(b)))
    walk(stylize(cutout(c)))
