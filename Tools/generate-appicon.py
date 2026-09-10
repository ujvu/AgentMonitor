"""
AgentMonitor app icon — v2

Concept: a stylized "watchful eye" that doubles as a Dynamic Island:
- deep navy background with subtle radial vignette
- three concentric "agent rings" (matching the 3 primary axes the app
  watches: 5-hour rolling / weekly / MCP-monthly — same metaphor the
  GLM provider just adopted, so the icon is consistent with the app)
- a clean, centered "eye" formed by the innermost ring + pupil, evoking
  both the menu-bar monitor and the macOS Dynamic Island silhouette
- a small "scan dot" off-center, hinting at active observation

Palette: restrained — indigo for "primary monitored" + cyan DSH accent +
amber for the active scan, on a near-black navy. Should read clearly
at dock 16px and menu-bar 18px.
"""
from PIL import Image, ImageDraw, ImageFilter
import math
import os
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
# .icns lands in Resources/ so build.sh picks it up automatically.
OUT_DIR = os.environ.get("ICON_OUT_DIR", os.path.join(REPO_DIR, "Resources"))
# Intermediate PNGs go to a scratch dir unless ICON_PNG_DIR is set; pass
# --preview to keep them next to the repo for eyeballing.
if "--preview" in sys.argv:
    PNG_DIR = os.path.join(REPO_DIR, ".icon-preview")
else:
    PNG_DIR = os.environ.get("ICON_PNG_DIR", tempfile.mkdtemp(prefix="agentmonitor-icon-"))
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(PNG_DIR, exist_ok=True)

SIZE = 1024
CENTER = SIZE // 2

BG_OUTER = (12, 14, 24)
BG_INNER = (24, 28, 48)
RING_OUTER = (88, 92, 230)    # indigo, "monitoring layer"
RING_MID   = (110, 86, 220)   # violet, "secondary layer"
RING_INNER = (60, 180, 230)   # cyan, "DSH layer"
SCLERA_FILL = (232, 238, 252)   # light "eye white" pill — high contrast
SCLERA_RIM  = (255, 255, 255, 120)
PUPIL_DARK  = (14, 16, 30)      # dark pupil inside the light sclera
SCAN_DOT   = (250, 204, 21)   # amber, active attention
SCAN_HALO  = (255, 220, 60)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def radial_bg():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    max_r = math.hypot(CENTER, CENTER)
    for y in range(SIZE):
        for x in range(SIZE):
            d = math.hypot(x - CENTER, y - CENTER) / max_r
            t = (1.0 - d) ** 2
            c = lerp(BG_OUTER, BG_INNER, t)
            px[x, y] = c + (255,)
    return img


def annulus(cx, cy, r_out, r_in, color, alpha=255):
    """Return an RGBA layer holding one filled annulus.

    Drawing an annulus directly onto the composited background would punch a
    TRANSPARENT hole through it: `ImageDraw` in RGBA mode *replaces* pixels
    rather than blending, so the "hole" clears the background to alpha 0 and
    the interior renders as whatever sits behind the icon (white in Finder).
    Building each annulus on its own layer and compositing keeps the
    background visible through the hole.
    """
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer, "RGBA")
    ld.ellipse([cx - r_out, cy - r_out, cx + r_out, cy + r_out],
               fill=color + (alpha,))
    if r_in > 0:
        ld.ellipse([cx - r_in, cy - r_in, cx + r_in, cy + r_in],
                   fill=(0, 0, 0, 0))
    return layer


def soft_glow(layer, color, alpha=120, blur=42):
    blurred = layer.filter(ImageFilter.GaussianBlur(blur))
    mask = blurred.split()[3]
    tint = Image.new("RGBA", (SIZE, SIZE), color + (alpha,))
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(tint, (0, 0), mask)
    return out


