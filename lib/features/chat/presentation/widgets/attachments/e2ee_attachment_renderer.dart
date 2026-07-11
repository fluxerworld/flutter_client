import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/e2ee/e2ee_provider.dart';
import 'package:fluxer_app/features/chat/domain/message.dart';

/// Renders the attachments of an E2EE message. The wire attachments are opaque
/// ciphertext blobs (application/octet-stream); the real mime + per-file AES
/// key/iv live in the decrypted envelope, cached by the manager and fetched here
/// by message id, then paired POSITIONALLY with the wire attachments. Each image
/// is downloaded, decrypted in memory, and shown; anything without a usable key
/// (not addressed to us, or still-encrypted history) shows a lock. Futures are
/// memoized so a widget rebuild doesn't re-fetch or re-decrypt.
class E2eeAttachmentRenderer extends ConsumerStatefulWidget {
  const E2eeAttachmentRenderer({
    required this.messageId,
    required this.attachments,
    super.key,
  });

  final String messageId;
  final List<Attachment> attachments;

  @override
  ConsumerState<E2eeAttachmentRenderer> createState() =>
      _E2eeAttachmentRendererState();
}

class _E2eeAttachmentRendererState
    extends ConsumerState<E2eeAttachmentRenderer> {
  late Future<List<Map<String, Object?>>> _entriesFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture =
        ref.read(e2eeManagerProvider).cachedAttachments(widget.messageId);
  }

  @override
  void didUpdateWidget(E2eeAttachmentRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId) {
      _entriesFuture =
          ref.read(e2eeManagerProvider).cachedAttachments(widget.messageId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _entriesFuture,
      builder: (BuildContext context, AsyncSnapshot<List<Map<String, Object?>>>
          snapshot) {
        final List<Map<String, Object?>> entries =
            snapshot.data ?? const <Map<String, Object?>>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < widget.attachments.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _E2eeAttachmentItem(
                  attachment: widget.attachments[i],
                  entry: i < entries.length ? entries[i] : null,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _E2eeAttachmentItem extends ConsumerStatefulWidget {
  const _E2eeAttachmentItem({required this.attachment, required this.entry});

  final Attachment attachment;
  final Map<String, Object?>? entry;

  @override
  ConsumerState<_E2eeAttachmentItem> createState() =>
      _E2eeAttachmentItemState();
}

class _E2eeAttachmentItemState extends ConsumerState<_E2eeAttachmentItem> {
  Future<Uint8List>? _bytesFuture;

  String? get _key => widget.entry?['key'] as String?;
  String? get _iv => widget.entry?['iv'] as String?;
  String get _mime => (widget.entry?['mime'] as String?) ?? '';
  String get _name =>
      (widget.entry?['name'] as String?) ?? widget.attachment.filename;

  @override
  void initState() {
    super.initState();
    _maybeStartDownload();
  }

  @override
  void didUpdateWidget(_E2eeAttachmentItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry ||
        oldWidget.attachment.url != widget.attachment.url) {
      _bytesFuture = null;
      _maybeStartDownload();
    }
  }

  void _maybeStartDownload() {
    final String? key = _key;
    final String? iv = _iv;
    if (key == null || iv == null || !_mime.startsWith('image/')) {
      return;
    }
    _bytesFuture = _downloadAndDecrypt(widget.attachment.url, key, iv);
  }

  Future<Uint8List> _downloadAndDecrypt(
    String url,
    String key,
    String iv,
  ) async {
    final Response<List<int>> response = await Dio().get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return ref.read(e2eeManagerProvider).decryptAttachmentBytes(
          ciphertext: Uint8List.fromList(response.data ?? const <int>[]),
          keyBase64: key,
          ivBase64: iv,
        );
  }

  @override
  Widget build(BuildContext context) {
    if (_key == null || _iv == null) {
      // No key for this device (undecryptable / still-encrypted history).
      return _placeholder(Icons.lock_outline, _name);
    }
    final Future<Uint8List>? future = _bytesFuture;
    if (future == null) {
      // Non-image encrypted file — a chip; inline decrypted preview is
      // image-only in this slice (video/audio are a follow-up).
      return _placeholder(Icons.insert_drive_file_outlined, _name);
    }
    return FutureBuilder<Uint8List>(
      future: future,
      builder:
          (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        if (snapshot.hasError) {
          return _placeholder(Icons.lock_outline, _name);
        }
        final Uint8List? bytes = snapshot.data;
        if (bytes == null) {
          return _loadingBox();
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        );
      },
    );
  }

  Widget _loadingBox() => Container(
        width: 200,
        height: 120,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );

  Widget _placeholder(IconData icon, String name) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
