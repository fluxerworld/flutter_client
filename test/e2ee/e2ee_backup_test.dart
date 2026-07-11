import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxer_app/e2ee/e2ee_backup.dart';

// A real web-format E2EE backup blob (E2EEBackup.tsx envelope: PBKDF2-SHA256
// 600k + AES-256-GCM) produced with @matrix-org/olm 3.2.15 in the interop
// harness. Its v2 payload holds 1 account, 1 Olm session, 1 inbound Megolm
// session and 1 verification, so decrypting it exercises the exact production
// decrypt + parse path against a genuine cross-client blob.
const String _passphrase = 'correct horse battery staple';
const String _blobJson =
    '''{"version":2,"algorithm":"AES-GCM","kdf":"PBKDF2-SHA256","salt":"G9aBHS0qBWWliovAi9nkeA==","iterations":600000,"iv":"eMli7rrI7vCLBvmQ","ciphertext":"TKXhewRqaUKZVO3SreJ1Yj9QtkR+cYbNE7wyFxGJB/W4+6JxLNZJl5S392gwnjfWu4ZTYqF3oxRyTkd0jprVQ3JjrZ4qxCjBQtG6EDmqLArwN9vZXyWn0ie6j4AT8qK/MBElxFpgQ+rsyx+sA9aY2TSYwQXKbG3B8LTJXxAvI2PysPA8OSUtAM9CjO1DVfjAWU6w/0N7ghhdlprvl/FBtZdkChWsXp3ZXETpxxYYrDZJ/fOjdUzltJqncjIW932jZOzfctV7blD03myXwKH3mQE1tPxcoZEUNUlqWQa+/Z5NIB94X/EuJuEgBVDVVn1XZQrU13xAOoAzYFjn5CRKCb+82HzmIF9KeApVk0KCu5DqT8oubEK6F1btzbGXGFMyZ2gK0zLC6zvmP9Az94aAEuD4Mer0t4iR94m+qJHUnv+yso35ArDG4pweMYNzFq/g8bw9iwvXECpwN4r1gfc3dC3o8yFn9p3APOTzRFRC9jSgYCh7vdKKtZI2OBtoiX5lnxvXEHPyTQPcX+UWj9LkfPlUfADLo66RyxYRNY+F6+FVScV+SR2aqopVafCHNnDX+oGxjKwp4P/S/poxYxwK1OTh4lttpzv5PIHgw52zlR3L4Mn4DlsLTWZwE7w3smv+Gf3NhhfyWf6rgPk64KIE73vbuDYIzdoncOZrSMLwEw4wieQ7aQ5QtI61+2zqPLmP4noLKMVzCXL45PT37kfKKCT64Kf0V9UR9uiF5mfyKwYkHxjpLcCL0t2OKGmC4j85Ws3VyMoHOqjMhEMlMhZcbRUG2PPl6chDR22sonGDhqkXE/vFkVAGjzyTKy5uyZRUcOm/N+AE32JjJ8BqYZRSVkQ0qctz4sRDkW7a7RzeBWJEHxEaGx1PA+Ndm/zZwDssZbT7U61gYlrVxzg0M12Axj5YKkTTn7IF76gzbuM+3VgUvpJTg0WBSLtGYIXgYJpoZhnyYKKmydmeJXjr79+oZEFUlGiYNAFuSi5WxmLZ/Hl+g3uK2fhgn8GI+gP5zqkHxMs/PJ75iXMfCNPRAjCsYTq5HRfREoeJIFkcCnA7viWNJIcEdyfeSh3tEvvfXJOY3IQwbGFeQnLj2DfmmSx7z2qkEWYM8TJ7GJ3Xzgat91S51kYSG+ItEVQ5eJIb8YfR2NwkuFd9kZnK4jup8xvKqK5COOHwRwh43BHZ5Z+NydeoQSL0bp65gDj/RlECnAPKFb8+APfnH2K1v1guGX2Ezk7C+9hUQrrzwu0taxe+rjjZsIqVv2GdPjqenxF3B5dNYOukJlC1wFFjhlNwYw31IW0U5SLxLBsSdDXVVlo9cQpgsNzGiuAK1HDVs2fTwNUBT7O2+yAI+VsNi/NefTeajEuykKk82s4UyJ6GsLlaPsRhRXkYhm8AQ093rrO27NLY3AdKqS9K/dCPtxKorh80LwLAlTX1Lai/S5KAyM15oDYVUYGiPHPpYEl9WOtvWGcPaRFx6GYx32koMqJws0FYwJWGWSeSe8wBnVHEkGC+izO/EHtkgF5wtystuEQz7krZxaToLX9OsE9A141AFx6T2hNqB6uO5H6BpxyCv4rsCUj48+5GMtMBig6qZxMfH9M9U+tWXbfpZaqrxpKkQhwns0qvAuHQJztAf+Bq4rXrD/dIwjFBbRGts7540OUMHT0CUHE7qE9KmZmE9B7K3BrXnjAwxu8SjOkK0sagHyjPbyVAQ64b77786u86SzNwBXwXa5jLzS8mQyeOWlmxucD+QvP9L0HedfoV73flRjiIqKY05AnO30zqhvVlSoyDgk7EeFW/e5mEK6l3P40/4FwRZxjZyousThar7iNwdgcjjGdeJiZuBw+L0GnRfDtAKfkI34qG3aJl4YuJvf1KZkqCUo2+lJMO0f2YSwEc+QW0sVaHR+iQag0rnPGsZzVOvpTq1iXJwymhhxRq45HYvl5eghqAYapEhIyHGJQlBnW2d7Pn+/GXKNQfQ+8FRzSLz9KY1mQ0rHEtom+0ZQgtdqSAdpRqCLGkk90c8jtitERgxM3cX1BI0KsHBimf9lE5+rBoFq7Gk+gBcAKVSMtYJie0Ky68fRol9O+JDhLH+C9rXsXlLNjgwb+g8ui0oNkn8TMNgivOx3XlpJkZW9eBRVXnbnarIu1iSsXnneYty7L1LQwnrje3oRgvaCMRmRB685RvQytuqYPYbdvh8i7ip0m7JgcUu0/Bj+paArcWPWws95JszhYXmxLpAmf5/Q6MfKCj1dUb3RLKOMDMwpUYIDvjYgK4dqsNkqX74cSTm7OeDEIqSd5XHmn0ESQGAEyVSJzX4my795Wq7Z3W82tEwgadxOzSvhykF1j71l9wsinve0NiEYhlA2v/LfrHHdOoTpORP9JZUA1ML8DxhzitqRLka5V5GwGdeYTgB3oL/8WTlDukrqF/IfxOmZ84lHbksW8UR0t7MFiH0RFyOKnNwA4Lzjwq7Lqz3+7rxhgN+gfIdVTK9jOSkC5gWZn4uaBAiQrSyvR2hP4OyX2BboeBxoHNeOZj/1tV8Vti1psz1DNrfc2ZgQpxVpLC"}''';

