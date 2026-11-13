import 'package:cryptdrive/src/core/perf_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('perfLog puts the wall-clock time of the call in front of the line', () {
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    try {
      perfLog('[upload] a.bin: row up');
    } finally {
      debugPrint = original;
    }

    expect(printed.single, matches(r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[upload\] a\.bin: row up$'));
  });
}