def render(simplified=False):
    """Render the icon.

    simplified=True is used for the small icns slots (16/32/64px) where three
    concentric rings collapse into mud. It keeps a single bold ring plus a
    proportionally larger eye so the "watchful eye" reads at menu-bar and
    cmd-tab sizes.

    Layering note: every shape with a hole (the annuli) is drawn on its own
    transparent layer and composited, because drawing an annulus directly
    replaces pixels with alpha 0 and would punch a transparent hole through
    the background gradient.
    """
    out = radial_bg()

    if simplified:
        # Small slots: one bold ring, generous stroke, big center gap.
        r_out, r_in = CENTER - 40, CENTER - 118
        ring = annulus(CENTER, CENTER, r_out, r_in, RING_OUTER, 255)
        out.alpha_composite(soft_glow(ring, RING_OUTER, alpha=60, blur=56))
        out.alpha_composite(ring)
        eye_w, eye_h = 520, 268
        iris_r, halo_r = 116, 152
        dot_dx, dot_w = 8, 52
    else:
        rings = [
            # r_out, r_in, color, alpha  (uniform stroke + 40px gap)
            (CENTER - 110, CENTER - 156, RING_OUTER, 255),  # outermost
            (CENTER - 196, CENTER - 240, RING_MID,   255),  # middle
            (CENTER - 280, CENTER - 324, RING_INNER, 240),  # inner (cyan, DSH)
        ]
        for r_out, r_in, color, alpha in rings:
            ring = annulus(CENTER, CENTER, r_out, r_in, color, alpha)
            if color == RING_OUTER:
                out.alpha_composite(soft_glow(ring, RING_OUTER, alpha=70, blur=42))
            out.alpha_composite(ring)
        eye_w, eye_h = 400, 160
        iris_r, halo_r = 64, 88
        dot_dx, dot_w = 8, 36

    d = ImageDraw.Draw(out, "RGBA")

    # Central "eye" — a LIGHT sclera pill with a dark pupil. The earlier
    # version used a near-black pill on a near-black background, which
    # vanished at small sizes (the icon read as "ring + amber dot"). A light
    # pill is high contrast at every size and reads unmistakably as an eye.
    ex0 = CENTER - eye_w // 2
    ey0 = CENTER - eye_h // 2
    radius = eye_h // 2
    pill = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pill, "RGBA")
    pd.rounded_rectangle([ex0, ey0, ex0 + eye_w, ey0 + eye_h],
                         radius=radius, fill=SCLERA_FILL + (255,))
    pd.rounded_rectangle([ex0, ey0, ex0 + eye_w, ey0 + eye_h],
                         radius=radius, outline=SCLERA_RIM, width=3)
    out.alpha_composite(pill)

    # Pupil — dark, slightly off-axis so the eye reads as "looking".
    iris = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    idd = ImageDraw.Draw(iris, "RGBA")
    cx = CENTER + dot_dx
    idd.ellipse([cx - iris_r, CENTER - iris_r, cx + iris_r, CENTER + iris_r],
                fill=PUPIL_DARK + (255,))
    # Amber ring inside the pupil — ties the focal point to the app's
    # "attention" accent colour without muddying the silhouette.
    if iris_r > 20:
        rw = max(3, int(iris_r * 0.22))
        idd.ellipse([cx - iris_r + rw, CENTER - iris_r + rw,
                     cx + iris_r - rw, CENTER + iris_r - rw],
                    outline=SCAN_DOT + (235,), width=rw)
    # Specular glint, upper-left of the pupil.
    gx = cx - int(iris_r * 0.34)
    gy = CENTER - int(iris_r * 0.38)
    gr = max(2, int(iris_r * 0.30))
    idd.ellipse([gx - gr, gy - gr, gx + gr, gy + gr],
                fill=(255, 255, 255, 235))
    out.alpha_composite(iris)

    # macOS rounded-square (squircle-ish) mask.
    mask = Image.new("L", (SIZE, SIZE), 0)
    md = ImageDraw.Draw(mask)
    corner = int(SIZE * 0.225)
    md.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=corner, fill=255)
    rounded = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded.paste(out, (0, 0), mask)
    return rounded


def write_png_set(rgb):
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    paths = {}
    for s in sizes:
        im = rgb if s == 1024 else rgb.resize((s, s), Image.LANCZOS)
        path = os.path.join(PNG_DIR, f"icon_{s}.png")
        im.save(path, "PNG")
        paths[s] = path
    return paths, sizes


def write_icns(png_paths, out_path):
    type_codes = {
        16: b"\x10", 32: b"\x20", 64: b"\x30", 128: b"\x40",
        256: b"\x50", 512: b"\x60", 1024: b"\x70",
    }
    payload = b""
    for s, p in png_paths.items():
        if s not in type_codes:
            continue
        with open(p, "rb") as f:
            data = f.read()
        payload += type_codes[s] + len(data).to_bytes(4, "big") + data
    total = 8 + len(payload)
    with open(out_path, "wb") as f:
        f.write(b"icns" + total.to_bytes(4, "big") + payload)


def main():
    full = render(simplified=False)
    simple = render(simplified=True)

    # Size-adaptive art: small slots get the simplified design so the icon
    # stays legible at menu-bar / cmd-tab sizes, where three thin rings mud.
    small_sizes = [16, 32, 64]
    large_sizes = [128, 256, 512, 1024]

    paths = {}
    for s in small_sizes:
        im = simple.resize((s, s), Image.LANCZOS)
        p = os.path.join(PNG_DIR, f"icon_{s}.png")
        im.save(p, "PNG")
        paths[s] = p
    for s in large_sizes:
        im = full if s == 1024 else full.resize((s, s), Image.LANCZOS)
        p = os.path.join(PNG_DIR, f"icon_{s}.png")
        im.save(p, "PNG")
        paths[s] = p

    print("Wrote PNGs (size-adaptive):")
    for s in sorted(paths):
        kind = "simple" if s in small_sizes else "full"
        print(f"  {s:>4}px [{kind}]: {paths[s]}")

    icns_path = os.path.join(OUT_DIR, "AgentMonitor.icns")
    write_icns(paths, icns_path)
    print(f"\nWrote ICNS: {icns_path}")
    full.save(os.path.join(PNG_DIR, "AppIcon-1024.png"), "PNG")
    simple.save(os.path.join(PNG_DIR, "AppIcon-simple-1024.png"), "PNG")
    print(f"Wrote 1024 sources (full + simple) to {PNG_DIR}")
    print("\nNext: ./build.sh && ./deploy.sh")


if __name__ == "__main__":
    main()