Map<String, dynamic> _blob() =>
    (jsonDecode(_blobJson) as Map).cast<String, dynamic>();

void main() {
  group('decryptBackupBlob', () {
    test('decrypts a real web-format v2 backup and parses every artifact', () {
      final payload = decryptBackupBlob(_blob(), _passphrase);
      expect(payload.version, 2);
      expect(payload.pickleKey, isNotNull);
      expect(payload.account, isNotNull);
      expect(payload.account!.userId, '1234567890');
      expect(payload.account!.deviceId, 'DEVICEWEB01');
      expect(payload.sessions, hasLength(1));
      expect(payload.sessions.first.remoteUserId, '9999');
      expect(payload.sessions.first.remoteDeviceId, 'ALICEDEV1');
      expect(payload.inboundGroupSessions, hasLength(1));
      expect(payload.inboundGroupSessions.first.channelId,
          '1507277470612189184');
      expect(payload.verifications, hasLength(1));
      expect(payload.verifications.first.remoteDeviceId, 'ALICEDEV1');
      expect(payload.verifications.first.source, 'manual');
    });

    test('wrong passphrase throws E2eeBackupWrongPassphrase', () {
      expect(
        () => decryptBackupBlob(_blob(), 'not the passphrase'),
        throwsA(isA<E2eeBackupWrongPassphrase>()),
      );
    });

    test('unknown algorithm throws E2eeBackupCorrupt', () {
      final b = _blob()..['algorithm'] = 'AES-CBC';
      expect(() => decryptBackupBlob(b, _passphrase),
          throwsA(isA<E2eeBackupCorrupt>()));
    });

    test('unknown kdf throws E2eeBackupCorrupt', () {
      final b = _blob()..['kdf'] = 'scrypt';
      expect(() => decryptBackupBlob(b, _passphrase),
          throwsA(isA<E2eeBackupCorrupt>()));
    });

    test('non-integer iterations throws E2eeBackupCorrupt', () {
      final b = _blob()..['iterations'] = '600000';
      expect(() => decryptBackupBlob(b, _passphrase),
          throwsA(isA<E2eeBackupCorrupt>()));
    });

    test('invalid base64 salt throws E2eeBackupCorrupt', () {
      final b = _blob()..['salt'] = 'not valid base64 !!!';
      expect(() => decryptBackupBlob(b, _passphrase),
          throwsA(isA<E2eeBackupCorrupt>()));
    });

    test('tampered ciphertext fails the GCM tag', () {
      final b = _blob();
      final ct = base64Decode(b['ciphertext'] as String);
      ct[0] ^= 0xFF;
      b['ciphertext'] = base64Encode(ct);
      expect(() => decryptBackupBlob(b, _passphrase),
          throwsA(isA<E2eeBackupWrongPassphrase>()));
    });
  });
}
