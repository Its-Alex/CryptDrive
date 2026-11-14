import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Closes the on-screen keyboard first: on phones it shrinks the viewport over the target.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> chooseMenuAction(WidgetTester tester, String entryPath, String action) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('menu:$entryPath')));
  await pumpUntilFound(tester, find.text(action));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(action).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> pumpUntilGone(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder to disappear');
}

/// A mouse click on a row selects it, a second click opens or enters it. Touch has
/// no such model: a single tap already opens, so a second tap would hit whatever
/// the list shows after navigating.
Future<void> openEntry(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
    await tester.pump();
    return;
  }
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(finder);
  await tester.pump();
}

/// Ctrl-click, which toggles a row without dropping the rest of the selection.
Future<void> controlClick(WidgetTester tester, Finder finder) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.tap(finder);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Lets the row icon cross-fade finish, so only the current check mark is in the tree.
Future<void> settleCheck(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

/// Sends a key chord the way a desktop user would: modifier down, key, modifier up.
Future<void> pressWithControl(WidgetTester tester, LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key, physicalKey: physical);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> pressWithControlShift(WidgetTester tester, LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key, physicalKey: physical);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> pressWithControlAlt(WidgetTester tester, LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft, physicalKey: PhysicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key, physicalKey: physical);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft, physicalKey: PhysicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: PhysicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> pressWithAlt(WidgetTester tester, LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft, physicalKey: PhysicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key, physicalKey: physical);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft, physicalKey: PhysicalKeyboardKey.altLeft);
  await tester.pump();
}

Future<void> pressWithShift(WidgetTester tester, LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key, physicalKey: physical);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
  await tester.pump();
}

Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
  await tester.sendKeyEvent(key, physicalKey: physical);
  await tester.pump();
}
