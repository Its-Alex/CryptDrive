# cryptdrive_native

Dart FFI bindings to CryptDrive's native library (rclone, built from
[`native/`](../../../native)). The plugin only bundles the prebuilt library on
each platform; build it with `native/build.sh` first.

- `CryptDriveBindings`: synchronous mapping of the C API.
- `Rclone`: async facade, each call on its own isolate; `runJob` for
  `_async` rc jobs with progress.
