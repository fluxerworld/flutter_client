import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:fluxer_app/core/theme/fluxer_color_theme.dart';
import 'package:fluxer_app/core/theme/fluxer_theme_extension.dart';
import 'package:fluxer_app/e2ee/e2ee_manager.dart';
import 'package:fluxer_app/e2ee/e2ee_provider.dart';
import 'package:fluxer_app/features/dm/domain/dm_conversation.dart';
import 'package:fluxer_app/features/settings/presentation/sheets/e2ee_fingerprint_sheet.dart';
import 'package:fluxer_app/features/ui/bottom_sheet/fluxer_bottom_sheet.dart';
import 'package:fluxer_app/l10n/generated/fluxer_localizations.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Group-DM verification router, mirroring the web E2EEGroupFingerprintModal:
/// lists the other members with an aggregate verified/partial/unverified badge;
/// tapping one opens the single-peer [E2eeFingerprintSheet] for that member
/// (the authoritative per-device verification UI).
class E2eeGroupFingerprintSheet extends ConsumerStatefulWidget {
  const E2eeGroupFingerprintSheet({required this.members, super.key});

  final List<GroupMemberInfo> members;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required List<GroupMemberInfo> members,
  }) {
    return FluxerBottomSheet.show<void>(
      context,
      title: FluxerLocalizations.of(context).e2eeVerifyGroupTitle,
      useRootNavigator: true,
      builder: (_, _) => E2eeGroupFingerprintSheet(members: members),
    );
  }

  @override
  ConsumerState<E2eeGroupFingerprintSheet> createState() =>
      _E2eeGroupFingerprintSheetState();
}

class _E2eeGroupFingerprintSheetState
    extends ConsumerState<E2eeGroupFingerprintSheet> {
  bool _loading = true;
  List<GroupMemberInfo> _others = const [];
  Map<String, E2eePeerVerification> _statuses = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ownId = ref.read(currentUserIdProvider);
    final others =
        widget.members.where((m) => m.id != ownId).toList(growable: false);
    final manager = ref.read(e2eeManagerProvider);
    final entries = await Future.wait(others.map((m) async {
      try {
        return MapEntry(m.id, await manager.peerVerificationStatus(m.id));
      } on Object {
        return MapEntry(m.id, E2eePeerVerification.unverified);
      }
    }));
    if (!mounted) {
      return;
    }
    setState(() {
      _others = others;
      _statuses = Map<String, E2eePeerVerification>.fromEntries(entries);
      _loading = false;
    });
  }

  Future<void> _openMember(GroupMemberInfo member) async {
    await E2eeFingerprintSheet.show(
      context,
      ref,
      recipientUserId: member.id,
      recipientName: member.name,
    );
    // The member may have (un)verified devices — refresh the aggregate badges.
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final layout = context.layout;
    final l10n = FluxerLocalizations.of(context);

    return Padding(
      padding: EdgeInsets.all(layout.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.e2eeVerifyGroupDescription,
            style: TextStyle(fontSize: 14, color: colors.textPrimaryMuted),
          ),
          SizedBox(height: layout.s4),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_others.isEmpty)
            Text(
              l10n.e2eeVerifyGroupNoMembers,
              style: TextStyle(fontSize: 13, color: colors.textTertiary),
            )
          else
            for (final member in _others)
              Padding(
                padding: EdgeInsets.only(bottom: layout.s2),
                child: _memberRow(member, colors, l10n),
              ),
        ],
      ),
    );
  }

  Widget _memberRow(
    GroupMemberInfo member,
    FluxerColorTheme colors,
    FluxerLocalizations l10n,
  ) {
    final status = _statuses[member.id] ?? E2eePeerVerification.unverified;
    final (IconData icon, Color color, String label) = switch (status) {
      E2eePeerVerification.verified => (
          PhosphorIconsBold.shieldCheck,
          colors.textPositive,
          l10n.e2eeVerifyStatusVerified,
        ),
      E2eePeerVerification.partial => (
          PhosphorIconsBold.shieldWarning,
          colors.statusWarning,
          l10n.e2eeVerifyGroupPartial,
        ),
      E2eePeerVerification.unverified => (
          PhosphorIconsBold.shield,
          colors.textTertiary,
          l10n.e2eeVerifyStatusUnverified,
        ),
    };
    return Material(
      color: colors.backgroundSecondary,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => unawaited(_openMember(member)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              PhosphorIcon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      member.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      label,
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  ],
                ),
              ),
              Text(
                l10n.e2eeVerifyGroupReview,
                style: TextStyle(fontSize: 12, color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
