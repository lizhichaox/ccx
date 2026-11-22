#!/usr/bin/env python3
"""Generate CPX's CHAOX-family app icons (SVG masters, macOS AppIcon set, and preview sheet).

Design rules aligned with `ipx/characters/chaox/marks.md`:
  - Three colors max (ground included):
      * Light: warm paper #F5F1E9, night ink #070809, REC crimson #D9383A
      * Dark:  night ink  #070809, warm paper #F5F1E9, REC crimson #FF5A5F
  - Accent color falls on "CP" (Capture + Paste), while "X" stays in ink.
  - Heavy italic glyphs match `ipx/src/chaox/redraw/italic.ts` (`GLYPH_P` and `GLYPH_X`,
    cap height 76..124, STEM = 13.03, SLANT = 7.97) paired with a mathematically sheared
    parametric heavy-italic "C" and subtle viewfinder corner brackets in faint ink.

Usage:
  python3 scripts/generate-icons.py [--preview /tmp/cpx-icon-preview.png]
"""
import argparse
import json
import math
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESIGN_DIR = os.path.join(ROOT, "Design", "Icon")
APPICON_DIR = os.path.join(ROOT, "App", "Assets.xcassets", "AppIcon.appiconset")

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]

# Verbatim P and X glyphs from ipx/src/chaox/redraw/italic.ts (200x200 space, y = 76..124).
GLYPH_P = (
    "M79.5332 124L87.502 76H108.221C111.783 76 114.783 76.7031 117.221 78.1094"
    "C119.658 79.5156 121.408 81.4922 122.471 84.0391C123.533 86.5859 123.783 89.5625 123.221 92.9687"
    "C122.658 96.4375 121.408 99.4297 119.471 101.945C117.549 104.445 115.096 106.375 112.111 107.734"
    "C109.143 109.078 105.814 109.75 102.127 109.75H89.752L91.4395 99.625H101.189"
    "C102.752 99.625 104.127 99.3594 105.314 98.8281C106.502 98.2812 107.463 97.5156 108.197 96.5312"
    "C108.932 95.5312 109.408 94.3437 109.627 92.9687C109.846 91.5937 109.744 90.4219 109.322 89.4531"
    "C108.916 88.4687 108.213 87.7187 107.213 87.2031C106.229 86.6719 104.971 86.4062 103.439 86.4062"
    "H98.8457L92.5645 124H79.5332Z"
)

GLYPH_X = (
    "M144.221 76L149.752 89.9688H150.127L160.439 76H175.533L157.252 100L168.127 124H153.596"
    "L147.783 109.75H147.408L136.908 124H121.721L140.471 100L130.158 76H144.221Z"
)

# Family italic metrics from italic.ts: 48pt cap height shifts right by 7.97pt.
STEM = 13.03
SLANT = 7.97
SHEAR = SLANT / 48.0

# Canonical wordmark magnification from italic.ts (780 / 150.5) and slight boost for <=64px icons.
CANONICAL_SCALE = 780.0 / 150.5
SMALL_SCALE = CANONICAL_SCALE * 1.07
SMALL_PIXELS = 64

APPEARANCES = {
    "light": {
        "ground": "#F5F1E9",
        "ink": "#070809",
        "accent": "#D9383A",
        "frame_opacity_large": 0.22,
        "frame_opacity_small": 0.34,
    },
    "dark": {
        "ground": "#070809",
        "ink": "#F5F1E9",
        "accent": "#FF5A5F",
        "frame_opacity_large": 0.26,
        "frame_opacity_small": 0.38,
    },
}

MAC_SIZES = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]


def shear_point(x: float, y: float, dx: float = 0.0) -> tuple[float, float]:
    """Apply the CHAOX family italic shear anchored at baseline y=124."""
    return (x + dx + (124.0 - y) * SHEAR, y)


