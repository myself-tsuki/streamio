#!/usr/bin/env python3
"""Renders Streamio's app icon into Assets.xcassets/AppIcon.appiconset (needs Pillow).

The mark: a camera lens on a graphite squircle, broadcast arcs on either side and a red
on-air dot, drawn at 4x and downsampled for clean edges.
"""
import json
import math
import os
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled 1024 canvas (2x; keeps memory low)
OUT = os.path.join(os.path.dirname(__file__), "..", "Streamio", "Assets.xcassets", "AppIcon.appiconset")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return mask


def render():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset = int(S * 100 / 1024)
    radius = int(S * 185 / 1024)
    body = S - 2 * inset

    # Drop shadow, as on macOS icon template.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [inset, inset + S * 12 // 1024, S - inset, S - inset + S * 12 // 1024], radius=radius, fill=(0, 0, 0, 110))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 18 / 1024)))

    # Graphite-to-ink vertical gradient body.
    top, bottom = (44, 52, 66), (13, 16, 22)
    gradient = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(gradient)
    for y in range(S):
        t = min(1, max(0, (y - inset) / body))
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, t) + (255,))
    icon.paste(gradient, (0, 0), squircle_mask(S, inset, radius))

    d = ImageDraw.Draw(icon)
    cx, cy = S // 2, int(S * 0.52)

    # Broadcast arcs, left and right of the lens.
    arc_color = (126, 200, 255, 255)
    for i, r in enumerate([0.30, 0.375]):
        rr = int(S * r)
        width = int(S * 0.026)
        alpha = 255 if i == 0 else 150
        color = arc_color[:3] + (alpha,)
        box = [cx - rr, cy - rr, cx + rr, cy + rr]
        d.arc(box, start=145, end=215, fill=color, width=width)
        d.arc(box, start=-35, end=35, fill=color, width=width)

    # Lens: outer barrel, ring, glass, highlight.
    def circle(r, fill):
        rr = int(S * r)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=fill)

    circle(0.205, (226, 232, 240, 255))
    circle(0.180, (30, 36, 48, 255))
    circle(0.150, (64, 120, 190, 255))
    circle(0.118, (18, 40, 78, 255))
    circle(0.070, (8, 14, 28, 255))
    hr = int(S * 0.034)
    hx, hy = cx - int(S * 0.052), cy - int(S * 0.052)
    d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(200, 230, 255, 210))

    # On-air dot, top right of the lens.
    rx, ry, rr = cx + int(S * 0.215), cy - int(S * 0.215), int(S * 0.062)
    d.ellipse([rx - rr - S // 200, ry - rr - S // 200, rx + rr + S // 200, ry + rr + S // 200], fill=(13, 16, 22, 255))
    d.ellipse([rx - rr, ry - rr, rx + rr, ry + rr], fill=(255, 59, 48, 255))

    # Subtle top sheen.
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    for y in range(inset, inset + body // 2):
        t = (y - inset) / (body / 2)
        sd.line([(0, y), (S, y)], fill=(255, 255, 255, int(22 * (1 - t))))
    masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    masked.paste(sheen, (0, 0), squircle_mask(S, inset, radius))
    icon.alpha_composite(masked)
    return icon.resize((1024, 1024), Image.LANCZOS)


def main():
    master = render()
    images = []
    for points in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    master.save(os.path.join(os.path.dirname(__file__), "..", "docs", "icon-preview.png"))


if __name__ == "__main__":
    os.makedirs(os.path.join(os.path.dirname(__file__), "..", "docs"), exist_ok=True)
    main()
