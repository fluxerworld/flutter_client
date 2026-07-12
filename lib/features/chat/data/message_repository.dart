import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:fluxer_app/core/api/dio_error_message.dart';
import 'package:fluxer_app/core/database/fluxer_database.dart' as db;
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/core/utils/message_mention_resolver.dart';
import 'package:fluxer_app/e2ee/e2ee_manager.dart';
import 'package:fluxer_app/e2ee/e2ee_wire.dart';
import 'package:fluxer_app/features/channels/data/read_state_repository.dart';
import 'package:fluxer_app/features/chat/domain/api_attachment_metadata.dart';
import 'package:fluxer_app/features/chat/domain/message.dart';
import 'package:fluxer_app/features/chat/utils/client_nonce.dart';
import 'package:fluxer_app/features/chat/utils/message_page_sync.dart';
import 'package:fluxer_app/shared/utils/guild_user_display.dart';
import 'package:fluxer_app/shared/utils/sdk_converters.dart';
import 'package:fluxer_app/shared/utils/snowflake_time.dart';
import 'package:fluxer_dart/export.dart';

const int kMessageFlagCompactAttachments = 1 << 17;

/// Thrown when a message can't be sent to an always-on-E2EE channel because it
/// couldn't be encrypted (Group DM Megolm not yet supported, identity not ready,
/// or the recipient has no device). The send is refused rather than leaked as
/// plaintext; the UI shows it as a failed send.
class E2eeEncryptionUnavailableException implements Exception {
  const E2eeEncryptionUnavailableException(this.channelType);

  final int channelType;

  @override
  String toString() =>
      'E2eeEncryptionUnavailableException(channelType: $channelType)';
}

class MessageListLoadResult {
  const MessageListLoadResult({
    required this.messages,
    this.embeddedReplyParents = const [],
  });

  final List<Message> messages;
  final List<Message> embeddedReplyParents;
}

Map<String, dynamic> buildMessageCreateBody({
  required String content,
  String? replyToId,
  bool replyMention = true,
  String? clientNonce,
  List<String> stickerIds = const [],
  String? favoriteMemeId,
  List<ApiAttachmentMetadata>? attachments,
  int? messageFlags,
  bool tts = false,
}) {
  final body = <String, dynamic>{};
  if (content.isNotEmpty) {
    body['content'] = content;
  }
  if (replyToId != null) {
    body['message_reference'] = <String, dynamic>{'message_id': replyToId};
    body['allowed_mentions'] = <String, dynamic>{'replied_user': replyMention};
  }
  if (stickerIds.isNotEmpty) {
    body['sticker_ids'] = stickerIds;
  }
  var flags = messageFlags ?? 0;
  if (favoriteMemeId != null) {
    body['favorite_meme_id'] = favoriteMemeId;
    flags |= kMessageFlagCompactAttachments;
  }
  if (flags != 0) {
    body['flags'] = flags;
  }
  if (tts) {
    body['tts'] = true;
  }
  if (attachments != null && attachments.isNotEmpty) {
    body['attachments'] = attachments
        .map((ApiAttachmentMetadata e) => e.toJson())
        .toList();
  }
  if (clientNonce != null && clientNonce.isNotEmpty) {
    body['nonce'] = clientNonce;
  }
  return body;
}

/// Builds the request body for a message forward.
///
/// Forwards reference a source message and MUST NOT carry
/// content/embeds/attachments/stickers. The server builds the snapshot itself
/// (it rejects forward refs that include content). [attachmentIds]/
/// [embedIndices] narrow which media the server snapshots. Omit them to
/// forward the whole message.
Map<String, dynamic> buildForwardMessageBody({
  required String sourceChannelId,
  required String sourceMessageId,
  String? sourceGuildId,
  List<String>? attachmentIds,
  List<int>? embedIndices,
  String? clientNonce,
}) {
  final reference = <String, dynamic>{
    'type': 1, // MessageReferenceType.forward
    'channel_id': sourceChannelId,
    'message_id': sourceMessageId,
  };
  if (sourceGuildId != null && sourceGuildId.isNotEmpty) {
    reference['guild_id'] = sourceGuildId;
  }
  if (attachmentIds != null && attachmentIds.isNotEmpty) {
    reference['attachment_ids'] = attachmentIds;
  }
  if (embedIndices != null && embedIndices.isNotEmpty) {
    reference['embed_indices'] = embedIndices;
  }
  final body = <String, dynamic>{'message_reference': reference};
  if (clientNonce != null && clientNonce.isNotEmpty) {
    body['nonce'] = clientNonce;
  }
  return body;
}

