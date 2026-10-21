"""Animatable layer split of the 14 lime memes.

Each layer: c = mask content (white = lime, black = cut out, same language as gen.py),
gap = how far (in 480-unit space) this layer erases what is under it,
anims = list of motions, eyes = blink covers [(cx, cy, rx, ry)], blink = (period s, phase 0..1, length 0..1).
Motions (s = sin(2*pi*(t/p + ph))):
  rot   a deg about (x, y)              move  dx, dy
  scale sx, sy about (x, y)             shake a px at f Hz
  flash visible while frac(t/p + ph) < on
"""
import io, json, sys, os
import numpy as np, cv2, cairosvg
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import obj, solid, limb, cut, text, open_hand, explosion, cat_bust, INTER800, INTER900, K

def L(c, gap=0, anims=(), eyes=(), blink=None, mood=None):
    return {"c": c, "gap": gap, "anims": list(anims), "eyes": list(eyes), "blink": blink, "mood": mood}

# A face that follows a mood value (0 = the drawing as it is, 1 = the full expression), on top of its layer.
# strokes: cut-out quadratic strokes that morph from a = (x0, y0, cx, cy, x1, y1, width) at mood `start`
#          to b at mood `end` (width 0 = not there), e.g. a mouth curling into a smirk or a brow going up.
# eyes:    an eye hole (cx, cy, rx, ry) with a pupil of radius pupil0 at (cx, cy + 1). Once mood is above 0
#          the hole is redrawn as a lens whose upper and lower halves shrink from ry to top / bottom, and
#          the pupil moves by (dx, dy) and shrinks to pupil1, all at mood 1.
def stroke(a, b, start=0.0, end=1.0):
    return {"a": list(a), "b": list(b), "s": start, "e": end}

def mood_face(strokes, eyes):
    keys = ("cx", "cy", "rx", "ry", "top", "bottom", "pupil0", "pupil1", "dx", "dy")
    return {"strokes": strokes, "eyes": [dict(zip(keys, e)) for e in eyes]}

def rot(a, p, x, y, ph=0.0): return {"t": "rot", "a": a, "p": p, "ph": ph, "x": x, "y": y}
def move(dx, dy, p, ph=0.0): return {"t": "move", "dx": dx, "dy": dy, "p": p, "ph": ph}
def scale(sx, sy, p, x, y, ph=0.0): return {"t": "scale", "sx": sx, "sy": sy, "p": p, "ph": ph, "x": x, "y": y}
def shake(a, f): return {"t": "shake", "a": a, "f": f}
def flash(p, on, ph=0.0): return {"t": "flash", "p": p, "on": on, "ph": ph}

MEMES = {}

# 02 camera grin -----------------------------------------------------------------------------
blob = solid('path d="M200 90 C290 90 320 160 318 250 C316 350 280 420 200 420 C120 420 84 350 86 250 C88 160 110 90 200 90 Z"')
blob += limb("M92 300 Q66 336 86 376", 11, 0) + solid('circle cx="88" cy="382" r="13"')
blob += limb("M170 414 L166 450", 10, 0) + limb("M230 414 L236 450", 10, 0)
blob += solid('circle cx="165" cy="200" r="10"', K) + solid('circle cx="235" cy="196" r="10"', K)
blob += cut("M142 172 Q164 154 188 166", 8) + cut("M216 170 L254 164", 8)
blob += solid('path d="M146 246 Q200 334 266 240 Z"', K)
blob += solid('path d="M156 250 L256 246 L248 266 L166 270 Z"')
cam = limb("M360 340 L322 452", 9, 6) + limb("M360 340 L360 452", 9, 6) + limb("M360 340 L400 452", 9, 6)
cam += obj('rect x="334" y="328" width="52" height="16" rx="5"', 6)
cam += obj('path d="M326 244 L344 216 L388 216 L404 244 Z"', 7)
cam += obj('rect x="290" y="240" width="150" height="92" rx="14"', 8)
cam += obj('rect x="444" y="252" width="30" height="56" rx="5"', 5)
cam += obj('rect x="210" y="254" width="90" height="70" rx="10"', 8)
cam += cut("M232 256 V322 M250 256 V322", 6)
cam += solid('circle cx="420" cy="258" r="6"', K)
MEMES["02_camera_grin"] = [
    L(blob, 0, [rot(2.5, 2.4, 200, 450)], [(165, 200, 12, 12), (235, 196, 12, 12)], (3.0, 0.1, 0.05)),
    L(cam, 8),
    L(solid('circle cx="420" cy="258" r="7.5"'), 0, [flash(1.3, 0.5, 0.25)]),
]

