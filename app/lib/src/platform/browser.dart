import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../core/app_store.dart';

/// localStorage: survives reloads, stays in this browser.
class BrowserAppStore implements AppStore {
  static const _prefix = 'cryptdrive.';

  @override
  Future<String?> read(String key) async => web.window.localStorage.getItem('$_prefix$key');

  @override
  Future<void> write(String key, String value) async => web.window.localStorage.setItem('$_prefix$key', value);

  @override
  Future<void> delete(String key) async => web.window.localStorage.removeItem('$_prefix$key');
}

AppStore browserAppStore() => BrowserAppStore();

void reloadPage() => web.window.location.reload();

const _sessionPasswordKey = 'cryptdrive.unlock';

/// sessionStorage: kept across reloads of this tab, gone when the tab closes.
String? readSessionPassword() => web.window.sessionStorage.getItem(_sessionPasswordKey);

void writeSessionPassword(String? password) {
  if (password == null) {
    web.window.sessionStorage.removeItem(_sessionPasswordKey);
  } else {
    web.window.sessionStorage.setItem(_sessionPasswordKey, password);
  }
}

/// Hands decrypted bytes to the browser: opens them in a new tab, or downloads them.
void deliverFile(String name, List<Uint8List> parts, {String? mimeType, bool openInNewTab = false}) {
  final blob = web.Blob(
    [for (final part in parts) part.toJS].toJS,
    web.BlobPropertyBag(type: mimeType ?? 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  // A new tab opened long after the click can be blocked as a popup: fall back to a download.
  if (!openInNewTab || web.window.open(url, '_blank') == null) {
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = name;
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
  }
  // Long enough for the browser to start reading the blob; the URL would otherwise pin the bytes in memory.
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
}

/// Opens [authUrl] in a popup and returns the query parameters Google redirects
/// to web/oauth_callback.html with.
Future<Map<String, String>> runOAuthPopup(Uri authUrl) {
  final result = Completer<Map<String, String>>();
  final popup = web.window.open(authUrl.toString(), 'cryptdrive-oauth', 'popup,width=520,height=680');
  if (popup == null) {
    return Future.error(StateError('The browser blocked the sign-in popup: allow popups for this site.'));
  }

  late final JSFunction listener;
  Timer? closedWatch;
  void finish() {
    web.window.removeEventListener('message', listener);
    closedWatch?.cancel();
  }

  listener = ((web.MessageEvent event) {
    if (event.origin != web.window.location.origin) return;
    final data = event.data;
    if (data == null || !data.isA<JSObject>()) return;
    final search = (data as JSObject).getProperty<JSString?>('cryptdriveOAuth'.toJS)?.toDart;
    if (search == null) return;
    finish();
    result.complete(Uri.parse('https://callback$search').queryParameters);
  }).toJS;
  web.window.addEventListener('message', listener);
  closedWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (popup.closed && !result.isCompleted) {
      finish();
      result.completeError(StateError('The sign-in window was closed.'));
    }
  });
  return result.future;
}
