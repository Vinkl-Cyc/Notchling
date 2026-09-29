#!/usr/bin/env python3
"""Draws the Notchling app icon (Pip the sprout) into Notchling/Assets.xcassets. Needs Pillow + numpy."""
import json
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..", "Notchling", "Assets.xcassets", "AppIcon.appiconset")
N = 2048  # supersampled canvas


def cubic(p0, p1, p2, p3, n=60):
    ts = np.linspace(0, 1, n)[:, None]
    p0, p1, p2, p3 = map(np.array, (p0, p1, p2, p3))
    return ((1 - ts) ** 3 * p0 + 3 * (1 - ts) ** 2 * ts * p1 + 3 * (1 - ts) * ts ** 2 * p2 + ts ** 3 * p3).tolist()


def quad(p0, p1, p2, n=40):
    ts = np.linspace(0, 1, n)[:, None]
    p0, p1, p2 = map(np.array, (p0, p1, p2))
    return ((1 - ts) ** 2 * p0 + 2 * (1 - ts) * ts * p1 + ts ** 2 * p2).tolist()


def body(cx, base, w, h):
    top = (cx, base - h)
    pts = []
    pts += cubic(top, (cx + w * .30, base - h), (cx + w / 2, base - h * .72), (cx + w / 2, base - h * .38))
    pts += cubic((cx + w / 2, base - h * .38), (cx + w / 2, base - h * .06), (cx + w * .30, base), (cx, base))
    pts += cubic((cx, base), (cx - w * .30, base), (cx - w / 2, base - h * .06), (cx - w / 2, base - h * .38))
    pts += cubic((cx - w / 2, base - h * .38), (cx - w / 2, base - h * .72), (cx - w * .30, base - h), top)
    return [tuple(p) for p in pts]


def leaf(ox, oy, length, angle):
    pts = quad((0, 0), (length * .5, -length * .5), (length, 0)) + quad((length, 0), (length * .5, length * .5), (0, 0))
    c, s = np.cos(angle), np.sin(angle)
    return [(ox + x * c - y * s, oy + x * s + y * c) for x, y in pts]


def draw_icon():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = int(N * 0.09)
    # Background: deep night-blue squircle with a soft glow
    d.rounded_rectangle([m, m, N - m, N - m], radius=int(N * 0.2), fill=(22, 27, 38, 255))
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([N * .25, N * .3, N * .75, N * .85], fill=(80, 200, 150, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(N * 0.08))
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, N - m, N - m], radius=int(N * 0.2), fill=255)
    img.paste(Image.alpha_composite(img, glow), (0, 0), mask)
    d = ImageDraw.Draw(img)

    S = N * 0.78
    cx, base = N / 2, N * 0.80
    w, h = S * 0.62, S * 0.56
    dark = (70, 160, 128)
    # shadow
    d.ellipse([cx - w * .42, base - S * .015, cx + w * .42, base + S * .03], fill=(0, 0, 0, 90))
    # arms (behind)
    for side in (-1, 1):
        ax, ay = cx + side * w * .40, base - h * .42
        d.ellipse([ax - w * .07 + side * w * .05, ay - w * .03, ax + w * .07 + side * w * .05, ay + w * .25], fill=dark)
    # body with vertical gradient
    grad = Image.new("RGBA", (N, N))
    top_c, bot_c = np.array([158, 235, 199]), np.array([84, 184, 148])
    ys = np.linspace(0, 1, N)
    ky = np.clip((ys - (base - h) / N) / (h / N), 0, 1)[:, None]
    col = (top_c * (1 - ky) + bot_c * ky).astype(np.uint8)
    arr = np.zeros((N, N, 4), np.uint8)
    arr[:, :, :3] = col[:, None, :]
    arr[:, :, 3] = 255
    grad = Image.fromarray(arr, "RGBA")
    bmask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(bmask).polygon(body(cx, base, w, h), fill=255)
    img.paste(grad, (0, 0), bmask)
    d = ImageDraw.Draw(img)
    # belly
    belly = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(belly).ellipse([cx - w * .25, base - h * .46, cx + w * .25, base - h * .06], fill=(255, 255, 255, 66))
    img = Image.alpha_composite(img, belly)
    d = ImageDraw.Draw(img)
    # feet
    for side in (-1, 1):
        fx = cx + side * w * .2
        d.ellipse([fx - w * .12, base - S * .047, fx + w * .12, base + S * .028], fill=dark)
    # sprout
    top = (cx, base - h)
    tip = (cx + S * .01, base - h - S * .12)
    stem = quad((top[0], top[1] + S * .01), (cx - S * .025, base - h - S * .06), tip)
    d.line([tuple(p) for p in stem], fill=(70, 158, 77), width=int(S * .025), joint="curve")
    d.polygon(leaf(tip[0], tip[1], S * .17, -0.5), fill=(107, 204, 102))
    d.polygon(leaf(tip[0], tip[1], S * .15, np.pi + 0.5), fill=(107, 204, 102))
    # eyes
    ink = (31, 38, 46)
    ey = base - h * .64
    rx, ry = S * .052, S * .066
    for side in (-1, 1):
        ex = cx + side * w * .19
        d.ellipse([ex - rx, ey - ry, ex + rx, ey + ry], fill=ink)
        hr = rx * .36
        d.ellipse([ex - rx * .32 - hr, ey - ry * .38 - hr, ex - rx * .32 + hr, ey - ry * .38 + hr], fill="white")
        blush = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        bx = ex + side * rx * .55
        ImageDraw.Draw(blush).ellipse([bx - rx * .75, ey + ry * .95, bx + rx * .75, ey + ry * 1.55], fill=(255, 128, 153, 120))
        img = Image.alpha_composite(img, blush)
        d = ImageDraw.Draw(img)
    # smile
    my, mw = ey + S * .1, S * .08
    smile = quad((cx - mw * .6, my - mw * .05), (cx, my + mw * 1.25), (cx + mw * .6, my - mw * .05))
    d.polygon([tuple(p) for p in smile], fill=ink)
    d.ellipse([cx - mw * .25, my + mw * .22, cx + mw * .25, my + mw * .5], fill=(255, 115, 128))
    return img


def main():
    os.makedirs(ROOT, exist_ok=True)
    big = draw_icon()
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    images = []
    for size, scale in specs:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        big.resize((px, px), Image.LANCZOS).save(os.path.join(ROOT, name))
        images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(ROOT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, f, indent=2)
    with open(os.path.join(ROOT, "..", "Contents.json"), "w") as f:
        json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(os.path.dirname(__file__), "..", "docs/icon-preview.png"))
    print("icon written")


if __name__ == "__main__":
    main()
