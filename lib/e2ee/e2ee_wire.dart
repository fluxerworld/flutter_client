// The frozen E2EE wire contract, shared byte-for-byte with the web
// (/opt/fluxer/fluxer_app) and React Native (/home/claudeuser/fluxer-mobile)
// clients and the server. NOTHING in this file may change independently of the
// other two clients — a divergence here silently breaks cross-client decrypt.
//
// Anchor: both other clients use libolm 3.2.15; this client uses vodozemac
// (libolm-compatible). Interop was verified at the crate level before the port.
import 'dart:convert';

/// Bumped only if the envelope grammar itself changes. Current wire is v1.
const int kE2eeWireVersion = 1;

/// Message flag set on encrypted messages. Mirrors `MESSAGE_FLAG_ENCRYPTED`
/// (`1 << 18`) in web/RN and `MessageFlags.ENCRYPTED` server-side.
const int kMessageFlagEncrypted = 1 << 18; // 262144

/// Channel types that carry E2EE. Only 1:1 DMs (Olm) and group DMs (Megolm).
/// Matches web `SUPPORTED_CHANNEL_TYPES` = {DM, GROUP_DM}.
const int kChannelTypeDm = 1;
const int kChannelTypeGroupDm = 3;

bool isEncryptedChannelType(int channelType) =>
    channelType == kChannelTypeDm || channelType == kChannelTypeGroupDm;

/// Olm message types on the wire, matching libolm's `{type, body}`.
/// type 0 = PRE_KEY (X3DH session init); type 1 = normal message.
const int kOlmMessageTypePreKey = 0;
const int kOlmMessageTypeNormal = 1;

/// One recipient device's ciphertext slot inside an Olm (1:1) payload.
/// `body` is the base64 libolm/vodozemac Olm message.
class OlmCiphertext {
  const OlmCiphertext({required this.type, required this.body});

  final int type;
  final String body;

  factory OlmCiphertext.fromJson(Map<String, Object?> json) => OlmCiphertext(
        type: (json['type']! as num).toInt(),
        body: json['body']! as String,
      );

  Map<String, Object?> toJson() => {'type': type, 'body': body};
}

/// A `ciphertexts` map key. Each recipient DEVICE gets its own slot; the key is
/// `"<userId>:<deviceId>"`. Senders fan out one Olm ciphertext per device.
String olmSlotKey(String userId, String deviceId) => '$userId:$deviceId';

/// The two shapes a message's `encrypted_payload` can take. Modelled loosely
/// (a plain map on the wire, validated here) — same "loose-at-wire, strict-in-
/// crypto" stance as web/RN, since the server does not enforce the shape.
sealed class EncryptedPayload {
  const EncryptedPayload();

  /// Parse a raw `encrypted_payload` map, or null if it isn't a recognised
  /// E2EE envelope (so callers can fall through to plaintext handling).
  static EncryptedPayload? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final json = raw.cast<String, Object?>();
    final version = json['v'];
    if (version is! num || version.toInt() != kE2eeWireVersion) {
      return null;
    }

    final senderDeviceId = json['sender_device_id'];
    final senderIdentityKey = json['sender_identity_key'];
    if (senderDeviceId is! String || senderIdentityKey is! String) {
      return null;
    }

    if (json['kind'] == 'megolm') {
      final sessionId = json['session_id'];
      final ciphertext = json['ciphertext'];
      if (sessionId is! String || ciphertext is! String) {
        return null;
      }
      return MegolmPayload(
        senderDeviceId: senderDeviceId,
        senderIdentityKey: senderIdentityKey,
        sessionId: sessionId,
        ciphertext: ciphertext,
      );
    }

    final ct = json['ciphertexts'];
    if (ct is! Map) {
      return null;
    }
    final ciphertexts = <String, OlmCiphertext>{};
    for (final entry in ct.entries) {
      final v = entry.value;
      if (entry.key is! String || v is! Map) {
        return null;
      }
      ciphertexts[entry.key! as String] =
          OlmCiphertext.fromJson(v.cast<String, Object?>());
    }
    return OlmPayload(
      senderDeviceId: senderDeviceId,
      senderIdentityKey: senderIdentityKey,
      ciphertexts: ciphertexts,
    );
  }

  Map<String, Object?> toJson();
}

