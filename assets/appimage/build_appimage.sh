#!/usr/bin/env bash
# Packages wifiscan_gui.py + WiFiScan.sh + mac-vendors.json into one WiFiScan-x86_64.AppImage.
# Runtime requirements on the machine that RUNS the AppImage: python3, python3-tk, policykit-1 (pkexec).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "$HERE/.." && pwd)"
BUILD_DIR="$HERE/build"
APPDIR="$BUILD_DIR/WiFiScan.AppDir"
APPIMAGETOOL="$BUILD_DIR/appimagetool"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"

cp "$ASSETS_DIR/WiFiScan.sh" "$APPDIR/usr/bin/"
cp "$ASSETS_DIR/mac-vendors.json" "$APPDIR/usr/bin/"
cp "$HERE/wifiscan_gui.py" "$APPDIR/usr/bin/"
chmod +x "$APPDIR/usr/bin/WiFiScan.sh" "$APPDIR/usr/bin/wifiscan_gui.py"

cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec python3 "$HERE/usr/bin/wifiscan_gui.py" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/wifiscan.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=WiFiScan
Exec=wifiscan_gui.py
Icon=wifiscan
Categories=Network;
Terminal=false
EOF

# 1x1 placeholder icon — swap wifiscan.png for something nicer before showing a client.
base64 -d > "$APPDIR/wifiscan.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
EOF

if [[ ! -x "$APPIMAGETOOL" ]]; then
    mkdir -p "$BUILD_DIR"
    echo "Downloading appimagetool..."
    curl -L -o "$APPIMAGETOOL" \
        https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$APPIMAGETOOL"
fi

"$APPIMAGETOOL" "$APPDIR" "$BUILD_DIR/WiFiScan-x86_64.AppImage"
echo "Built: $BUILD_DIR/WiFiScan-x86_64.AppImage"
echo "Runtime requirements on the target machine: python3, python3-tk, policykit-1 (pkexec)."
