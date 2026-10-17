#!/usr/bin/env python3
"""Make Reqly for Windows' app icon from the Icon Composer document.

design/logo/Reqly.icon is the icon's one source. Icon Composer renders it on a Mac, and this script
packs the render into windows/Reqly/Assets/Reqly.ico, at the sizes Windows shows, with a little
room around it as Windows icons have. It also writes Reqly.png, the large icon the app's own windows
show, such as Welcome:

    python3 tools/windows_icon.py

It needs Xcode, for Icon Composer's renderer, and Pillow. Run it again whenever Reqly.icon changes.
Windows shows one icon in light and dark mode alike, so the .ico has the default appearance.

The notification area, at the end of the taskbar, shows the menu-bar icon's glyph instead, as the
Mac's menu bar does: black on a light taskbar and white on a dark one, since Windows doesn't color
it as macOS colors a template image. The script draws it from the menu-bar icon's SVG into
NotificationIcon-on-light.ico and NotificationIcon-on-dark.ico, with tools/render_svg.swift. At 16,
20 and 24 pixels, the sizes at 100%, 125% and 150% scaling, the SVG's lines fall between rows of
pixels and blur, so the script draws those sizes itself, with each line on whole pixels.
"""
import io
import os
import struct
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "design", "logo", "Reqly.icon")
OUTPUT = os.path.join(ROOT, "windows", "Reqly", "Assets", "Reqly.ico")
PICTURE = os.path.join(ROOT, "windows", "Reqly", "Assets", "Reqly.png")
DEVELOPER = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
ICTOOL = os.path.join(
    os.path.dirname(os.path.dirname(DEVELOPER)), "Contents", "Applications", "Icon Composer.app",
    "Contents", "Executables", "ictool")
# The sizes Windows draws app icons at, from the title bar at 100% to File Explorer's largest view.
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]
# The room around the icon, as a part of its size: a pixel at 16.
INSET = 1 / 16
# Reqly.png's size: sharp at 92 points on a screen at 200%, and smaller ones.
PICTURE_SIZE = 256
GLYPH = os.path.join(ROOT, "design", "logo", "menubar", "MenuBarIcon.imageset", "menubar.svg")
RENDER_SVG = os.path.join(ROOT, "tools", "render_svg.swift")
# The notification area's icons, by the taskbar they're for, and the glyph's color on it.
NOTIFICATION_ICONS = [
    (os.path.join(ROOT, "windows", "Reqly", "Assets", "NotificationIcon-on-light.ico"), (0, 0, 0)),
    (os.path.join(ROOT, "windows", "Reqly", "Assets", "NotificationIcon-on-dark.ico"), (255, 255, 255)),
]
# The sizes Windows draws small icons at, from 100% to 300% scaling.
NOTIFICATION_SIZES = [16, 20, 24, 28, 32, 36, 40, 48]
# The glyph on whole pixels at the sizes where the SVG's lines blur, in pixels from the top left.
# The disc is about as big as the SVG's at each size, centered on the line of traffic, and the line
# seen through it sits a little more than a line's thickness above, as in the SVG. Rows run from the
# first number up to the second. The line's ends are where its round ends start; at 16 pixels, where
# the lines are 1 pixel thick, round ends would only blur, so it stops square there.
HINTED = {
    16: {"disc": ((8, 7.5), 4.5), "line": (7, 8), "line_ends": (1, 15), "round_ends": False, "inner_line": (5, 6)},
    20: {"disc": ((10, 10), 6), "line": (9, 11), "line_ends": (2, 18), "round_ends": True, "inner_line": (6, 8)},
    24: {"disc": ((12, 12), 7), "line": (11, 13), "line_ends": (2, 22), "round_ends": True, "inner_line": (8, 10)},
}


def render():
    """The default appearance at 1024 pixels, as Icon Composer draws it."""
    if not os.path.exists(ICTOOL):
        sys.exit(f"Icon Composer's renderer isn't at {ICTOOL}. Install Xcode, or set DEVELOPER_DIR.")
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "icon.png")
        subprocess.run(
            [ICTOOL, SOURCE, "--export-image", "--output-file", path, "--platform", "macOS",
             "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"],
            check=True, stdout=subprocess.DEVNULL)
        return Image.open(path).convert("RGBA")


