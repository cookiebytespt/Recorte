"""Regenerates recorte-banner-light.svg and recorte-banner-dark.svg (text as outlines).

Needs: pip install fonttools uharfbuzz
Fonts: download BricolageGrotesque[opsz,wdth,wght].ttf from github.com/google/fonts (ofl/bricolagegrotesque)
as bg.ttf next to this script, then make the two static instances it expects:

    python3 -c "from fontTools.ttLib import TTFont; from fontTools.varLib.instancer import instantiateVariableFont as i
    for n,l in (('bold',dict(wght=600,opsz=96,wdth=100)),('reg',dict(wght=400,opsz=24,wdth=100))):
        f=TTFont('bg.ttf'); i(f,l,inplace=True); f.save(n+'.ttf')"

Run from this folder: python3 make-banner.py
"""
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

def outline(fontfile, text, size, x, baseline, tracking_em=0.0):
    data = open(fontfile, "rb").read()
    face = hb.Face(data); font = hb.Font(face)
    buf = hb.Buffer(); buf.add_str(text); buf.guess_segment_properties()
    hb.shape(font, buf, {"kern": True, "liga": True})
    tt = TTFont(fontfile); gs = tt.getGlyphSet(); order = tt.getGlyphOrder()
    upm = tt["head"].unitsPerEm; s = size / upm
    pen = SVGPathPen(gs); cx = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        g = order[info.codepoint]
        gs[g].draw(TransformPen(pen, (s, 0, 0, -s, x + (cx + pos.x_offset) * s, baseline - pos.y_offset * s)))
        cx += pos.x_advance + tracking_em * upm
    width = (cx - tracking_em * upm) * s
    return pen.getCommands(), width

ICON = '''<g transform="translate({x} {y}) scale({k})">
<rect x="100" y="100" width="824" height="824" rx="185" fill="#E8553D"/>
<path d="M332 292 H692 Q732 292 732 332 V590 L590 732 H332 Q292 732 292 692 V332 Q292 292 332 292 Z" fill="#FFFFFF"/>
<path d="M420 640 V384 H520 A64 64 0 0 1 520 512 H420 M500 512 L560 628" fill="none" stroke="#E8553D" stroke-width="56" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M732 590 L590 732 Q584 612 590 590 Q612 584 732 590 Z" fill="#EADFD6"/>
</g>'''

W, H = 1600, 480
icon_px = 340                        # visible tile = 824/1024 of this
k = icon_px / 1024
gap = 40
_, ww = outline("bold.ttf", "Recorte", 200, 0, 0, -0.01)
_, sw = outline("reg.ttf", "cutting studio for macOS", 46, 0, 0)
text_w = max(ww, sw)
total = icon_px * 824/1024 + gap + text_w
left = (W - total) / 2
icon_x = left - 100 * k
tx = left + icon_px * 824/1024 + gap
word, _ = outline("bold.ttf", "Recorte", 200, tx, 262, -0.01)
slog, _ = outline("reg.ttf", "cutting studio for macOS", 46, tx + 8, 336)

for mode, bg, fg, sub in (("light", "#FAF8F5", "#16181D", "#5E626B"), ("dark", "#16181D", "#FFFFFF", "#A3A7B0")):
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="Recorte — cutting studio for macOS">
<title>Recorte — cutting studio for macOS</title>
<rect width="{W}" height="{H}" rx="32" fill="{bg}"/>
{ICON.format(x=round(icon_x,2), y=round((H-icon_px)/2,2), k=round(k,5))}
<path d="{word}" fill="{fg}"/>
<path d="{slog}" fill="{sub}"/>
</svg>
'''
    open(f"recorte-banner-{mode}.svg", "w").write(svg)
print(ww, sw)
