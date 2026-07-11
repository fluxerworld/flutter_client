import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:fluxer_app/core/providers/database_provider.dart';
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/e2ee/e2ee_attachments.dart';
import 'package:fluxer_app/e2ee/e2ee_wire.dart';
import 'package:fluxer_app/features/chat/data/attachment_upload_client.dart';
import 'package:fluxer_app/features/chat/data/prepared_attachments.dart';
import 'package:fluxer_app/features/chat/domain/api_attachment_metadata.dart';
import 'package:fluxer_app/features/chat/domain/cloud_composer_attachments.dart';
import 'package:fluxer_app/features/chat/domain/message_upload_send_cancelled_exception.dart';
import 'package:fluxer_app/features/chat/domain/message_upload_session.dart';
import 'package:fluxer_app/features/chat/domain/pending_attachment.dart';
import 'package:fluxer_app/features/chat/providers/messages/message_upload_sessions_provider.dart';
import 'package:fluxer_app/features/chat/providers/upload/attachment_upload_client_provider.dart';
import 'package:fluxer_app/features/chat/providers/upload/user_upload_limits_provider.dart';
import 'package:fluxer_app/features/chat/utils/attachment_filename_utils.dart';
import 'package:fluxer_app/features/chat/utils/file_upload_constants.dart';
import 'package:fluxer_app/features/chat/utils/file_upload_validator.dart'
    show
        FileUploadValidationError,
        FileUploadValidationResult,
        FileUploadValidator;
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'cloud_upload_controller.g.dart';

@Riverpod(keepAlive: true)
class CloudUploadController extends _$CloudUploadController {
  int _nextAttachmentId = 1;
  final Map<int, CancelToken> _activeUploadControllers = <int, CancelToken>{};
  String _channelId = '';

  @override
  CloudComposerAttachments build(String channelId) {
    _channelId = channelId;
    ref.onDispose(() {
      for (final CancelToken c in _activeUploadControllers.values) {
        c.cancel();
      }
      _activeUploadControllers.clear();
    });
    return CloudComposerAttachments.empty;
  }

  Future<FileUploadValidationResult> addFiles(List<XFile> files) async {
    if (files.isEmpty) {
      return const FileUploadValidationResult.failure(
        FileUploadValidationError.noFiles,
      );
    }
    final int maxFileBytes = ref.read(maxAttachmentFileBytesProvider);
    final FileUploadValidator validator = FileUploadValidator(
      maxAttachments: kMaxAttachmentsPerMessage,
      maxFileBytes: maxFileBytes,
      maxMultipartRequestBytes: maxFileBytes,
    );
    final FileUploadValidationResult validation = await validator
        .validateAddFiles(
          currentCount: state.items.length,
          newFiles: files,
          multipartPayloadPreview: const <String, dynamic>{'content': ''},
        );
    if (!validation.isValid) {
      return validation;
    }
    final List<PendingAttachment> created = <PendingAttachment>[];
    for (final XFile file in files) {
      final XFile resolved = await _ensureResolvableFile(file);
      final int length = await resolved.length();
      final String contentType = FileUploadValidator.guessContentTypeFromName(
        resolved.name,
      );
      created.add(
        PendingAttachment(
          id: _nextAttachmentId++,
          channelId: _channelId,
          file: resolved,
          filename: resolved.name,
          size: length,
          contentType: contentType,
          status: PendingAttachmentStatus.pending,
          uploadProgress: 0,
        ),
      );
    }
    state = CloudComposerAttachments(<PendingAttachment>[
      ...state.items,
      ...created,
    ]);
    return const FileUploadValidationResult.success();
  }

  Future<XFile> _ensureResolvableFile(XFile file) async {
    final String safeName = sanitizeAttachmentFilename(
      rawUploadFilenameForSanitization(name: file.name, path: file.path),
      mimeType: file.mimeType,
    );
    final String path = file.path.trim();
    if (path.isNotEmpty && File(path).existsSync()) {
      final String onDiskBasename = path_lib.basename(path);
      if (onDiskBasename == safeName) {
        return XFile(path, mimeType: file.mimeType);
      }
      final Directory dir = await getTemporaryDirectory();
      final File dest = File(
        '${dir.path}/fluxer_upload_${DateTime.now().microsecondsSinceEpoch}_$safeName',
      );
      await File(path).copy(dest.path);
      return XFile(dest.path, mimeType: file.mimeType);
    }
    final Uint8List bytes = await file.readAsBytes();
    final Directory dir = await getTemporaryDirectory();
    final File temp = File(
      '${dir.path}/fluxer_upload_${DateTime.now().microsecondsSinceEpoch}_$safeName',
    );
    await temp.writeAsBytes(bytes, flush: true);
    return XFile(temp.path, mimeType: file.mimeType);
  }

