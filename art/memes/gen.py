import os, sys
import cairosvg
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

HERE = os.path.dirname(os.path.abspath(__file__))
LIME = "#E8FD6E"
W, K = "#fff", "#000"
F = HERE + "/fonts/fontsource-{}-5.3.0/package/files/{}"
INTER900 = F.format("inter", "inter-latin-900-normal.woff2")
INTER800 = F.format("inter", "inter-latin-800-normal.woff2")

# ---------- helpers (mask language: white = lime, black = cut out) ----------
def obj(el, gap=8):
    return (f'<{el} fill="{K}" stroke="{K}" stroke-width="{2*gap}" stroke-linejoin="round"/>'
            f'<{el} fill="{W}"/>')

def solid(el, c=W):
    return f'<{el} fill="{c}"/>'

def limb(d, w=11, gap=6):
    out = ""
    if gap:
        out += f'<path d="{d}" fill="none" stroke="{K}" stroke-width="{w+2*gap}" stroke-linecap="round" stroke-linejoin="round"/>'
    return out + f'<path d="{d}" fill="none" stroke="{W}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>'

def cut(d, w=6):
    return f'<path d="{d}" fill="none" stroke="{K}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>'

def text_d(fontpath, s, size, cx, baseline, max_w=None):
    font = TTFont(fontpath)
    gs = font.getGlyphSet(); cmap = font.getBestCmap(); hmtx = font["hmtx"]
    upm = font["head"].unitsPerEm
    names = [cmap[ord(ch)] for ch in s]
    total = sum(hmtx[n][0] for n in names)
    sc = size / upm
    if max_w and total * sc > max_w:
        sc = max_w / total
    x = cx - total * sc / 2
    d = ""
    for n in names:
        pen = SVGPathPen(gs)
        gs[n].draw(TransformPen(pen, (sc, 0, 0, -sc, x, baseline)))
        d += pen.getCommands()
        x += hmtx[n][0] * sc
    return d

def text(fontpath, s, size, cx, baseline, c=W, max_w=None):
    return f'<path fill="{c}" d="{text_d(fontpath, s, size, cx, baseline, max_w)}"/>'

def open_hand(px, py, mirror=False):
    m = -1 if mirror else 1
    fingers = [(-14, -12, -22, -50), (-5, -18, -8, -58), (6, -18, 8, -58), (15, -12, 22, -46)]
    thumb = (8, 10, 26, -2)
    segs = [f"M{px+m*a} {py+b} L{px+m*c} {py+d}" for a, b, c, d in fingers + [thumb]]
    out = ""
    for s in segs:
        out += f'<path d="{s}" stroke="{K}" stroke-width="22" stroke-linecap="round"/>'
    out += f'<circle cx="{px}" cy="{py}" r="26" fill="{K}"/>'
    for s in segs:
        out += f'<path d="{s}" stroke="{W}" stroke-width="10" stroke-linecap="round"/>'
    return out + f'<circle cx="{px}" cy="{py}" r="20" fill="{W}"/>'

# ---------- the pieces ----------
def cat_bust():
    # frontal tabby bust, used by the explosion memes
    s = obj('path d="M230 300 L222 228 L264 262 Q300 250 336 262 L378 228 L370 300 Q388 345 366 382 Q346 410 300 412 Q254 410 234 382 Q212 345 230 300 Z"', 9)
    s += solid('path d="M242 392 Q236 440 226 486 L374 486 Q364 440 358 392 Q330 414 300 414 Q270 414 242 392 Z"')
    s += solid('path d="M236 288 L231 248 L256 268 Z"', K) + solid('path d="M364 288 L369 248 L344 268 Z"', K)
    s += cut("M290 272 L292 292 M300 268 V294 M310 272 L308 292", 4)
    s += solid('circle cx="276" cy="320" r="15"', K) + solid('circle cx="324" cy="320" r="15"', K)
    s += solid('circle cx="281" cy="314" r="4"') + solid('circle cx="329" cy="314" r="4"')
    s += solid('path d="M291 350 L309 350 L300 361 Z"', K)
    s += cut("M300 361 Q293 373 283 369 M300 361 Q307 373 317 369", 4)
    s += cut("M262 398 Q300 420 338 398", 4)
    return s

