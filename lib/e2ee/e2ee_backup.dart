// The E2EE key-backup OUTER ENVELOPE: decrypting a server-stored backup blob
// (produced by the web/RN clients via E2EEBackup.tsx) into a typed payload.
//
// Envelope, byte-compatible with the web writer:
//   PBKDF2-SHA256(passphrase, salt, iterations) -> 256-bit AES key
//   AES-256-GCM(iv, ciphertext‖16-byte tag)     -> UTF-8 JSON payload
// salt is 16 bytes, iv 12 bytes, all fields standard (padded) base64. The GCM
// tag is APPENDED to the ciphertext (WebCrypto layout) — pointycastle's
// GCMBlockCipher consumes that tag-appended form directly, matching the
// attachment path (e2ee_attachments.dart). Proven byte-identical with WebCrypto
// in the ~/e2ee-spike/backup harness.
//
// This module does ONLY the envelope + parse. Importing the pickled crypto into
// the key store lives in e2ee_manager.dart (restoreFromBackup).
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The passphrase produced the wrong AES key, so GCM tag verification failed —
/// i.e. a wrong passphrase (or a corrupted ciphertext). Surface to the UI as
/// "wrong passphrase".
class E2eeBackupWrongPassphrase implements Exception {
  const E2eeBackupWrongPassphrase();
  @override
  String toString() => 'E2eeBackupWrongPassphrase';
}

/// The blob is structurally invalid: unknown algorithm/kdf, un-parseable JSON,
/// or an unsupported payload version. Distinct from a wrong passphrase.
class E2eeBackupCorrupt implements Exception {
  const E2eeBackupCorrupt(this.reason);
  final String reason;
  @override
  String toString() => 'E2eeBackupCorrupt($reason)';
}

/// A libolm-pickled account inside the backup.
class BackupPickledAccount {
  const BackupPickledAccount({
    required this.userId,
    required this.deviceId,
    required this.pickle,
  });
  final String userId;
  final String deviceId;
  final String pickle;
}

/// A libolm-pickled 1:1 Olm session inside the backup.
class BackupPickledSession {
  const BackupPickledSession({
    required this.remoteUserId,
    required this.remoteDeviceId,
    required this.sessionId,
    required this.pickle,
    required this.createdAt,
    required this.lastUsedAt,
  });
  final String remoteUserId;
  final String remoteDeviceId;
  final String sessionId;
  final String pickle;
  final int createdAt; // epoch ms
  final int lastUsedAt; // epoch ms
}

/// A libolm-pickled inbound Megolm session inside the backup.
class BackupPickledInboundGroup {
  const BackupPickledInboundGroup({
    required this.channelId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.sessionId,
    required this.pickle,
    required this.senderIdentityKey,
    required this.createdAt,
  });
  final String channelId;
  final String senderUserId;
  final String senderDeviceId;
  final String sessionId;
  final String pickle;
  final String senderIdentityKey;
  final int createdAt; // epoch ms
}

/// The decrypted, parsed backup payload. Outbound group sessions and
/// verifications are intentionally NOT modelled: outbound Megolm is minted fresh
/// on the restoring device (importing it would resume a sender ratchet that a
/// still-live original device could collide with), and there is no Flutter
/// verifications table yet.
class E2eeBackupPayload {
  const E2eeBackupPayload({
    required this.version,
    required this.pickleKey,
    required this.account,
    required this.sessions,
    required this.inboundGroupSessions,
  });

  final int version; // inner `v`: 1 or 2
  final String? pickleKey; // the libolm pickle key (a string); may be null
  final BackupPickledAccount? account;
  final List<BackupPickledSession> sessions;
  final List<BackupPickledInboundGroup> inboundGroupSessions; // v2 only
}

Uint8List _b64(String s) {
  try {
    return base64Decode(s);
  } on FormatException {
    throw const E2eeBackupCorrupt('bad base64');
  }
}

Uint8List _pbkdf2(String passphrase, Uint8List salt, int iterations) {
  final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return d.process(Uint8List.fromList(utf8.encode(passphrase)));
}

Uint8List _gcmDecrypt(Uint8List key, Uint8List iv, Uint8List ctWithTag) {
  final c = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  final out = Uint8List(c.getOutputSize(ctWithTag.length));
  final n = c.processBytes(ctWithTag, 0, ctWithTag.length, out, 0);
  final total = n + c.doFinal(out, n);
  return total == out.length ? out : Uint8List.sublistView(out, 0, total);
}

