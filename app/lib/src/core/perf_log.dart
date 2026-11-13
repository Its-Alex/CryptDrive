import 'package:flutter/foundation.dart';

/// Prints [message] behind the wall-clock time of the call, so a performance
/// line can be placed against another trace and not only against the line above.
void perfLog(String message) => debugPrint('[${_wallClock(DateTime.now())}] $message');

String _wallClock(DateTime now) {
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${now.year}-${pad(now.month, 2)}-${pad(now.day, 2)} '
      '${pad(now.hour, 2)}:${pad(now.minute, 2)}:${pad(now.second, 2)}.${pad(now.millisecond, 3)}';
}