def explosion(y=0, lines=True):
    s = f'<g transform="translate(0 {y})">'
    for cx, cy, r in [(120, 150, 70), (210, 110, 88), (312, 118, 80), (392, 168, 62), (72, 205, 50), (240, 185, 92), (160, 212, 62), (330, 212, 62)]:
        s += solid(f'circle cx="{cx}" cy="{cy}" r="{r}"')
    s += solid('rect x="34" y="226" width="412" height="44" rx="22"')
    if lines: s += cut("M150 116 Q172 96 198 108 M262 88 Q286 72 310 86 M350 140 Q372 128 392 142 M96 182 Q112 168 132 176 M196 160 Q214 150 236 158 M284 168 Q300 156 320 164", 6)
    return s + "</g>"

PIECES = {}

def piece(name):
    def deco(f):
        PIECES[name] = f
        return f
    return deco

@piece("02_camera_grin")
def p02():
    s = solid('path d="M200 90 C290 90 320 160 318 250 C316 350 280 420 200 420 C120 420 84 350 86 250 C88 160 110 90 200 90 Z"')
    s += limb("M92 300 Q66 336 86 376", 11, 0) + solid('circle cx="88" cy="382" r="13"')
    s += limb("M170 414 L166 450", 10, 0) + limb("M230 414 L236 450", 10, 0)
    s += solid('circle cx="165" cy="200" r="10"', K) + solid('circle cx="235" cy="196" r="10"', K)
    s += cut("M142 172 Q164 154 188 166", 8) + cut("M216 170 L254 164", 8)
    s += solid('path d="M146 246 Q200 334 266 240 Z"', K)
    s += solid('path d="M156 250 L256 246 L248 266 L166 270 Z"')
    for x in (346, 372, 398):
        pass
    s += limb("M360 340 L322 452", 9, 6) + limb("M360 340 L360 452", 9, 6) + limb("M360 340 L400 452", 9, 6)
    s += obj('rect x="334" y="328" width="52" height="16" rx="5"', 6)
    s += obj('path d="M326 244 L344 216 L388 216 L404 244 Z"', 7)
    s += obj('rect x="290" y="240" width="150" height="92" rx="14"', 8)
    s += obj('rect x="444" y="252" width="30" height="56" rx="5"', 5)
    s += obj('rect x="210" y="254" width="90" height="70" rx="10"', 8)
    s += cut("M232 256 V322 M250 256 V322", 6)
    s += solid('circle cx="420" cy="258" r="6"', K)
    return s

@piece("03_shocked")
def p03():
    s = solid('path d="M240 120 C330 120 360 190 360 275 C360 370 320 420 240 420 C160 420 120 370 120 275 C120 190 150 120 240 120 Z"')
    s += limb("M210 414 L198 450", 10, 0) + limb("M270 414 L282 450", 10, 0)
    s += solid('ellipse cx="190" cy="454" rx="22" ry="10"') + solid('ellipse cx="290" cy="454" rx="22" ry="10"')
    s += solid('circle cx="204" cy="232" r="25"', K) + solid('circle cx="276" cy="232" r="25"', K)
    s += solid('circle cx="204" cy="232" r="7"') + solid('circle cx="276" cy="232" r="7"')
    s += cut("M178 190 Q204 172 230 186 M250 186 Q276 172 302 190", 8)
    s += cut("M214 160 Q240 151 266 160 M220 172 Q240 165 260 172", 5)
    s += solid('ellipse cx="240" cy="318" rx="21" ry="27"', K)
    s += limb("M126 296 Q74 210 150 154", 12, 0) + limb("M354 296 Q406 210 330 154", 12, 0)
    s += obj('circle cx="158" cy="150" r="18"', 6) + obj('circle cx="322" cy="150" r="18"', 6)
    s += limb("M100 112 L124 136 M84 162 L114 168 M380 112 L356 136 M396 162 L366 168", 7, 0)
    return s

