import 'package:flutter_test/flutter_test.dart';
import 'package:fluxer_dart/export.dart';

// Regression: the fluxer.world server's mapUserToPrivateResponse does NOT emit
// has_verified_phone / premium_discriminator / premium_perks_disabled, and sends
// required_actions as null. The forked SDK marked all four required (non-null),
// so /users/@me failed to deserialize at startup:
//   "CheckedFromJsonException: Could not create 'UserPrivateResponse'. There is
//    a problem with 'has_verified_phone'".
// Fixture mirrors the real server emit set with those four absent/null.
Map<String, Object?> _serverShape() => <String, Object?>{
      'id': '1507',
      'username': 'xuruh',
      'discriminator': '0001',
      'global_name': null,
      'avatar': null,
      'avatar_color': null,
      'bot': false,
      'system': false,
      'flags': 0,
      'is_staff': false,
      'acls': <String>[],
      'traits': <String>[],
      'email': 'a@b.c',
      'email_bounced': false,
      'phone': null,
      'verified': true,
      'mfa_enabled': true,
      'nsfw_allowed': true,
      'premium_type': 0,
      'premium_will_cancel': false,
      'premium_badge_masked': false,
      'premium_badge_hidden': false,
      'premium_badge_timestamp_hidden': false,
      'premium_badge_sequence_hidden': false,
      'premium_purchase_disabled': false,
      'premium_enabled_override': false,
      'has_ever_purchased': false,
      'has_dismissed_premium_onboarding': false,
      'has_unread_gift_inventory': false,
      'unread_gift_inventory_count': 0,
      'required_actions': null, // server sends null
      // has_verified_phone / premium_discriminator / premium_perks_disabled: ABSENT
    };

void main() {
  test('parses the real /users/@me shape (4 fields absent/null)', () {
    final u = UserPrivateResponse.fromJson(_serverShape());
    expect(u.id, '1507');
    expect(u.username, 'xuruh');
    expect(u.hasVerifiedPhone, isNull);
    expect(u.premiumDiscriminator, isNull);
    expect(u.premiumPerksDisabled, isNull);
    expect(u.requiredActions, isNull);
  });
}
