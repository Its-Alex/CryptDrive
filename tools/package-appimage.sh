#!/usr/bin/env bash
# Packages the Linux release bundle (app/build/linux/x64/release/bundle) as an AppImage.
# Usage: tools/package-appimage.sh [output.AppImage]
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$repo/app/build/linux/x64/release/bundle"
output="${1:-$repo/app/build/CryptDrive-x86_64.AppImage}"
appimagetool_version=1.9.1

[ -x "$bundle/cryptdrive" ] || { echo "run 'flutter build linux --release' in app/ first" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/cryptdrive-appimage.XXXXXX")"
trap 'rm -r "$work"' EXIT
appdir="$work/CryptDrive.AppDir"
mkdir -p "$appdir/usr"
cp -r "$bundle" "$appdir/usr/bin"

cat >"$appdir/cryptdrive.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=CryptDrive
Comment=Encrypted Google Drive client (rclone crypt)
Exec=cryptdrive
Icon=cryptdrive
Categories=Utility;Security;
DESKTOP
cp "$repo/app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" "$appdir/cryptdrive.png"
cat >"$appdir/AppRun" <<'APPRUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
exec "$here/usr/bin/cryptdrive" "$@"
APPRUN
chmod +x "$appdir/AppRun"

tool="${XDG_CACHE_HOME:-$HOME/.cache}/cryptdrive/appimagetool-$appimagetool_version-x86_64.AppImage"
if [ ! -x "$tool" ]; then
	mkdir -p "$(dirname "$tool")"
	curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/$appimagetool_version/appimagetool-x86_64.AppImage"
	chmod +x "$tool"
fi
# appimagetool is itself an AppImage: extract-and-run avoids needing FUSE (CI runners, containers).
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$tool" --no-appstream "$appdir" "$output"
echo "$output"