@piece("04_explosion_cat")
def p04():
    s = explosion(0)
    s += limb("M0 300 H480", 5, 0) + limb("M40 330 H120 M330 340 H440 M150 360 H210", 4, 0)
    s += '<g>' + cat_bust().replace('fill="#fff"/>', 'fill="#fff"/>', 1) + '</g>'
    return s

@piece("05_investigating")
def p05():
    s = solid('path d="M270 110 C350 110 380 180 380 270 C380 370 345 425 270 425 C195 425 160 370 160 270 C160 180 190 110 270 110 Z"')
    s += limb("M240 420 L234 452", 10, 0) + limb("M300 420 L306 452", 10, 0)
    s += solid('circle cx="240" cy="216" r="9"', K) + solid('ellipse cx="300" cy="216" rx="10" ry="6"', K)
    s += cut("M218 184 Q240 160 264 176", 8) + cut("M284 196 L322 190", 8)
    s += solid('ellipse cx="262" cy="288" rx="10" ry="8"', K)
    s += limb("M150 228 L196 306", 16, 6)
    s += obj('circle cx="128" cy="186" r="48"', 8)
    s += solid('circle cx="128" cy="186" r="35"', K)
    s += limb("M106 170 Q112 154 130 150", 6, 0)
    s += limb("M170 344 Q186 330 196 314", 11, 6)
    s += obj('circle cx="198" cy="310" r="16"', 6)
    return s

@piece("06_train_duo")
def p06():
    s = solid('path d="M130 170 C195 170 215 225 215 300 C215 380 185 430 130 430 C75 430 45 380 45 300 C45 225 65 170 130 170 Z"')
    s += cut("M98 256 Q109 264 120 256 M140 256 Q151 264 162 256", 6) + cut("M118 300 H142", 5)
    s += solid('path d="M370 150 C440 150 465 210 465 290 C465 375 435 430 370 430 C305 430 275 375 275 290 C275 210 300 150 370 150 Z"')
    s += solid('circle cx="322" cy="244" r="8"', K) + solid('circle cx="354" cy="242" r="8"', K)
    s += cut("M306 218 Q322 204 338 214", 6) + cut("M346 220 L372 216", 6)
    s += solid('ellipse cx="336" cy="296" rx="8" ry="7"', K)
    s += obj('rect x="88" y="318" width="64" height="94" rx="11"', 8)
    s += solid('rect x="97" y="329" width="46" height="66" rx="4"', K)
    s += obj('circle cx="88" cy="372" r="13"', 5) + obj('circle cx="154" cy="366" r="13"', 5)
    s += limb("M222 374 L268 404", 12, 6)
    s += limb("M288 420 Q282 410 272 404", 11, 6)
    s += obj('circle cx="204" cy="356" r="27"', 7) + solid('circle cx="204" cy="356" r="18"', K)
    s += limb("M192 348 Q196 338 206 336", 5, 0)
    s += obj('circle cx="272" cy="404" r="13"', 5)
    s += limb("M226 132 L160 270", 16, 7)
    s += obj('path d="M140 310 L180 280 L136 262 Z"', 7)
    s += obj('path d="M240 8 L292 64 L240 128 L188 64 Z"', 7)
    s += solid('circle cx="224" cy="58" r="6"', K) + solid('circle cx="256" cy="58" r="6"', K) + cut("M230 88 H250", 5)
    return s

