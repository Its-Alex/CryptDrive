import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TransferKind { upload, decrypt }

/// A running upload or decryption, shown inline on its row.
class Transfer {
  const Transfer({required this.kind, required this.path, this.fraction});

  final TransferKind kind;

  /// Vault path of the file: the destination of an upload, the source of a decryption.
  final String path;
  final double? fraction;

  String get name => path.split('/').last;

  String get directory {
    final slash = path.lastIndexOf('/');
    return slash == -1 ? '' : path.substring(0, slash);
  }

  Transfer withFraction(double? value) => Transfer(kind: kind, path: path, fraction: value);
}

class Transfers extends Notifier<Map<String, Transfer>> {
  @override
  Map<String, Transfer> build() => const {};

  void start(TransferKind kind, String path) => state = {...state, path: Transfer(kind: kind, path: path)};

  void progress(String path, double? fraction) {
    final transfer = state[path];
    if (transfer != null) state = {...state, path: transfer.withFraction(fraction)};
  }

  void finish(String path) => state = Map.of(state)..remove(path);
}

final transfersProvider = NotifierProvider<Transfers, Map<String, Transfer>>(Transfers.new);
