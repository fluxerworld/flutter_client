import 'package:cross_file/cross_file.dart';

import 'package:fluxer_app/features/chat/domain/api_attachment_metadata.dart';

class PreparedAttachments {
  const PreparedAttachments({
    this.attachmentMetadata,
    this.attachmentFiles,
    this.encryptedAttachmentEntries,
  });

  final List<ApiAttachmentMetadata>? attachmentMetadata;
  final List<XFile>? attachmentFiles;

  /// For an E2EE channel: the per-file `{key, iv, mime, name, width?, height?}`
  /// envelope entries (positionally aligned to [attachmentMetadata]). The files
  /// were already encrypted in place before upload, so [attachmentMetadata] is
  /// opaque (encrypted.bin / octet-stream) and these entries — which carry the
  /// decryption keys — must be sealed inside the message's E2EE envelope.
  final List<Map<String, Object?>>? encryptedAttachmentEntries;

  bool get isEmpty =>
      (attachmentMetadata == null || attachmentMetadata!.isEmpty) &&
      (attachmentFiles == null || attachmentFiles!.isEmpty);

  static const PreparedAttachments empty = PreparedAttachments();
}
