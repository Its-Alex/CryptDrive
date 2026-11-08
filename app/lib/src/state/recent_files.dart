import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/vault_service.dart';
import 'providers.dart';

enum RecentAction { opened, uploaded }

class RecentFile {
  const RecentFile({required this.entry, required this.action, required this.at});

  factory RecentFile.fromJson(Map<String, dynamic> json) => RecentFile(
    entry: VaultEntry(
      path: json['path'] as String,
      name: json['name'] as String,
      isDir: false,
      size: json['size'] as int,
      modTime: DateTime.tryParse(json['modTime'] as String? ?? ''),
      mimeType: json['mimeType'] as String?,
    ),
    action: RecentAction.values.byName(json['action'] as String),
    at: DateTime.parse(json['at'] as String),
  );

  final VaultEntry entry;
  final RecentAction action;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'path': entry.path,
    'name': entry.name,
    'size': entry.size,
    'modTime': entry.modTime?.toIso8601String(),
    'mimeType': entry.mimeType,
    'action': action.name,
    'at': at.toIso8601String(),
  };
}

/// Files recently opened or uploaded on this device, newest first.
class RecentFiles extends AsyncNotifier<List<RecentFile>> {
  static const _limit = 50;
  late File _store;

  @override
  Future<List<RecentFile>> build() async {
    final environment = await ref.watch(environmentProvider.future);
    _store = File(p.join(environment.supportDir.path, 'recent-files.json'));
    if (!await _store.exists()) return [];
    try {
      final decoded = jsonDecode(await _store.readAsString()) as List;
      return decoded.map((item) => RecentFile.fromJson(item as Map<String, dynamic>)).toList();
    } on FormatException {
      return [];
    }
  }

  Future<void> record(VaultEntry entry, RecentAction action) async {
    final current = await future;
    final updated = [
      RecentFile(entry: entry, action: action, at: DateTime.now()),
      ...current.where((item) => item.entry.path != entry.path),
    ].take(_limit).toList();
    state = AsyncData(updated);
    await _save(updated);
  }

  /// Keeps the list in step with renames, moves and deletions done in the browser.
  Future<void> forget(String pathPrefix) async {
    final current = await future;
    final updated = current
        .where((item) => item.entry.path != pathPrefix && !item.entry.path.startsWith('$pathPrefix/'))
        .toList();
    if (updated.length == current.length) return;
    state = AsyncData(updated);
    await _save(updated);
  }

  Future<void> _save(List<RecentFile> items) async {
    await _store.parent.create(recursive: true);
    await _store.writeAsString(jsonEncode(items.map((item) => item.toJson()).toList()));
  }
}

final recentFilesProvider = AsyncNotifierProvider<RecentFiles, List<RecentFile>>(RecentFiles.new);