def ellipse_arc_segments(
    cx: float,
    cy: float,
    rx: float,
    ry: float,
    t0: float,
    t1: float,
    max_step: float = math.pi / 2.5,
):
    """Return cubic Bezier segments [(p0, c0, c1, p1), ...] approximating an ellipse arc."""
    steps = max(1, math.ceil(abs(t1 - t0) / max_step))
    dt = (t1 - t0) / steps
    k = (4.0 / 3.0) * math.tan(dt / 4.0)
    segments = []
    for i in range(steps):
        a0 = t0 + i * dt
        a1 = a0 + dt
        ca0, sa0 = math.cos(a0), math.sin(a0)
        ca1, sa1 = math.cos(a1), math.sin(a1)
        p0 = (cx + rx * ca0, cy + ry * sa0)
        p1 = (cx + rx * ca1, cy + ry * sa1)
        c0 = (p0[0] - k * rx * sa0, p0[1] + k * ry * ca0)
        c1 = (p1[0] + k * rx * sa1, p1[1] - k * ry * ca1)
        segments.append((p0, c0, c1, p1))
    return segments


def build_glyph_c(dx: float = 34.5) -> str:
    """Construct heavy-italic 'C' matching GLYPH_P/X weight (STEM=13.03) and horizontal arms (10.4)."""
    cx, cy = 22.8, 100.0
    # Outer loop: top-right cut -> top -> left spine -> bottom -> bottom-right cut.
    rx_out_left, rx_out_right, ry_out = 22.8, 18.6, 24.8
    # Inner loop: matching 13.03 left stem and 10.40 top/bottom horizontal arms.
    rx_in_left, rx_in_right, ry_in = 22.8 - STEM, 8.2, 24.8 - 10.40

    y_open_top = 92.2
    y_open_bot = 107.8

    theta_out_top = math.asin((y_open_top - cy) / ry_out)   # negative angle, top-right
    theta_out_bot = math.asin((y_open_bot - cy) / ry_out)   # positive angle, bottom-right
    theta_in_top = math.asin((y_open_top - cy) / ry_in)
    theta_in_bot = math.asin((y_open_bot - cy) / ry_in)

    # Outer path travels counter-clockwise: top-right -> -pi/2 -> -pi -> -3pi/2 -> bottom-right (2pi + theta_out_bot).
    outer_segs = (
        ellipse_arc_segments(cx, cy, rx_out_right, ry_out, theta_out_top, -math.pi / 2)
        + ellipse_arc_segments(cx, cy, rx_out_left, ry_out, -math.pi / 2, -math.pi)
        + ellipse_arc_segments(cx, cy, rx_out_left, ry_out, -math.pi, -1.5 * math.pi)
        + ellipse_arc_segments(cx, cy, rx_out_right, ry_out, -1.5 * math.pi, -2 * math.pi + theta_out_bot)
    )

    # Inner path returns clockwise: bottom-right -> +pi/2 -> pi -> 3pi/2 -> top-right (2pi + theta_in_top).
    inner_segs = (
        ellipse_arc_segments(cx, cy, rx_in_right, ry_in, theta_in_bot, math.pi / 2)
        + ellipse_arc_segments(cx, cy, rx_in_left, ry_in, math.pi / 2, math.pi)
        + ellipse_arc_segments(cx, cy, rx_in_left, ry_in, math.pi, 1.5 * math.pi)
        + ellipse_arc_segments(cx, cy, rx_in_right, ry_in, 1.5 * math.pi, 2 * math.pi + theta_in_top)
    )

    def fmt(pt: tuple[float, float]) -> str:
        sx, sy = shear_point(pt[0], pt[1], dx=dx)
        return f"{sx:.3f} {sy:.3f}"

    start = outer_segs[0][0]
    commands = [f"M{fmt(start)}"]
    for _, c0, c1, p1 in outer_segs:
        commands.append(f"C{fmt(c0)},{fmt(c1)},{fmt(p1)}")

    # Horizontal cut at bottom arm into inner loop.
    commands.append(f"L{fmt(inner_segs[0][0])}")
    for _, c0, c1, p1 in inner_segs:
        commands.append(f"C{fmt(c0)},{fmt(c1)},{fmt(p1)}")

    # Horizontal cut back to outer top arm.
    commands.append("Z")
    return "".join(commands)


GLYPH_C = build_glyph_c(dx=34.5)

# Horizontal adjustments relative to italic.ts source coordinates:
#   C spans ~37.5 .. ~80.3
#   P spans ~79.5 .. ~123.6  (+3.5 right breath from C -> 83.0 .. 127.1)
#   X spans ~121.7 .. ~175.5 (+5.5 right to stay balanced after P -> 127.2 .. 181.0)
P_DX = 3.5
X_DX = 5.5
WORD_LEFT = 37.4
WORD_RIGHT = 175.533 + X_DX


