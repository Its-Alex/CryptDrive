import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';

void main() {
  final sinceMain = Stopwatch()..start();
  stderr.writeln('cryptdrive startup: Dart code running');
  WidgetsFlutterBinding.ensureInitialized().addPostFrameCallback(
    (_) => stderr.writeln('cryptdrive startup: first frame ${sinceMain.elapsedMilliseconds} ms after start'),
  );
  runApp(const ProviderScope(retry: noRetry, child: CryptDriveApp()));
}
