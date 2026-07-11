// AES-256-GCM file encryption for E2EE attachments. Byte-compatible with the
// web client's WebCrypto (crypto.subtle {name:'AES-GCM'}) — this is the frozen
// cross-client contract and MUST NOT diverge:
//   * key   : 32 random bytes (AES-256)
//   * iv    : 12 random bytes (96-bit GCM nonce), fresh per file
//   * output: ciphertext with the 16-byte (128-bit) auth tag APPENDED, exactly
//             as crypto.subtle.encrypt returns it — no header/magic bytes
//   * key/iv are STANDARD base64 (padded, not base64url) inside the envelope
//
// Only the small {key,iv,mime,name} envelope entry travels through Olm/Megolm;
// the bulk ciphertext is uploaded to the normal attachment store. The entry is
// paired to its uploaded blob POSITIONALLY (envelope.attachments[i] <-> the
// message's attachments[i]), so callers MUST preserve file order.
//
// RN does not yet implement attachment E2EE, so an encrypted attachment is
// currently only round-trippable web <-> Flutter (text still interops all three).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-256 key length in bytes.
const int kAttachmentKeyBytes = 32;

/// GCM nonce length in bytes (96-bit).
const int kAttachmentIvBytes = 12;

/// GCM auth-tag length in bits (16 bytes, appended to the ciphertext).
const int kAttachmentTagBits = 128;

/// The result of encrypting one file: the `ciphertext` to upload and the
/// `envelopeEntry` (`{key, iv, mime, name, width?, height?}`) that is sealed in
/// the message's E2EE envelope so recipients can decrypt it.
typedef EncryptedAttachment = ({
  Uint8List ciphertext,
  Map<String, Object?> envelopeEntry,
});

class E2eeAttachments {
  E2eeAttachments({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  /// Encrypt one file's [plaintext] bytes with a fresh AES-256-GCM key.
  EncryptedAttachment encryptFile({
    required Uint8List plaintext,
    required String mime,
    required String name,
    int? width,
    int? height,
  }) {
    final key = _randomBytes(kAttachmentKeyBytes);
    final iv = _randomBytes(kAttachmentIvBytes);
    final ciphertext = _gcm(
      forEncryption: true,
      key: key,
      iv: iv,
      input: plaintext,
    );
    final entry = <String, Object?>{
      'key': base64Encode(key),
      'iv': base64Encode(iv),
      'mime': mime,
      'name': name,
      // Omit width/height entirely when unknown/zero — web reads `?? fallback`,
      // which does NOT catch a literal 0 and would render at zero pixels.
      if (width != null && width > 0) 'width': width,
      if (height != null && height > 0) 'height': height,
    };
    return (ciphertext: ciphertext, envelopeEntry: entry);
  }

  /// Decrypt attachment [ciphertext] (ciphertext||tag) with the base64 [keyBase64]
  /// and [ivBase64] from an envelope entry. Throws on an authentication failure.
  Uint8List decryptFile({
    required Uint8List ciphertext,
    required String keyBase64,
    required String ivBase64,
  }) =>
      _gcm(
        forEncryption: false,
        key: base64Decode(keyBase64),
        iv: base64Decode(ivBase64),
        input: ciphertext,
      );

  Uint8List _gcm({
    required bool forEncryption,
    required Uint8List key,
    required Uint8List iv,
    required Uint8List input,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(KeyParameter(key), kAttachmentTagBits, iv, Uint8List(0)),
      );
    final output = Uint8List(cipher.getOutputSize(input.length));
    final written = cipher.processBytes(input, 0, input.length, output, 0);
    final total = written + cipher.doFinal(output, written);
    return total == output.length
        ? output
        : Uint8List.sublistView(output, 0, total);
  }

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));
}