def viewfinder_brackets(ink: str, opacity: float, small: bool) -> str:
    """Subtle architectural viewfinder L-brackets framing the mark."""
    inset = 126.0 if not small else 118.0
    arm = 112.0 if not small else 132.0
    stroke_w = 24.0 if not small else 36.0
    far = 1024.0 - inset
    paths = [
        f"M{inset + arm:.0f} {inset:.0f}H{inset:.0f}V{inset + arm:.0f}",
        f"M{far - arm:.0f} {inset:.0f}H{far:.0f}V{inset + arm:.0f}",
        f"M{inset + arm:.0f} {far:.0f}H{inset:.0f}V{far - arm:.0f}",
        f"M{far - arm:.0f} {far:.0f}H{far:.0f}V{far - arm:.0f}",
    ]
    return (
        f'<g fill="none" stroke="{ink}" stroke-opacity="{opacity}" '
        f'stroke-width="{stroke_w:.0f}" stroke-linecap="square" stroke-linejoin="miter">'
        + "".join(f'<path d="{d}"/>' for d in paths)
        + "</g>"
    )


def wordmark(ink: str, accent: str, small: bool) -> str:
    scale = SMALL_SCALE if small else CANONICAL_SCALE
    tx = 512.0 - ((WORD_LEFT + WORD_RIGHT) / 2.0) * scale
    ty = 512.0 - 100.0 * scale
    return (
        f'<g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.4f})">'
        f'<path d="{GLYPH_C}" fill="{accent}"/>'
        f'<path transform="translate({P_DX} 0)" d="{GLYPH_P}" fill="{accent}"/>'
        f'<path transform="translate({X_DX} 0)" d="{GLYPH_X}" fill="{ink}"/>'
        "</g>"
    )


def body(appearance: str, small: bool = False) -> str:
    cfg = APPEARANCES[appearance]
    opacity = cfg["frame_opacity_small"] if small else cfg["frame_opacity_large"]
    return (
        f'<rect width="1024" height="1024" fill="{cfg["ground"]}"/>'
        + viewfinder_brackets(cfg["ink"], opacity, small)
        + wordmark(cfg["ink"], cfg["accent"], small)
    )


def full_bleed_svg(appearance: str, size: int = 1024) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
        + body(appearance, small=False)
        + "</svg>"
    )


def mac_plate_svg(appearance: str, size: int) -> str:
    small = size <= SMALL_PIXELS
    plate = 'x="100" y="100" width="824" height="824" rx="185"'
    ground = APPEARANCES[appearance]["ground"]
    shadow_opacity = "0.28" if appearance == "light" else "0.45"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
        "<defs>"
        f'<clipPath id="plate"><rect {plate}/></clipPath>'
        '<filter id="shadow" x="-12%" y="-12%" width="124%" height="132%">'
        f'<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="{shadow_opacity}"/>'
        "</filter>"
        "</defs>"
        f'<rect {plate} fill="{ground}" filter="url(#shadow)"/>'
        '<g clip-path="url(#plate)"><g transform="translate(100 100) scale(0.8046875)">'
        + body(appearance, small=small)
        + "</g></g></svg>"
    )


def chrome_binary() -> str:
    chosen = os.environ.get("CHROME")
    if chosen and os.access(chosen, os.X_OK):
        return chosen
    for candidate in CHROME_CANDIDATES:
        if os.access(candidate, os.X_OK):
            return candidate
    sys.exit("generate-icons.py: Chrome/Chromium binary not found")


