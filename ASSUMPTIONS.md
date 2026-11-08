# Assumptions and decisions made without asking

Every decision below was taken while implementing the plan, either by applying
the plan's own recommendation or, where the plan was silent, by picking the
mainstream and reversible option. Each is easy to revisit.

## Toolchain and repository

| # | Decision | Why / how to revisit |
|---|----------|----------------------|
| 1 | Pinned Flutter **3.47.9** (latest stable), Go **1.27.3** (already installed), Temurin **21.0.13** for Gradle, mise `android-sdk` **23.0** (cmdline-tools), CMake 4.4.5, Ninja 1.13.2, rclone CLI **1.76.0**, all in `mise.toml`. | Exact versions everywhere so `mise install` is reproducible; bump in one place. |
| 2 | **No `mise.lock`** (`[settings] lockfile = false`). | The local mise (2026.10.19) writes a v3 lockfile that drops the linux-x64 conda entries; mise 2026.11.4 (what CI gets) writes v4, which the local mise can't read. With every tool pinned exactly, the lockfile added breakage without much safety. Re-enable once everyone runs mise ≥ 2026.11. |
| 3 | Clang for the Flutter Linux runner comes from **`conda:clang` 23.1.4**, wrapped by `tools/bin/clang{,++}` (added to `PATH` by mise). | No system clang and no root on this machine. The wrapper disables conda's own sysroot/linker so the runner links against the host GTK. On a machine with a system clang, the wrapper still works. |
| 4 | Android SDK packages: platform 36 and **37.0**, build-tools 36.0.0, **NDK 28.2.13676358** (Flutter 3.47's default), emulator. App `compileSdk = 37` because `receive_sharing_intent` 1.9 compiles against 37; `targetSdk` stays at Flutter's default (36). | Drop back to Flutter's default compileSdk once the plugin no longer needs 37. |
| 5 | `org.gradle.daemon=false` and a 2 GiB Gradle heap in `app/android/gradle.properties` (template asked for 8 GiB). | This 6 GiB VM runs `earlyoom`, which killed Gradle daemons and the emulator. Harmless on CI. |
| 6 | Root `.gitignore` ignores `*.lock`: added an exception for `app/pubspec.lock` (apps commit it). | |
| 7 | Package/application id **`io.github.itsalex.cryptdrive`**, display name **CryptDrive**, version 0.1.0. | Matches the GitHub remote `Its-Alex/CryptDrive`. |
| 8 | License: **MIT** (same as rclone). | Plan was silent; change `LICENSE` if needed. |

## Native layer (`native/`)

| # | Decision | Why / how to revisit |
|---|----------|----------------------|
| 9 | rclone pinned at **v1.76.0** (`go.mod`), linked through `librclone/librclone` + `backend/all` + `fs/operations` + `fs/sync`; no mount, no cmount (RSAF pattern). | As the plan says. |
| 10 | C API: `CryptDriveInitialize(configPath)`, `RcloneRPC`, `RcloneFreeString`, `RcloneFinalize`, `CryptDriveSetConfigPassword`. The config path is set **at initialization**, before rclone installs its config storage; `config/setpath` still works afterwards. | rclone only installs file-backed config storage if a path is set at that moment; otherwise it would read the user's own `~/.config/rclone/rclone.conf`. |
| 11 | The in-process authorize helper is exposed as the rc method **`cryptdrive/authorize`** (async, cancellable with `config/oauthstop`, auth URL read from `config/oauthstatus`); `SetConfigPassword` is a **separate C symbol**. | Authorize needs rclone's job machinery (async + cancel); the config password must never go through rc, whose debug log prints parameters. |
| 12 | rclone's `AskPassword` is turned off and its log level set to NOTICE. | A wrong config password would otherwise block on a terminal prompt inside the app. |
| 13 | `RcloneFinalize` first stops every running rc job (≤ 5 s), calling the job functions directly. | Plan constraint: upstream `Finalize` leaves async jobs running. |
| 14 | Import/export of `rclone.conf` lives in Go as rc methods `cryptdrive/importconfig` / `cryptdrive/exportconfig`. Export is the **plain** standard file (passwords obscured, as rclone writes them). Import accepts plain or **encrypted** (`RCLONE_ENCRYPT_V0`) files; values are copied verbatim, sections with the same name are replaced. | rclone's config decryption only works with its one process-global key (which holds the app's own key), so the import decrypts with the same documented format (NaCl secretbox, SHA-256 key) — verified against a file encrypted by the rclone 1.76 CLI (`native/bridge/testdata`). |
| 15 | Android libraries are built with `-Wl,-z,max-page-size=16384`, for ABIs arm64-v8a, armeabi-v7a, x86_64; `minSdk` 24. | 16 KiB page requirement for Android 15+ targets. |
| 16 | iOS ships a **device-only** (`arm64`) `c-archive`, force-loaded by the plugin podspec, symbols kept with `STRIP_STYLE = non-global`; macOS a universal dylib. | One static library can't hold device and simulator arm64 slices. Untested (tier 3). |

## Dart / Flutter

