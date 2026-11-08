#!/usr/bin/env bash
# Runs a command with what a Linux desktop session gives CryptDrive: a Wayland
# compositor and a Secret Service, both throwaway and isolated from the user's own.
# Usage: tools/linux-headless.sh <command...>   (e.g. flutter test integration_test -d linux)
set -euo pipefail

if [ -z "${CRYPTDRIVE_HEADLESS_INNER:-}" ]; then
	export CRYPTDRIVE_HEADLESS_INNER=1
	exec mise exec conda:weston@16.0.2 github:grimsteel/pass-secret-service@0.7.1 -- \
		dbus-run-session -- "$0" "$@"
fi

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/cryptdrive-headless.XXXXXX")"
cleanup() {
	kill "${secret_service_pid:-}" "${weston_pid:-}" 2>/dev/null || true
	gpgconf --homedir "$sandbox/gnupg" --kill all 2>/dev/null || true
	rm -r "$sandbox"
}
trap cleanup EXIT

export GNUPGHOME="$sandbox/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key cryptdrive-headless@localhost default default never
key_fingerprint="$(gpg --batch --with-colons --list-keys cryptdrive-headless@localhost | awk -F: '/^fpr:/ {print $10; exit}')"
mkdir "$sandbox/password-store"
echo "$key_fingerprint" >"$sandbox/password-store/.gpg-id"
pass-secret-service -d "$sandbox/password-store" &
secret_service_pid=$!

export XDG_RUNTIME_DIR="$sandbox/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
weston --backend=headless --renderer=pixman --width="${HEADLESS_WIDTH:-1280}" --height="${HEADLESS_HEIGHT:-800}" --socket=wayland-cryptdrive --debug \
	--idle-time=0 >"$sandbox/weston.log" 2>&1 &
weston_pid=$!
for _ in $(seq 100); do
	[ -S "$XDG_RUNTIME_DIR/wayland-cryptdrive" ] && break
	sleep 0.1
done
export WAYLAND_DISPLAY=wayland-cryptdrive GDK_BACKEND=wayland LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1
unset DISPLAY

"$@"
