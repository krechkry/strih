import math, cv2

def poly_to_d(p, corner_len=10.0, corner_deg=45.0, nd=1):
    """p: list of (x, y) in output units. Sharp vertices stay corners (L), soft ones become Q curves."""
    n = len(p)
    if n < 3:
        return ""
    f = lambda v: (f"{v:.{nd}f}".rstrip("0").rstrip(".") or "0")
    mid = lambda a, b: ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    def corner(i):
        a, b, c = p[i - 1], p[i], p[(i + 1) % n]
        l1 = math.hypot(b[0] - a[0], b[1] - a[1]); l2 = math.hypot(c[0] - b[0], c[1] - b[1])
        if l1 == 0 or l2 == 0:
            return True
        cosang = ((b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1])) / (l1 * l2)
        turn = math.degrees(math.acos(max(-1, min(1, cosang))))
        return turn > corner_deg or min(l1, l2) > corner_len
    m0 = mid(p[-1], p[0])
    d = f"M{f(m0[0])} {f(m0[1])}"
    for i in range(n):
        b = p[i]; m = mid(b, p[(i + 1) % n])
        if corner(i):
            d += f"L{f(b[0])} {f(b[1])}L{f(m[0])} {f(m[1])}"
        else:
            d += f"Q{f(b[0])} {f(b[1])} {f(m[0])} {f(m[1])}"
    return d + "Z"

def contours_to_d(cs, scale, eps=1.1, min_area=40, **kw):
    out = []
    for c in cs:
        if abs(cv2.contourArea(c)) < min_area:
            continue
        a = cv2.approxPolyDP(c, eps, True).reshape(-1, 2)
        pts = [((x + 0.5) * scale, (y + 0.5) * scale) for x, y in a.tolist()]
        out.append(poly_to_d(pts, **kw))
    return "".join(out)
