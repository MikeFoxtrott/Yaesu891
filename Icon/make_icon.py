#!/usr/bin/env python3
"""Erzeugt Logo und App-Icon „Mike Foxtrott“ (MF).

Motiv: eine kleine Sendeantenne – Fußplatte, Stab mit Verlängerungsspule und leuchtender Spitze –
von der Funkwellen nach beiden Seiten ausgehen. Das Logo ist die Antenne plus der Schriftzug.

Aufruf:  python3 make_icon.py   → schreibt SVG, PNG und AppIcon.icns in diesen Ordner.
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent

# ---- Farben ---------------------------------------------------------------
NAVY_TOP, NAVY_BOT = "#0F2A44", "#071827"
ORANGE_LIGHT, ORANGE_MID, ORANGE_DARK = "#FFB84D", "#F28A1E", "#C9560F"
CREAM_LIGHT, CREAM_DARK = "#FFF8EA", "#FFE3B5"
INK = "#0B2238"
TEAL = "#4FE3D2"

# ---- Geometrie der Antenne (Koordinaten im 1024er-Raster) -----------------
CX = 512                    # Mittelachse
TIP_Y = 316                 # Mittelpunkt der Spitze (Ursprung der Funkwellen)
MAST_TOP, MAST_BOT = 330, 722
COIL_TOP, COIL_BOT = 462, 606
BASE_Y = 722


def pt(angle_deg, r, cx, cy):
    """Punkt bei Winkel (0° = oben, im Uhrzeigersinn positiv) und Radius um (cx, cy)."""
    a = math.radians(angle_deg)
    return cx + r * math.sin(a), cy - r * math.cos(a)


def wave_arc(side, radius, span=36):
    """Funkwelle: Kreisbogen um die Antennenspitze, nach links (side=-1) oder rechts (+1)."""
    x0, y0 = pt(side * 90 - span, radius, CX, TIP_Y)
    x1, y1 = pt(side * 90 + span, radius, CX, TIP_Y)
    return f"M{x0:.1f},{y0:.1f} A{radius},{radius} 0 0 1 {x1:.1f},{y1:.1f}"


def mark_group():
    """Die Sendeantenne mit Funkwellen, ohne Hintergrund."""
    parts = []
    # Funkwellen: drei Bögen je Seite, nach außen schwächer
    for side in (-1, 1):
        for r, op, w in ((96, 1.0, 24), (168, 0.68, 22), (240, 0.38, 20)):
            parts.append(f'<path d="{wave_arc(side, r)}" fill="none" stroke="{TEAL}" stroke-width="{w}" '
                         f'stroke-linecap="round" opacity="{op}"/>')
    # Leuchten um die Spitze
    parts.append(f'<circle cx="{CX}" cy="{TIP_Y}" r="70" fill="url(#tipglow)"/>')
    # Fuß: Magnet-/Standfuß und Platte
    parts.append(f'<rect x="{CX - 84}" y="{BASE_Y + 50}" width="168" height="46" rx="16" fill="{ORANGE_DARK}"/>')
    parts.append(f'<rect x="{CX - 150}" y="{BASE_Y}" width="300" height="66" rx="26" fill="url(#cream)" '
                 f'stroke="{ORANGE_DARK}" stroke-width="6"/>')
    # Stab
    parts.append(f'<rect x="{CX - 24}" y="{MAST_TOP}" width="48" height="{MAST_BOT - MAST_TOP + 12}" rx="24" fill="url(#mast)"/>')
    # Verlängerungsspule: gestapelte Windungen
    n = 6
    h = (COIL_BOT - COIL_TOP) / n
    for i in range(n):
        y = COIL_TOP + i * h
        parts.append(f'<rect x="{CX - 58}" y="{y:.1f}" width="116" height="{h - 6:.1f}" rx="{(h - 6) / 2:.1f}" '
                     f'fill="url(#coil)" stroke="{ORANGE_DARK}" stroke-width="3"/>')
    # Spitze
    parts.append(f'<circle cx="{CX}" cy="{TIP_Y}" r="30" fill="url(#tip)" stroke="{ORANGE_DARK}" stroke-width="5"/>')
    return "\n  ".join(parts)


DEFS = f"""
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{NAVY_TOP}"/><stop offset="1" stop-color="{NAVY_BOT}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.4" r="0.6">
      <stop offset="0" stop-color="#1E6A7A" stop-opacity="0.55"/><stop offset="1" stop-color="#1E6A7A" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="mast" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{ORANGE_MID}"/><stop offset="0.45" stop-color="{ORANGE_LIGHT}"/><stop offset="1" stop-color="{ORANGE_DARK}"/>
    </linearGradient>
    <linearGradient id="coil" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{ORANGE_LIGHT}"/><stop offset="1" stop-color="{ORANGE_MID}"/>
    </linearGradient>
    <radialGradient id="tip" cx="0.4" cy="0.35" r="0.75">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="{CREAM_DARK}"/><stop offset="1" stop-color="{ORANGE_LIGHT}"/>
    </radialGradient>
    <radialGradient id="tipglow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{TEAL}" stop-opacity="0.85"/><stop offset="1" stop-color="{TEAL}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="cream" x1="0.2" y1="0" x2="0.8" y2="1">
      <stop offset="0" stop-color="{CREAM_LIGHT}"/><stop offset="1" stop-color="{CREAM_DARK}"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity="0.45"/>
    </filter>
    <clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="188"/></clipPath>
  </defs>"""


def icon_svg():
    """App-Icon im macOS-Raster: 1024 px Leinwand, 824 px große abgerundete Fläche."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{DEFS}
  <rect x="100" y="100" width="824" height="824" rx="188" fill="url(#bg)" filter="url(#shadow)"/>
  <g clip-path="url(#body)">
    <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
  </g>
  <rect x="103" y="103" width="818" height="818" rx="185" fill="none" stroke="#fff" stroke-opacity="0.12" stroke-width="4"/>
  <g transform="translate(512 512) scale(0.98) translate(-512 -540)">
  {mark_group()}
  </g>
