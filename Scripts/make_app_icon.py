#!/usr/bin/env python3
"""Draws the app icon, Packaging/AppIcon.icns, from the logo in
docs/assets/sandseek-logo.svg (the same shapes, drawn with Pillow, since the
SVG cannot be rendered without extra tools). The rounded square fills 824 of
1024 pixels, as Apple's icon grid asks.

    python3 Scripts/make_app_icon.py Packaging/AppIcon.icns
"""
import sys
from PIL import Image, ImageDraw

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i]-a[i])*t)) for i in range(3))
def hexc(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))

def vgrad(size, top, bottom, y0, y1, S):
    g = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(g)
    for y in range(size):
        t = min(max((y/S - y0) / (y1 - y0), 0), 1)
        d.line([(0, y), (size, y)], fill=lerp(hexc(top), hexc(bottom), t))
    return g

def cubic(p0, p1, p2, p3, n=200):
    out = []
    for i in range(n+1):
        t = i/n; u = 1-t
        out.append((u**3*p0[0]+3*u*u*t*p1[0]+3*u*t*t*p2[0]+t**3*p3[0],
                    u**3*p0[1]+3*u*u*t*p1[1]+3*u*t*t*p2[1]+t**3*p3[1]))
    return out

def render(px):
    SS = 4; size = px*SS; S = size/256
    sc = lambda pts: [(x*S, y*S) for x, y in pts]
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # background rounded square, vertical gradient
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([8*S, 8*S, 248*S, 248*S], radius=56*S, fill=255)
    img.paste(vgrad(size, "#1F3A5F", "#0F2236", 8, 248, S), (0, 0), mask)
    # lens view
    view = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    vd = ImageDraw.Draw(view)
    vd.rectangle([40*S, 40*S, 190*S, 190*S], fill=hexc("#9CC9E8"))
    vd.ellipse([126*S, 72*S, 154*S, 100*S], fill=hexc("#FFF3C4"))
    d1 = cubic((40,140),(70,112),(100,112),(128,132)) + cubic((128,132),(150,148),(170,128),(190,118)) + [(190,190),(40,190)]
    m1 = Image.new("L", (size, size), 0); ImageDraw.Draw(m1).polygon(sc(d1), fill=255)
    view.paste(vgrad(size, "#F2C879", "#D99A3E", 112, 190, S), (0, 0), m1)
    d2 = cubic((40,160),(72,146),(104,150),(132,166)) + cubic((132,166),(154,178),(172,170),(190,160)) + [(190,190),(40,190)]
    m2 = Image.new("L", (size, size), 0); ImageDraw.Draw(m2).polygon(sc(d2), fill=255)
    view.paste(vgrad(size, "#E3A954", "#B9772A", 146, 190, S), (0, 0), m2)
    lens = Image.new("L", (size, size), 0)
    ImageDraw.Draw(lens).ellipse([50*S, 50*S, 174*S, 174*S], fill=255)
    img.paste(view, (0, 0), lens)
    d = ImageDraw.Draw(img)
    rim = hexc("#F5F7FA")
    # rim: circle r=62 stroke 14 -> outer 69, inner 55
    ring = Image.new("L", (size, size), 0); rd = ImageDraw.Draw(ring)
    rd.ellipse([43*S, 43*S, 181*S, 181*S], fill=255); rd.ellipse([57*S, 57*S, 167*S, 167*S], fill=0)
    img.paste(Image.new("RGBA", (size, size), rim + (255,)), (0, 0), ring)
    # handle: line 158,158 -> 204,204 width 22, round caps
    d.line([158*S, 158*S, 204*S, 204*S], fill=rim + (255,), width=int(22*S))
    for cx in (158, 204):
        d.ellipse([(cx-11)*S, (cx-11)*S, (cx+11)*S, (cx+11)*S], fill=rim + (255,))
    return img.resize((px, px), Image.LANCZOS)

def app_icon():
    """The 1024-pixel icon: the logo's rounded square on Apple's grid."""
    art = render(int(round(824 * 256 / 240)))  # the square (8..248) becomes 824 px
    s = art.size[0] / 256
    left = round(8 * s)
    square = art.crop((left, left, left + 824, left + 824))
    icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    icon.paste(square, (100, 100), square)
    return icon


if __name__ == "__main__":
    app_icon().save(sys.argv[1], sizes=[(16, 16), (32, 32), (64, 64), (128, 128),
                                        (256, 256), (512, 512), (1024, 1024)])
