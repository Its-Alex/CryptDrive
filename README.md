# CryptDrive

One open-source app that talks to Google Drive directly over its API and
encrypts/decrypts client-side, on demand — like Cryptomator's Android app, but
on every platform, and without a sync client, FUSE mount or local mirror.

- **Vault format: [rclone crypt](https://rclone.org/crypt/), unmodified.** Export
  your `rclone.conf` from the app and the same vault opens with the
  [rclone CLI](https://rclone.org/), [RSAF](https://github.com/chenxiaolong/RSAF)
  or Round Sync. No custom format, no lock-in.
- **Bring your own Google OAuth client.** See
  [docs/google-oauth-client.md](docs/google-oauth-client.md).
- **No crypto, OAuth or Drive code of its own**: a thin Go wrapper links
  [rclone v1.76.0](https://github.com/rclone/rclone/releases/tag/v1.76.0) as a
  library, called from Flutter through Dart FFI.

| Platform | Tier | Status |
|----------|------|--------|
| Linux | 1 — built and tested | AppImage |
| Android | 1 — built and tested (emulator) | APK per ABI |
| Windows | 2 — CI-built | msix (experimental) |
| macOS | 3 — CI-built, untested | dmg (experimental) |
| iOS | 3 — CI-built, untested | unsigned build (experimental) |

## Layout

```
app/                         Flutter app (Riverpod)
app/packages/cryptdrive_native  Dart FFI plugin bundling the native library
native/                      Go wrapper over rclone (c-shared / c-archive)
tools/                       build, packaging and test harness scripts
docs/                        user and developer docs
```

## Quick start

```sh
mise install                 # Go, Flutter, JDK, Android SDK, CMake, Ninja, clang, rclone
mise run native:linux        # build libcryptdrive.so
cd app && flutter run -d linux
```

See [docs/development.md](docs/development.md) for Android, tests and
packaging, and [docs/manual-verification.md](docs/manual-verification.md) for
the steps that need a real Google account.

Decisions taken during implementation are listed in
[ASSUMPTIONS.md](ASSUMPTIONS.md).

## License

[MIT](LICENSE). rclone is MIT-licensed as well.
