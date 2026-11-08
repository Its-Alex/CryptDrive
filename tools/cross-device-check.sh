#!/usr/bin/env bash
# MVP acceptance check with a local folder standing in for Google Drive:
# the phone (Android emulator) creates a vault and uploads a photo, then the
# laptop (Linux app, headless) and the plain rclone CLI open that same vault.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
package=io.github.itsalex.cryptdrive
work="$(mktemp -d "${TMPDIR:-/tmp}/cryptdrive-cross-device.XXXXXX")"
trap 'rm -r "$work"' EXIT

"$repo/tools/android-integration-test.sh" integration_test/cross_device_phone_test.dart

phone_files="$(adb shell run-as "$package" pwd | tr -d '\r')/files"
adb exec-out run-as "$package" tar c -C files cross-device | tar x -C "$work"
sed "s#$phone_files/cross-device#$work/cross-device#g" "$work/cross-device/exported-rclone.conf" \
	>"$work/cross-device/laptop-rclone.conf"

echo "Storage as Google Drive would see it:"
(cd "$work/cross-device/drive" && find . -type f)
if find "$work/cross-device/drive" | grep -q IMG_0001; then
	echo "plaintext file name found in storage" >&2
	exit 1
fi

rclone --config "$work/cross-device/laptop-rclone.conf" cat vault:IMG_0001.png | cmp - "$work/cross-device/camera/IMG_0001.png"
echo "rclone CLI: decrypted IMG_0001.png matches the phone's original"

cd "$repo/app"
"$repo/tools/linux-headless.sh" flutter test integration_test/cross_device_laptop_test.dart -d linux \
	--dart-define=CROSS_DEVICE_DIR="$work/cross-device"