  List<PendingAttachment> claimForMessage(String nonce) {
    if (state.items.isEmpty) {
      return const <PendingAttachment>[];
    }
    final List<PendingAttachment> claimed = List<PendingAttachment>.from(
      state.items,
    );
    state = CloudComposerAttachments.empty;
    ref
        .read(messageUploadSessionsProvider.notifier)
        .createSession(
          nonce: nonce,
          channelId: _channelId,
          attachments: claimed,
        );
    return claimed;
  }

  void restoreToComposer(String nonce) {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      return;
    }
    for (final int attachmentId in session.attachments.map(
      (PendingAttachment a) => a.id,
    )) {
      _activeUploadControllers.remove(attachmentId)?.cancel();
    }
    state = CloudComposerAttachments(<PendingAttachment>[
      ...state.items,
      ...session.attachments.map(
        (PendingAttachment a) => a.copyWith(
          status: PendingAttachmentStatus.pending,
          uploadProgress: 0,
          uploadFilename: null,
          multipartUploadId: null,
          fileSizePlan: null,
          contentTypePlan: null,
        ),
      ),
    ]);
    ref.read(messageUploadSessionsProvider.notifier).removeSession(nonce);
  }

  void cancelMessageUpload(String nonce) {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      return;
    }
    for (final PendingAttachment attachment in session.attachments) {
      _activeUploadControllers.remove(attachment.id)?.cancel();
    }
    ref.read(messageUploadSessionsProvider.notifier).removeSession(nonce);
  }

  void removeMessageUpload(String nonce) {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      return;
    }
    for (final PendingAttachment attachment in session.attachments) {
      _activeUploadControllers.remove(attachment.id)?.cancel();
    }
    ref.read(messageUploadSessionsProvider.notifier).removeSession(nonce);
  }

  Future<PreparedAttachments> prepareSessionForSend({
    required String nonce,
    required bool favoriteMemePayload,
  }) async {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      throw const MessageUploadSendCancelledException();
    }
    if (session.attachments.isEmpty) {
      return PreparedAttachments.empty;
    }
    // For an E2EE channel, encrypt every file IN PLACE before ANY branch that
    // uploads files — including the favoriteMeme path below — so every path
    // sends only ciphertext. Fail-closed by construction (a throw aborts with
    // nothing uploaded) and idempotent (a retry reuses the existing ciphertext).
    final List<Map<String, Object?>>? encryptedEntries =
        await _encryptE2eeAttachments(nonce);
    if (favoriteMemePayload) {
      final List<PendingAttachment> current = _requireSessionAttachments(nonce);
      return PreparedAttachments(
        attachmentMetadata: _mapApi(current),
        attachmentFiles: current.map((PendingAttachment e) => e.file).toList(),
        encryptedAttachmentEntries: encryptedEntries,
      );
    }
    try {
      ref
          .read(messageUploadSessionsProvider.notifier)
          .updateSendingProgress(nonce, 0);
      await Future.wait<void>(
        session.attachments.map(
          (PendingAttachment a) =>
              _ensureSessionAttachmentUploaded(nonce, a.id),
        ),
      );
      final List<PendingAttachment> latest = _requireSessionAttachments(nonce);
      final bool anyFailed = latest.any(
        (PendingAttachment e) => e.status == PendingAttachmentStatus.failed,
      );
      if (anyFailed) {
        _fallbackResetSessionUploadsForMultipartSend(nonce);
        final List<PendingAttachment> reset = _requireSessionAttachments(nonce);
        return PreparedAttachments(
          attachmentMetadata: _mapApi(reset),
          attachmentFiles: reset.map((PendingAttachment e) => e.file).toList(),
          encryptedAttachmentEntries: encryptedEntries,
        );
      }
      final List<PendingAttachment> ready = _requireSessionAttachments(nonce);
      return PreparedAttachments(
        attachmentMetadata: _mapApi(ready),
        encryptedAttachmentEntries: encryptedEntries,
      );
    } on MessageUploadSendCancelledException {
      rethrow;
    } on Object catch (e, st) {
      talker.warning('[CloudUpload] prepareSessionForSend error: $e\n$st');
      _fallbackResetSessionUploadsForMultipartSend(nonce);
      final List<PendingAttachment>? reset = ref
          .read(messageUploadSessionsProvider)[nonce]
          ?.attachments;
      if (reset == null) {
        throw const MessageUploadSendCancelledException();
      }
      return PreparedAttachments(
        attachmentMetadata: _mapApi(reset),
        attachmentFiles: reset.map((PendingAttachment e) => e.file).toList(),
        encryptedAttachmentEntries: encryptedEntries,
      );
    }
  }

  /// For an E2EE DM/Group-DM channel, encrypt each session attachment IN PLACE
  /// (replace its file with the ciphertext + opaque metadata) so every upload
  /// path below sends ciphertext, and return the per-file `{key,iv,mime,name,
  /// width?,height?}` entries to seal in the message envelope. Returns null for
  /// a normal channel (no change).
  Future<List<Map<String, Object?>>?> _encryptE2eeAttachments(
    String nonce,
  ) async {
    final dm = await ref
        .read(fluxerDatabaseProvider)
        .dmChannelDao
        .getDmChannelById(_channelId);
    if (dm == null || !isEncryptedChannelType(dm.type)) {
      return null;
    }
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null || session.attachments.isEmpty) {
      return null;
    }
    final E2eeAttachments e2ee = E2eeAttachments();
    final Directory tmpDir = await getTemporaryDirectory();
    final List<PendingAttachment> originals = List<PendingAttachment>.from(
      session.attachments,
    );
    // Phase 1: encrypt + write a ciphertext temp for every NOT-yet-encrypted
    // file, WITHOUT mutating the session, so a read/write failure leaves the
    // plaintext files untouched for a clean retry. An attachment that already
    // carries an encryptedEntry is a retry after a failed send — its file is
    // already ciphertext, so it is reused as-is (never re-encrypted).
    final List<({int id, String path, int size, Map<String, Object?> entry})>
    prepared = <({int id, String path, int size, Map<String, Object?> entry})>[];
    for (final PendingAttachment a in originals) {
      if (a.encryptedEntry != null) {
        continue;
      }
      final Uint8List bytes = await a.file.readAsBytes();
      final EncryptedAttachment enc = e2ee.encryptFile(
        plaintext: bytes,
        mime: a.contentType,
        name: a.filename,
        width: a.width,
        height: a.height,
      );
      final File tmp = await File(
        path_lib.join(tmpDir.path, 'e2ee_${nonce}_${a.id}.bin'),
      ).writeAsBytes(enc.ciphertext, flush: true);
      prepared.add((
        id: a.id,
        path: tmp.path,
        size: enc.ciphertext.length,
        entry: enc.envelopeEntry,
      ));
    }
    // Phase 2: swap each freshly-encrypted file to its ciphertext + opaque
    // metadata, stashing the entry on the attachment so a retry after a failed
    // send reuses it instead of re-encrypting the ciphertext. The real
    // name/mime/duration live only in the sealed envelope entry.
    for (final p in prepared) {
      _patchSessionAttachment(
        nonce,
        p.id,
        (PendingAttachment att) => att.copyWith(
          file: XFile(p.path),
          filename: 'encrypted.bin',
          contentType: 'application/octet-stream',
          size: p.size,
          description: null,
          duration: null,
          waveform: null,
          encryptedEntry: p.entry,
        ),
      );
    }
    // Return every entry in ORIGINAL order (reused + freshly-encrypted) so they
    // pair positionally with the wire attachments.
    final Map<int, Map<String, Object?>> freshById = <int, Map<String, Object?>>{
      for (final p in prepared) p.id: p.entry,
    };
    return <Map<String, Object?>>[
      for (final PendingAttachment a in originals)
        a.encryptedEntry ?? freshById[a.id]!,
    ];
  }

  MessageUploadSession _requireSession(String nonce) {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      throw const MessageUploadSendCancelledException();
    }
    return session;
  }

  List<PendingAttachment> _requireSessionAttachments(String nonce) {
    return _requireSession(nonce).attachments;
  }

  Future<void> _ensureSessionAttachmentUploaded(
    String nonce,
    int attachmentId,
  ) async {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      return;
    }
    final int index = session.attachments.indexWhere(
      (PendingAttachment e) => e.id == attachmentId,
    );
    if (index == -1) {
      return;
    }
    final PendingAttachment attachment = session.attachments[index];
    if (attachment.status == PendingAttachmentStatus.sending &&
        attachment.uploadFilename != null &&
        attachment.multipartUploadId == null) {
      return;
    }
    final CancelToken? existing = _activeUploadControllers[attachmentId];
    existing?.cancel();
    final CancelToken token = CancelToken();
    _activeUploadControllers[attachmentId] = token;
    _patchSessionAttachment(
      nonce,
      attachmentId,
      (PendingAttachment a) => a.copyWith(
        status: PendingAttachmentStatus.uploading,
        uploadProgress: 0,
      ),
    );
    try {
      final AttachmentUploadClient client = ref.read(
        attachmentUploadClientProvider,
      );
      final AttachmentUploadPlan plan = await client
          .requestAttachmentUploadPlan(
            channelId: _channelId,
            attachmentId: attachment.id,
            filename: attachment.filename,
            fileSize: attachment.size,
            contentType: attachment.contentType,
            cancelToken: token,
          );
      if (ref.read(messageUploadSessionsProvider)[nonce] == null) {
        return;
      }
      await client.uploadAttachmentPlan(
        UploadAttachmentPlanParams(
          channelId: _channelId,
          file: attachment.file,
          plan: plan,
          cancelToken: token,
          onPlanReady:
              ({
                required String uploadFilename,
                required int fileSize,
                required String contentType,
                String? uploadId,
              }) {
                _patchSessionAttachment(
                  nonce,
                  attachmentId,
                  (PendingAttachment a) => a.copyWith(
                    uploadFilename: uploadFilename,
                    fileSizePlan: fileSize,
                    contentTypePlan: contentType,
                    multipartUploadId: uploadId,
                  ),
                );
              },
          onProgress: (int uploadedBytes, int totalBytes) {
            final int effectiveTotal = totalBytes > 0
                ? totalBytes
                : attachment.size;
            final double p = effectiveTotal > 0
                ? (uploadedBytes / effectiveTotal).clamp(0.0, 1.0)
                : 0;
            _patchSessionAttachment(
              nonce,
              attachmentId,
              (PendingAttachment a) => a.copyWith(
                status: PendingAttachmentStatus.uploading,
                uploadProgress: p,
              ),
            );
          },
        ),
      );
      if (ref.read(messageUploadSessionsProvider)[nonce] == null) {
        return;
      }
      _patchSessionAttachment(
        nonce,
        attachmentId,
        (PendingAttachment a) => a.copyWith(
          status: PendingAttachmentStatus.sending,
          uploadProgress: 1,
          multipartUploadId: null,
        ),
      );
    } on Object catch (e, st) {
      if (ref.read(messageUploadSessionsProvider)[nonce] == null) {
        return;
      }
      talker.warning('[CloudUpload] session upload failed: $e\n$st');
      _patchSessionAttachment(
        nonce,
        attachmentId,
        (PendingAttachment a) => a.copyWith(
          status: PendingAttachmentStatus.failed,
          uploadProgress: 0,
        ),
      );
    } finally {
      _activeUploadControllers.remove(attachmentId);
    }
  }

  void _patchSessionAttachment(
    String nonce,
    int attachmentId,
    PendingAttachment Function(PendingAttachment) updater,
  ) {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      return;
    }
    final List<PendingAttachment> next = session.attachments
        .map((PendingAttachment e) => e.id == attachmentId ? updater(e) : e)
        .toList();
    ref
        .read(messageUploadSessionsProvider.notifier)
        .updateSessionAttachments(nonce, next, recomputeSendingProgress: true);
  }

  void _fallbackResetSessionUploadsForMultipartSend(String nonce) {
    final MessageUploadSession? session = ref.read(
      messageUploadSessionsProvider,
    )[nonce];
    if (session == null) {
      return;
    }
    ref
        .read(messageUploadSessionsProvider.notifier)
        .updateSessionAttachments(
          nonce,
          session.attachments
              .map(
                (PendingAttachment a) => a.copyWith(
                  status: PendingAttachmentStatus.pending,
                  uploadProgress: 0,
                  uploadFilename: null,
                  multipartUploadId: null,
                  fileSizePlan: null,
                  contentTypePlan: null,
                ),
              )
              .toList(),
        );
  }

  void _patchAttachment(
    int attachmentId,
    PendingAttachment Function(PendingAttachment) updater,
  ) {
    state = CloudComposerAttachments(
      state.items
          .map((PendingAttachment e) => e.id == attachmentId ? updater(e) : e)
          .toList(),
    );
  }

  Future<void> removeAttachment(int attachmentId) async {
    PendingAttachment? att;
    for (final PendingAttachment e in state.items) {
      if (e.id == attachmentId) {
        att = e;
        break;
      }
    }
    if (att == null) {
      return;
    }
    final CancelToken? c = _activeUploadControllers.remove(attachmentId);
    c?.cancel();
    state = CloudComposerAttachments(
      state.items.where((PendingAttachment e) => e.id != attachmentId).toList(),
    );
  }

  void updateAttachment(
    int attachmentId, {
    required String filename,
    required String? description,
    required int flags,
  }) {
    _patchAttachment(attachmentId, (PendingAttachment a) {
      return a.copyWith(
        filename: filename,
        description: description == null || description.isEmpty
            ? null
            : description,
        flags: flags,
      );
    });
  }

  void reorderAttachments(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= state.items.length ||
        newIndex < 0 ||
        newIndex >= state.items.length) {
      return;
    }
    final List<PendingAttachment> next = List<PendingAttachment>.from(
      state.items,
    );
    final PendingAttachment item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    state = CloudComposerAttachments(next);
  }

  Future<FileUploadValidationResult> addVoiceMessage({
    required XFile file,
    required int duration,
    required String waveform,
  }) async {
    if (state.items.isNotEmpty) {
      return const FileUploadValidationResult.failure(
        FileUploadValidationError.tooManyAttachments,
      );
    }
    final int maxFileBytes = ref.read(maxAttachmentFileBytesProvider);
    final FileUploadValidator validator = FileUploadValidator(
      maxAttachments: 1,
      maxFileBytes: maxFileBytes,
      maxMultipartRequestBytes: maxFileBytes,
    );
    final XFile resolved = await _ensureResolvableFile(file);
    final int length = await resolved.length();
    final FileUploadValidationResult validation = await validator
        .validateAddFiles(
          currentCount: 0,
          newFiles: <XFile>[resolved],
          multipartPayloadPreview: const <String, dynamic>{'content': ''},
        );
    if (!validation.isValid) {
      return validation;
    }
    final PendingAttachment created = PendingAttachment(
      id: _nextAttachmentId++,
      channelId: _channelId,
      file: resolved,
      filename: resolved.name,
      size: length,
      contentType: 'audio/wav',
      status: PendingAttachmentStatus.pending,
      uploadProgress: 0,
      duration: duration,
      waveform: waveform,
    );
    state = CloudComposerAttachments(<PendingAttachment>[created]);
    return const FileUploadValidationResult.success();
  }

  List<ApiAttachmentMetadata> _mapApi(List<PendingAttachment> list) {
    return List<ApiAttachmentMetadata>.generate(list.length, (int i) {
      final PendingAttachment a = list[i];
      final int flagsOut = a.flags;
      return ApiAttachmentMetadata(
        id: '$i',
        filename: a.filename,
        title: a.filename,
        uploadFilename: a.uploadFilename,
        fileSize: a.fileSizePlan ?? a.size,
        contentType: a.contentTypePlan ?? a.contentType,
        description: a.description,
        flags: flagsOut != 0 ? flagsOut : null,
        duration: a.duration,
        waveform: a.waveform,
      );
    });
  }

  void clearComposerAttachments() {
    for (final CancelToken c in _activeUploadControllers.values) {
      c.cancel();
    }
    _activeUploadControllers.clear();
    state = CloudComposerAttachments.empty;
  }
}
