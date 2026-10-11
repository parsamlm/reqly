#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$REPO_ROOT/linux-dists"
BUILD_DIR="$DIST_DIR/build"
PKG_ROOT="$DIST_DIR/pkg_root"

VERSION="1.0.0"
ARCH="amd64"
PKG_NAME="reqly_${VERSION}_${ARCH}"
OUTPUT_DEB="$REPO_ROOT/${PKG_NAME}.deb"

echo "=== Building Reqly Linux binary ==="
cmake -B "$BUILD_DIR" -S "$DIST_DIR" -G Ninja
ninja -C "$BUILD_DIR" -j"$(nproc)"

echo "=== Preparing Debian package structure ==="
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT"/DEBIAN
mkdir -p "$PKG_ROOT"/usr/bin
mkdir -p "$PKG_ROOT"/usr/share/applications
mkdir -p "$PKG_ROOT"/usr/share/icons/hicolor/scalable/apps
mkdir -p "$PKG_ROOT"/usr/share/icons/hicolor/128x128/apps

# Copy binary and strip debug symbols
cp "$BUILD_DIR/reqly" "$PKG_ROOT/usr/bin/reqly"
chmod 755 "$PKG_ROOT/usr/bin/reqly"
strip --strip-unneeded "$PKG_ROOT/usr/bin/reqly"

# Copy icons
if [ -f "$REPO_ROOT/design/logo/exports/reqly-icon.svg" ]; then
    cp "$REPO_ROOT/design/logo/exports/reqly-icon.svg" "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps/reqly.svg"
fi
if [ -f "$REPO_ROOT/design/logo/exports/reqly-icon-default.png" ]; then
    cp "$REPO_ROOT/design/logo/exports/reqly-icon-default.png" "$PKG_ROOT/usr/share/icons/hicolor/128x128/apps/reqly.png"
fi

# Desktop Entry
cat << 'EOF' > "$PKG_ROOT/usr/share/applications/reqly.desktop"
[Desktop Entry]
Name=Reqly
Comment=Network traffic inspector and HTTP/HTTPS proxy
Exec=reqly --gui
Icon=reqly
Terminal=false
Type=Application
Categories=Development;Network;WebDevelopment;Debugger;
Keywords=network;proxy;http;https;inspect;debug;packet;traffic;
StartupNotify=true
StartupWMClass=Reqly
EOF
chmod 644 "$PKG_ROOT/usr/share/applications/reqly.desktop"

# DEBIAN/control
cat << EOF > "$PKG_ROOT/DEBIAN/control"
Package: reqly
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: Reqly Contributors <support@reqly.net>
Depends: libc6 (>= 2.34), libgtk-3-0t64 | libgtk-3-0, libssl3 (>= 3.0.0), libstdc++6 (>= 11)
Description: Network traffic inspector for apps and devices
 Reqly is an open-source native network traffic inspector. It shows what
 your apps send and receive, clearly laid out. It features full HTTP/1.1 and
 HTTPS decryption, request editing and resending, breakpoints, map local,
 rewrites, slow network throttling, and HAR export.
EOF
chmod 644 "$PKG_ROOT/DEBIAN/control"

# DEBIAN/postinst
cat << 'EOF' > "$PKG_ROOT/DEBIAN/postinst"
#!/bin/sh
set -e

if [ -x /usr/bin/update-desktop-database ]; then
    update-desktop-database -q /usr/share/applications || true
fi

if [ -x /usr/bin/gtk-update-icon-cache ]; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

exit 0
EOF
chmod 755 "$PKG_ROOT/DEBIAN/postinst"

# DEBIAN/prerm
cat << 'EOF' > "$PKG_ROOT/DEBIAN/prerm"
#!/bin/sh
set -e

if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true
fi

exit 0
EOF
chmod 755 "$PKG_ROOT/DEBIAN/prerm"

echo "=== Packaging .deb file ==="
dpkg-deb --root-owner-group -Zxz --build "$PKG_ROOT" "$OUTPUT_DEB"

echo "=== Created .deb package at: $OUTPUT_DEB ==="
dpkg-deb -I "$OUTPUT_DEB"
dpkg-deb -c "$OUTPUT_DEB"
