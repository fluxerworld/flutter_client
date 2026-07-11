// Hand-written thin client for the server's 13 E2EE REST endpoints, on the
// app's authenticated Dio. Kept out of the generated dart_sdk (which tracks
// upstream and has no E2EE) so the submodule stays pristine — same isolation
// web/RN use. Request/response shapes mirror packages/schema E2EESchemas.tsx.
import 'package:dio/dio.dart';

/// A device's published public bundle (from list / register).
class E2eeDeviceInfo {
  const E2eeDeviceInfo({
    required this.deviceId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPrekey,
    this.deviceName,
    this.oneTimePrekeyCount,
  });

  final String deviceId;
  final String identityKey;
  final int registrationId;
  final E2eeSignedPrekey signedPrekey;
  final String? deviceName;
  final int? oneTimePrekeyCount;

  factory E2eeDeviceInfo.fromJson(Map<String, dynamic> j) => E2eeDeviceInfo(
        deviceId: j['device_id'] as String,
        identityKey: j['identity_key'] as String,
        registrationId: (j['registration_id'] as num).toInt(),
        signedPrekey:
            E2eeSignedPrekey.fromJson((j['signed_prekey'] as Map).cast()),
        deviceName: j['device_name'] as String?,
        oneTimePrekeyCount: (j['one_time_prekey_count'] as num?)?.toInt(),
      );
}

/// A claimed prekey bundle for one recipient device — enough to start an
/// outbound Olm (X3DH) session. `oneTimePrekey` is null if the device is out.
class E2eePrekeyBundle {
  const E2eePrekeyBundle({
    required this.deviceId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPrekey,
    this.oneTimePrekey,
  });

  final String deviceId;
  final String identityKey;
  final int registrationId;
  final E2eeSignedPrekey signedPrekey;
  final E2eeOneTimePrekey? oneTimePrekey;

  factory E2eePrekeyBundle.fromJson(Map<String, dynamic> j) => E2eePrekeyBundle(
        deviceId: j['device_id'] as String,
        identityKey: j['identity_key'] as String,
        registrationId: (j['registration_id'] as num).toInt(),
        signedPrekey:
            E2eeSignedPrekey.fromJson((j['signed_prekey'] as Map).cast()),
        oneTimePrekey: j['one_time_prekey'] == null
            ? null
            : E2eeOneTimePrekey.fromJson((j['one_time_prekey'] as Map).cast()),
      );
}

class E2eeSignedPrekey {
  const E2eeSignedPrekey({
    required this.keyId,
    required this.publicKey,
    required this.signature,
  });

  final int keyId;
  final String publicKey;
  final String signature;

  factory E2eeSignedPrekey.fromJson(Map<String, dynamic> j) => E2eeSignedPrekey(
        keyId: (j['id'] as num).toInt(),
        publicKey: j['public_key'] as String,
        signature: j['signature'] as String,
      );

  // Wire field is `id` (server SignedPrekeyPayload), not `key_id` — must match
  // the web/RN clients and the server zod schema exactly.
  Map<String, Object?> toJson() =>
      {'id': keyId, 'public_key': publicKey, 'signature': signature};
}

class E2eeOneTimePrekey {
  const E2eeOneTimePrekey({required this.keyId, required this.publicKey});

  final int keyId;
  final String publicKey;

  factory E2eeOneTimePrekey.fromJson(Map<String, dynamic> j) =>
      E2eeOneTimePrekey(
        keyId: (j['id'] as num).toInt(),
        publicKey: j['public_key'] as String,
      );

  // Wire field is `id` (server OneTimePrekeyPayload), not `key_id`.
  Map<String, Object?> toJson() => {'id': keyId, 'public_key': publicKey};
}

/// One recipient-device Olm blob carrying a Megolm session key (distribute).
class E2eeGroupSessionBlobOut {
  const E2eeGroupSessionBlobOut({
    required this.recipientUserId,
    required this.recipientDeviceId,
    required this.olmMessageType,
    required this.olmCiphertext,
  });

  final String recipientUserId;
  final String recipientDeviceId;
  final int olmMessageType;
  final String olmCiphertext;

  Map<String, Object?> toJson() => {
        'recipient_user_id': recipientUserId,
        'recipient_device_id': recipientDeviceId,
        'olm_message_type': olmMessageType,
        'olm_ciphertext': olmCiphertext,
      };
}

/// A pending group-session blob addressed to us (list).
class E2eeGroupSessionBlobIn {
  const E2eeGroupSessionBlobIn({
    required this.sessionId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.senderIdentityKey,
    required this.olmMessageType,
    required this.olmCiphertext,
  });

  final String sessionId;
  final String senderUserId;
  final String senderDeviceId;
  final String recipientDeviceId;
  final String senderIdentityKey;
  final int olmMessageType;
  final String olmCiphertext;

  factory E2eeGroupSessionBlobIn.fromJson(Map<String, dynamic> j) =>
      E2eeGroupSessionBlobIn(
        sessionId: j['session_id'] as String,
        senderUserId: j['sender_user_id'] as String,
        senderDeviceId: j['sender_device_id'] as String,
        recipientDeviceId: j['recipient_device_id'] as String,
        senderIdentityKey: j['sender_identity_key'] as String,
        olmMessageType: (j['olm_message_type'] as num).toInt(),
        olmCiphertext: j['olm_ciphertext'] as String,
      );
}

class E2eeApi {
  E2eeApi(this._dio);

  final Dio _dio;

  // ── Own device + keys ─────────────────────────────────────────────────────

