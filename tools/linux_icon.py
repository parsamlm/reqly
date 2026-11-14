#!/usr/bin/env python3
"""Make Reqly for Linux's app icon from the Icon Composer document.

design/logo/Reqly.icon is the icon's one source. Icon Composer renders it on a Mac, and this script
has it render the default appearance at each size GNOME shows app icons at, from 16 pixels in a
title bar to 512 in a software center, into linux/packaging/icons, laid out as the hicolor theme
lays them out:

    python3 tools/linux_icon.py

So linux/packaging/icons/hicolor/48x48/apps/net.reqly.Reqly.png is the 48-pixel one, named by the
app's ID. A package installs the folder in /usr/share/icons, and a run from the build folder finds
it in the checkout. Each size is drawn on its own, rather than scaled down from a big one, so the
small ones stay sharp, with a little room around it, as the Windows icon has.

It needs Xcode, for Icon Composer's renderer, and Pillow. Run it again whenever Reqly.icon changes.
GNOME shows one icon in light and dark alike, so it's the default appearance.
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "design", "logo", "Reqly.icon")
OUTPUT = os.path.join(ROOT, "linux", "packaging", "icons", "hicolor")
NAME = "net.reqly.Reqly.png"
DEVELOPER = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
ICTOOL = os.path.join(
    os.path.dirname(os.path.dirname(DEVELOPER)), "Contents", "Applications", "Icon Composer.app",
    "Contents", "Executables", "ictool")
# The sizes GNOME, KDE and Cinnamon draw app icons at, from the title bar to the software center.
SIZES = [16, 24, 32, 48, 64, 128, 256, 512]
# The room around the icon, as a part of its size: a pixel at 16, as tools/windows_icon.py has.
INSET = 1 / 16


def render(size):
    """The default appearance, `size` pixels square, as Icon Composer draws it."""
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "icon.png")
        subprocess.run(
            [ICTOOL, SOURCE, "--export-image", "--output-file", path, "--platform", "macOS",
             "--rendition", "Default", "--width", str(size), "--height", str(size), "--scale", "1"],
            check=True, stdout=subprocess.DEVNULL)
        with Image.open(path) as image:
            return image.convert("RGBA")


def main():
    if not os.path.exists(ICTOOL):
        sys.exit(f"Icon Composer's renderer isn't at {ICTOOL}. Install Xcode, or set DEVELOPER_DIR.")
    for size in SIZES:
        inset = round(size * INSET)
        canvas = Image.new("RGBA", (size, size))
        canvas.paste(render(size - 2 * inset), (inset, inset))
        folder = os.path.join(OUTPUT, f"{size}x{size}", "apps")
        os.makedirs(folder, exist_ok=True)
        canvas.save(os.path.join(folder, NAME), "PNG", optimize=True)
    print(f"wrote {os.path.relpath(OUTPUT, ROOT)}: {', '.join(map(str, SIZES))} px")


if __name__ == "__main__":
    main()
