// Thin wrapper over vodozemac (libolm-compatible). This layer only exposes the
// crypto primitives — account, Olm sessions, Megolm group sessions, pickling —
// in our own vocabulary. All protocol composition (which key goes where, the
// per-device fan-out, session lookup) lives in e2ee_manager.dart.
//
// vodozemac's Dart binding works in base64 for Olm messages (encrypt returns a
// base64 `ciphertext`; createInboundSession takes `preKeyMessageBase64`), so
// these values drop straight onto our wire `body`/`ciphertext` fields with no
// re-encoding. Outbound Olm sessions default to SessionConfig.version1(), the
// libolm-compatible version verified interoperable in the crate spike.
import 'dart:typed_data';

import 'package:flutter_vodozemac/flutter_vodozemac.dart' as flutter_vodozemac;
// Low-level bindings, imported ONLY to pin Megolm to session version 1. The
// high-level GroupSession()/InboundGroupSession() constructors hardcode
// vodozemac's default MegolmSessionConfig, which is version 2 (full-length MAC)
// — incompatible with the libolm 3.2.15 that web/RN use (version 1, truncated
// MAC), so group DMs would fail to decrypt cross-client. The public API exposes
// no config override, so we drop to the generated bindings (which DO accept a
// config) for the two group-session types. Mirrors the Olm path's version1 pin.
// ignore: implementation_imports
import 'package:vodozemac/src/generated/bindings.dart' as vzb;
import 'package:vodozemac/vodozemac.dart' as vodozemac;

/// The result of decrypting an inbound Olm pre-key message: a fresh session to
/// persist plus the recovered plaintext.
typedef InboundOlmResult = ({E2eeOlmSession session, String plaintext});

/// One-shot initialisation of the native vodozemac library. Must complete
/// before any other call here. Safe to await more than once.
Future<void> initE2eeCrypto() => flutter_vodozemac.init();

/// Wraps a vodozemac Olm account (this device's long-term identity + prekeys).
class E2eeAccount {
  E2eeAccount._(this._account);

  final vodozemac.Account _account;

  /// A brand-new identity. Only for genuine first-run registration — never call
  /// this to "recover" a device whose stored account merely failed to load.
  factory E2eeAccount.create() => E2eeAccount._(vodozemac.Account());

  /// Restore from an encrypted pickle produced by [toPickle].
  factory E2eeAccount.fromPickle(String pickle, Uint8List pickleKey) =>
      E2eeAccount._(vodozemac.Account.fromPickleEncrypted(
        pickle: pickle,
        pickleKey: pickleKey,
      ));

  /// Restore from a libolm-format pickle (e.g. a backup produced by the web/RN
  /// clients). vodozemac reads libolm pickles; the reverse export is not yet
  /// surfaced by the Dart binding.
  factory E2eeAccount.fromLibolmPickle(String pickle, Uint8List pickleKey) =>
      E2eeAccount._(vodozemac.Account.fromOlmPickleEncrypted(
        pickle: pickle,
        pickleKey: pickleKey,
      ));

  /// Curve25519 identity key, base64. This is the device's `identity_key`.
  String get identityKey => _account.curve25519Key.toBase64();

  /// Ed25519 signing key, base64. Used to sign the signed-prekey.
  String get ed25519Key => _account.ed25519Key.toBase64();

  /// Server-side cap on outstanding one-time keys; used to size top-ups.
  int get maxOneTimeKeys => _account.maxNumberOfOneTimeKeys;

  /// Generate [count] new one-time keys (they become visible via [oneTimeKeys]
  /// until [markKeysAsPublished] is called).
  void generateOneTimeKeys(int count) => _account.generateOneTimeKeys(count);

  /// Unpublished one-time keys, keyed by their local key id, values base64.
  Map<String, String> get oneTimeKeys => {
        for (final e in _account.oneTimeKeys.entries) e.key: e.value.toBase64(),
      };

  /// Mark all currently-generated one-time keys as published, so they are not
  /// returned by [oneTimeKeys] again.
  void markKeysAsPublished() => _account.markKeysAsPublished();

  /// Ed25519 signature over [message], base64. Used to sign the signed-prekey.
  String sign(String message) => _account.sign(message).toBase64();

  /// Start an outbound Olm session to a recipient device (X3DH). The first
  /// [E2eeOlmSession.encrypt] on the returned session yields a type-0 PRE_KEY
  /// message.
  E2eeOlmSession createOutboundSession({
    required String theirIdentityKey,
    required String theirOneTimeKey,
  }) =>
      E2eeOlmSession._(_account.createOutboundSession(
        identityKey: vodozemac.Curve25519PublicKey.fromBase64(theirIdentityKey),
        oneTimeKey: vodozemac.Curve25519PublicKey.fromBase64(theirOneTimeKey),
      ));