# 03 shocked ---------------------------------------------------------------------------------
body = solid('path d="M240 120 C330 120 360 190 360 275 C360 370 320 420 240 420 C160 420 120 370 120 275 C120 190 150 120 240 120 Z"')
body += limb("M210 414 L198 450", 10, 0) + limb("M270 414 L282 450", 10, 0)
body += solid('ellipse cx="190" cy="454" rx="22" ry="10"') + solid('ellipse cx="290" cy="454" rx="22" ry="10"')
body += solid('circle cx="204" cy="232" r="25"', K) + solid('circle cx="276" cy="232" r="25"', K)
body += solid('circle cx="204" cy="232" r="7"') + solid('circle cx="276" cy="232" r="7"')
body += cut("M178 190 Q204 172 230 186 M250 186 Q276 172 302 190", 8)
body += cut("M214 160 Q240 151 266 160 M220 172 Q240 165 260 172", 5)
body += solid('ellipse cx="240" cy="318" rx="21" ry="27"', K)
body += limb("M126 296 Q74 210 150 154", 12, 0) + limb("M354 296 Q406 210 330 154", 12, 0)
body += obj('circle cx="158" cy="150" r="18"', 6) + obj('circle cx="322" cy="150" r="18"', 6)
MEMES["03_shocked"] = [
    L(body, 0, [shake(1.8, 13)]),
    L(limb("M100 112 L124 136 M84 162 L114 168", 7, 0), 0, [scale(0.12, 0.12, 0.5, 130, 150)]),
    L(limb("M380 112 L356 136 M396 162 L366 168", 7, 0), 0, [scale(0.12, 0.12, 0.5, 350, 150, 0.5)]),
]

# 04 explosion cat ---------------------------------------------------------------------------
MEMES["04_explosion_cat"] = [
    L(explosion(0), 0, [scale(0.03, 0.045, 1.7, 240, 270)]),
    L(limb("M0 300 H480", 5, 0) + limb("M40 330 H120 M330 340 H440 M150 360 H210", 4, 0)),
    L(cat_bust(), 9, [scale(0, 0.012, 2.2, 300, 480)], [(276, 320, 17, 17), (324, 320, 17, 17)], (4.0, 0.2, 0.04)),
]

# 05 investigating ---------------------------------------------------------------------------
body = solid('path d="M270 110 C350 110 380 180 380 270 C380 370 345 425 270 425 C195 425 160 370 160 270 C160 180 190 110 270 110 Z"')
body += limb("M240 420 L234 452", 10, 0) + limb("M300 420 L306 452", 10, 0)
body += solid('circle cx="240" cy="216" r="9"', K) + solid('ellipse cx="300" cy="216" rx="10" ry="6"', K)
body += cut("M218 184 Q240 160 264 176", 8) + cut("M284 196 L322 190", 8)
body += solid('ellipse cx="262" cy="288" rx="10" ry="8"', K)
glass = limb("M150 228 L196 306", 16, 6) + obj('circle cx="128" cy="186" r="48"', 8) + solid('circle cx="128" cy="186" r="35"', K)
glass += limb("M106 170 Q112 154 130 150", 6, 0) + limb("M170 344 Q186 330 196 314", 11, 6) + obj('circle cx="198" cy="310" r="16"', 6)
MEMES["05_investigating"] = [
    L(body, 0, [scale(0, 0.012, 1.8, 270, 450)], [(240, 216, 11, 11), (300, 216, 12, 8)], (2.8, 0.4, 0.05)),
    L(glass, 6, [rot(5, 2.2, 192, 326), move(0, -3, 1.1)]),
]

