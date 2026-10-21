"""Reference renderer: the same motion math the Swift view uses, rendered with cairo.
python3 animcheck.py memes.json out_dir  -> parity.txt + frames sheet."""
import io, json, math, sys, os
import numpy as np, cairosvg
from PIL import Image

def frac(x): return x - math.floor(x)

def mat_mul(a, b):
    # 2x3 affine, returns a∘b (apply b first, then a)
    a0, a1, a2, a3, a4, a5 = a; b0, b1, b2, b3, b4, b5 = b
    return (a0*b0 + a2*b1, a1*b0 + a3*b1, a0*b2 + a2*b3, a1*b2 + a3*b3, a0*b4 + a2*b5 + a4, a1*b4 + a3*b5 + a5)

def T(x, y): return (1, 0, 0, 1, x, y)
def R(deg):
    r = math.radians(deg); c, s = math.cos(r), math.sin(r)
    return (c, s, -s, c, 0, 0)
def S(x, y): return (x, 0, 0, y, 0, 0)

def layer_state(lay, t):
    m = (1, 0, 0, 1, 0, 0); visible = True
    for a in lay.get("anims", []):
        k = a["t"]
        if k == "shake":
            w = 2 * math.pi * a["f"] * t
            step = T(a["a"] * math.sin(w), a["a"] * 0.6 * math.sin(w * 1.37 + 1))
        elif k == "flash":
            visible = visible and frac(t / a["p"] + a["ph"]) < a["on"]
            continue
        else:
            s = math.sin(2 * math.pi * (t / a["p"] + a["ph"]))
            if k == "rot":
                step = mat_mul(T(a["x"], a["y"]), mat_mul(R(a["a"] * s), T(-a["x"], -a["y"])))
            elif k == "move":
                step = T(a["dx"] * s, a["dy"] * s)
            elif k == "scale":
                step = mat_mul(T(a["x"], a["y"]), mat_mul(S(1 + a["sx"] * s, 1 + a["sy"] * s), T(-a["x"], -a["y"])))
        m = mat_mul(step, m)
    blink = 0.0
    if "blink" in lay:
        p, ph, ln = lay["blink"]
        u = frac(t / p + ph)
        blink = math.sin(math.pi * u / ln) if u < ln else 0.0
    return m, visible, blink

def render_svg(body, px):
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480"><rect width="480" height="480" fill="#000"/>{body}</svg>'
    return np.array(Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px))).convert("L")).astype(np.float32) / 255

def frame(meme, t, px=480):
    acc = np.zeros((px, px), np.float32)
    for lay in meme:
        m, vis, blink = layer_state(lay, t)
        if not vis:
            continue
        tf = 'matrix(' + ",".join(f"{v:.5f}" for v in m) + ')'
        if "gap" in lay:
            acc *= 1 - render_svg(f'<path transform="{tf}" fill="#fff" d="{lay["gap"]}"/>', px)
        body = f'<path transform="{tf}" fill="#fff" fill-rule="evenodd" d="{lay["d"]}"/>'
        if blink > 0:
            for cx, cy, rx, ry in lay["eyes"]:
                body += f'<ellipse transform="{tf}" cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry*blink:.3f}" fill="#fff"/>'
        acc = np.maximum(acc, render_svg(body, px))
    return acc

def to_img(a):
    a = (a * 255).astype(np.uint8)
    rgb = np.zeros(a.shape + (3,), np.uint8); rgb[...] = (21, 23, 24)
    lime = np.array([0xE4, 0xFF, 0x5A], np.float32)
    out = rgb * (1 - a[..., None] / 255) + lime * (a[..., None] / 255)
    return Image.fromarray(out.astype(np.uint8))

if __name__ == "__main__":
    data = json.load(open(sys.argv[1])); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
    names = sorted(data)
    # parity: t=0 with flash layers allowed; compare to approved stills
    ref_dir = sys.argv[3] if len(sys.argv) > 3 else None
    report = []
    times = [0.0, 0.2, 0.4, 0.6, 0.8, 1.15]
    T0 = 200
    sheet = Image.new("RGB", (T0 * len(times), T0 * len(names)), (21, 23, 24))
    for r, n in enumerate(names):
        for c, t in enumerate(times):
            im = to_img(frame(data[n], t, 400)).resize((T0 - 4, T0 - 4))
            sheet.paste(im, (c * T0 + 2, r * T0 + 2))
        if ref_dir:
            ref = np.array(Image.open(f"{ref_dir}/{n}.png").convert("RGBA").resize((480, 480)))[..., 3].astype(np.float32) / 255
            now = frame(data[n], 0.0, 480)
            diff = np.abs(ref - now) > 0.5
            report.append(f"{n}: {diff.mean()*100:.2f}% pixels differ")
            if diff.mean() > 0.003:
                vis = np.zeros((480, 480, 3), np.uint8); vis[..., 1] = (ref * 255).astype(np.uint8); vis[..., 0] = (now * 255).astype(np.uint8)
                Image.fromarray(vis).save(f"{out}/diff_{n}.png")
    sheet.save(f"{out}/frames.png")
    open(f"{out}/parity.txt", "w").write("\n".join(report))
    print("\n".join(report))
