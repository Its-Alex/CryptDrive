# Development

Everything is pinned in [`mise.toml`](../mise.toml): run `mise install` once.

## Architecture

```
Flutter UI (app/, Riverpod)
  └─ Dart FFI (app/packages/cryptdrive_native)
      └─ thin Go wrapper (native/, RSAF-style)
          └─ rclone librclone/librclone + backend/all  (Drive API + crypt)
```

The native library exposes the same C symbols on every platform:

| Symbol | Purpose |
|--------|---------|
| `CryptDriveInitialize(configPath)` | Start rclone with its config file in app-private storage |
| `CryptDriveSetConfigPassword(password)` | Key of the encrypted `rclone.conf`; fails on a wrong password |
| `RcloneRPC(method, inputJson)` | Any [rc method](https://rclone.org/rc/), plus `cryptdrive/authorize`, `cryptdrive/importconfig`, `cryptdrive/exportconfig` |
| `RcloneFreeString(str)` | Free strings returned above |
| `RcloneFinalize()` | Stop running jobs, then finalize |

## Native library

| Command | Output (inside the plugin, git-ignored) | Where |
|---------|------------------------------------------|-------|
| `mise run native:linux` | `linux/lib/libcryptdrive.so` | Linux |
| `mise run native:android` (or `native/build.sh android x86_64`) | `android/src/main/jniLibs/<abi>/libcryptdrive.so` | Linux/macOS with the NDK |
| `native/build.sh windows-x64` | `windows/lib/cryptdrive.dll` | Windows with MinGW gcc |
| `mise run native:macos` | `macos/Libraries/libcryptdrive.dylib` (universal) | macOS |
| `mise run native:ios` | `ios/Libraries/libcryptdrive.a` (c-archive) | macOS |

They are plain `go build -buildmode=c-shared` / `c-archive` commands; see
[`native/build.sh`](../native/build.sh).

## Tests

| Command | What it covers |
|---------|----------------|
| `mise run test:native` | Go: encrypted round-trip over a local remote, config encryption on disk, wrong password, import/export (plain and encrypted `rclone.conf`), in-process OAuth up to Google's consent redirect, job shutdown |
| `mise run test:app` | Dart: FFI wrapper unit tests, and the core round-trip (encrypt → upload → list → download → decrypt, CRUD, preview, config export) against a local crypt remote, including the **rclone CLI** reading and writing the same vault |
| `tools/linux-headless.sh flutter test integration_test/app_flow_test.dart -d linux` (in `app/`) | The app's UI flow on the Linux desktop with a real Secret Service, without a display |
| `mise exec -- tools/android-integration-test.sh` | The same flow on an Android emulator |
| `mise exec -- tools/cross-device-check.sh` | MVP acceptance check: the phone creates a vault and uploads a photo; the Linux app and the rclone CLI open it |

`tools/linux-headless.sh` runs any command with a throwaway Weston
(headless) compositor and a throwaway Secret Service
([pass-secret-service](https://github.com/grimsteel/pass-secret-service)), so
it needs neither a desktop session nor root.

## Packaging

| Target | Command |
|--------|---------|
| AppImage | `cd app && flutter build linux --release && ../tools/package-appimage.sh` |
| APK | `cd app && flutter build apk --release --split-per-abi` |
| msix | `cd app && flutter build windows --release && dart run msix:create` (Windows) |
| dmg | `cd app && flutter build macos --release && hdiutil create …` (see CI) |
| iOS | `cd app && flutter build ios --release --no-codesign` |

CI (`.github/workflows/ci.yml`) builds all of these; Windows, macOS and iOS
jobs are experimental and never block.
