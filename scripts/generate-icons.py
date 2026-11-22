#!/usr/bin/env python3
"""Generate CCX's CHAOX-family app icons (SVG masters, AppIcon set, MenuBarIcon, and preview sheet).

Design rules aligned with `ipx/characters/chaox/marks.md`:
  - Four roles max (ground + ink brackets + dual wordmark accents):
      * Light: warm paper #F5F1E9, night ink #070809, "CC" mint green #17A57A, "X" blood red #B0101A
      * Dark:  night ink  #070809, warm paper #F5F1E9, "CC" mint green #4AE3B5, "X" blood red #D61A26
  - "CC" (Control · Command) is mint green and "X" is blood red, framed by neutral ink brackets.
  - Heavy italic glyphs match `ipx/src/chaox/redraw/italic.ts` (`GLYPH_X`,
    cap height 76..124, STEM = 13.03, SLANT = 7.97) paired with two mathematically
    sheared parametric heavy-italic "C"s and subtle viewfinder corner brackets.

Usage:
  python3 scripts/generate-icons.py [--preview /tmp/ccx-icon-preview.png]
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESIGN_DIR = os.path.join(ROOT, "Design", "Icon")
APPICON_DIR = os.path.join(ROOT, "App", "Assets.xcassets", "AppIcon.appiconset")
BRANDICON_DIR = os.path.join(ROOT, "App", "Assets.xcassets", "BrandIcon.imageset")
MENUBARICON_DIR = os.path.join(ROOT, "App", "Assets.xcassets", "MenuBarIcon.imageset")

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]

# Verbatim X glyph from ipx/src/chaox/redraw/italic.ts (200x200 space, y = 76..124).
GLYPH_X = (
    "M144.221 76L149.752 89.9688H150.127L160.439 76H175.533L157.252 100L168.127 124H153.596"
    "L147.783 109.75H147.408L136.908 124H121.721L140.471 100L130.158 76H144.221Z"
)

# Family italic metrics from italic.ts: 48pt cap height shifts right by 7.97pt.
STEM = 13.03
SLANT = 7.97
SHEAR = SLANT / 48.0

# Canonical wordmark magnification from italic.ts (780 / 150.5) and boosts for <=64px / 18pt icons.
CANONICAL_SCALE = 780.0 / 150.5
SMALL_SCALE = CANONICAL_SCALE * 1.07
MENUBAR_SCALE = CANONICAL_SCALE * 0.90
SMALL_PIXELS = 64

APPEARANCES = {
    "light": {
        "ground": "#F5F1E9",
        "ink": "#070809",
        "cc": "#17A57A",
        "x": "#B0101A",
        "frame_opacity_large": 0.22,
        "frame_opacity_small": 0.34,
        "frame_opacity_menubar": 0.34,
    },
    "dark": {
        "ground": "#070809",
        "ink": "#F5F1E9",
        "cc": "#4AE3B5",
        "x": "#D61A26",
        "frame_opacity_large": 0.26,
        "frame_opacity_small": 0.38,
        "frame_opacity_menubar": 0.36,
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


GLYPH_C1 = build_glyph_c(dx=34.5)
GLYPH_C2 = build_glyph_c(dx=78.0)

# Horizontal adjustments relative to italic.ts source coordinates:
#   C1 spans ~38.35 .. ~80.24
#   C2 spans ~81.85 .. ~123.74 (+4.2pt optical breath after C1)
#   X  spans ~121.72 .. ~175.53 (+1.5 right so C2's open mouth pairs evenly with X)
X_DX = 1.5
WORD_LEFT = 38.35
WORD_RIGHT = 175.533 + X_DX


def viewfinder_brackets(
    ink: str,
    opacity: float,
    small: bool,
    inset_override: float | None = None,
    arm_override: float | None = None,
    stroke_override: float | None = None,
) -> str:
    """Subtle architectural viewfinder L-brackets framing the mark."""
    inset = inset_override if inset_override is not None else (126.0 if not small else 118.0)
    arm = arm_override if arm_override is not None else (112.0 if not small else 132.0)
    stroke_w = stroke_override if stroke_override is not None else (24.0 if not small else 36.0)
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


def wordmark(cc_color: str, x_color: str, small: bool = False, scale_override: float | None = None) -> str:
    scale = scale_override if scale_override is not None else (SMALL_SCALE if small else CANONICAL_SCALE)
    tx = 512.0 - ((WORD_LEFT + WORD_RIGHT) / 2.0) * scale
    ty = 512.0 - 100.0 * scale
    return (
        f'<g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.4f})">'
        f'<path d="{GLYPH_C1}" fill="{cc_color}"/>'
        f'<path d="{GLYPH_C2}" fill="{cc_color}"/>'
        f'<path transform="translate({X_DX} 0)" d="{GLYPH_X}" fill="{x_color}"/>'
        "</g>"
    )


def body(appearance: str, small: bool = False) -> str:
    cfg = APPEARANCES[appearance]
    opacity = cfg["frame_opacity_small"] if small else cfg["frame_opacity_large"]
    return (
        f'<rect width="1024" height="1024" fill="{cfg["ground"]}"/>'
        + viewfinder_brackets(cfg["ink"], opacity, small)
        + wordmark(cfg["cc"], cfg["x"], small=small)
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
    cfg = APPEARANCES[appearance]
    ground = cfg["ground"]
    ink = cfg["ink"]
    shadow_opacity = "0.28" if appearance == "light" else "0.45"
    rim_opacity = "0.18" if appearance == "dark" else "0.08"
    rim_width = "10" if small else "6"
    clip_id = f"plate-{appearance}-{size}"
    shadow_id = f"shadow-{appearance}-{size}"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
        "<defs>"
        f'<clipPath id="{clip_id}"><rect {plate}/></clipPath>'
        f'<filter id="{shadow_id}" x="-12%" y="-12%" width="124%" height="132%">'
        f'<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="{shadow_opacity}"/>'
        "</filter>"
        "</defs>"
        f'<rect {plate} fill="{ground}" filter="url(#{shadow_id})"/>'
        f'<g clip-path="url(#{clip_id})"><g transform="translate(100 100) scale(0.8046875)">'
        + body(appearance, small=small)
        + f'</g><rect {plate} fill="none" stroke="{ink}" stroke-opacity="{rim_opacity}" stroke-width="{rim_width}"/></g></svg>'
    )


def menu_bar_icon_svg(appearance: str, size: int) -> str:
    """Full-frame squircle badge matching CCX's brand icon for 18pt/36px menu bar rendering."""
    plate = 'x="36" y="36" width="952" height="952" rx="220"'
    cfg = APPEARANCES[appearance]
    ground = cfg["ground"]
    ink = cfg["ink"]
    rim_opacity = "0.20" if appearance == "dark" else "0.16"
    clip_id = f"menubar-plate-{appearance}-{size}"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
        "<defs>"
        f'<clipPath id="{clip_id}"><rect {plate}/></clipPath>'
        "</defs>"
        f'<rect {plate} fill="{ground}"/>'
        f'<g clip-path="url(#{clip_id})">'
        + viewfinder_brackets(
            ink,
            cfg["frame_opacity_menubar"],
            small=True,
            inset_override=132.0,
            arm_override=132.0,
            stroke_override=36.0,
        )
        + wordmark(cfg["cc"], cfg["x"], small=True, scale_override=MENUBAR_SCALE)
        + f'<rect {plate} fill="none" stroke="{ink}" stroke-opacity="{rim_opacity}" stroke-width="24"/>'
        "</g></svg>"
    )