  /// Register this device's identity, signed prekey and one-time prekeys.
  Future<E2eeDeviceInfo> registerDevice({
    required String deviceId,
    required String identityKey,
    required int registrationId,
    required E2eeSignedPrekey signedPrekey,
    required List<E2eeOneTimePrekey> oneTimePrekeys,
    String? deviceName,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/users/@me/e2ee/devices',
      data: {
        'device_id': deviceId,
        'device_name': ?deviceName,
        'identity_key': identityKey,
        'registration_id': registrationId,
        'signed_prekey': signedPrekey.toJson(),
        'one_time_prekeys': oneTimePrekeys.map((k) => k.toJson()).toList(),
      },
    );
    return E2eeDeviceInfo.fromJson(res.data!);
  }

  /// Our own registered devices (used to detect whether our device is gone
  /// server-side before ever re-registering).
  Future<List<E2eeDeviceInfo>> listOwnDevices() async {
    final res = await _dio.get<List<dynamic>>('/users/@me/e2ee/devices');
    return (res.data ?? const [])
        .map((e) => E2eeDeviceInfo.fromJson((e as Map).cast()))
        .toList();
  }

  Future<void> deleteDevice(String deviceId) =>
      _dio.delete<void>('/users/@me/e2ee/devices/${Uri.encodeComponent(deviceId)}');

  Future<void> rotateSignedPrekey(
    String deviceId,
    E2eeSignedPrekey signedPrekey,
  ) =>
      _dio.put<void>(
        '/users/@me/e2ee/devices/${Uri.encodeComponent(deviceId)}/signed-prekey',
        data: {'signed_prekey': signedPrekey.toJson()},
      );

  Future<int> topUpOneTimePrekeys(
    String deviceId,
    List<E2eeOneTimePrekey> oneTimePrekeys,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/users/@me/e2ee/devices/${Uri.encodeComponent(deviceId)}/one-time-prekeys',
      data: {'one_time_prekeys': oneTimePrekeys.map((k) => k.toJson()).toList()},
    );
    // Server responds {added, total_unclaimed}; the post-top-up unclaimed count
    // is what the replenish loop compares against the threshold.
    return (res.data?['total_unclaimed'] as num?)?.toInt() ?? 0;
  }

  // ── Peer keys ─────────────────────────────────────────────────────────────

  /// A peer's published devices (identity + signed prekey, no one-time keys) —
  /// used for the identity-key rotation check.
  Future<List<E2eeDeviceInfo>> listPublicDevices(String userId) async {
    final res = await _dio.get<List<dynamic>>(
      '/users/${Uri.encodeComponent(userId)}/e2ee/devices',
    );
    return (res.data ?? const [])
        .map((e) => E2eeDeviceInfo.fromJson((e as Map).cast()))
        .toList();
  }

  /// Claim one prekey bundle per device for a recipient user, consuming a
  /// one-time key on each. Used to start outbound Olm sessions.
  Future<List<E2eePrekeyBundle>> claimPrekeyBundles(String userId) async {
    final res = await _dio.post<List<dynamic>>(
      '/users/${Uri.encodeComponent(userId)}/e2ee/keys/claim',
    );
    return (res.data ?? const [])
        .map((e) => E2eePrekeyBundle.fromJson((e as Map).cast()))
        .toList();
  }

  // ── Backup (Phase 3) ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getBackup() async {
    final res = await _dio.get<Map<String, dynamic>>('/users/@me/e2ee/backup');
    return res.data;
  }

  Future<void> uploadBackup(Map<String, Object?> blob) =>
      _dio.put<void>('/users/@me/e2ee/backup', data: blob);

  Future<void> deleteBackup() => _dio.delete<void>('/users/@me/e2ee/backup');

  // ── Group sessions (Phase 2) ──────────────────────────────────────────────

  /// Distribute a Megolm session key to recipient devices, each blob Olm-wrapped.
  Future<void> distributeGroupSession({
    required String channelId,
    required String sessionId,
    required String senderDeviceId,
    required String senderIdentityKey,
    required List<E2eeGroupSessionBlobOut> recipientBlobs,
  }) =>
      _dio.post<void>(
        '/channels/${Uri.encodeComponent(channelId)}/e2ee/group-sessions',
        data: {
          'session_id': sessionId,
          'sender_device_id': senderDeviceId,
          'sender_identity_key': senderIdentityKey,
          'recipient_blobs': recipientBlobs.map((b) => b.toJson()).toList(),
        },
      );

  /// Pending group-session blobs addressed to us on a channel.
  Future<List<E2eeGroupSessionBlobIn>> listGroupSessions(String channelId) async {
    final res = await _dio.get<List<dynamic>>(
      '/channels/${Uri.encodeComponent(channelId)}/e2ee/group-sessions',
    );
    return (res.data ?? const [])
        .map((e) => E2eeGroupSessionBlobIn.fromJson((e as Map).cast()))
        .toList();
  }

  /// Acknowledge (delete) a consumed blob. session_id is base64 (may contain
  /// '/' and '+'), so every path segment is component-encoded.
  Future<void> ackGroupSessionBlob({
    required String channelId,
    required String sessionId,
    required String recipientDeviceId,
    required String senderDeviceId,
  }) =>
      _dio.delete<void>(
        '/channels/${Uri.encodeComponent(channelId)}/e2ee/group-sessions'
        '/${Uri.encodeComponent(sessionId)}'
        '/${Uri.encodeComponent(recipientDeviceId)}'
        '/${Uri.encodeComponent(senderDeviceId)}',
      );
}
