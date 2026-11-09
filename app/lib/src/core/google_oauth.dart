import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Google's authorization-code flow with PKCE, run from the browser.
///
/// Needs a "Web application" OAuth client whose authorized JavaScript origin is
/// the app's origin and whose redirect URI is [redirectUri].
class GoogleBrowserOAuth {
  GoogleBrowserOAuth({required this.clientId, required this.clientSecret, required this.redirectUri, Random? random})
    : _random = random ?? Random.secure() {
    verifier = _randomString(64);
    state = _randomString(32);
  }

  static const driveScope = 'https://www.googleapis.com/auth/drive';

  final String clientId;
  final String clientSecret;
  final Uri redirectUri;
  final Random _random;
  late final String verifier;
  late final String state;

  String _randomString(int length) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(length, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
  }

  Uri get authorizationUrl => Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
    'client_id': clientId,
    'redirect_uri': redirectUri.toString(),
    'response_type': 'code',
    'scope': driveScope,
    // A refresh token is only issued with offline access, and only on the consent screen.
    'access_type': 'offline',
    'prompt': 'consent',
    'state': state,
    'code_challenge': base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', ''),
    'code_challenge_method': 'S256',
  });

  /// Turns Google's redirect parameters into an rclone token (oauth2.Token JSON).
  Future<String> exchange(Map<String, String> redirectParameters, {http.Client? client}) async {
    final error = redirectParameters['error'];
    if (error != null) throw GoogleOAuthException('Google refused the sign-in: $error');
    if (redirectParameters['state'] != state) throw GoogleOAuthException('Sign-in state mismatch: try again.');
    final code = redirectParameters['code'];
    if (code == null) throw GoogleOAuthException('Google returned no authorization code.');

    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': code,
          'code_verifier': verifier,
          'grant_type': 'authorization_code',
          'redirect_uri': redirectUri.toString(),
        },
      );
      final reply = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw GoogleOAuthException('Token exchange failed: ${reply['error_description'] ?? reply['error']}');
      }
      return rcloneToken(reply, now: DateTime.now());
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static String rcloneToken(Map<String, dynamic> reply, {required DateTime now}) {
    final expiresIn = (reply['expires_in'] as num?)?.toInt() ?? 3600;
    return jsonEncode({
      'access_token': reply['access_token'],
      'token_type': reply['token_type'] ?? 'Bearer',
      'refresh_token': reply['refresh_token'],
      'expiry': now.toUtc().add(Duration(seconds: expiresIn)).toIso8601String(),
    });
  }
}

class GoogleOAuthException implements Exception {
  GoogleOAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