def chrome_binary() -> str:
    chosen = os.environ.get("CHROME")
    if chosen and os.access(chosen, os.X_OK):
        return chosen
    for candidate in CHROME_CANDIDATES:
        if os.access(candidate, os.X_OK):
            return candidate
    sys.exit("generate-icons.py: Chrome/Chromium binary not found")


def render_svg_to_png(
    chrome: str, work: str, svg: str, out_png: str, width: int, height: int
) -> None:
    html_path = os.path.join(work, os.path.basename(out_png) + ".html")
    profile_dir = tempfile.mkdtemp(prefix="chrome-", dir=work)
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(f'<!doctype html><html><body style="margin:0;overflow:hidden;background:transparent">{svg}</body></html>')
    try:
        subprocess.run(
            [
                chrome,
                "--headless=new",
                "--disable-gpu",
                f"--user-data-dir={profile_dir}",
                "--no-first-run",
                "--no-default-browser-check",
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
    finally:
        shutil.rmtree(profile_dir, ignore_errors=True)


def render_html_to_png(chrome: str, work: str, html_path: str, out_png: str, width: int, height: int) -> None:
    profile_dir = tempfile.mkdtemp(prefix="chrome-", dir=work)
    try:
        subprocess.run(
            [
                chrome,
                "--headless=new",
                "--disable-gpu",
                f"--user-data-dir={profile_dir}",
                "--no-first-run",
                "--no-default-browser-check",
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
    finally:
        shutil.rmtree(profile_dir, ignore_errors=True)


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


def write_brand_icon_imageset() -> None:
    os.makedirs(BRANDICON_DIR, exist_ok=True)
    copies = [
        ("icon_256x256.png", "brand_icon@1x.png"),
        ("icon_256x256@2x.png", "brand_icon@2x.png"),
        ("icon_256x256-dark.png", "brand_icon-dark@1x.png"),
        ("icon_256x256@2x-dark.png", "brand_icon-dark@2x.png"),
    ]
    for src_name, dst_name in copies:
        shutil.copyfile(os.path.join(APPICON_DIR, src_name), os.path.join(BRANDICON_DIR, dst_name))

    images = [
        {"filename": "brand_icon@1x.png", "idiom": "mac", "scale": "1x"},
        {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": "brand_icon-dark@1x.png",
            "idiom": "mac",
            "scale": "1x",
        },
        {"filename": "brand_icon@2x.png", "idiom": "mac", "scale": "2x"},
        {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": "brand_icon-dark@2x.png",
            "idiom": "mac",
            "scale": "2x",
        },
    ]
    payload = {"images": images, "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(BRANDICON_DIR, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def write_menubar_icon_imageset(chrome: str, work: str) -> None:
    os.makedirs(MENUBARICON_DIR, exist_ok=True)
    specs = [
        ("light", 1, 18, "menubar_icon@1x.png"),
        ("light", 2, 36, "menubar_icon@2x.png"),
        ("dark", 1, 18, "menubar_icon-dark@1x.png"),
        ("dark", 2, 36, "menubar_icon-dark@2x.png"),
    ]
    for appearance, _, px, filename in specs:
        out_png = os.path.join(MENUBARICON_DIR, filename)
        render_svg_to_png(chrome, work, menu_bar_icon_svg(appearance, px), out_png, px, px)

    images = [
        {"filename": "menubar_icon@1x.png", "idiom": "mac", "scale": "1x"},
        {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": "menubar_icon-dark@1x.png",
            "idiom": "mac",
            "scale": "1x",
        },
        {"filename": "menubar_icon@2x.png", "idiom": "mac", "scale": "2x"},
        {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": "menubar_icon-dark@2x.png",
            "idiom": "mac",
            "scale": "2x",
        },
    ]
    payload = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "original"},
    }
    with open(os.path.join(MENUBARICON_DIR, "Contents.json"), "w", encoding="utf-8") as f:
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
  .menubar-row {{ display: flex; gap: 24px; align-items: center; margin-top: 22px; }}
  .bar {{
    display: inline-flex;
    align-items: center;
    gap: 14px;
    padding: 8px 16px;
    border-radius: 10px;
    font-size: 12px;
    font-weight: 600;
  }}
  .bar-dark {{ background: #1C1C1E; color: #E5E5EA; }}
  .bar-light {{ background: #EAEAEF; color: #1C1C1E; }}
  .icon-box {{ display: inline-flex; align-items: center; gap: 8px; }}
</style>
</head>
<body>
  <h1>CCX — Mint Green CC + Blood Red X Review</h1>
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
  <div class="menubar-row">
    <div class="bar bar-dark">
      <span>Menu Bar Dark</span>
      <span class="icon-box">{menu_bar_icon_svg("dark", 18)}<span>18pt</span></span>
      <span class="icon-box">{menu_bar_icon_svg("dark", 36)}<span>36px (2x)</span></span>
    </div>
    <div class="bar bar-light">
      <span>Menu Bar Light</span>
      <span class="icon-box">{menu_bar_icon_svg("light", 18)}<span>18pt</span></span>
      <span class="icon-box">{menu_bar_icon_svg("light", 36)}<span>36px (2x)</span></span>
    </div>
  </div>
</body>
</html>"""
    html_path = os.path.join(work, "preview.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)
    render_html_to_png(chrome, work, html_path, out_png, 920, 720)


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
        rendered: dict[tuple[str, int], str] = {}
        for points, scale in MAC_SIZES:
            px = points * scale
            suffix = "@2x" if scale == 2 else ""
            for appearance in ("light", "dark"):
                dark_suffix = "-dark" if appearance == "dark" else ""
                filename = f"icon_{points}x{points}{suffix}{dark_suffix}.png"
                out_png = os.path.join(APPICON_DIR, filename)
                key = (appearance, px)
                if key in rendered:
                    shutil.copyfile(rendered[key], out_png)
                else:
                    render_svg_to_png(chrome, work, mac_plate_svg(appearance, px), out_png, px, px)
                    rendered[key] = out_png

        write_menubar_icon_imageset(chrome, work)

        if args.preview:
            write_preview_sheet(chrome, work, args.preview)

    write_contents_json()
    write_brand_icon_imageset()
    print("Generated Design/Icon SVG masters, 20 AppIcon PNGs, BrandIcon imageset, and MenuBarIcon imageset")


if __name__ == "__main__":
    main()
