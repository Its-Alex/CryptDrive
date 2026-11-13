import 'dart:io';
import 'dart:typed_data';

import 'package:cryptdrive/src/core/drop_folder_plan.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory scratch;

  setUp(() async => scratch = await Directory.systemTemp.createTemp('cryptdrive-drop-test'));
  tearDown(() => scratch.delete(recursive: true));

  Directory folder(String relative) => Directory(p.join(scratch.path, relative))..createSync(recursive: true);
  File file(String relative, String contents) {
    final target = File(p.join(scratch.path, relative));
    target.parent.createSync(recursive: true);
    return target..writeAsStringSync(contents);
  }

  test('a dropped folder mirrors its tree, empty folders included', () async {
    file('holiday/day1/beach.jpg', 'jpeg');
    file('holiday/notes.txt', 'pack light');
    folder('holiday/day2');

    final plan = await planFolderUpload(folder('holiday'), 'Trips');

    expect(plan.folders.first, 'Trips/holiday');
    expect(plan.folders, unorderedEquals(['Trips/holiday', 'Trips/holiday/day1', 'Trips/holiday/day2']));
    expect(
      plan.files.map((upload) => upload.vaultPath),
      unorderedEquals(['Trips/holiday/notes.txt', 'Trips/holiday/day1/beach.jpg']),
    );
    expect(
      plan.files.every((upload) => File(upload.localPath).existsSync()),
      isTrue,
      reason: 'local paths must be readable while the plan is uploaded',
    );
  });

  test('every folder comes after its parent', () async {
    file('project/lib/src/main.dart', 'void main() {}');
    file('project/README.md', 'readme');

    final plan = await planFolderUpload(folder('project'), '');

    expect(plan.folders, ['project', 'project/lib', 'project/lib/src']);
    for (final upload in plan.files) {
      expect(plan.folders, contains(parent(upload.vaultPath)));
    }
  });

  test('an empty folder still produces a folder to create', () async {
    final plan = await planFolderUpload(folder('Empty'), 'Inbox');

    expect(plan.folders, ['Inbox/Empty']);
    expect(plan.files, isEmpty);
    expect(plan.isEmpty, isFalse);
  });

  test('symlinks are skipped, so a loop cannot hang the walk', () async {
    file('linked/real.txt', 'real');
    Link(p.join(scratch.path, 'linked', 'loop')).createSync(scratch.path);

    final plan = await planFolderUpload(folder('linked'), '');

    expect(plan.files.map((upload) => upload.vaultPath), ['linked/real.txt']);
    expect(plan.folders, ['linked']);
  }, skip: Platform.isWindows);

  test('a folder dropped in a browser keeps its relative paths', () async {
    final dropped = DropItemDirectory('batch', [
      DropItemFile.fromData(Uint8List.fromList([1, 2]), path: 'top.bin', name: 'top.bin'),
      DropItemDirectory('sub', [
        DropItemFile.fromData(Uint8List.fromList([3]), path: 'deep.bin', name: 'deep.bin'),
      ], name: 'sub'),
    ], name: 'batch');

    final uploads = await planDroppedFolderMemory(dropped);

    expect(uploads.map((upload) => upload.path), ['batch/top.bin', 'batch/sub/deep.bin']);
    expect(uploads.map((upload) => upload.bytes.length), [2, 1]);
  });
}

String parent(String vaultPath) {
  final slash = vaultPath.lastIndexOf('/');
  return slash == -1 ? '' : vaultPath.substring(0, slash);
}