# 06 train duo -------------------------------------------------------------------------------
left = solid('path d="M130 170 C195 170 215 225 215 300 C215 380 185 430 130 430 C75 430 45 380 45 300 C45 225 65 170 130 170 Z"')
left += cut("M98 256 Q109 264 120 256 M140 256 Q151 264 162 256", 6) + cut("M118 300 H142", 5)
right = solid('path d="M370 150 C440 150 465 210 465 290 C465 375 435 430 370 430 C305 430 275 375 275 290 C275 210 300 150 370 150 Z"')
right += solid('circle cx="322" cy="244" r="8"', K) + solid('circle cx="354" cy="242" r="8"', K)
right += cut("M306 218 Q322 204 338 214", 6) + cut("M346 220 L372 216", 6)
right += solid('ellipse cx="336" cy="296" rx="8" ry="7"', K)
phone = obj('rect x="88" y="318" width="64" height="94" rx="11"', 8) + solid('rect x="97" y="329" width="46" height="66" rx="4"', K)
phone += obj('circle cx="88" cy="372" r="13"', 5) + obj('circle cx="154" cy="366" r="13"', 5)
mag = limb("M222 374 L268 404", 12, 6) + limb("M288 420 Q282 410 272 404", 11, 6)
mag += obj('circle cx="204" cy="356" r="27"', 7) + solid('circle cx="204" cy="356" r="18"', K)
mag += limb("M192 348 Q196 338 206 336", 5, 0) + obj('circle cx="272" cy="404" r="13"', 5)
arrow = limb("M226 132 L160 270", 16, 7) + obj('path d="M140 310 L180 280 L136 262 Z"', 7)
diamond = obj('path d="M240 8 L292 64 L240 128 L188 64 Z"', 7)
diamond += solid('circle cx="224" cy="58" r="6"', K) + solid('circle cx="256" cy="58" r="6"', K) + cut("M230 88 H250", 5)
MEMES["06_train_duo"] = [
    L(left, 0, [scale(0, 0.01, 2.0, 130, 430)]),
    L(right, 0, [scale(0, 0.01, 2.0, 370, 430, 0.5)], [(322, 244, 10, 10), (354, 242, 10, 10)], (2.6, 0.6, 0.05)),
    L(phone, 8),
    L(mag, 6, [rot(6, 1.6, 272, 404)]),
    L(arrow, 7, [move(-3, 7, 0.7)]),
    L(diamond, 7, [move(0, -5, 2.0), rot(6, 3.0, 240, 68)]),
]

# 07 smug cat --------------------------------------------------------------------------------
head = solid('path d="M50 480 Q30 300 86 180 L70 56 L176 128 Q240 108 306 124 L414 58 L398 184 Q452 300 430 480 Z"')
head += solid('path d="M92 168 L84 86 L150 132 Z"', K) + solid('path d="M392 168 L400 88 L332 128 Z"', K)
head += solid('path d="M118 216 Q162 198 210 214 Q166 238 118 216 Z"', K) + solid('path d="M272 210 Q314 194 356 210 Q318 232 272 210 Z"', K)
head += cut("M108 208 Q160 182 216 206 M264 202 Q314 178 364 202", 9)
head += solid('circle cx="194" cy="216" r="5"') + solid('circle cx="340" cy="210" r="5"')
head += solid('path d="M226 298 Q245 286 264 298 Q252 318 245 318 Q238 318 226 298 Z"', K)
head += cut("M245 318 Q252 346 282 340 M245 318 Q236 340 212 336", 5)
head += cut("M302 330 L394 316 M302 344 L398 348 M186 330 L96 318 M186 344 L92 350", 3)
hand = limb("M372 480 L352 432", 30, 7) + limb("M314 388 L270 344", 24, 7) + obj('circle cx="338" cy="412" r="36"', 8)
hand += cut("M314 410 H356 M318 428 H354", 4)
MEMES["07_smug_cat"] = [
    L(head, 0, [rot(1.6, 3.2, 240, 480)]),
    L(hand, 7, [move(-4, -5, 0.55)]),
]