def render_svg_to_png(chrome: str, work: str, svg: str, out_png: str, width: int, height: int) -> None:
    html_path = os.path.join(work, os.path.basename(out_png) + ".html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(f'<!doctype html><html><body style="margin:0;overflow:hidden;background:transparent">{svg}</body></html>')
    subprocess.run(
        [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            "--default-background-color=00000000",
            f"--window-size={width},{height}",
            f"--screenshot={out_png}",
            "file://" + html_path,
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )


def render_html_to_png(chrome: str, html_path: str, out_png: str, width: int, height: int) -> None:
    subprocess.run(
        [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            f"--window-size={width},{height}",
            f"--screenshot={out_png}",
            "file://" + html_path,
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )


def write_contents_json() -> None:
    images = []
    for points, scale in MAC_SIZES:
        size_str = f"{points}x{points}"
        scale_str = f"{scale}x"
        suffix = "@2x" if scale == 2 else ""
        images.append({
            "filename": f"icon_{points}x{points}{suffix}.png",
            "idiom": "mac",
            "scale": scale_str,
            "size": size_str,
        })
        images.append({
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": f"icon_{points}x{points}{suffix}-dark.png",
            "idiom": "mac",
            "scale": scale_str,
            "size": size_str,
        })

    payload = {"images": images, "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(APPICON_DIR, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def write_preview_sheet(chrome: str, work: str, out_png: str) -> None:
    html = f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  body {{
    margin: 0;
    padding: 32px;
    background: #E2E0DC;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    color: #1D1D1F;
  }}
  h1 {{ margin: 0 0 20px; font-size: 20px; font-weight: 700; }}
  .grid {{ display: flex; gap: 28px; align-items: flex-start; }}
  .card {{
    background: rgba(255,255,255,0.55);
    border-radius: 16px;
    padding: 18px;
    text-align: center;
  }}
  .label {{ margin-top: 10px; font-size: 12px; color: #555; font-weight: 600; }}
  .plates {{ display: flex; gap: 16px; align-items: flex-end; margin-top: 24px; }}
  .plates figure {{ margin: 0; text-align: center; }}
</style>
</head>
<body>
  <h1>CPX — CHAOX App Icon Review</h1>
  <div class="grid">
    <div class="card">
      <div style="border-radius:46px;overflow:hidden;width:240px;height:240px;box-shadow:0 8px 24px rgba(0,0,0,0.12)">
        {full_bleed_svg("light", 240)}
      </div>
      <div class="label">Light Full-Bleed (Paper #F5F1E9)</div>
    </div>
    <div class="card">
      <div style="border-radius:46px;overflow:hidden;width:240px;height:240px;box-shadow:0 8px 24px rgba(0,0,0,0.22)">
        {full_bleed_svg("dark", 240)}
      </div>
      <div class="label">Dark Full-Bleed (Night #070809)</div>
    </div>
  </div>
  <div class="plates">
    <figure>{mac_plate_svg("light", 180)}<figcaption class="label">macOS Light 180</figcaption></figure>
    <figure>{mac_plate_svg("dark", 180)}<figcaption class="label">macOS Dark 180</figcaption></figure>
    <figure>{mac_plate_svg("light", 96)}<figcaption class="label">96</figcaption></figure>
    <figure>{mac_plate_svg("light", 64)}<figcaption class="label">64</figcaption></figure>
    <figure>{mac_plate_svg("light", 32)}<figcaption class="label">32</figcaption></figure>
    <figure>{mac_plate_svg("dark", 32)}<figcaption class="label">32 Dark</figcaption></figure>
    <figure>{mac_plate_svg("light", 16)}<figcaption class="label">16</figcaption></figure>
  </div>
</body>
</html>"""
    html_path = os.path.join(work, "preview.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)
    render_html_to_png(chrome, html_path, out_png, 920, 620)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", help="Optional path for a visual review contact sheet PNG")
    args = parser.parse_args()

    os.makedirs(DESIGN_DIR, exist_ok=True)
    os.makedirs(APPICON_DIR, exist_ok=True)

    for appearance in ("light", "dark"):
        svg_path = os.path.join(DESIGN_DIR, f"icon-{appearance}.svg")
        with open(svg_path, "w", encoding="utf-8") as f:
            f.write(full_bleed_svg(appearance) + "\n")

    chrome = chrome_binary()
    with tempfile.TemporaryDirectory() as work:
        for points, scale in MAC_SIZES:
            px = points * scale
            suffix = "@2x" if scale == 2 else ""
            for appearance in ("light", "dark"):
                dark_suffix = "-dark" if appearance == "dark" else ""
                filename = f"icon_{points}x{points}{suffix}{dark_suffix}.png"
                out_png = os.path.join(APPICON_DIR, filename)
                render_svg_to_png(chrome, work, mac_plate_svg(appearance, px), out_png, px, px)

        if args.preview:
            write_preview_sheet(chrome, work, args.preview)

    write_contents_json()
    print(f"Generated Design/Icon SVG masters and 20 macOS icons in {os.path.relpath(APPICON_DIR, ROOT)}")


if __name__ == "__main__":
    main()
