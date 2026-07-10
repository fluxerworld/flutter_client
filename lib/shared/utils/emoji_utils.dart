import 'package:fluxer_app/core/instance/instance_endpoints.dart';
import 'package:fluxer_app/shared/utils/emoji_registry.dart';

// Follow the instance's own static CDN (resolved from /.well-known/fluxer, with
// the Fluxerworld default in InstanceEndpoints) rather than hardcoding an
// upstream host. Our webroot serves the twemoji set under /emoji.
String get _kTwemojiCdn => '${InstanceEndpoints.staticCdn}/emoji';

const int kCustomEmojiFetchSize = 96;

/// Resolves a reaction or shortcode [emoji] value to Unicode surrogates.
String resolveUnicodeEmoji(String emoji) {
  final entry = EmojiRegistry.entryByName(emoji);
  if (entry != null) {
    return entry.surrogates;
  }
  final resolved = EmojiRegistry.resolveSync(emoji);
  if (resolved != null) {
    return resolved;
  }
  return emoji;
}

String emojiToCodePoints(String emoji) {
  final containsZwj = emoji.contains('\u200D');
  final processed = containsZwj ? emoji : emoji.replaceAll('\uFE0F', '');
  return processed.runes
      .map((r) => r.toRadixString(16).replaceAll(RegExp('^0+'), ''))
      .where((s) => s.isNotEmpty)
      .join('-');
}

String? getTwemojiUrl(String unicode) {
  final codePoints = emojiToCodePoints(unicode);
  if (codePoints.isEmpty) {
    return null;
  }
  return '$_kTwemojiCdn/$codePoints.svg';
}

String getCustomEmojiMarkdown({
  required String name,
  required String id,
  bool animated = false,
}) => '<${animated ? 'a' : ''}:$name:$id>';
