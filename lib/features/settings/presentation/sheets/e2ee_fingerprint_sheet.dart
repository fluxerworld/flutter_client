import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:fluxer_app/core/theme/fluxer_color_theme.dart';
import 'package:fluxer_app/core/theme/fluxer_layout_theme.dart';
import 'package:fluxer_app/core/theme/fluxer_theme_extension.dart';
import 'package:fluxer_app/e2ee/e2ee_api.dart';
import 'package:fluxer_app/e2ee/e2ee_key_store.dart';
import 'package:fluxer_app/e2ee/e2ee_manager.dart';
import 'package:fluxer_app/e2ee/e2ee_provider.dart';
import 'package:fluxer_app/features/ui/bottom_sheet/fluxer_bottom_sheet.dart';
import 'package:fluxer_app/features/ui/button/fluxer_button.dart';
import 'package:fluxer_app/features/ui/button/fluxer_button_size.dart';
import 'package:fluxer_app/l10n/generated/fluxer_localizations.dart';
import 'package:fluxer_app/shared/utils/relative_time.dart';

/// Manual device-verification (fingerprint comparison) for a peer, mirroring the
/// web E2EEFingerprintModal: shows your own device fingerprints (display-only)
/// and the peer's (verifiable — mark/clear), plus a reset-sessions escape hatch.
class E2eeFingerprintSheet extends ConsumerStatefulWidget {
  const E2eeFingerprintSheet({
    required this.recipientUserId,
    required this.recipientName,
    super.key,
  });

  final String recipientUserId;
  final String recipientName;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required String recipientUserId,
    required String recipientName,
  }) {
    return FluxerBottomSheet.show<void>(
      context,
      title: FluxerLocalizations.of(context).e2eeVerifyTitle,
      useRootNavigator: true,
      builder: (_, _) => E2eeFingerprintSheet(
        recipientUserId: recipientUserId,
        recipientName: recipientName,
      ),
    );
  }

  @override
  ConsumerState<E2eeFingerprintSheet> createState() =>
      _E2eeFingerprintSheetState();
}

