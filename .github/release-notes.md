Pre-release: everything except live Google sign-in is tested (see [docs/manual-verification.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/manual-verification.md)). The vault format is plain [rclone crypt](https://rclone.org/crypt/).

| File | Platform | Notes |
|------|----------|-------|
| `CryptDrive-x86_64.AppImage` | Linux x86_64 | Needs a Secret Service (GNOME Keyring, KWallet…) |
| `CryptDrive-android-arm64-v8a.apk` | Android, most phones | Signed with a debug key |
| `CryptDrive-android-armeabi-v7a.apk` | Android, older 32-bit phones | Signed with a debug key |
| `CryptDrive-android-x86_64.apk` | Android emulators, x86 tablets | Signed with a debug key |
| `CryptDrive-windows-x64.msix` / `.zip` | Windows x64 | Experimental; the msix uses a test certificate |
| `CryptDrive-macos.dmg` | macOS | Experimental, unsigned, untested |
| `CryptDrive-unsigned-ios.zip` | iOS | Experimental, unsigned, untested: needs re-signing to install |

Before the first launch, create your own Google OAuth client: [docs/google-oauth-client.md](https://github.com/Its-Alex/CryptDrive/blob/main/docs/google-oauth-client.md). `SHA256SUMS` lists the checksums of every file.
