Pre-release: everything except live Google sign-in is tested (see [docs/manual-verification.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/manual-verification.md)). The vault format is plain [rclone crypt](https://rclone.org/crypt/).

| File | Platform | Notes |
|------|----------|-------|
| `CryptDrive-x86_64.AppImage` | Linux x86_64 | Needs a Secret Service (GNOME Keyring, KWallet…) |
| `CryptDrive-linux-x86_64.tar.gz` | Linux x86_64, unpacked | Same app without AppImage: extract and run `CryptDrive/cryptdrive` |
| `CryptDrive-android.apk` | Android 7+, every phone and emulator (arm64, arm, x86_64) | Allow installs from your browser or file manager when Android asks |
| `CryptDrive-windows-x64-setup.exe` | Windows x64 | Experimental. Unsigned: on the SmartScreen warning, click *More info* → *Run anyway*. Installs for the current user, no admin needed |
| `CryptDrive-windows-x64.zip` | Windows x64, portable | Experimental. Extract and run `cryptdrive.exe` |
| `CryptDrive-macos.dmg` | macOS | Experimental, unsigned, untested |
| `CryptDrive-unsigned-ios.zip` | iOS | Experimental, unsigned, untested: needs re-signing to install |
| `CryptDrive-web.tar.gz` | Web, any static host | Zero-knowledge web app: files are encrypted in the browser. Serve over HTTPS ([docs/web.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/web.md)) |

Before the first launch, create your own Google OAuth client: [docs/google-oauth-client.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/google-oauth-client.md). `SHA256SUMS` lists the checksums of every file.

Try the web app at https://its-alex.github.io/CryptDrive/ (needs your own Web application OAuth client, see [docs/web.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/web.md#google-oauth-client-for-the-web)), or self-host it as a container image (static files only, port 8080): `docker run -p 8080:8080 ghcr.io/its-alex/cryptdrive-web:latest` (or the tag of this release without its `v`), then put it behind an HTTPS reverse proxy.