class MessageRepository {
  final FluxerClient _client;
  final Dio _dio;
  final db.FluxerDatabase _db;
  final String? _currentUserId;
  final E2eeManager _e2ee;
  final Map<String, Future<MessageListLoadResult>> _inFlightPages =
      <String, Future<MessageListLoadResult>>{};

  MessageRepository(
    this._client,
    this._dio,
    this._db,
    this._currentUserId,
    this._e2ee,
  );

  Stream<List<Message>> watchMessages(String channelId) {
    return _db.messageDao
        .watchMessages(channelId)
        .map((rows) => rows.map(Message.fromRow).toList());
  }

  Future<List<Message>> getCachedMessages(
    String channelId, {
    int limit = 30,
  }) async {
    final rows = await _db.messageDao.getMessages(channelId, limit: limit);
    return rows.map(Message.fromRow).toList();
  }

  Future<List<Message>> getCachedMessagesBefore(
    String channelId,
    String beforeId, {
    int limit = 30,
  }) async {
    final rows = await _db.messageDao.getMessages(
      channelId,
      limit: limit,
      beforeId: beforeId,
    );
    return rows.map(Message.fromRow).toList();
  }

  Future<List<Message>> getCachedMessagesAfter(
    String channelId,
    String afterId, {
    int limit = 30,
  }) async {
    final rows = await _db.messageDao.getMessagesAfter(
      channelId,
      afterId,
      limit: limit,
    );
    return rows.map(Message.fromRow).toList();
  }

  Future<List<Message>> getMessages({
    required String channelId,
    int limit = 30,
    String? before,
    String? after,
    String? around,
  }) async {
    final page = await loadMessagePage(
      channelId: channelId,
      limit: limit,
      before: before,
      after: after,
      around: around,
    );
    return page.messages;
  }

  Future<MessageListLoadResult> loadMessagePage({
    required String channelId,
    int limit = 30,
    String? before,
    String? after,
    String? around,
  }) {
    final String key =
        '$channelId|${before ?? ''}|${after ?? ''}|${around ?? ''}|$limit';
    final Future<MessageListLoadResult>? existing = _inFlightPages[key];
    if (existing != null) {
      return existing;
    }
    final Future<MessageListLoadResult> future =
        _fetchMessagePage(
          channelId: channelId,
          limit: limit,
          before: before,
          after: after,
          around: around,
        ).whenComplete(() {
          _inFlightPages.removeWhere((k, _) => k == key);
        });
    _inFlightPages[key] = future;
    return future;
  }

  Future<MessageListLoadResult> _fetchMessagePage({
    required String channelId,
    int limit = 30,
    String? before,
    String? after,
    String? around,
  }) async {
    try {
      final data = await _client.channels.listMessages(
        channelId: channelId,
        limit: limit.toString(),
        before: before,
        after: after,
        around: around,
      );

      final embeddedReplyParents = <Message>[];
      for (final sdk in data) {
        final referenced = sdk.referencedMessage;
        if (referenced != null) {
          embeddedReplyParents.add(
            Message.fromReferencedSdk(
              referenced,
              currentUserId: _currentUserId,
            ),
          );
        }
      }

      final mentionCtx = await buildMessageMentionContext(
        _db,
        currentUserId: _currentUserId,
        channelId: channelId,
      );
      await _ensureE2eeReadyForPage(data);
      final built = await Future.wait(
        data.map((sdk) {
          final Message m = Message.fromSdk(sdk, currentUserId: _currentUserId)
              .copyWith(
                isMentioned: messageMentionsUser(
                  mentionCtx,
                  authorId: sdk.author.id,
                  mentionedUserIds: sdk.mentions.map((u) => u.id).toList(),
                  mentionEveryone: sdk.mentionEveryone,
                  mentionRoleIds: sdk.mentionRoles,
                ),
              );
          return _decryptIncoming(m, sdk);
        }),
      );
      final messages = built.reversed.toList();

      for (final sdk in data) {
        if (sdk.webhookId == null) {
          await upsertPartialUser(_db, sdk.author);
        }
        await upsertMentionUsersFromSdk(_db, sdk.mentions);
      }
      await _db.messageDao.upsertMessages(
        messages.map((m) => m.toCompanion()).toList(),
      );
      await _pruneStaleMessagesForNetworkPage(channelId, messages);

      if (messages.isNotEmpty) {
        final last = messages.last;
        await _db.dmChannelDao.updateLastMessage(
          channelId,
          last.id,
          last.content,
          last.authorId,
          last.timestamp,
        );
      }

      if (messages.any((m) => m.isMentioned)) {
        await ReadStateRepository(_client, _db).recomputeMentionsAfterBackfill(
          channelId: channelId,
          currentUserId: _currentUserId,
        );
      }

      return MessageListLoadResult(
        messages: messages,
        embeddedReplyParents: embeddedReplyParents,
      );
    } on DioException catch (e) {
      // SDK deserialization can fail on a 200 response
      // (e.g. missing fields). Fall back to manual parsing.
      if (e.response?.statusCode == 200) {
        talker.warning(
          '[MessageRepo] SDK parse failed, '
          'using fallback: ${e.error}',
        );
        final messages = await _getMessagesFallback(
          channelId: channelId,
          limit: limit,
          before: before,
          after: after,
          around: around,
        );
        return MessageListLoadResult(messages: messages);
      }
      throw Exception(
        e.error?.toString() ?? e.message ?? 'Failed to fetch messages',
      );
    }
  }