  /// Establish an inbound Olm session from a received type-0 PRE_KEY message and
  /// decrypt it in one step. Consumes the matching one-time key.
  InboundOlmResult createInboundSession({
    required String theirIdentityKey,
    required String preKeyMessageBase64,
  }) {
    final r = _account.createInboundSession(
      theirIdentityKey:
          vodozemac.Curve25519PublicKey.fromBase64(theirIdentityKey),
      preKeyMessageBase64: preKeyMessageBase64,
    );
    return (session: E2eeOlmSession._(r.session), plaintext: r.plaintext);
  }

  /// Encrypted pickle for local persistence (NOT the wire; local only).
  String toPickle(Uint8List pickleKey) => _account.toPickleEncrypted(pickleKey);
}

/// An established Olm 1:1 session with one peer device.
class E2eeOlmSession {
  E2eeOlmSession._(this._session);

  final vodozemac.Session _session;

  String get sessionId => _session.sessionId;

  /// Encrypt to `{type, body}`. `type` is 0 (PRE_KEY) until the peer has
  /// replied, then 1 (normal). `body` is base64 — the wire value verbatim.
  ({int type, String body}) encrypt(String plaintext) {
    final e = _session.encrypt(plaintext);
    return (type: e.messageType, body: e.ciphertext);
  }

  /// Decrypt a `{type, body}` message from the peer on this session.
  String decrypt({required int type, required String body}) =>
      _session.decrypt(messageType: type, ciphertext: body);

  String toPickle(Uint8List pickleKey) => _session.toPickleEncrypted(pickleKey);

  factory E2eeOlmSession.fromPickle(String pickle, Uint8List pickleKey) =>
      E2eeOlmSession._(vodozemac.Session.fromPickleEncrypted(
        pickle: pickle,
        pickleKey: pickleKey,
      ));
}

/// libolm-compatible Megolm session config (version 1, truncated MAC). Used for
/// EVERY group session so the wire matches web/RN (see the import note above).
vzb.VodozemacMegolmSessionConfig _megolmV1() =>
    vzb.VodozemacMegolmSessionConfig.version1();

/// An outbound Megolm group session (this device's sender ratchet for a group
/// DM channel).
class E2eeOutboundGroupSession {
  E2eeOutboundGroupSession._(this._session);

  final vzb.VodozemacGroupSession _session;

  factory E2eeOutboundGroupSession.create() => E2eeOutboundGroupSession._(
        vzb.VodozemacGroupSession(config: _megolmV1()),
      );

  /// Stable id, byte-identical to libolm's — it routes the distribute/list/ack
  /// URLs, so it MUST match across clients (verified in the spike).
  String get sessionId => _session.sessionId();

  /// The current session key to distribute to recipient devices (Olm-wrapped).
  String get sessionKey => _session.sessionKey();

  /// Encrypt to a Megolm ciphertext (the wire `ciphertext` value).
  String encrypt(String plaintext) => _session.encrypt(plaintext: plaintext);

  String toPickle(Uint8List pickleKey) =>
      _session.pickleEncrypted(pickleKey: vzb.U8Array32(pickleKey));

  factory E2eeOutboundGroupSession.fromPickle(String pickle, Uint8List key) =>
      E2eeOutboundGroupSession._(vzb.VodozemacGroupSession.fromPickleEncrypted(
        pickle: pickle,
        pickleKey: vzb.U8Array32(key),
      ));
}

/// An inbound Megolm group session (a peer's sender ratchet we received).
class E2eeInboundGroupSession {
  E2eeInboundGroupSession._(this._session);

  final vzb.VodozemacInboundGroupSession _session;

  /// Import from a session key distributed by the sender.
  factory E2eeInboundGroupSession.fromSessionKey(String sessionKey) =>
      E2eeInboundGroupSession._(vzb.VodozemacInboundGroupSession(
        sessionKey: sessionKey,
        config: _megolmV1(),
      ));

  String get sessionId => _session.sessionId();

  /// Decrypt a Megolm ciphertext, returning the plaintext and its ratchet index.
  ({String plaintext, int messageIndex}) decrypt(String ciphertext) {
    final r = _session.decrypt(encrypted: ciphertext);
    return (plaintext: r.field0, messageIndex: r.field1);
  }

  String toPickle(Uint8List pickleKey) =>
      _session.pickleEncrypted(pickleKey: vzb.U8Array32(pickleKey));

  factory E2eeInboundGroupSession.fromPickle(String pickle, Uint8List key) =>
      E2eeInboundGroupSession._(
        vzb.VodozemacInboundGroupSession.fromPickleEncrypted(
          pickle: pickle,
          pickleKey: vzb.U8Array32(key),
        ),
      );
}