# 08 nerd cat --------------------------------------------------------------------------------
head = solid('path d="M36 430 L36 176 L76 76 L142 150 Q190 136 240 150 L304 76 L330 176 L330 430 Z"')
head += '<rect x="50" y="196" width="112" height="82" rx="16" fill="none" stroke="#000" stroke-width="16"/>'
head += '<rect x="204" y="196" width="112" height="82" rx="16" fill="none" stroke="#000" stroke-width="16"/>'
head += cut("M162 226 Q183 212 204 226", 12) + cut("M50 220 H36", 12)
head += solid('circle cx="106" cy="238" r="23"', K) + solid('circle cx="260" cy="238" r="23"', K)
head += solid('circle cx="113" cy="230" r="6"') + solid('circle cx="267" cy="230" r="6"')
head += solid('path d="M150 322 Q183 300 216 322 Q202 354 183 356 Q164 354 150 322 Z"', K)
head += cut("M183 356 V372", 5)
hand = obj('rect x="372" y="96" width="46" height="230" rx="23"', 9) + obj('rect x="354" y="262" width="112" height="134" rx="42"', 9)
hand += cut("M418 290 Q440 286 462 292 M418 322 Q440 318 462 324 M418 354 Q440 350 460 356", 5)
hand += limb("M362 336 Q392 362 424 342", 22, 7)
hand += solid('rect x="383" y="106" width="24" height="30" rx="10"', K) + solid('rect x="388" y="111" width="14" height="20" rx="6"')
MEMES["08_nerd_cat"] = [
    L(head, 0, [rot(1.2, 2.8, 183, 430)], [(106, 238, 25, 25), (260, 238, 25, 25)], (3.6, 0.5, 0.04)),
    L(hand, 9, [move(0, -9, 0.8), rot(3, 0.8, 410, 400, 0.25)]),
]

# 09 ipod float ------------------------------------------------------------------------------
arcs = "".join(f'<path d="M{240-r} 480 A{r} {r} 0 0 1 {240+r} 480" fill="none" stroke="#fff" stroke-width="7"/>' for r in (300, 324, 348))
clouds = solid('path d="M60 360 Q60 330 92 332 Q100 306 130 316 Q156 304 166 334 Q190 336 186 360 Z"')
clouds += solid('path d="M318 420 Q316 392 346 394 Q356 370 384 380 Q410 370 418 398 Q442 402 438 420 Z"')
def star(cx, cy, r):
    return f'<path d="M{cx} {cy-r} Q{cx} {cy} {cx+r} {cy} Q{cx} {cy} {cx} {cy+r} Q{cx} {cy} {cx-r} {cy} Q{cx} {cy} {cx} {cy-r} Z" fill="#fff"/>'
