import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/vault_service.dart';
import '../state/transfers.dart';
import 'theme.dart';

/// Decrypted image thumbnails, kept in memory only and loaded a few at a time.
class ThumbnailCache {
  ThumbnailCache._();

  static final instance = ThumbnailCache._();
  static const _capacity = 120;
  static const _parallelLoads = 3;

  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List?>>{};
  final _queue = Queue<Completer<void>>();
  int _running = 0;

  static bool supports(VaultEntry entry) =>
      !entry.isDir &&
      (entry.mimeType?.startsWith('image/') ?? false) &&
      entry.size > 0 &&
      entry.size <= VaultService.previewMaxBytes;

  String _key(VaultEntry entry) => '${entry.path}@${entry.modTime?.millisecondsSinceEpoch}:${entry.size}';

  Uint8List? peek(VaultEntry entry) => _cache[_key(entry)];

  Future<Uint8List?> load(VaultService vault, VaultEntry entry) {
    final key = _key(entry);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    return _pending[key] ??= _load(vault, entry, key).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<Uint8List?> _load(VaultService vault, VaultEntry entry, String key) async {
    if (_running >= _parallelLoads) {
      final turn = Completer<void>();
      _queue.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final bytes = await vault.readHead(entry);
      _cache[key] = bytes;
      if (_cache.length > _capacity) _cache.remove(_cache.keys.first);
      return bytes;
    } catch (_) {
      return null;
    } finally {
      _running--;
      if (_queue.isNotEmpty) _queue.removeFirst().complete();
    }
  }
}

class EntryIcon extends StatefulWidget {
  const EntryIcon({super.key, required this.entry, required this.vault, this.size = 40});

  final VaultEntry entry;
  final VaultService vault;
  final double size;

  @override
  State<EntryIcon> createState() => _EntryIconState();
}

class _EntryIconState extends State<EntryIcon> {
  Uint8List? _thumbnail;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(EntryIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path || oldWidget.entry.modTime != widget.entry.modTime) {
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    if (!ThumbnailCache.supports(widget.entry)) return;
    _thumbnail = ThumbnailCache.instance.peek(widget.entry);
    if (_thumbnail != null) return;
    ThumbnailCache.instance.load(widget.vault, widget.entry).then((bytes) {
      if (mounted && bytes != null) setState(() => _thumbnail = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = fileTypeStyle(scheme, isDir: widget.entry.isDir, mimeType: widget.entry.mimeType);
    final radius = BorderRadius.circular(10);
    final placeholder = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: style.color.withValues(alpha: 0.14), borderRadius: radius),
      child: Icon(style.icon, color: style.color, size: widget.size * 0.55),
    );
    final thumbnail = _thumbnail;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: thumbnail == null
          ? placeholder
          : ClipRRect(
              key: const ValueKey('thumbnail'),
              borderRadius: radius,
              child: Image.memory(
                thumbnail,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: (widget.size * MediaQuery.devicePixelRatioOf(context)).round(),
                errorBuilder: (_, _, _) => placeholder,
              ),
            ),
    );
  }
}

/// A row of the file list: icon or thumbnail, name, details, and inline progress.
class EntryRow extends StatelessWidget {
  const EntryRow({
    super.key,
    required this.entry,
    required this.vault,
    required this.onTap,
    required this.onMenu,
    this.transfer,
    this.busy = false,
    this.subtitleOverride,
  });

  final VaultEntry entry;
  final VaultService vault;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;
  final Transfer? transfer;
  final bool busy;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final running = transfer;
    final subtitle = running != null
        ? '${running.kind == TransferKind.upload ? 'Encrypting and uploading' : 'Decrypting'}…'
              '${running.fraction == null ? '' : ' ${(running.fraction! * 100).round()}%'}'
        : subtitleOverride ?? describeEntry(entry);
    return InkWell(
      onTap: running == null && !busy ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            EntryIcon(entry: entry, vault: vault),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    child: running == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 6, right: 12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(value: running.fraction, minHeight: 3),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(
                key: Key('menu:${entry.path}'),
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onPressed: running == null ? onMenu : null,
              ),
          ],
        ),
      ),
    );
  }
}

/// Grey placeholder rows that pulse while a folder loads.
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key});

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
    );
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 8,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              bar(40, 40),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [bar(140.0 + (index % 3) * 40, 12), const SizedBox(height: 8), bar(90, 10)],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String describeEntry(VaultEntry entry) {
  if (entry.isDir) return 'Folder';
  final parts = [
    if (!entry.isDir && entry.size >= 0) formatBytes(entry.size),
    if (entry.modTime != null) formatDate(entry.modTime!.toLocal()),
  ];
  return parts.join(' · ');
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

String formatDate(DateTime time) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final now = DateTime.now();
  if (time.year == now.year && time.month == now.month && time.day == now.day) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
  final day = '${months[time.month - 1]} ${time.day}';
  return time.year == now.year ? day : '$day, ${time.year}';
}
