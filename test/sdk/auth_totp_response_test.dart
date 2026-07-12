import 'package:flutter_test/flutter_test.dart';
import 'package:fluxer_dart/export.dart';

// Regression: the login / TOTP-MFA / register endpoints return only
// {token, user_id} (no `user`). AuthTokenWithUserIdResponse.user must be
// optional or fromJson throws on those valid 200 responses — which surfaced as
// "invalid, please refresh the app" on the 2FA screen.
void main() {
  test('parses a token response with NO user field', () {
    final r = AuthTokenWithUserIdResponse.fromJson(
      <String, Object?>{'token': 'tok-abc', 'user_id': '1507'},
    );
    expect(r.token, 'tok-abc');
    expect(r.userId, '1507');
    expect(r.user, isNull);
  });

  test('still parses a response WITH user', () {
    final r = AuthTokenWithUserIdResponse.fromJson(<String, Object?>{
      'token': 't',
      'user_id': '1',
      'user': <String, Object?>{
        'id': '1',
        'username': 'x',
        'discriminator': '0001',
        'avatar': null,
        'flags': 0,
      },
    });
    expect(r.user, isNotNull);
    expect(r.user!.username, 'x');
  });
}