/// 1:1 DM payload: one Olm ciphertext per recipient device.
class OlmPayload extends EncryptedPayload {
  const OlmPayload({
    required this.senderDeviceId,
    required this.senderIdentityKey,
    required this.ciphertexts,
  });

  final String senderDeviceId;
  final String senderIdentityKey;
  final Map<String, OlmCiphertext> ciphertexts;

  @override
  Map<String, Object?> toJson() => {
        'v': kE2eeWireVersion,
        'sender_device_id': senderDeviceId,
        'sender_identity_key': senderIdentityKey,
        'ciphertexts': {
          for (final e in ciphertexts.entries) e.key: e.value.toJson(),
        },
      };
}

/// Group DM payload: a single Megolm ciphertext identified by `session_id`.
class MegolmPayload extends EncryptedPayload {
  const MegolmPayload({
    required this.senderDeviceId,
    required this.senderIdentityKey,
    required this.sessionId,
    required this.ciphertext,
  });

  final String senderDeviceId;
  final String senderIdentityKey;
  final String sessionId;
  final String ciphertext;

  @override
  Map<String, Object?> toJson() => {
        'v': kE2eeWireVersion,
        'kind': 'megolm',
        'sender_device_id': senderDeviceId,
        'sender_identity_key': senderIdentityKey,
        'session_id': sessionId,
        'ciphertext': ciphertext,
      };
}

/// The plaintext sealed inside Olm/Megolm is a v2 JSON envelope so we can carry
/// per-attachment keys alongside the text without changing the outer wire. A
/// v1 sender (raw string) is still read cleanly — detection mirrors web/RN.
class PlaintextEnvelope {
  const PlaintextEnvelope({required this.text, this.attachments = const []});

  final String text;
  final List<Map<String, Object?>> attachments;

  /// Wrap text (+ optional attachment entries) into the v2 envelope string.
  String encode() {
    final env = <String, Object?>{'v': 2, 'text': text};
    if (attachments.isNotEmpty) {
      env['attachments'] = attachments;
    }
    return jsonEncode(env);
  }

  /// Reverse of [encode], with a v1 fallback: anything that isn't a JSON object
  /// with `v == 2` and a string `text` is treated as a raw v1 string. Strict on
  /// purpose so a user literally typing `{"v":2,...}` isn't misparsed.
  factory PlaintextEnvelope.decode(String decrypted) {
    if (decrypted.isEmpty || decrypted.codeUnitAt(0) != 0x7b) {
      return PlaintextEnvelope(text: decrypted);
    }
    try {
      final parsed = jsonDecode(decrypted);
      if (parsed is Map &&
          parsed['v'] == 2 &&
          parsed['text'] is String) {
        final atts = parsed['attachments'];
        return PlaintextEnvelope(
          text: parsed['text'] as String,
          attachments: atts is List
              ? atts
                  .whereType<Map<Object?, Object?>>()
                  .map((e) => e.cast<String, Object?>())
                  .toList()
              : const [],
        );
      }
    } on FormatException {
      // fall through to v1
    }
    return PlaintextEnvelope(text: decrypted);
  }
}

/// Derive a libolm-style one-time-key id int from the server key id + index.
/// Ported from web `hashKeyIdToInt`. Dart ints are 64-bit, so every arithmetic
/// step is truncated to signed 32-bit via [_i32] to reproduce JS `| 0` exactly.
/// Verified byte-identical against the JS implementation.
int hashKeyIdToInt(String matrixId, int index) {
  var h = 0;
  for (var i = 0; i < matrixId.length; i++) {
    h = _i32(h * 31 + matrixId.codeUnitAt(i));
  }
  return _i32(h ^ (index << 16)).abs();
}

/// Ported from web `deriveRegistrationId`. Same 32-bit-truncation discipline.
int deriveRegistrationId(String curveKey, String ed25519Key) {
  var h = 0;
  final combined = '$curveKey:$ed25519Key';
  for (var i = 0; i < combined.length; i++) {
    h = _i32(h * 33 + combined.codeUnitAt(i));
  }
  return h.abs() & 0x7fffffff;
}

/// Truncate to signed 32-bit — the Dart equivalent of JS `x | 0`.
int _i32(int x) => x.toSigned(32);
