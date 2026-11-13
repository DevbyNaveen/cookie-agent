#!/usr/bin/env python3
"""Generates Brand/*.svg: the Enkeon Voice mark, its menu-bar template and the macOS app icon.

The mark is Enkeon's six-blade aperture (the Console favicon) opened wider, as if listening,
with a three-bar voice waveform in the opening. Geometry: blade i is the triangle from inner
vertex v_i along cut i and cut i+1; scaling the inner hexagon opens the aperture.
"""
import math, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Brand")
OPEN = 1.42          # inner hexagon radius vs. the Console mark's 38.45
GAP = 6.5            # cut width
SHADES = ["#5AA3C5", "#3C88AC", "#5398B7", "#4A90B1", "#539ABB", "#458CAC"]
BRIGHT = ["#7CC1E0", "#3A86AC", "#5FA6C6", "#4B92B4", "#69AFCF", "#4589AB"]  # on the dark icon


def geometry():
    r = 38.452 * OPEN
    verts = [(r * math.sin(math.radians(60 * i + 60)), -r * math.cos(math.radians(60 * i + 60))) for i in range(6)]
    # Console order: cut i starts at these inner vertices and runs along these directions.
    starts = [(33.3, -19.226), (33.3, 19.226), (0, 38.452), (-33.3, 19.226), (-33.3, -19.226), (0, -38.452)]
    dirs = [(-0.866, -0.5), (0, -1), (0.866, -0.5), (0.866, 0.5), (0, 1), (-0.866, 0.5)]
    starts = [(x * OPEN, y * OPEN) for x, y in starts]
    far = 420
    cuts = [(s, (s[0] + far * d[0], s[1] + far * d[1])) for s, d in zip(starts, dirs)]
    blades = [[s, (s[0] + far * dirs[i][0], s[1] + far * dirs[i][1]),
               (s[0] + far * dirs[(i + 1) % 6][0], s[1] + far * dirs[(i + 1) % 6][1])] for i, s in enumerate(starts)]
    return cuts, blades


def pts(points):
    return " ".join(f"{x:.3f},{y:.3f}" for x, y in points)


def mark(shades, bars, sheen=False, mono=None):
    """The mark on a -104…104 square; `mono` paints every part one color (template images)."""
    cuts, blades = geometry()
    hexagon = pts([(66.603 * math.sin(math.radians(60 * i)) * 1.0, -76.906 * math.cos(math.radians(60 * i))) for i in range(6)])
    hexagon = "0,-76.906 66.603,-38.453 66.603,38.453 0,76.906 -66.603,38.453 -66.603,-38.453"
    lines = "".join(f'<line x1="{a[0]:.3f}" y1="{a[1]:.3f}" x2="{b[0]:.3f}" y2="{b[1]:.3f}" stroke="#000" stroke-width="{GAP}"/>' for a, b in cuts)
    body = "".join(f'<polygon points="{pts(b)}" fill="{mono or shades[i]}"/>' for i, b in enumerate(blades))
    if sheen:
        body += '<rect x="-120" y="-120" width="240" height="240" fill="url(#sheen)"/>'
    # Three bars, the middle one tallest: a voice, centred in the opening.
    w, gap, heights = 9.5, 7.5, [26, 46, 30]
    xs = [-(w + gap), 0, w + gap]
    bar = "".join(f'<rect x="{x - w / 2:.2f}" y="{-h / 2:.2f}" width="{w}" height="{h}" rx="{w / 2}" fill="{mono or bars}"/>' for x, h in zip(xs, heights))
    defs = (f'<mask id="m" maskUnits="userSpaceOnUse" x="-400" y="-400" width="800" height="800">'
            f'<polygon points="{hexagon}" fill="#fff" stroke="#fff" stroke-width="40" stroke-linejoin="round"/>{lines}</mask>')
    if sheen:
        defs += ('<linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1">'
                 '<stop offset="0" stop-color="#fff" stop-opacity="0.28"/><stop offset="0.5" stop-color="#fff" stop-opacity="0"/>'
                 '<stop offset="1" stop-color="#000" stop-opacity="0.18"/></linearGradient>')
    return defs, f'<g mask="url(#m)">{body}</g>{bar}'


def write(name, svg):
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, name), "w").write(svg)


def main():
    defs, body = mark(SHADES, "#3C88AC")
    write("enkeon-voice-mark.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-104 -104 208 208" role="img" aria-label="Enkeon Voice"><defs>{defs}</defs>{body}</svg>\n')
    defs, body = mark(SHADES, "#000", mono="#000")
    write("enkeon-voice-template.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-104 -104 208 208"><defs>{defs}</defs>{body}</svg>\n')

    # macOS icon: 1024 canvas, 824 squircle-ish rounded square at 100 (Apple's grid), deep ink glass.
    defs, body = mark(BRIGHT, "#F4FBFF", sheen=True)
    icon = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Enkeon Voice">
<defs>{defs}
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1D4C60"/><stop offset="0.55" stop-color="#0F2A35"/><stop offset="1" stop-color="#081820"/></linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.47" r="0.5"><stop offset="0" stop-color="#5AA9CC" stop-opacity="0.55"/><stop offset="0.6" stop-color="#2F7A9C" stop-opacity="0.12"/><stop offset="1" stop-color="#2F7A9C" stop-opacity="0"/></radialGradient>
<radialGradient id="warm" cx="0.82" cy="0.92" r="0.55"><stop offset="0" stop-color="#E0A458" stop-opacity="0.35"/><stop offset="1" stop-color="#E0A458" stop-opacity="0"/></radialGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.35"/><stop offset="0.25" stop-color="#fff" stop-opacity="0.06"/><stop offset="1" stop-color="#fff" stop-opacity="0.02"/></linearGradient>
<linearGradient id="drop" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.35"/></linearGradient>
</defs>
<rect x="100" y="112" width="824" height="824" rx="186" fill="url(#drop)" opacity="0.3"/>
<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#bg)"/>
<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#warm)"/>
<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#glow)"/>
<rect x="101.5" y="101.5" width="821" height="821" rx="184.5" fill="none" stroke="url(#rim)" stroke-width="3"/>
<g transform="translate(512 512) scale(2.9)">{body}</g>
</svg>
'''
    write("enkeon-voice-icon.svg", icon)

    # The app draws the mark itself (sidebar, menu bar), from the same SVG.
    mark_svg = open(os.path.join(OUT, "enkeon-voice-mark.svg")).read().strip()
    template_svg = open(os.path.join(OUT, "enkeon-voice-template.svg")).read().strip()
    swift = os.path.join(OUT, "..", "Sources", "Enkeon", "BrandMark.swift")
    open(swift, "w").write(f'''// Generated by scripts/brand.py from Brand/*.svg. Do not edit by hand: regenerate.
import AppKit

enum BrandMark {{
    /// The Enkeon Voice mark in color.
    @MainActor static let color = image(##"{mark_svg}"##, template: false)
    /// The mark in one color, following the menu bar's.
    @MainActor static let template = image(##"{template_svg}"##, template: true)

    private static func image(_ svg: String, template: Bool) -> NSImage {{
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = template
        return image
    }}
}}
''')
    print("wrote Brand/enkeon-voice-{mark,template,icon}.svg and Sources/Enkeon/BrandMark.swift")


if __name__ == "__main__":
    main()
