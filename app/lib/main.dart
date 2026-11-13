import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/core/licenses.dart';
import 'src/core/perf_log.dart';

void main() {
  final sinceMain = Stopwatch()..start();
  perfLog('cryptdrive startup: Dart code running');
  WidgetsFlutterBinding.ensureInitialized().addPostFrameCallback(
    (_) => perfLog('cryptdrive startup: first frame ${sinceMain.elapsedMilliseconds} ms after start'),
  );
  registerGoModuleLicenses();
  runApp(const ProviderScope(retry: noRetry, child: CryptDriveApp()));
}