@piece("07_smug_cat")
def p07():
    s = solid('path d="M50 480 Q30 300 86 180 L70 56 L176 128 Q240 108 306 124 L414 58 L398 184 Q452 300 430 480 Z"')
    s += solid('path d="M92 168 L84 86 L150 132 Z"', K) + solid('path d="M392 168 L400 88 L332 128 Z"', K)
    s += solid('path d="M118 216 Q162 198 210 214 Q166 238 118 216 Z"', K) + solid('path d="M272 210 Q314 194 356 210 Q318 232 272 210 Z"', K)
    s += cut("M108 208 Q160 182 216 206 M264 202 Q314 178 364 202", 9)
    s += solid('circle cx="194" cy="216" r="5"') + solid('circle cx="340" cy="210" r="5"')
    s += solid('path d="M226 298 Q245 286 264 298 Q252 318 245 318 Q238 318 226 298 Z"', K)
    s += cut("M245 318 Q252 346 282 340 M245 318 Q236 340 212 336", 5)
    s += cut("M302 330 L394 316 M302 344 L398 348 M186 330 L96 318 M186 344 L92 350", 3)
    s += limb("M372 480 L352 432", 30, 7)
    s += limb("M314 388 L270 344", 24, 7)
    s += obj('circle cx="338" cy="412" r="36"', 8)
    s += cut("M314 410 H356 M318 428 H354", 4)
    return s

@piece("08_nerd_cat")
def p08():
    s = solid('path d="M36 430 L36 176 L76 76 L142 150 Q190 136 240 150 L304 76 L330 176 L330 430 Z"')
    s += '<rect x="50" y="196" width="112" height="82" rx="16" fill="none" stroke="#000" stroke-width="16"/>'
    s += '<rect x="204" y="196" width="112" height="82" rx="16" fill="none" stroke="#000" stroke-width="16"/>'
    s += cut("M162 226 Q183 212 204 226", 12) + cut("M50 220 H36", 12)
    s += solid('circle cx="106" cy="238" r="23"', K) + solid('circle cx="260" cy="238" r="23"', K)
    s += solid('circle cx="113" cy="230" r="6"') + solid('circle cx="267" cy="230" r="6"')
    s += solid('path d="M150 322 Q183 300 216 322 Q202 354 183 356 Q164 354 150 322 Z"', K)
    s += cut("M183 356 V372", 5)
    s += obj('rect x="372" y="96" width="46" height="230" rx="23"', 9)
    s += obj('rect x="354" y="262" width="112" height="134" rx="42"', 9)
    s += cut("M418 290 Q440 286 462 292 M418 322 Q440 318 462 324 M418 354 Q440 350 460 356", 5)
    s += limb("M362 336 Q392 362 424 342", 22, 7)
    s += solid('rect x="383" y="106" width="24" height="30" rx="10"', K)
    s += solid('rect x="388" y="111" width="14" height="20" rx="6"')
    return s

@piece("09_ipod_float")
def p09():
    s = ""
    for r in (300, 324, 348):
        s += f'<path d="M{240-r} 480 A{r} {r} 0 0 1 {240+r} 480" fill="none" stroke="#fff" stroke-width="7"/>'
    s += solid('path d="M60 360 Q60 330 92 332 Q100 306 130 316 Q156 304 166 334 Q190 336 186 360 Z"')
    s += solid('path d="M318 420 Q316 392 346 394 Q356 370 384 380 Q410 370 418 398 Q442 402 438 420 Z"')
    for cx, cy, r in [(80, 90, 16), (420, 76, 13), (420, 260, 10), (64, 240, 9)]:
        s += f'<path d="M{cx} {cy-r} Q{cx} {cy} {cx+r} {cy} Q{cx} {cy} {cx} {cy+r} Q{cx} {cy} {cx-r} {cy} Q{cx} {cy} {cx} {cy-r} Z" fill="#fff"/>'
    s += limb("M178 238 L166 276 M214 244 L208 284 M292 242 L302 280", 9, 6)
    s += limb("M384 176 C420 250 330 300 262 382", 4, 4)
    s += obj('path d="M110 170 C110 118 170 98 240 98 C322 98 380 118 380 170 C380 226 322 246 240 246 C164 246 110 226 110 170 Z"', 8)
    s += cut("M296 152 Q307 162 318 152 M332 150 Q343 160 354 150", 5)
    s += cut("M312 186 Q328 196 344 184", 5)
    s += obj('circle cx="380" cy="168" r="11"', 5)
    s += obj('rect x="240" y="378" width="40" height="64" rx="7"', 6)
    s += solid('rect x="247" y="386" width="26" height="20" rx="3"', K)
    s += solid('circle cx="260" cy="424" r="10"', K) + solid('circle cx="260" cy="424" r="4"')
    return s