floaty = limb("M178 238 L166 276 M214 244 L208 284 M292 242 L302 280", 9, 6)
floaty += limb("M384 176 C420 250 330 300 262 382", 4, 4)
floaty += obj('path d="M110 170 C110 118 170 98 240 98 C322 98 380 118 380 170 C380 226 322 246 240 246 C164 246 110 226 110 170 Z"', 8)
floaty += cut("M296 152 Q307 162 318 152 M332 150 Q343 160 354 150", 5) + cut("M312 186 Q328 196 344 184", 5)
floaty += obj('circle cx="380" cy="168" r="11"', 5)
floaty += obj('rect x="240" y="378" width="40" height="64" rx="7"', 6)
floaty += solid('rect x="247" y="386" width="26" height="20" rx="3"', K)
floaty += solid('circle cx="260" cy="424" r="10"', K) + solid('circle cx="260" cy="424" r="4"')
MEMES["09_ipod_float"] = [
    L(arcs),
    L(clouds, 0, [move(10, 0, 7.0)]),
    L(star(80, 90, 16), 0, [scale(0.35, 0.35, 1.3, 80, 90)]),
    L(star(420, 76, 13), 0, [scale(0.35, 0.35, 1.3, 420, 76, 0.33)]),
    L(star(420, 260, 10), 0, [scale(0.35, 0.35, 1.3, 420, 260, 0.66)]),
    L(star(64, 240, 9), 0, [scale(0.35, 0.35, 1.3, 64, 240, 0.5)]),
    L(floaty, 8, [move(0, -9, 3.2), rot(2.5, 4.4, 250, 260)]),
]

# 10 absolute cinema -------------------------------------------------------------------------
chair = solid('rect x="128" y="70" width="224" height="232" rx="42"')
chair += obj('rect x="110" y="292" width="260" height="58" rx="20"', 7)
chair += obj('rect x="66" y="226" width="82" height="124" rx="30"', 7) + obj('rect x="332" y="226" width="82" height="124" rx="30"', 7)
blob = obj('path d="M240 110 C305 110 325 160 325 225 C325 300 295 332 240 332 C185 332 155 300 155 225 C155 160 175 110 240 110 Z"', 9)
blob += solid('circle cx="214" cy="198" r="8"', K) + solid('circle cx="266" cy="198" r="8"', K)
blob += cut("M196 174 L228 178 M252 178 L284 174", 7) + cut("M222 246 Q240 236 258 246", 7)
MEMES["10_absolute_cinema"] = [
    L(chair),
    L(blob, 9, [scale(0, 0.012, 2.4, 240, 332)], [(214, 198, 10, 10), (266, 198, 10, 10)], (4.2, 0.35, 0.04)),
    L(limb("M162 254 Q100 254 104 178", 12, 7) + open_hand(104, 156), 7, [rot(-4, 1.6, 162, 254)]),
    L(limb("M318 254 Q380 254 376 178", 12, 7) + open_hand(376, 156, mirror=True), 7, [rot(4, 1.6, 318, 254)]),
    L(text(INTER800, "ABSOLUTE", 34, 240, 398) + text(INTER900, "CINEMA", 104, 240, 476, max_w=440)),
]

