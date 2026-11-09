import 'dart:typed_data';

import '../core/app_store.dart';

AppStore browserAppStore() => throw UnsupportedError('browser only');

void reloadPage() => throw UnsupportedError('browser only');

String? readSessionPassword() => throw UnsupportedError('browser only');

void writeSessionPassword(String? password) => throw UnsupportedError('browser only');

void deliverFile(String name, List<Uint8List> parts, {String? mimeType, bool openInNewTab = false}) =>
    throw UnsupportedError('browser only');

Future<Map<String, String>> runOAuthPopup(Uri authUrl) => throw UnsupportedError('browser only');
