import 'package:cryptdrive/src/core/licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the Go modules of the native library are listed with their license text', () async {
    registerGoModuleLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final packages = entries.expand((entry) => entry.packages).toSet();
    expect(packages, containsAll(['github.com/rclone/rclone', 'Go (standard library and runtime)']));
    final rclone = entries.firstWhere((entry) => entry.packages.contains('github.com/rclone/rclone'));
    expect(rclone.paragraphs.map((paragraph) => paragraph.text).join(' '), contains('MIT'));
  });
}