| # | Decision | Why / how to revisit |
|---|----------|----------------------|
| 17 | The Dart FFI wrapper is a local **FFI plugin package** `app/packages/cryptdrive_native` that bundles the prebuilt library on each platform (CMake `bundled_libraries`, `jniLibs`, podspec `vendored_libraries`). Bindings are hand-written (5 symbols), not ffigen. | Mainstream Flutter mechanism for prebuilt native libraries on all five platforms. |
| 18 | Every native call runs on a short-lived isolate (`Isolate.run`); long operations use `_async: true` + `job/status`, progress from `core/stats` group `job/<id>`. | Keeps the UI isolate responsive. |
| 19 | Riverpod 3 with automatic retry **disabled** (`ProviderScope(retry: noRetry)`). | Bootstrap failures (no keystore, locked config) need the user, not retries. |
| 20 | Remote names: storage `gdrive` (Drive) or `localstore` (local folder), vault `vault`; crypt with `filename_encryption = standard`, `directory_name_encryption = true`, optional salt (`password2`). A config imported with other names still works: the vault is `vault` or the first crypt remote. | rclone defaults; readable when exported. |
| 21 | Onboarding offers a **"Local folder" storage** next to Google Drive. | The plan's acceptance test needs a stand-in for Drive without live OAuth; also useful to try the app. |
| 22 | Drive remote created with `scope = drive`, `config_is_local = false`, `nonInteractive`; the token comes from the in-app sign-in or from pasted `rclone authorize` output (anything around the JSON object is stripped; a `refresh_token` is required). Changing the client ID requires a new token. | Per the plan; tokens are bound to their OAuth client. |
| 23 | The config password is 32 random bytes generated on first launch and kept in `flutter_secure_storage`. If the config exists but the password is gone or wrong, the app shows **"Configuration locked"** with a reset; an existing password with no config (iOS reinstall) is simply reused. | Plan's `flutter_secure_storage` caveats. |
| 24 | Android: `allowBackup="false"`, `fullBackupContent="false"`, data-extraction rules excluding everything. | Plan caveat: restored prefs break key unwrap. |
| 25 | Rename/move of **files** uses `operations/movefile`; **folders** use `sync/move` (server-side) with `deleteEmptySrcDirs`, then `operations/rmdir` of the leftover. Delete: `operations/deletefile` / `operations/purge`. | `operations/movefile` only moves files. |
| 26 | Open: decrypt to `<temp>/cryptdrive-opened/<random>/<name>` with `operations/copyfile`, hand off with `open_filex`; Share via `share_plus` (not offered on Linux, which has no file share sheet); **"Save decrypted copy…"** via the file picker on every platform. Temp dir wiped at start, on exit request and on detach. | Plan; startup wipe covers kills. |
| 27 | Preview (text, JSON, images ≤ 2 MiB) via one `operations/getfile` call (`count` ≤ 2 MiB, base64). | Plan: ranged 2 MiB getfile for small previews. |
| 28 | Upload: `file_picker` (multi-select) or Android share target (`SEND`/`SEND_MULTIPLE`, `*/*`, via `receive_sharing_intent`); files without a local path are staged to a temp dir, then `operations/copyfile`. | Plan. iOS share extension not added (plan only asks for the Android share target). |
| 29 | Moving uses a text field for the destination folder (no folder picker dialog). | Simplest reversible UI. |
| 30 | macOS entitlements: network client + server (loopback OAuth), user-selected files. No keychain-sharing entitlement (needs a signing team). | Tier 3, untested. |

## Testing and verification

| # | Decision | Why / how to revisit |
|---|----------|----------------------|
| 31 | Local headless Linux GUI runs use `tools/linux-headless.sh`: **Weston 16 headless (pixman renderer) from conda** + **pass-secret-service 0.7.1** with a throwaway GPG key, inside `dbus-run-session`, all isolated from the user's session. | This machine has no display server and no Secret Service, and installing them needs root. Mesa renders the Flutter client in software (`LIBGL_ALWAYS_SOFTWARE=1`). |
| 32 | Android emulator tests run on an **API 30 `default` x86_64** image with 1 GiB RAM, 720×1280, via `tools/android-integration-test.sh` (build first, then boot; results read from logcat) instead of `flutter drive`. | `earlyoom` on this 6 GiB VM killed the API 35 emulator during Gradle builds and `flutter drive`. |
| 33 | The cross-device MVP check (`tools/cross-device-check.sh`) copies the phone's vault folder out of the emulator with `adb run-as` and rewrites the local path in the exported `rclone.conf`. | With a local folder standing in for Drive, the two devices don't share storage; with Drive the conf needs no rewrite. |
| 34 | CI: Linux, Android build and Android emulator jobs are required; Windows, macOS and iOS jobs are `continue-on-error: true`. GitHub Actions pinned to their current majors. All seven jobs pass on GitHub ([run 42517819477](https://github.com/Its-Alex/CryptDrive/actions/runs/42517819477)). The Android jobs first delete the runner's preinstalled SDKs (disk space), and `native/build.sh` prefers the pinned NDK over the runner's `ANDROID_NDK_HOME`. | Plan's platform tiers. |
| 37 | `MainActivity` drops shared streams it can't read before `receive_sharing_intent` sees them. | The plugin copies shared files without catching errors: an unreadable URI (seen with the emulator's Gallery) crashed the app. |
| 38 | Kotlin compiles in-process (`kotlin.compiler.execution.strategy=in-process`). | One JVM instead of two on low-memory machines. |
| 35 | Release APKs are signed with the debug key (Flutter template default), split per ABI. MSIX uses the `msix` package's test certificate. | Real signing needs keys the user owns. |
| 36 | The OAuth docs recommend **publishing** the consent screen (unverified, personal use) to avoid Testing mode's 7-day refresh-token expiry. | Otherwise the user signs in again every week. |