  Future<Message> fetchMessage({
    required String channelId,
    required String messageId,
  }) async {
    try {
      final sdk = await _client.channels.getMessage(
        channelId: channelId,
        messageId: messageId,
      );
      if (sdk.webhookId == null) {
        await upsertPartialUser(_db, sdk.author);
      }
      await upsertMentionUsersFromSdk(_db, sdk.mentions);
      Message message = Message.fromSdk(sdk, currentUserId: _currentUserId)
          .copyWith(
            isMentioned: await resolveMessageMentionsUser(
              _db,
              currentUserId: _currentUserId,
              channelId: channelId,
              authorId: sdk.author.id,
              mentionedUserIds: sdk.mentions.map((u) => u.id).toList(),
              mentionEveryone: sdk.mentionEveryone,
              mentionRoleIds: sdk.mentionRoles,
            ),
          );
      await _ensureE2eeReadyForPage(<MessageResponseSchema>[sdk]);
      message = await _decryptIncoming(message, sdk);
      await _db.messageDao.upsertMessage(message.toCompanion());
      return message;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        rethrow;
      }
      throw Exception(
        e.error?.toString() ?? e.message ?? 'Failed to fetch message',
      );
    }
  }

  /// Fallback: fetch raw JSON and parse manually,
  /// skipping individual messages that fail.
  Future<List<Message>> _getMessagesFallback({
    required String channelId,
    int limit = 30,
    String? before,
    String? after,
    String? around,
  }) async {
    final queryParams = <String, dynamic>{
      'limit': limit,
      'before': ?before,
      'after': ?after,
      'around': ?around,
    };
    final response = await _dio.get<List<dynamic>>(
      '/channels/$channelId/messages',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data == null) {
      return [];
    }

    final messages = <Message>[];
    final mentionCtx = await buildMessageMentionContext(
      _db,
      currentUserId: _currentUserId,
      channelId: channelId,
    );
    // Bootstrap once before decrypting (mirrors _fetchMessagePage) so a page
    // fetched during the cold-start bootstrap race doesn't persist empty rows.
    final String? uid = _currentUserId;
    if (uid != null &&
        data.any(
          (json) => json is Map && json['encrypted_payload'] != null,
        )) {
      try {
        await _e2ee.ensureBootstrapped(uid);
      } on Object {
        // Proceed; decrypt returns transient if still not ready.
      }
    }
    for (final json in data.reversed) {
      try {
        final map = json as Map<String, dynamic>;
        final author = map['author'] as Map<String, dynamic>;
        messages.add(
          Message(
            id: map['id'] as String,
            channelId: map['channel_id'] as String,
            authorId: author['id'] as String,
            authorName: resolveMessageAuthorNameFromJson(author),
            authorAvatar: author['avatar'] as String?,
            authorAvatarColor: author['avatar_color'] as int?,
            authorIsBot: (author['bot'] as bool?) ?? false,
            authorIsSystem: (author['system'] as bool?) ?? false,
            webhookId: map['webhook_id'] as String?,
            content: (map['content'] as String?) ?? '',
            timestamp: DateTime.parse(map['timestamp'] as String),
            editedTimestamp: map['edited_timestamp'] != null
                ? DateTime.tryParse(map['edited_timestamp'] as String)
                : null,
            embeds:
                (map['embeds'] as List<dynamic>?)
                    ?.map((e) => Embed.fromJson(e as Map<String, dynamic>))
                    .toList() ??
                const [],
            attachments:
                (map['attachments'] as List<dynamic>?)
                    ?.map((e) => Attachment.fromJson(e as Map<String, dynamic>))
                    .toList() ??
                const [],
            stickers:
                (map['stickers'] as List<dynamic>?)
                    ?.map(
                      (e) => MessageSticker.fromJson(e as Map<String, dynamic>),
                    )
                    .toList() ??
                const [],
            replyToId:
                (map['message_reference']
                        as Map<String, dynamic>?)?['message_id']
                    as String?,
            messageReference: map['message_reference'] != null
                ? MessageReference.fromJson(
                    map['message_reference'] as Map<String, dynamic>,
                  )
                : null,
            messageSnapshots:
                (map['message_snapshots'] as List<dynamic>?)
                    ?.map(
                      (e) =>
                          MessageSnapshot.fromJson(e as Map<String, dynamic>),
                    )
                    .toList() ??
                const [],
            isPinned: (map['pinned'] as bool?) ?? false,
            isMentioned: messageMentionsUser(
              mentionCtx,
              authorId: author['id'] as String,
              mentionedUserIds: _mentionedUserIdsFromJson(map),
              mentionEveryone: (map['mention_everyone'] as bool?) ?? false,
              mentionRoleIds:
                  (map['mention_roles'] as List<dynamic>?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  const [],
            ),
            mentionedUserIds: _mentionedUserIdsFromJson(map),
            type: (map['type'] as int?) ?? 0,
            flags: (map['flags'] as int?) ?? 0,
          ),
        );
        messages[messages.length - 1] = await _decryptRawIncoming(
          messages.last,
          senderUserId: author['id'] as String,
          encryptedPayload: map['encrypted_payload'],
        );

        final String? webhookId = map['webhook_id'] as String?;
        if (webhookId == null) {
          final authorId = author['id'] as String;
          await _db.userDao.upsertUser(
            db.UsersCompanion.insert(
              id: authorId,
              username: (author['username'] as String?) ?? '',
              memberSince: Value(dateTimeFromUserSnowflakeOrNull(authorId)),
            ),
          );
          await upsertMentionUsersFromJson(
            _db,
            map['mentions'] as List<dynamic>?,
          );
        }
      } on Object catch (e) {
        talker.warning('[MessageRepo] Skipping message: $e');
      }
    }

    if (messages.isNotEmpty) {
      await _db.messageDao.upsertMessages(
        messages.map((m) => m.toCompanion()).toList(),
      );
      await _pruneStaleMessagesForNetworkPage(channelId, messages);

      final last = messages.last;
      await _db.dmChannelDao.updateLastMessage(
        channelId,
        last.id,
        last.content,
        last.authorId,
        last.timestamp,
      );
    }

    if (messages.any((m) => m.isMentioned)) {
      await ReadStateRepository(_client, _db).recomputeMentionsAfterBackfill(
        channelId: channelId,
        currentUserId: _currentUserId,
      );
    }

    return messages;
  }

  Future<void> _pruneStaleMessagesForNetworkPage(
    String channelId,
    List<Message> networkPage,
  ) async {
    if (networkPage.isEmpty) {
      return;
    }
    final DateTime oldest = networkPage.first.timestamp;
    final DateTime newest = networkPage.last.timestamp;
    final List<db.Message> localRows = await _db.messageDao
        .getMessagesInTimestampRange(channelId, oldest, newest);
    final List<String> staleIds = networkPageStaleLocalIds(
      localMessageIds: localRows.map((db.Message row) => row.id),
      networkPage: networkPage,
    );
    await _db.messageDao.deleteMessages(staleIds);
  }

  List<String> _mentionedUserIdsFromJson(Map<String, dynamic> map) {
    final mentions = map['mentions'] as List<dynamic>?;
    if (mentions == null) {
      return const [];
    }
    return [
      for (final mention in mentions)
        if (mention is Map<String, dynamic> && mention['id'] != null)
          mention['id'].toString(),
    ];
  }

  Future<void> addReaction({
    required String channelId,
    required String messageId,
    required String emoji,
  }) async {
    await _client.channels.addReaction(
      channelId: channelId,
      messageId: messageId,
      emoji: emoji,
    );
  }

  Future<void> removeReaction({
    required String channelId,
    required String messageId,
    required String emoji,
  }) async {
    await _client.channels.removeOwnReaction(
      channelId: channelId,
      messageId: messageId,
      emoji: emoji,
    );
  }

  Future<void> removeAllReactions({
    required String channelId,
    required String messageId,
  }) async {
    await _client.channels.removeAllReactions(
      channelId: channelId,
      messageId: messageId,
    );
  }

  Future<Message> sendMessage({
    required String channelId,
    required String content,
    String? replyToId,
    bool replyMention = true,
    String? clientNonce,
    List<String> stickerIds = const [],
    String? favoriteMemeId,
    List<ApiAttachmentMetadata>? attachmentMetadata,
    List<XFile>? attachmentFiles,
    List<Map<String, Object?>>? encryptedAttachmentEntries,
    int? messageFlags,
    bool tts = false,
  }) async {
    try {
      final Map<String, dynamic> body = buildMessageCreateBody(
        content: content,
        replyToId: replyToId,
        replyMention: replyMention,
        clientNonce: clientNonce,
        stickerIds: stickerIds,
        favoriteMemeId: favoriteMemeId,
        attachments: attachmentMetadata,
        messageFlags: messageFlags,
        tts: tts,
      );

      final bool encrypted = await _maybeEncryptBody(
        channelId: channelId,
        content: content,
        clientNonce: clientNonce,
        body: body,
        attachments: encryptedAttachmentEntries ?? const [],
      );

      if (attachmentFiles != null && attachmentFiles.isNotEmpty) {
        final FormData formData = FormData();
        formData.fields.add(MapEntry('payload_json', jsonEncode(body)));
        for (var i = 0; i < attachmentFiles.length; i++) {
          final XFile x = attachmentFiles[i];
          formData.files.add(
            MapEntry(
              'files[$i]',
              await MultipartFile.fromFile(x.path, filename: x.name),
            ),
          );
        }
        final Response<Map<String, dynamic>> response = await _dio
            .post<Map<String, dynamic>>(
              '/channels/$channelId/messages',
              data: formData,
              options: Options(
                contentType: 'multipart/form-data',
                sendTimeout: const Duration(minutes: 30),
                receiveTimeout: const Duration(minutes: 5),
              ),
            );
        final Map<String, dynamic>? data = response.data;
        if (data == null) {
          throw Exception('Empty response from sendMessage');
        }
        final MessageResponseSchema schema = MessageResponseSchema.fromJson(
          data,
        );
        Message message = Message.fromSdk(
          schema,
          currentUserId: _currentUserId,
        ).copyWith(isMentioned: false);
        if (encrypted) {
          // The server echoes empty content for an encrypted message; reapply
          // the plaintext so our own just-sent message renders the text, not the
          // lock placeholder, and the persisted row matches the gateway echo.
          message = message.copyWith(content: content);
          _e2ee.recordSentPlaintext(
            text: content,
            messageId: message.id,
            nonce: clientNonce,
            channelId: channelId,
            attachments: encryptedAttachmentEntries ?? const [],
          );
        }
        await _db.messageDao.upsertMessage(message.toCompanion());
        return message;
      }

      final Message sent = await _postMessage(
        channelId,
        body,
        plaintextOverride: encrypted ? content : null,
      );
      if (encrypted) {
        _e2ee.recordSentPlaintext(
          text: content,
          messageId: sent.id,
          nonce: clientNonce,
          channelId: channelId,
          attachments: encryptedAttachmentEntries ?? const [],
        );
      }
      return sent;
    } on DioException {
      rethrow;
    }
  }

  /// Bootstrap the E2EE identity once before decrypting a history page, but
  /// only when the page actually contains an encrypted message.
  Future<void> _ensureE2eeReadyForPage(
    List<MessageResponseSchema> data,
  ) async {
    final String? userId = _currentUserId;
    if (userId == null) {
      return;
    }
    final bool anyEncrypted = data.any(
      (MessageResponseSchema sdk) => sdk.encryptedPayload != null,
    );
    if (!anyEncrypted) {
      return;
    }
    try {
      await _e2ee.ensureBootstrapped(userId);
    } on Object {
      // Proceed; decrypt returns transient if still not ready.
    }
  }

  /// Decrypt an inbound message from REST history. On success the plaintext
  /// replaces the empty server content; otherwise the message is returned
  /// unchanged (the manager's plaintext cache keeps a message decrypted once it
  /// has been read live, so re-renders stay consistent).
  Future<Message> _decryptIncoming(Message msg, MessageResponseSchema sdk) =>
      _decryptRawIncoming(
        msg,
        senderUserId: sdk.author.id,
        encryptedPayload: sdk.encryptedPayload,
      );

  Future<Message> _decryptRawIncoming(
    Message msg, {
    required String senderUserId,
    required Object? encryptedPayload,
  }) async {
    if ((msg.flags & kMessageFlagEncrypted) == 0 || encryptedPayload == null) {
      return msg;
    }
    final DecryptionOutcome outcome = await _e2ee.tryDecryptForCurrentDevice(
      senderUserId: senderUserId,
      encryptedPayloadRaw: encryptedPayload,
      channelId: msg.channelId,
      messageId: msg.id,
      nonce: msg.clientNonce,
    );
    if (outcome is DecryptionOk) {
      return msg.copyWith(content: outcome.text);
    }
    return msg;
  }

  /// Encrypt [body] in place for an E2EE DM/Group-DM channel: replaces the
  /// plaintext content with an `encrypted_payload` and sets the ENCRYPTED flag.
  /// Returns true when the body was encrypted (so the caller records the sent
  /// plaintext for its own echo). Falls back to plaintext (returns false) for
  /// non-encrypted channels, or when the manager isn't ready / has no reachable
  /// recipient device — the same safe degrade the web/RN clients use.
  Future<bool> _maybeEncryptBody({
    required String channelId,
    required String content,
    required String? clientNonce,
    required Map<String, dynamic> body,
    List<Map<String, Object?>> attachments = const [],
  }) async {
    final String? userId = _currentUserId;
    if (userId == null) {
      return false;
    }
    final db.DmChannel? dm = await _db.dmChannelDao.getDmChannelById(channelId);
    if (dm == null || !isEncryptedChannelType(dm.type)) {
      return false;
    }
    // Ensure the identity is ready before deciding to encrypt, so a send that
    // races startup doesn't fail to encrypt an E2EE DM.
    try {
      await _e2ee.ensureBootstrapped(userId);
    } on Object {
      // Bootstrap failed; handled by the fail-closed check below.
    }

    final List<String> recipients = <String>[];
    try {
      final Object? decoded = jsonDecode(dm.recipientIds);
      if (decoded is List) {
        for (final Object? e in decoded) {
          final String s = e.toString();
          if (s.isNotEmpty) {
            recipients.add(s);
          }
        }
      }
    } on Object {
      // Malformed recipient list → manager gets an empty set and returns null.
    }

    final Map<String, Object?>? payload = await _e2ee.tryEncryptForChannel(
      channelId: channelId,
      channelType: dm.type,
      recipientUserIds: recipients,
      plaintext: content,
      attachments: attachments,
    );
    if (payload == null) {
      // FAIL CLOSED: this is an always-on-E2EE channel but we could not produce
      // an encrypted payload (Group DM Megolm isn't implemented yet, or the
      // identity isn't ready / the recipient has no device). Never fall back to
      // plaintext on an encrypted channel — refuse the send so the UI surfaces a
      // failure instead of leaking cleartext.
      throw E2eeEncryptionUnavailableException(dm.type);
    }
    body.remove('content');
    body['flags'] = ((body['flags'] as int?) ?? 0) | kMessageFlagEncrypted;
    body['encrypted_payload'] = payload;
    // Pre-id echo cache (before the server assigns a message id).
    _e2ee.recordSentPlaintext(
      text: content,
      nonce: clientNonce,
      channelId: channelId,
      attachments: attachments,
    );
    return true;
  }

  Future<Message> _postMessage(
    String channelId,
    Map<String, dynamic> body, {
    String? plaintextOverride,
  }) async {
    final Response<Map<String, dynamic>> response = await _dio
        .post<Map<String, dynamic>>(
          '/channels/$channelId/messages',
          data: body,
          options: Options(
            sendTimeout: const Duration(minutes: 5),
            receiveTimeout: const Duration(minutes: 2),
          ),
        );
    final Map<String, dynamic>? data = response.data;
    if (data == null) {
      throw Exception('Empty response from sendMessage');
    }
    final MessageResponseSchema schema = MessageResponseSchema.fromJson(data);
    Message message = Message.fromSdk(
      schema,
      currentUserId: _currentUserId,
    ).copyWith(isMentioned: false);
    if (plaintextOverride != null) {
      // Reapply our own plaintext over the server's empty encrypted echo.
      message = message.copyWith(content: plaintextOverride);
    }
    await _db.messageDao.upsertMessage(message.toCompanion());
    return message;
  }

  /// Forwards [sourceMessageId] from [sourceChannelId] to each channel in
  /// [destinationChannelIds]. When [comment] is non-empty a separate message is
  /// sent after each forward so it renders below the forwarded snapshot. Sends
  /// are sequential per destination (matching the web client) and throw on the
  /// first failed request.
  Future<void> forwardMessage({
    required String sourceChannelId,
    required String sourceMessageId,
    required List<String> destinationChannelIds,
    String? sourceGuildId,
    List<String>? attachmentIds,
    List<int>? embedIndices,
    String? comment,
  }) async {
    final String? trimmedComment = comment?.trim();
    final bool hasComment = trimmedComment != null && trimmedComment.isNotEmpty;
    // A forward posts a server-assembled snapshot of the source message plus an
    // optional comment, neither of which is E2EE-encrypted. Forwarding into an
    // always-on-E2EE channel would leak cleartext, so refuse it up front (before
    // sending to any destination) rather than partially leaking.
    for (final String destinationId in destinationChannelIds) {
      final db.DmChannel? dm = await _db.dmChannelDao.getDmChannelById(
        destinationId,
      );
      if (dm != null && isEncryptedChannelType(dm.type)) {
        throw E2eeEncryptionUnavailableException(dm.type);
      }
    }
    try {
      for (final String destinationId in destinationChannelIds) {
        await _postMessage(
          destinationId,
          buildForwardMessageBody(
            sourceChannelId: sourceChannelId,
            sourceMessageId: sourceMessageId,
            sourceGuildId: sourceGuildId,
            attachmentIds: attachmentIds,
            embedIndices: embedIndices,
            clientNonce: clientNonceGenerator.next(),
          ),
        );
        if (hasComment) {
          await _postMessage(
            destinationId,
            buildMessageCreateBody(
              content: comment!,
              clientNonce: clientNonceGenerator.next(),
            ),
          );
        }
      }
    } on DioException catch (e) {
      throw Exception(dioExceptionMessage(e, 'Failed to forward message'));
    }
  }

  Future<Message> editMessage({
    required String channelId,
    required String messageId,
    required String content,
  }) async {
    try {
      final MessageResponseSchema schema = await _client.channels.editMessage(
        channelId: channelId,
        messageId: messageId,
        content: content,
      );
      final Message message = Message.fromSdk(
        schema,
        currentUserId: _currentUserId,
      ).copyWith(isMentioned: false);
      await _db.messageDao.upsertMessage(message.toCompanion());
      return message;
    } on DioException catch (e) {
      throw Exception(dioExceptionMessage(e, 'Failed to edit message'));
    }
  }

  Future<Message> setMessageFlags({
    required String channelId,
    required String messageId,
    required int flags,
  }) async {
    try {
      final MessageResponseSchema schema = await _client.channels.editMessage(
        channelId: channelId,
        messageId: messageId,
        flags: flags,
      );
      final Message message = Message.fromSdk(
        schema,
        currentUserId: _currentUserId,
      ).copyWith(isMentioned: false);
      await _db.messageDao.upsertMessage(message.toCompanion());
      return message;
    } on DioException catch (e) {
      throw Exception(
        e.response?.statusMessage ?? 'Failed to update message flags',
      );
    }
  }

  Future<int> purgePersonalNotesMessages(String channelId) async {
    try {
      final response = await _client.channels.purgePersonalNotesMessages(
        channelId: channelId,
      );
      await _db.messageDao.deleteMessagesForChannel(channelId);
      return response.deletedCount;
    } on DioException catch (e) {
      throw Exception(
        e.response?.statusMessage ?? 'Failed to purge personal notes',
      );
    }
  }

  Future<void> deleteMessage({
    required String channelId,
    required String messageId,
  }) async {
    try {
      await _client.channels.deleteMessage(
        channelId: channelId,
        messageId: messageId,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return;
      }
      throw Exception(e.response?.statusMessage ?? 'Failed to delete message');
    }
  }
}
