import 'package:cryptdrive/src/core/vault_service.dart';
import 'package:cryptdrive/src/state/recent_files.dart';
import 'package:cryptdrive/src/state/transfers.dart';
import 'package:cryptdrive/src/ui/entry_widgets.dart';
import 'package:cryptdrive/src/ui/file_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transfers track progress per vault path until finished', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final transfers = container.read(transfersProvider.notifier);

    transfers.start(TransferKind.upload, 'Photos/beach.jpg');
    transfers.progress('Photos/beach.jpg', 0.5);
    final running = container.read(transfersProvider)['Photos/beach.jpg']!;
    expect((running.directory, running.name, running.fraction), ('Photos', 'beach.jpg', 0.5));

    transfers.finish('Photos/beach.jpg');
    expect(container.read(transfersProvider), isEmpty);
  });

  test('recent files survive a JSON round-trip', () {
    final original = RecentFile(
      entry: VaultEntry(
        path: 'Docs/lease.pdf',
        name: 'lease.pdf',
        isDir: false,
        size: 1234,
        modTime: DateTime.utc(2026, 11, 8),
        mimeType: 'application/pdf',
      ),
      action: RecentAction.opened,
      at: DateTime.utc(2026, 11, 8, 12),
    );
    final copy = RecentFile.fromJson(original.toJson());
    expect(copy.toJson(), original.toJson());
  });

  test('sizes read like a files app', () {
    expect(formatBytes(24), '24 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(3 * 1024 * 1024 + 1), '3.0 MB');
    expect(formatBytes(800 * 1024), '800 KB');
  });

  test('only script-free types open in a browser tab', () {
    VaultEntry file(String mime) =>
        VaultEntry(path: 'f', name: 'f', isDir: false, size: 1, modTime: null, mimeType: mime);
    expect(opensInBrowserTab(file('image/jpeg')), isTrue);
    expect(opensInBrowserTab(file('application/pdf')), isTrue);
    expect(opensInBrowserTab(file('image/svg+xml')), isFalse);
    expect(opensInBrowserTab(file('text/html')), isFalse);
    expect(opensInBrowserTab(file('application/xhtml+xml')), isFalse);
  });
}