class _E2eeFingerprintSheetState extends ConsumerState<E2eeFingerprintSheet> {
  bool _loading = true;
  bool _hasError = false;
  bool _notSignedIn = false;
  List<E2eeDeviceInfo> _ownDevices = const [];
  List<E2eeDeviceInfo> _peerDevices = const [];
  Map<String, StoredE2eeVerification> _verifications = const {};
  bool _resetting = false;
  bool _resetDone = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _hasError = false;
      _notSignedIn = false;
    });
    final ownId = ref.read(currentUserIdProvider);
    if (ownId == null) {
      setState(() {
        _loading = false;
        _notSignedIn = true;
      });
      return;
    }
    final manager = ref.read(e2eeManagerProvider);
    try {
      final own = await manager.fetchPublicDevices(ownId);
      final peer = await manager.fetchPublicDevices(widget.recipientUserId);
      final verifications =
          await manager.verificationsForUser(widget.recipientUserId);
      if (!mounted) {
        return;
      }
      setState(() {
        _ownDevices = own;
        _peerDevices = peer;
        _verifications = verifications;
        _loading = false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _refreshVerifications() async {
    final verifications =
        await ref.read(e2eeManagerProvider).verificationsForUser(
              widget.recipientUserId,
            );
    if (!mounted) {
      return;
    }
    setState(() => _verifications = verifications);
  }

  Future<void> _markVerified(E2eeDeviceInfo device) async {
    await ref.read(e2eeManagerProvider).markDeviceVerified(
          userId: widget.recipientUserId,
          deviceId: device.deviceId,
          identityKey: device.identityKey,
        );
    await _refreshVerifications();
  }

  Future<void> _clearVerification(E2eeDeviceInfo device) async {
    await ref.read(e2eeManagerProvider).clearDeviceVerification(
          userId: widget.recipientUserId,
          deviceId: device.deviceId,
        );
    await _refreshVerifications();
  }

  Future<void> _resetSessions() async {
    setState(() {
      _resetting = true;
      _resetDone = false;
    });
    try {
      await ref
          .read(e2eeManagerProvider)
          .resetSessionsForPeer(widget.recipientUserId);
      if (mounted) {
        setState(() => _resetDone = true);
      }
    } on Object {
      // Best-effort; leave the button available to retry.
    } finally {
      if (mounted) {
        setState(() => _resetting = false);
      }
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
            l10n.e2eeVerifyDescription(widget.recipientName),
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
          else if (_notSignedIn)
            Text(
              l10n.e2eeVerifyNotSignedIn,
              style: TextStyle(fontSize: 14, color: colors.statusDanger),
            )
          else if (_hasError) ...[
            Text(
              l10n.e2eeVerifyLoadError,
              style: TextStyle(fontSize: 14, color: colors.statusDanger),
            ),
            SizedBox(height: layout.s2),
            FluxerButton.secondary(
              onPressedAsync: _load,
              label: l10n.e2eeVerifyRetry,
              size: FluxerButtonSize.small,
              fitContent: true,
            ),
          ] else ...[
            _section(
              title: l10n.e2eeVerifyYourDevices,
              devices: _ownDevices,
              verifiable: false,
              colors: colors,
              layout: layout,
              l10n: l10n,
            ),
            SizedBox(height: layout.s4),
            _section(
              title: l10n.e2eeVerifyTheirDevices(widget.recipientName),
              devices: _peerDevices,
              verifiable: true,
              colors: colors,
              layout: layout,
              l10n: l10n,
            ),
            SizedBox(height: layout.s4),
            FluxerButton.dangerSecondary(
              onPressedAsync: _resetting ? null : _resetSessions,
              label: _resetDone
                  ? l10n.e2eeVerifyResetDone
                  : l10n.e2eeVerifyReset,
              isLoading: _resetting,
              size: FluxerButtonSize.small,
              fitContent: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required List<E2eeDeviceInfo> devices,
    required bool verifiable,
    required FluxerColorTheme colors,
    required FluxerLayoutTheme layout,
    required FluxerLocalizations l10n,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        SizedBox(height: layout.s2),
        if (devices.isEmpty)
          Text(
            l10n.e2eeVerifyNoDevices,
            style: TextStyle(fontSize: 13, color: colors.textTertiary),
          )
        else
          for (final device in devices)
            Padding(
              padding: EdgeInsets.only(bottom: layout.s2),
              child: _deviceRow(device, verifiable, colors, layout, l10n),
            ),
      ],
    );
  }

  Widget _deviceRow(
    E2eeDeviceInfo device,
    bool verifiable,
    FluxerColorTheme colors,
    FluxerLayoutTheme layout,
    FluxerLocalizations l10n,
  ) {
    final entry = verifiable ? _verifications[device.deviceId] : null;
    final status = verifiable
        ? e2eeDeviceVerificationStatus(entry, device.identityKey)
        : E2eeDeviceVerification.unverified;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.backgroundSecondary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  device.deviceName ?? l10n.e2eeVerifyUnnamedDevice,
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (verifiable) _statusBadge(status, colors, l10n),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            _formatFingerprint(device.identityKey),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: colors.textPrimaryMuted,
            ),
          ),
          if (verifiable &&
              status == E2eeDeviceVerification.verified &&
              entry != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.e2eeVerifyVerifiedAt(relativeTime(entry.verifiedAt, l10n)),
              style: TextStyle(fontSize: 12, color: colors.textTertiary),
            ),
          ],
          if (verifiable) ...[
            SizedBox(height: layout.s2),
            Row(
              children: [
                if (status != E2eeDeviceVerification.verified)
                  FluxerButton.primary(
                    onPressedAsync: () => _markVerified(device),
                    label: l10n.e2eeVerifyMarkVerified,
                    size: FluxerButtonSize.small,
                    fitContent: true,
                  ),
                if (status != E2eeDeviceVerification.unverified) ...[
                  const SizedBox(width: 8),
                  FluxerButton.secondary(
                    onPressedAsync: () => _clearVerification(device),
                    label: l10n.e2eeVerifyClear,
                    size: FluxerButtonSize.small,
                    fitContent: true,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBadge(
    E2eeDeviceVerification status,
    FluxerColorTheme colors,
    FluxerLocalizations l10n,
  ) {
    final (String label, Color color) = switch (status) {
      E2eeDeviceVerification.verified => (
          l10n.e2eeVerifyStatusVerified,
          colors.textPositive
        ),
      E2eeDeviceVerification.changed => (
          l10n.e2eeVerifyStatusChanged,
          colors.statusWarning
        ),
      E2eeDeviceVerification.unverified => (
          l10n.e2eeVerifyStatusUnverified,
          colors.textTertiary
        ),
    };
    return Text(
      label,
      style: TextStyle(fontSize: 12, color: color),
    );
  }

  String _formatFingerprint(String key) {
    final groups = <String>[];
    for (var i = 0; i < key.length; i += 4) {
      groups.add(key.substring(i, i + 4 > key.length ? key.length : i + 4));
    }
    return groups.join(' ');
  }
}
