import 'package:flutter_test/flutter_test.dart';
import 'package:fluxer_dart/export.dart';

// Regression: the fluxer.world gateway READY payload diverges from the upstream
// SDK's required-field expectations. Before these fixes GuildCreateData.fromJson
// threw a CheckedFromJsonException while parsing the active guild, which the
// EventParser swallowed into an UnknownGatewayEvent — so onReady/setReady never
// fired and the app hung forever on the boot screen.
//
// Divergences captured from a live READY frame:
//   * guild members / relationships carry id-only user refs ({"id": "..."}),
//     with the full user in the top-level `users` array;
//   * GuildResponse omits `nsfw` and `content_warning_level`;
//   * GuildEmojiResponse omits `nsfw`;
//   * RelationshipResponse omits `user`, `share_voice_activity`,
//     `friend_shares_voice_activity`.
void main() {
  test('UserPartialResponse parses an id-only reference', () {
    final u = UserPartialResponse.fromJson(<String, Object?>{'id': '1478'});
    expect(u.id, '1478');
    expect(u.username, ''); // sentinel: callers skip persisting id-only refs
    expect(u.discriminator, '0');
    expect(u.flags, 0);
    expect(u.globalName, isNull);
    expect(u.avatar, isNull);
  });

  test('RelationshipResponse parses without an embedded user', () {
    final r = RelationshipResponse.fromJson(<String, Object?>{
      'id': '1479312669390548992',
      'type': 1,
      'since': '2026-03-06T03:02:41.989Z',
      'nickname': null,
    });
    expect(r.id, '1479312669390548992'); // == target user id
    expect(r.user, isNull);
    expect(r.shareVoiceActivity, false);
    expect(r.friendSharesVoiceActivity, false);
  });

  test('GuildEmojiResponse parses without nsfw', () {
    final e = GuildEmojiResponse.fromJson(<String, Object?>{
      'id': '1490273490665022407',
      'name': 'rules',
      'animated': false,
    });
    expect(e.nsfw, isNull);
  });

  test('GuildResponse parses without nsfw / content_warning_level', () {
    final g = GuildResponse.fromJson(<String, Object?>{
      'name': 'Admins',
      'afk_timeout': 300,
      'splash_card_alignment': 0,
      'id': '1479075661330083840',
      'owner_id': '1478435633637634048',
      'disabled_operations': 0,
      'nsfw_level': 0,
      'mfa_level': 0,
      'default_message_notifications': 0,
      'verification_level': 0,
      'features': <String>[],
      'system_channel_flags': 0,
      'explicit_content_filter': 0,
    });
    expect(g.name, 'Admins');
    expect(g.nsfw, false); // defaulted
    expect(g.contentWarningLevel, isNull);
  });
}