</svg>"""


def logo_svg():
    """Querformatiges Logo: Antenne links, Schriftzug „Mike Foxtrott“ rechts."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="640" viewBox="0 0 2000 640">{DEFS}
  <rect width="2000" height="640" fill="url(#bg)"/>
  <g transform="translate(-150 -60) scale(0.78)">
    {mark_group()}
  </g>
  <text x="560" y="392" font-family="'SF Pro Display','Helvetica Neue','Inter','Arial','DejaVu Sans',sans-serif"
        font-size="200" font-weight="800" fill="#FFF3DC" letter-spacing="-3">Mike <tspan fill="{ORANGE_MID}">Foxtrott</tspan></text>
</svg>"""


def render(svg_path, png_path, w, h, scale=1.0):
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": w, "height": h}, device_scale_factor=scale)
        page.goto(svg_path.as_uri())
        page.screenshot(path=str(png_path), omit_background=True)
        b.close()


def main():
    (OUT / "AppIcon.svg").write_text(icon_svg(), encoding="utf-8")
    (OUT / "Logo.svg").write_text(logo_svg(), encoding="utf-8")
    render(OUT / "AppIcon.svg", OUT / "AppIcon.png", 1024, 1024)
    render(OUT / "Logo.svg", OUT / "Logo.png", 2000, 640)

    from PIL import Image
    base = Image.open(OUT / "AppIcon.png").convert("RGBA")
    # .icns mit allen üblichen Größen (16 … 1024 px)
    base.save(OUT / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    for s in (512, 128, 32):
        base.resize((s, s), Image.LANCZOS).save(OUT / f"AppIcon-{s}.png")
    print("fertig:", ", ".join(sorted(p.name for p in OUT.iterdir() if p.name != "make_icon.py")))


if __name__ == "__main__":
    main()
