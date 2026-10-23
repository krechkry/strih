"""Store screenshot footage: Krystof as a meme-cast blob (solid lime, thick gaps, dot face) on calm dark backgrounds.

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
K = np.array([0x0D, 0x0E, 0x10], np.float32)


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


def face_xml():
    """OpenCV's frontal face detector (to put the dot face where the real one is)."""
    path = os.path.join(HERE, ".cache", "haarcascade_frontalface_default.xml")
    if not os.path.exists(path):
        import urllib.request
        os.makedirs(os.path.dirname(path), exist_ok=True)
        urllib.request.urlretrieve("https://raw.githubusercontent.com/opencv/opencv/4.x/data/haarcascades/"
                                   "haarcascade_frontalface_default.xml", path)
    return path


def smooth_mask(m, s):
    return cv2.GaussianBlur(m.astype(np.float32), (0, 0), s) > 0.5

def clean_shape(m, win):
    """Redraw a mask from its outlines, each one smoothed along its length: clean curves, no fuzz."""
    m8 = m.astype(np.uint8)
    cs, hier = cv2.findContours(m8, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    out = np.zeros_like(m8)
    if hier is None:
        return out > 0
    win = max(3, int(win)) | 1
    k = np.ones(win, np.float32) / win
    for i, c in enumerate(cs):
        p = c[:, 0, :].astype(np.float32)
        if len(p) < win * 2 or cv2.contourArea(c) < (win * 2) ** 2:
            continue
        pp = np.concatenate([p[-win:], p, p[:win]])
        sx = np.convolve(pp[:, 0], k, "same")[win:-win]
        sy = np.convolve(pp[:, 1], k, "same")[win:-win]
        poly = np.stack([sx, sy], 1).round().astype(np.int32).reshape(-1, 1, 2)
        hole = hier[0][i][3] >= 0
        cv2.fillPoly(out, [poly], 0 if hole else 1, cv2.LINE_AA)
    return out > 0


def meme_figure(rgba, face="smile", gap=0.012, soft=0.009):
    """The meme cast's look: one solid lime shape, thick black gaps where parts meet, a dot face."""
    a = rgba[..., 3]; h, w = a.shape
    inside = clean_shape(smooth_mask(a > 127, max(2, h * soft * 0.5)), h * 0.02)
    rgb = np.ascontiguousarray(rgba[..., :3])
    sm = cv2.pyrMeanShiftFiltering(rgb, 14, 36)
    lab = cv2.cvtColor(sm, cv2.COLOR_RGB2LAB).astype(np.float32)
    L, A, B = lab[..., 0], lab[..., 1], lab[..., 2]
    warm = inside & (A > 135) & (B > 137)
    kc = max(3, int(h * 0.04)) | 1
    skin = cv2.morphologyEx(warm.astype(np.uint8), cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kc, kc)))
    skin = cv2.morphologyEx(skin, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kc // 2 | 1, kc // 2 | 1)))
    skin = smooth_mask(skin > 0, h * 0.008) & inside
    # small bits flip to the other part (hair rims, finger gaps), so only real parts stay
    total = inside.sum()
    for _ in range(2):
        for m_ in (skin, inside & ~skin):
            n, lab_, st, _ = cv2.connectedComponentsWithStats(m_.astype(np.uint8))
            for i in range(1, n):
                if st[i, cv2.CC_STAT_AREA] < 0.03 * total:
                    skin = skin ^ (lab_ == i)
        skin &= inside
    skin = clean_shape(skin, h * 0.025) & inside
    # thin strips of clothes along the edge of the skin become skin (no stray dashes on the outline)
    cloth = (inside & ~skin).astype(np.uint8)
    kk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (int(h * 0.03) | 1, int(h * 0.03) | 1))
    cloth = cv2.morphologyEx(cloth, cv2.MORPH_OPEN, kk) > 0
    skin = inside & ~cloth
    parts = np.zeros((h, w), np.int32)
    parts[inside] = 1; parts[skin] = 2
    # thick gaps only where two parts meet, never along the outer edge
    g = max(3, int(h * gap)) | 1
    ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (g, g))
    gaps = np.zeros((h, w), bool)
    for i in (1, 2):
        m = (parts == i).astype(np.uint8)
        gaps |= (cv2.dilate(m, ker) > 0) & (parts > 0) & (parts != i)
    gaps = smooth_mask(gaps, g * 0.25)
    n, lab_, st, _ = cv2.connectedComponentsWithStats(gaps.astype(np.uint8))
    gaps = np.isin(lab_, [i for i in range(1, n) if st[i, cv2.CC_STAT_AREA] > g * g * 8])   # no specks
    fig = inside & ~gaps
    # face: a simple meme face on the photo's face position
    out = np.zeros((h, w, 4), np.uint8)
    col = np.where(fig[..., None], LIME, K)
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    casc = cv2.CascadeClassifier(face_xml())
    faces = casc.detectMultiScale(gray, 1.1, 5, minSize=(int(w * 0.06), int(w * 0.06)))
    if len(faces):
        fx, fy, fw, fh = min(faces, key=lambda f: f[1] + f[3] / 2)   # the top one is the face
        # cover the photo's face with plain lime first (the skin part already is), then draw the face
        r = max(3, int(fw * 0.07))
        ey = int(fy + fh * 0.42)
        for ex in (fx + fw * 0.32, fx + fw * 0.68):
            cv2.circle(col, (int(ex), ey), r, K.tolist(), -1, cv2.LINE_AA)
        mw = max(3, int(fw * 0.075))
        cx, my = fx + fw / 2, fy + fh * 0.74
        if face == "smile":
            pts = np.array([[cx - fw * 0.17, my - fh * 0.03], [cx, my + fh * 0.06], [cx + fw * 0.17, my - fh * 0.03]], np.int32)
            cv2.polylines(col, [pts.reshape(-1, 1, 2)], False, K.tolist(), mw, cv2.LINE_AA)
        elif face == "o":
            cv2.ellipse(col, (int(cx), int(my)), (int(fw * 0.09), int(fh * 0.12)), 0, 0, 360, K.tolist(), -1, cv2.LINE_AA)
        else:
            cv2.line(col, (int(cx - fw * 0.13), int(my)), (int(cx + fw * 0.13), int(my)), K.tolist(), mw, cv2.LINE_AA)
    out[..., :3] = col.astype(np.uint8)
    out[..., 3] = (cv2.GaussianBlur(inside.astype(np.float32), (0, 0), 1.0) * 255).astype(np.uint8)
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


# calm dark backgrounds, like the app's own grays, each with a slight tint
VIOLET = ((46, 44, 60), (20, 20, 26), (70, 66, 92))
OCEAN = ((38, 50, 58), (17, 21, 26), (58, 76, 86))
SUNSET = ((58, 48, 44), (22, 20, 20), (88, 72, 62))


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
        bg[int(H * 0.95):] *= 0.8   # floor
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
    talk(meme_figure(cutout(a, "isnet-general-use"), "smile"))
    stand(meme_figure(cutout(b), "flat"))
    jump(meme_figure(cutout(c, add=JUMP_FOOT), "o"))
