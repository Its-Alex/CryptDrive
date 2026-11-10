#!/usr/bin/env bash
# Builds libcryptdrive for one target and drops it where the cryptdrive_native plugin bundles it.
# Usage: native/build.sh linux-x64|linux-arm64|windows-x64|android [abi...]|macos|ios|web
set -euo pipefail

native_dir="$(cd "$(dirname "$0")" && pwd)"
plugin_dir="$native_dir/../app/packages/cryptdrive_native"
go_flags=(-trimpath -ldflags="-s -w")
android_min_sdk=24

build_c_shared() {
	local output="$1"
	mkdir -p "$(dirname "$output")"
	(cd "$native_dir" && go build "${go_flags[@]}" -buildmode=c-shared -o "$output" .)
	rm -f "${output%.*}.h"
}

ndk_toolchain_bin() {
	local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
	local ndk="$sdk/ndk/${CRYPTDRIVE_NDK_VERSION:-28.2.13676358}"
	[ -d "$ndk" ] || ndk="${ANDROID_NDK_HOME:?NDK ${CRYPTDRIVE_NDK_VERSION:-28.2.13676358} not found in $sdk/ndk}"
	local host
	case "$(uname -s)" in
	Linux) host=linux-x86_64 ;;
	Darwin) host=darwin-x86_64 ;;
	*) echo "unsupported NDK host $(uname -s)" >&2; exit 1 ;;
	esac
	echo "$ndk/toolchains/llvm/prebuilt/$host/bin"
}

build_android_abi() {
	local abi="$1" goarch clang_target goarm=""
	case "$abi" in
	arm64-v8a) goarch=arm64; clang_target=aarch64-linux-android ;;
	armeabi-v7a) goarch=arm; goarm=7; clang_target=armv7a-linux-androideabi ;;
	x86_64) goarch=amd64; clang_target=x86_64-linux-android ;;
	*) echo "unknown Android ABI: $abi" >&2; exit 1 ;;
	esac
	local toolchain
	toolchain="$(ndk_toolchain_bin)"
	# 16 KiB pages are required for apps targeting Android 15+ on arm64 devices.
	CGO_ENABLED=1 GOOS=android GOARCH="$goarch" GOARM="$goarm" \
		CC="$toolchain/${clang_target}${android_min_sdk}-clang" \
		CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
		build_c_shared "$plugin_dir/android/src/main/jniLibs/$abi/libcryptdrive.so"
}

build_apple() {
	local goos="$1" goarch="$2" sdk="$3" min_flag="$4" mode="$5" output="$6"
	local cc
	cc="$(xcrun --sdk "$sdk" --find clang)"
	local sysroot
	sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
	local clang_arch="$goarch"
	[ "$goarch" = amd64 ] && clang_arch=x86_64
	mkdir -p "$(dirname "$output")"
	(cd "$native_dir" && CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" \
		CC="$cc -arch $clang_arch -isysroot $sysroot $min_flag" \
		CGO_CFLAGS="-arch $clang_arch -isysroot $sysroot $min_flag" \
		CGO_LDFLAGS="-arch $clang_arch -isysroot $sysroot $min_flag" \
		go build "${go_flags[@]}" -buildmode="$mode" -o "$output" .)
	rm -f "${output%.*}.h"
}

target="${1:?target required}"
shift || true
case "$target" in
linux-x64)
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 build_c_shared "$plugin_dir/linux/lib/libcryptdrive.so"
	;;
linux-arm64)
	CGO_ENABLED=1 GOOS=linux GOARCH=arm64 build_c_shared "$plugin_dir/linux/lib/libcryptdrive.so"
	;;
windows-x64)
	CGO_ENABLED=1 GOOS=windows GOARCH=amd64 build_c_shared "$plugin_dir/windows/lib/cryptdrive.dll"
	;;
android)
	abis=("$@")
	[ ${#abis[@]} -eq 0 ] && abis=(arm64-v8a armeabi-v7a x86_64)
	for abi in "${abis[@]}"; do
		build_android_abi "$abi"
	done
	;;
macos)
	work="$(mktemp -d)"
	build_apple darwin arm64 macosx -mmacosx-version-min=10.15 c-shared "$work/arm64.dylib"
	build_apple darwin amd64 macosx -mmacosx-version-min=10.15 c-shared "$work/amd64.dylib"
	mkdir -p "$plugin_dir/macos/Libraries"
	lipo -create "$work/arm64.dylib" "$work/amd64.dylib" -output "$plugin_dir/macos/Libraries/libcryptdrive.dylib"
	install_name_tool -id "@rpath/libcryptdrive.dylib" "$plugin_dir/macos/Libraries/libcryptdrive.dylib"
	;;
ios)
	# Device only: a single static library cannot hold both device and simulator arm64 slices.
	build_apple ios arm64 iphoneos -miphoneos-version-min=15.0 c-archive "$plugin_dir/ios/Libraries/libcryptdrive.a"
	;;
web)
	web_dir="$native_dir/../app/web/cryptdrive"
	# net/http on js/wasm only uses fetch when the transport has no dial hook, and rclone
	# always sets one, so build from a vendored copy with patches/_fshttp/http.go swapped in.
	work="$(mktemp -d "${TMPDIR:-/tmp}/cryptdrive-web-build.XXXXXX")"
	trap 'rm -r "$work"' EXIT
	mkdir -p "$work/native"
	cp -a "$native_dir/go.mod" "$native_dir/go.sum" "$native_dir/main.go" "$native_dir/bridge" "$native_dir/wasm" "$work/native/"
	(cd "$work/native" && go mod vendor)
	cp "$native_dir/patches/_fshttp/http.go" "$work/native/vendor/github.com/rclone/rclone/fs/fshttp/http.go"
	(cd "$work/native" && GOOS=js GOARCH=wasm go build "${go_flags[@]}" -o "$web_dir/cryptdrive.wasm" ./wasm)
	cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$web_dir/wasm_exec.js"
	;;
*)
	echo "unknown target: $target" >&2
	exit 1
	;;
esac
