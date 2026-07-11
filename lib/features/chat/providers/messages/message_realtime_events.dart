import 'package:fluxer_dart/export.dart';
import 'package:fluxer_dart/gateway.dart';

class MessagePersistSnapshot {
  const MessagePersistSnapshot({
    required this.mentionsCurrentUser,
    required this.isDm,
    required this.guildStorageId,
    required this.acknowledgedByGateway,
    this.notificationLevel,
    this.decryptedContent,
  });

  final bool mentionsCurrentUser;
  final bool isDm;
  final String? guildStorageId;
  final bool acknowledgedByGateway;
  final UserNotificationSettings? notificationLevel;

  /// Decrypted plaintext for an E2EE message, or null when the message isn't
  /// encrypted (or couldn't be decrypted). The live view rebuilds its Message
  /// from the raw event, so it must prefer this over the empty event content.
  final String? decryptedContent;
}

class MessageCreateDispatch {
  const MessageCreateDispatch({required this.event, required this.snapshot});

  final MessageCreateEvent event;
  final MessagePersistSnapshot snapshot;
}

sealed class MessageRealtimeEvent {
  const MessageRealtimeEvent();
}

class MessageCreated extends MessageRealtimeEvent {
  const MessageCreated({required this.event, required this.snapshot});

  final MessageCreateEvent event;
  final MessagePersistSnapshot snapshot;
}

class MessageUpdated extends MessageRealtimeEvent {
  final MessageUpdateEvent event;

  /// Decrypted plaintext for an edited E2EE message (null when not encrypted or
  /// undecryptable) — the live view must prefer this over the empty edit body.
  final String? decryptedContent;

  const MessageUpdated(this.event, {this.decryptedContent});
}

class MessageDeleted extends MessageRealtimeEvent {
  final MessageDeleteEvent event;

  const MessageDeleted(this.event);
}

class MessagesDeletedBulk extends MessageRealtimeEvent {
  final MessageDeleteBulkEvent event;

  const MessagesDeletedBulk(this.event);
}

class MessageReactionsChanged extends MessageRealtimeEvent {
  final String channelId;
  final String messageId;

  const MessageReactionsChanged({
    required this.channelId,
    required this.messageId,
  });
}