/// Decrypt + parse a backup blob. Throws [E2eeBackupWrongPassphrase] on a GCM
/// auth failure (bad passphrase / tampered ciphertext) and [E2eeBackupCorrupt]
/// on any structural problem.
E2eeBackupPayload decryptBackupBlob(
  Map<String, dynamic> blob,
  String passphrase,
) {
  final algorithm = blob['algorithm'];
  final kdf = blob['kdf'];
  if (algorithm != 'AES-GCM' || kdf != 'PBKDF2-SHA256') {
    throw E2eeBackupCorrupt('unknown algorithm/kdf: $algorithm/$kdf');
  }
  final iterations = blob['iterations'];
  final saltB64 = blob['salt'];
  final ivB64 = blob['iv'];
  final ciphertextB64 = blob['ciphertext'];
  if (iterations is! int ||
      saltB64 is! String ||
      ivB64 is! String ||
      ciphertextB64 is! String) {
    throw const E2eeBackupCorrupt('missing/invalid envelope fields');
  }

  final salt = _b64(saltB64);
  final iv = _b64(ivB64);
  final ciphertext = _b64(ciphertextB64);
  final key = _pbkdf2(passphrase, salt, iterations);

  final Uint8List plaintextBytes;
  try {
    plaintextBytes = _gcmDecrypt(key, iv, ciphertext);
  } on Object {
    // GCM tag verification failed → wrong passphrase (or tampering).
    throw const E2eeBackupWrongPassphrase();
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(plaintextBytes));
  } on Object {
    throw const E2eeBackupCorrupt('payload is not valid JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const E2eeBackupCorrupt('payload is not an object');
  }
  return _parsePayload(decoded);
}

E2eeBackupPayload _parsePayload(Map<String, dynamic> p) {
  final v = p['v'];
  if (v != 1 && v != 2) {
    throw E2eeBackupCorrupt('unsupported payload version: $v');
  }

  BackupPickledAccount? account;
  final rawAccount = p['account'];
  if (rawAccount is Map<String, dynamic>) {
    account = BackupPickledAccount(
      userId: _str(rawAccount, 'user_id'),
      deviceId: _str(rawAccount, 'device_id'),
      pickle: _str(rawAccount, 'pickle'),
    );
  }

  final sessions = <BackupPickledSession>[];
  for (final e in _list(p['sessions'])) {
    if (e is! Map<String, dynamic>) {
      continue;
    }
    sessions.add(BackupPickledSession(
      remoteUserId: _str(e, 'remote_user_id'),
      remoteDeviceId: _str(e, 'remote_device_id'),
      sessionId: _str(e, 'session_id'),
      pickle: _str(e, 'pickle'),
      createdAt: _int(e, 'created_at'),
      lastUsedAt: _int(e, 'last_used_at'),
    ));
  }

  final inbound = <BackupPickledInboundGroup>[];
  if (v == 2) {
    for (final e in _list(p['inbound_group_sessions'])) {
      if (e is! Map<String, dynamic>) {
        continue;
      }
      inbound.add(BackupPickledInboundGroup(
        channelId: _str(e, 'channel_id'),
        senderUserId: _str(e, 'sender_user_id'),
        senderDeviceId: _str(e, 'sender_device_id'),
        sessionId: _str(e, 'session_id'),
        pickle: _str(e, 'pickle'),
        senderIdentityKey: _str(e, 'sender_identity_key'),
        createdAt: _int(e, 'created_at'),
      ));
    }
  }

  final pickleKey = p['pickle_key'];
  return E2eeBackupPayload(
    version: v as int,
    pickleKey: pickleKey is String ? pickleKey : null,
    account: account,
    sessions: sessions,
    inboundGroupSessions: inbound,
  );
}

List<dynamic> _list(Object? v) => v is List ? v : const <dynamic>[];

String _str(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! String) {
    throw E2eeBackupCorrupt('field "$key" is not a string');
  }
  return v;
}

int _int(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is int) {
    return v;
  }
  if (v is num) {
    return v.toInt();
  }
  throw E2eeBackupCorrupt('field "$key" is not a number');
}