@piece("10_absolute_cinema")
def p10():
    s = solid('rect x="128" y="70" width="224" height="232" rx="42"')
    s += obj('rect x="110" y="292" width="260" height="58" rx="20"', 7)
    s += obj('rect x="66" y="226" width="82" height="124" rx="30"', 7) + obj('rect x="332" y="226" width="82" height="124" rx="30"', 7)
    s += obj('path d="M240 110 C305 110 325 160 325 225 C325 300 295 332 240 332 C185 332 155 300 155 225 C155 160 175 110 240 110 Z"', 9)
    s += solid('circle cx="214" cy="198" r="8"', K) + solid('circle cx="266" cy="198" r="8"', K)
    s += cut("M196 174 L228 178 M252 178 L284 174", 7)
    s += cut("M222 246 Q240 236 258 246", 7)
    s += limb("M162 254 Q100 254 104 178", 12, 7) + limb("M318 254 Q380 254 376 178", 12, 7)
    s += open_hand(104, 156) + open_hand(376, 156, mirror=True)
    s += text(INTER800, "ABSOLUTE", 34, 240, 398)
    s += text(INTER900, "CINEMA", 104, 240, 476, max_w=440)
    return s

@piece("11_deadpan")
def p11():
    s = solid('path d="M240 70 C330 70 365 130 362 200 C358 280 310 320 240 320 C170 320 120 280 118 200 C115 130 150 70 240 70 Z"')
    s += solid('ellipse cx="204" cy="166" rx="17" ry="11"', K) + solid('ellipse cx="276" cy="166" rx="17" ry="11"', K)
    s += solid('circle cx="204" cy="167" r="5"') + solid('circle cx="276" cy="167" r="5"')
    s += cut("M184 154 Q204 144 224 154 M256 154 Q276 144 296 154", 5)
    s += cut("M240 178 L235 204", 4) + solid('ellipse cx="232" cy="208" rx="5" ry="3.5"', K) + solid('ellipse cx="248" cy="208" rx="5" ry="3.5"', K)
    s += cut("M212 250 Q240 245 268 250", 7) + cut("M224 264 Q240 268 256 264", 3)
    s += limb("M130 236 Q108 320 120 400", 8, 0) + limb("M350 236 Q372 320 360 400", 8, 0)
    s += solid('ellipse cx="120" cy="410" rx="12" ry="14"') + solid('ellipse cx="360" cy="410" rx="12" ry="14"')
    s += limb("M210 316 L204 440", 8, 0) + limb("M270 316 L276 440", 8, 0)
    s += solid('ellipse cx="196" cy="446" rx="20" ry="8"') + solid('ellipse cx="284" cy="446" rx="20" ry="8"')
    return s

