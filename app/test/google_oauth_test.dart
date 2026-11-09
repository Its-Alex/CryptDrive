import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptdrive/src/core/google_oauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final redirect = Uri.parse('https://drive.example.com/oauth_callback.html');
  GoogleBrowserOAuth newFlow() =>
      GoogleBrowserOAuth(clientId: 'id.apps', clientSecret: 'secret', redirectUri: redirect, random: Random(1));

  test('authorization URL asks for offline drive access with PKCE', () {
    final flow = newFlow();
    final query = flow.authorizationUrl.queryParameters;
    expect(flow.authorizationUrl.host, 'accounts.google.com');
    expect(query['scope'], 'https://www.googleapis.com/auth/drive');
    expect(query['access_type'], 'offline');
    expect(query['redirect_uri'], redirect.toString());
    expect(query['state'], flow.state);
    final challenge = base64Url.encode(sha256.convert(utf8.encode(flow.verifier)).bytes).replaceAll('=', '');
    expect(query['code_challenge'], challenge);
    expect(query['code_challenge_method'], 'S256');
  });

  test('exchange posts the code with the verifier and returns an rclone token', () async {
    final flow = newFlow();
    late Map<String, String> sent;
    final client = MockClient((request) async {
      sent = Uri.splitQueryString(request.body);
      return http.Response(
        jsonEncode({'access_token': 'ya29.a', 'refresh_token': '1//r', 'expires_in': 3599, 'token_type': 'Bearer'}),
        200,
      );
    });
    final token = jsonDecode(await flow.exchange({'code': 'c0de', 'state': flow.state}, client: client)) as Map;
    expect(sent['code'], 'c0de');
    expect(sent['code_verifier'], flow.verifier);
    expect(sent['redirect_uri'], redirect.toString());
    expect(sent['client_secret'], 'secret');
    expect(token['refresh_token'], '1//r');
    expect(DateTime.parse(token['expiry'] as String).isAfter(DateTime.now()), isTrue);
  });

  test('exchange rejects a mismatched state or a Google error', () async {
    final flow = newFlow();
    final client = MockClient((_) async => fail('no request expected'));
    await expectLater(
      flow.exchange({'code': 'c', 'state': 'other'}, client: client),
      throwsA(isA<GoogleOAuthException>()),
    );
    await expectLater(flow.exchange({'error': 'access_denied'}, client: client), throwsA(isA<GoogleOAuthException>()));
  });
}
