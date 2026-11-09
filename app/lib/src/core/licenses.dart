import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _separator = '--------------------------------------------------------------------------------';

/// Adds the Go modules compiled into the native library and the browser engine
/// (rclone and its dependencies) to the licenses Flutter collects from Dart packages.
void registerGoModuleLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/licenses/go.txt');
    for (final chunk in text.split('$_separator\n').skip(1)) {
      final newline = chunk.indexOf('\n');
      if (newline <= 0) continue;
      yield LicenseEntryWithLineBreaks([chunk.substring(0, newline)], chunk.substring(newline + 1).trim());
    }
  });
}