# 11 deadpan ---------------------------------------------------------------------------------
body = solid('path d="M240 70 C330 70 365 130 362 200 C358 280 310 320 240 320 C170 320 120 280 118 200 C115 130 150 70 240 70 Z"')
body += solid('ellipse cx="204" cy="166" rx="17" ry="11"', K) + solid('ellipse cx="276" cy="166" rx="17" ry="11"', K)
body += solid('circle cx="204" cy="167" r="5"') + solid('circle cx="276" cy="167" r="5"')
body += cut("M240 178 L235 204", 4) + solid('ellipse cx="232" cy="208" rx="5" ry="3.5"', K) + solid('ellipse cx="248" cy="208" rx="5" ry="3.5"', K)
# brows and mouth are not drawn here: they are the mood face below, so the app can turn him into a smirk
deadpan_face = mood_face(
    strokes=[
        # brows: his right one (viewer's left) arches up, the other drops a bit and flattens
        stroke((184, 154, 204, 144, 224, 154, 5), (182, 146, 202, 130, 225, 146, 5.5)),
        stroke((256, 154, 276, 144, 296, 154, 5), (255, 157, 276, 151, 298, 152, 5.5)),
        # mouth: flat line to a one-sided smirk, the right corner up
        stroke((212, 250, 240, 245, 268, 250, 7), (208, 253, 230, 259, 272, 236, 7)),
        # lower lip goes away early
        stroke((224, 264, 240, 268, 256, 264, 3), (240, 265, 240, 265, 240, 265, 0), 0, 0.3),
        # dimple by the raised corner
        stroke((284, 238, 284, 238, 284, 238, 0), (282, 229, 289, 237, 283, 246, 4), 0.45, 1),
        # goatee: thin mustache, soul patch, chin beard
        stroke((238, 223, 238, 223, 238, 223, 0), (221, 228, 237, 216, 252, 221, 5), 0.65, 1),
        stroke((240, 293, 240, 293, 240, 293, 0), (240, 288, 240, 293, 240, 300, 8), 0.6, 1),
    ],
    # narrowed, knowing eyes: heavy upper lid, lower lid pushed up, pupil small and level
    eyes=[(204, 166, 17, 11, 6.5, 3.5, 5, 3.6, 1, -1), (276, 166, 17, 11, 5.5, 3, 5, 3.4, 1, 0)],
)
body += limb("M210 316 L204 440", 8, 0) + limb("M270 316 L276 440", 8, 0)
body += solid('ellipse cx="196" cy="446" rx="20" ry="8"') + solid('ellipse cx="284" cy="446" rx="20" ry="8"')
MEMES["11_deadpan"] = [
    L(body, 0, [], [(204, 168, 18.5, 12.5), (276, 168, 18.5, 12.5)], (6.5, 0.2, 0.022),
      deadpan_face),
    L(limb("M130 236 Q108 320 120 400", 8, 0) + solid('ellipse cx="120" cy="410" rx="12" ry="14"'), 0, [rot(0.8, 4.5, 130, 236)]),
    L(limb("M350 236 Q372 320 360 400", 8, 0) + solid('ellipse cx="360" cy="410" rx="12" ry="14"'), 0, [rot(-0.8, 4.5, 350, 236)]),
]

# 12 weirded out (confused, looking off to the side) ----------------------------------------------
suit = obj('path d="M40 480 Q56 410 150 384 L240 432 L330 384 Q424 410 440 480 Z"', 6)
suit += obj('path d="M156 380 L240 434 L200 480 L132 480 Z"', 6) + obj('path d="M324 380 L240 434 L280 480 L348 480 Z"', 6)
suit += obj('path d="M226 432 L254 432 L262 480 L218 480 Z"', 6)
head = obj('path d="M240 40 C360 40 405 120 400 230 C395 340 330 400 240 400 C150 400 85 340 80 230 C75 120 120 40 240 40 Z"', 8)
head += solid('ellipse cx="178" cy="208" rx="19" ry="10"', K) + solid('ellipse cx="294" cy="204" rx="19" ry="13"', K)
head += cut("M156 200 Q178 190 200 202", 6)
head += cut("M140 170 L206 186", 13) + cut("M262 160 Q294 140 328 154", 12)
head += cut("M222 170 L226 192 M236 168 L238 190", 5)
head += cut("M234 216 Q220 258 240 266", 6)
head += solid('ellipse cx="270" cy="318" rx="12" ry="9" transform="rotate(-15 270 318)"', K) + cut("M290 304 Q298 316 291 330", 4)
pupils = solid('circle cx="190" cy="205" r="6"') + solid('circle cx="306" cy="200" r="6.5"')
tilt = rot(3, 3.6, 240, 400)
MEMES["12_suspicious"] = [
    L(suit),
    L(head, 8, [tilt]),
    # the pupils glance around but never at the camera; blinking shuts them too
    L(pupils, 0, [move(3, 1, 3.0), tilt], [(178, 208, 21, 12), (294, 204, 21, 15)], (4.2, 0.7, 0.04)),
]