def sized(icon, size):
    inset = round(size * INSET)
    canvas = Image.new("RGBA", (size, size))
    inner = size - 2 * inset
    canvas.paste(icon.resize((inner, inner), Image.LANCZOS), (inset, inset))
    data = io.BytesIO()
    canvas.save(data, "PNG", optimize=True)
    return data.getvalue()


def glyphs():
    """The menu-bar icon's glyph at each notification-area size, as AppKit draws its SVG."""
    with tempfile.TemporaryDirectory() as folder:
        subprocess.run(
            ["xcrun", "swift", RENDER_SVG, GLYPH, folder, *map(str, NOTIFICATION_SIZES)],
            check=True, env={**os.environ, "DEVELOPER_DIR": DEVELOPER})
        drawn = {}
        for size in NOTIFICATION_SIZES:
            with Image.open(os.path.join(folder, f"{size}.png")) as image:
                drawn[size] = image.convert("RGBA")
        return drawn


def hinted(size):
    """The glyph as HINTED lays it out at a size, as the SVG draws it: the disc at 38%, the line of
    traffic outside it, and the line seen through it, inside. Each pixel is as dark as the share of
    it the shapes cover."""
    layout = HINTED[size]
    (cx, cy), radius = layout["disc"]
    line, ends, inner = layout["line"], layout["line_ends"], layout["inner_line"]
    middle, half = (line[0] + line[1]) / 2, (line[1] - line[0]) / 2
    samples = 16
    coverage = []
    for py in range(size):
        for px in range(size):
            total = 0.0
            for sy in range(samples):
                y = py + (sy + 0.5) / samples
                for sx in range(samples):
                    x = px + (sx + 0.5) / samples
                    if (x - cx) ** 2 + (y - cy) ** 2 <= radius**2:
                        total += 1.0 if inner[0] <= y < inner[1] else 0.38
                    elif line[0] <= y < line[1] and ends[0] <= x < ends[1]:
                        total += 1.0
                    elif layout["round_ends"] and min((x - end) ** 2 for end in ends) + (y - middle) ** 2 <= half**2:
                        total += 1.0
            coverage.append(round(255 * total / samples**2))
    glyph = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    alpha = Image.new("L", (size, size))
    alpha.putdata(coverage)
    glyph.putalpha(alpha)
    return glyph


def tinted(glyph, color):
    """The glyph in one color, keeping its own transparency, such as the disc's."""
    canvas = Image.new("RGBA", glyph.size, color + (255,))
    canvas.putalpha(glyph.getchannel("A"))
    data = io.BytesIO()
    canvas.save(data, "PNG", optimize=True)
    return data.getvalue()


def ico(images):
    """An .ico file holding PNG images, which Windows reads at every size."""
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, payload = b"", b""
    for size, png in images:
        # 0 stands for 256 in an icon's directory.
        side = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", side, side, 0, 0, 1, 32, len(png), offset + len(payload))
        payload += png
    return header + entries + payload


def main():
    icon = render()
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "wb") as file:
        file.write(ico([(size, sized(icon, size)) for size in SIZES]))
    print(f"wrote {os.path.relpath(OUTPUT, ROOT)}: {', '.join(map(str, SIZES))} px")
    with open(PICTURE, "wb") as file:
        file.write(sized(icon, PICTURE_SIZE))
    print(f"wrote {os.path.relpath(PICTURE, ROOT)}: {PICTURE_SIZE} px")
    drawn = glyphs()
    for size in HINTED:
        drawn[size] = hinted(size)
    for path, color in NOTIFICATION_ICONS:
        with open(path, "wb") as file:
            file.write(ico([(size, tinted(drawn[size], color)) for size in NOTIFICATION_SIZES]))
        print(f"wrote {os.path.relpath(path, ROOT)}: {', '.join(map(str, NOTIFICATION_SIZES))} px")


if __name__ == "__main__":
    main()