@piece("12_suspicious")
def p12():
    s = obj('path d="M40 480 Q56 410 150 384 L240 432 L330 384 Q424 410 440 480 Z"', 6)
    s += obj('path d="M156 380 L240 434 L200 480 L132 480 Z"', 6) + obj('path d="M324 380 L240 434 L280 480 L348 480 Z"', 6)
    s += obj('path d="M226 432 L254 432 L262 480 L218 480 Z"', 6)
    s += obj('path d="M240 40 C360 40 405 120 400 230 C395 340 330 400 240 400 C150 400 85 340 80 230 C75 120 120 40 240 40 Z"', 8)
    s += solid('ellipse cx="178" cy="208" rx="19" ry="10"', K) + solid('ellipse cx="294" cy="204" rx="19" ry="13"', K)
    s += cut("M156 200 Q178 190 200 202", 6)
    s += cut("M140 170 L206 186", 13) + cut("M262 160 Q294 140 328 154", 12)
    s += cut("M222 170 L226 192 M236 168 L238 190", 5)
    s += cut("M234 216 Q220 258 240 266", 6)
    s += solid('ellipse cx="270" cy="318" rx="12" ry="9" transform="rotate(-15 270 318)"', K) + cut("M290 304 Q298 316 291 330", 4)
    s += solid('circle cx="190" cy="205" r="6"') + solid('circle cx="306" cy="200" r="6.5"')
    return s

@piece("14_thumbs_up_cat")
def p14():
    s = solid('path d="M150 480 Q160 300 226 252 L300 236 L374 252 Q440 300 450 480 Z"')
    s += obj('path d="M266 246 L300 330 L334 246 Z"', 5)
    s += obj('path d="M292 262 L308 262 L314 330 L300 350 L286 330 Z"', 5)
    s += cut("M264 246 L248 322 L300 404 M336 246 L352 322 L300 404", 5)
    s += obj('path d="M240 140 L232 60 L272 95 Q300 88 328 95 L368 60 L360 140 Q372 190 340 222 Q300 245 260 222 Q228 190 240 140 Z"', 8)
    s += solid('path d="M244 124 L240 84 L262 104 Z"', K) + solid('path d="M356 124 L360 84 L338 104 Z"', K)
    s += solid('circle cx="280" cy="146" r="10"', K) + solid('circle cx="320" cy="146" r="10"', K)
    s += solid('circle cx="283" cy="142" r="3"') + solid('circle cx="323" cy="142" r="3"')
    s += solid('path d="M293 170 L307 170 L300 179 Z"', K)
    s += cut("M300 179 Q292 190 284 186 M300 179 Q308 190 316 186", 4)
    s += limb("M230 360 L140 300", 50, 8)
    s += obj('rect x="72" y="100" width="40" height="130" rx="20"', 8)
    s += obj('rect x="60" y="196" width="112" height="128" rx="40"', 9)
    s += cut("M112 226 H166 M112 256 H168 M112 286 H164", 5)
    s += limb("M70 250 Q86 230 112 226", 6, 0)
    return s

def wrap(content):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480" width="480" height="480">'
            '<defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="480" height="480">'
            f'<rect width="480" height="480" fill="#000"/>{content}</mask></defs>'
            f'<rect width="480" height="480" fill="{LIME}" mask="url(#m)"/></svg>')

def render(name, content, out, px=1440):
    import io, numpy as np, cv2
    from PIL import Image
    mask_svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480">'
                f'<rect width="480" height="480" fill="#000"/>{content}</svg>')
    png = cairosvg.svg2png(bytestring=mask_svg.encode(), output_width=px, output_height=px)
    a = np.array(Image.open(io.BytesIO(png)).convert("L"))
    rgba = np.zeros((px, px, 4), np.uint8)
    rgba[..., 0], rgba[..., 1], rgba[..., 2] = 0xE8, 0xFD, 0x6E
    rgba[..., 3] = a
    Image.fromarray(rgba, "RGBA").save(f"{out}/{name}.png", optimize=True)
    # clean vector: trace the rendered silhouette into one lime path
    _, bw = cv2.threshold(a, 127, 255, cv2.THRESH_BINARY)
    cs, _ = cv2.findContours(bw, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
    from tracer import contours_to_d
    d = contours_to_d(cs, 480 / px, eps=1.1, min_area=30, nd=2)
    open(f"{out}/{name}.svg", "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480" width="480" height="480">'
        f'<path fill="{LIME}" fill-rule="evenodd" d="{d}"/></svg>')

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    only = sys.argv[2:] or list(PIECES)
    for name in only:
        render(name, PIECES[name](), out)
