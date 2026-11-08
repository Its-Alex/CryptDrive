#!/usr/bin/env bash
# Runs a Flutter integration test on an Android emulator without
# `flutter drive`: builds the test APK first, then boots the emulator, so the
# Gradle build and the emulator never hold memory at the same time.
# Usage: tools/android-integration-test.sh [test-file] [avd-name]
#   defaults: integration_test/app_flow_test.dart, cryptdrive_api30
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
test_file="${1:-integration_test/app_flow_test.dart}"
avd="${2:-cryptdrive_api30}"
package=io.github.itsalex.cryptdrive
apk="$repo/app/build/app/outputs/flutter-apk/app-debug.apk"
abi_platform=android-x64
# Pin where AVDs live so avdmanager, this script and the emulator agree (they differ on GitHub runners).
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"

cd "$repo/app"
flutter build apk --debug --target-platform "$abi_platform" -t "$test_file"

if ! adb get-state >/dev/null 2>&1; then
	if ! avdmanager list avd -c | grep -qx "$avd"; then
		echo no | avdmanager create avd -n "$avd" -p "$ANDROID_AVD_HOME/$avd.avd" -k "system-images;android-30;default;x86_64" -d pixel_4 --force
		config="$ANDROID_AVD_HOME/$avd.avd/config.ini"
		sed -i 's/^hw.ramSize=.*/hw.ramSize=1024/; s/^hw.lcd.width=.*/hw.lcd.width=720/; s/^hw.lcd.height=.*/hw.lcd.height=1280/; s/^hw.lcd.density=.*/hw.lcd.density=320/' "$config"
	fi
	setsid nohup "$ANDROID_HOME/emulator/emulator" -avd "$avd" -no-window -no-audio -no-boot-anim \
		-gpu swiftshader_indirect -no-snapshot -memory 1024 -cores 2 >"${TMPDIR:-/tmp}/cryptdrive-emulator.log" 2>&1 </dev/null &
	adb wait-for-device
	until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
fi

adb install -r "$apk"
adb logcat -c
adb shell am start -W -n "$package/.MainActivity" >/dev/null
log="$(mktemp)"
for _ in $(seq 120); do
	sleep 3
	adb logcat -d -s flutter >"$log"
	if grep -qE "All tests passed!|Some tests failed" "$log"; then break; fi
done
grep -vE "NOTICE" "$log" | sed -n '/^.* flutter : [0-9][0-9]:[0-9][0-9] +/p;/EXCEPTION CAUGHT/,/^.*═══════$/p'
grep -q "All tests passed!" "$log"
