import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/e2ee/e2ee_provider.dart';
import 'package:fluxer_app/features/chat/domain/message.dart';
import 'package:fluxer_app/l10n/generated/fluxer_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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

/// Refuse to decode a decrypted image larger than this — the display is capped
/// small, and a huge (or hostile) payload would blow up peak memory.
const int _kMaxAttachmentBytes = 30 * 1024 * 1024;

class _E2eeAttachmentItemState extends ConsumerState<_E2eeAttachmentItem> {
  Future<Uint8List>? _bytesFuture;

  // Non-image "decrypt + save" chip state.
  bool _saving = false;
  bool _saved = false;
  bool _saveFailed = false;

  // The envelope entry comes from sender-controlled JSON — read every field
  // defensively so a non-string/non-int value degrades to a placeholder rather
  // than throwing a synchronous cast error out of the widget lifecycle.
  String? _str(String field) {
    final Object? v = widget.entry?[field];
    return v is String ? v : null;
  }

  int? _int(String field) {
    final Object? v = widget.entry?[field];
    return v is int ? v : (v is num ? v.toInt() : null);
  }

  String? get _key => _str('key');
  String? get _iv => _str('iv');
  String get _mime => _str('mime') ?? '';
  String get _name => _str('name') ?? widget.attachment.filename;
  int? get _width => _int('width');
  int? get _height => _int('height');

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
      // This State can be reused for a different attachment (children are built
      // positionally without keys) — reset the save-chip flags too, or a new
      // attachment would inherit the previous one's "Saved" state.
      _saving = false;
      _saved = false;
      _saveFailed = false;
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
    final CancelToken cancelToken = CancelToken();
    final Response<List<int>> response = await Dio().get<List<int>>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 60),
      ),
      onReceiveProgress: (int received, int _) {
        // Abort a runaway download before it fills memory (ciphertext is
        // ~plaintext + a 16-byte tag).
        if (received > _kMaxAttachmentBytes + 4096) {
          cancelToken.cancel('attachment exceeds size cap');
        }
      },
    );
    final Uint8List bytes = ref.read(e2eeManagerProvider).decryptAttachmentBytes(
          ciphertext: Uint8List.fromList(response.data ?? const <int>[]),
          keyBase64: key,
          ivBase64: iv,
        );
    if (bytes.length > _kMaxAttachmentBytes) {
      throw Exception('decrypted attachment exceeds size cap');
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    if (_key == null || _iv == null) {
      // No key for this device (undecryptable / still-encrypted history).
      return _placeholder(Icons.lock_outline, _name);
    }
    final Future<Uint8List>? future = _bytesFuture;
    if (future == null) {
      // Non-image encrypted file: a tap-to-decrypt-and-save chip — the mobile
      // equivalent of the web client's click-to-decrypt download card.
      return _fileChip();
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
        final Size? size = _displaySize();
        final Widget image = Image.memory(
          bytes,
          fit: BoxFit.contain,
          width: size?.width,
          height: size?.height,
          // Bound the decoded bitmap to the display resolution — the source may
          // be far larger than the ~400px box it renders into.
          cacheWidth: (400 * MediaQuery.devicePixelRatioOf(context)).round(),
          // Bytes are authenticated (GCM), but the sender-labeled mime doesn't
          // guarantee they decode — degrade to a chip instead of a broken box.
          errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
              _placeholder(Icons.insert_drive_file_outlined, _name),
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: size != null
              ? image
              : ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 400, maxHeight: 400),
                  child: image,
                ),
        );
      },
    );
  }

  /// Display size derived from the envelope's sender-provided width/height,
  /// scaled to fit within 400x400 without upscaling. Null if dims are absent —
  /// callers fall back to a fixed box. Reserves the right aspect during load so
  /// the image doesn't pop the layout when it resolves.
  Size? _displaySize() {
    final int? w = _width;
    final int? h = _height;
    if (w == null || h == null || w <= 0 || h <= 0) {
      return null;
    }
    const double maxEdge = 400;
    final double scale = (w > h ? maxEdge / w : maxEdge / h).clamp(0.0, 1.0);
    return Size(w * scale, h * scale);
  }

  Widget _loadingBox() {
    final Size? size = _displaySize();
    return Container(
      width: size?.width ?? 200,
      height: size?.height ?? 120,
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
  }

  /// Download + decrypt the ciphertext in memory, write the plaintext to a temp
  /// file, and hand it to the OS share sheet so the user can save/forward it.
  Future<void> _downloadAndSave() async {
    final String? key = _key;
    final String? iv = _iv;
    if (key == null || iv == null || _saving) {
      return;
    }
    // Snapshot the sender-provided name/mime BEFORE the download await, so a
    // mid-flight entry swap (this State can be reused for a different
    // attachment) can't mislabel the file we write and share.
    final String safeName = _safeFileName(_name);
    final String mime = _mime;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    File? file;
    try {
      final Uint8List bytes =
          await _downloadAndDecrypt(widget.attachment.url, key, iv);
      final Directory dir = await getTemporaryDirectory();
      final Directory shareDir = Directory('${dir.path}/e2ee_share');
      await shareDir.create(recursive: true);
      // Prefix with the attachment id so two attachments whose names collide
      // (or are both blank) never share a temp file — a concurrent save could
      // otherwise route one attachment's decrypted plaintext into the other's
      // share sheet.
      file = File('${shareDir.path}/${widget.attachment.id}_$safeName');
      await file.writeAsBytes(bytes, flush: true);
      // Don't pop a share sheet over an unrelated screen if we've been disposed
      // mid-download (the finally still deletes the temp file).
      if (!mounted) {
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[
            XFile(
              file.path,
              mimeType: mime.isEmpty ? null : mime,
              name: safeName,
            ),
          ],
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _saved = true;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
      }
    } finally {
      // Never leave decrypted E2EE plaintext at rest: share_plus has already
      // copied the file into its own cache by the time share() returns, so our
      // copy is safe to remove on every path (success, cancel, error, dispose).
      if (file != null) {
        try {
          await file.delete();
        } on Object catch (_) {}
      }
    }
  }

  /// Reduce the sender-controlled attachment name to a safe temp-file basename:
  /// drop any directory components (path-traversal guard) and non-portable
  /// characters. The display still shows the original [_name].
  String _safeFileName(String name) {
    var base = name.split(RegExp(r'[/\\]')).last;
    base = base.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    if (base.isEmpty || base == '.' || base == '..') {
      base = 'attachment';
    }
    return base;
  }

  Widget _fileChip() {
    final FluxerLocalizations l10n = FluxerLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    final (IconData, String) state = _saving
        ? (Icons.hourglass_top, l10n.e2eeAttachmentDecrypting)
        : _saved
            ? (Icons.check_circle_outline, l10n.e2eeAttachmentSaved)
            : _saveFailed
                ? (Icons.error_outline, l10n.e2eeAttachmentSaveFailed)
                : (Icons.download_outlined, l10n.e2eeAttachmentTapToSave);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _saving ? null : () => unawaited(_downloadAndSave()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_saving)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(state.$1, size: 16, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontSize: 13),
                    ),
                    Text(
                      state.$2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
