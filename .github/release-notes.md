Pre-release: everything except live Google sign-in is tested (see [docs/manual-verification.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/manual-verification.md)). The vault format is plain [rclone crypt](https://rclone.org/crypt/).

| File | Platform | Notes |
|------|----------|-------|
| `CryptDrive-x86_64.AppImage` | Linux x86_64 | Needs a Secret Service (GNOME Keyring, KWallet…) |
| `CryptDrive-linux-x86_64.tar.gz` | Linux x86_64, unpacked | Same app without AppImage: extract and run `CryptDrive/cryptdrive` |
| `CryptDrive-android.apk` | Android 7+, every phone and emulator (arm64, arm, x86_64) | Allow installs from your browser or file manager when Android asks |
| `CryptDrive-windows-x64.msix` / `.zip` | Windows x64 | Experimental; the msix uses a test certificate |
| `CryptDrive-macos.dmg` | macOS | Experimental, unsigned, untested |
| `CryptDrive-unsigned-ios.zip` | iOS | Experimental, unsigned, untested: needs re-signing to install |

Before the first launch, create your own Google OAuth client: [docs/google-oauth-client.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/google-oauth-client.md). `SHA256SUMS` lists the checksums of every file.