# 14 suit cat, thumbs up ---------------------------------------------------------------------
torso = solid('path d="M150 480 Q160 300 226 252 L300 236 L374 252 Q440 300 450 480 Z"')
torso += obj('path d="M266 246 L300 330 L334 246 Z"', 5)
torso += obj('path d="M292 262 L308 262 L314 330 L300 350 L286 330 Z"', 5)
torso += cut("M264 246 L248 322 L300 404 M336 246 L352 322 L300 404", 5)
cathead = obj('path d="M240 140 L232 60 L272 95 Q300 88 328 95 L368 60 L360 140 Q372 190 340 222 Q300 245 260 222 Q228 190 240 140 Z"', 8)
cathead += solid('path d="M244 124 L240 84 L262 104 Z"', K) + solid('path d="M356 124 L360 84 L338 104 Z"', K)
cathead += solid('circle cx="280" cy="146" r="10"', K) + solid('circle cx="320" cy="146" r="10"', K)
cathead += solid('circle cx="283" cy="142" r="3"') + solid('circle cx="323" cy="142" r="3"')
cathead += solid('path d="M293 170 L307 170 L300 179 Z"', K)
cathead += cut("M300 179 Q292 190 284 186 M300 179 Q308 190 316 186", 4)
thumb = limb("M230 360 L140 300", 50, 8) + obj('rect x="72" y="100" width="40" height="130" rx="20"', 8)
thumb += obj('rect x="60" y="196" width="112" height="128" rx="40"', 9)
thumb += cut("M112 226 H166 M112 256 H168 M112 286 H164", 5) + limb("M70 250 Q86 230 112 226", 6, 0)
MEMES["14_thumbs_up_cat"] = [
    L(torso, 0, [scale(0, 0.01, 2.0, 300, 480)]),
    L(cathead, 8, [rot(4, 1.6, 300, 236)], [(280, 146, 12, 12), (320, 146, 12, 12)], (3.0, 0.3, 0.05)),
    L(thumb, 9, [rot(-6, 0.8, 230, 360)]),
]

# ---------------------------------------------------------------------------------------------
PX = 1440
KK = 480 / PX

def alpha_of(content):
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480"><rect width="480" height="480" fill="#000"/>{content}</svg>'
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=PX, output_height=PX)
    return np.array(Image.open(io.BytesIO(png)).convert("L"))

from tracer import contours_to_d as _ctd
def contours_to_d(cs, eps=1.1, min_area=40):
    return _ctd(cs, KK, eps=eps, min_area=min_area)

def build():
    data = {}
    for name, layers in MEMES.items():
        out = []
        for lay in layers:
            a = alpha_of(lay["c"])
            _, bw = cv2.threshold(a, 127, 255, cv2.THRESH_BINARY)
            cs, _ = cv2.findContours(bw, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
            entry = {"d": contours_to_d(cs)}
            if lay["gap"]:
                ext, _ = cv2.findContours(bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
                solid_mask = np.zeros_like(bw)
                cv2.drawContours(solid_mask, ext, -1, 255, -1)
                r = int(round(lay["gap"] / KK))
                k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
                grown = cv2.dilate(solid_mask, k)
                gcs, _ = cv2.findContours(grown, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
                entry["gap"] = contours_to_d(gcs, eps=1.6)
            if lay["anims"]:
                entry["anims"] = lay["anims"]
            if lay["eyes"]:
                entry["eyes"] = [list(e) for e in lay["eyes"]]
                entry["blink"] = list(lay["blink"])
            if lay["mood"]:
                entry["mood"] = lay["mood"]
            out.append(entry)
        data[name] = out
    return data

if __name__ == "__main__":
    data = build()
    json.dump(data, open(sys.argv[1], "w"), separators=(",", ":"))
    print({k: sum(len(l["d"]) + len(l.get("gap", "")) for l in v) for k, v in data.items()})
