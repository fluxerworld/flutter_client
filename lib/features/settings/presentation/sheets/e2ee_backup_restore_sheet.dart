import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:fluxer_app/core/theme/fluxer_theme_extension.dart';
import 'package:fluxer_app/e2ee/e2ee_manager.dart';
import 'package:fluxer_app/e2ee/e2ee_provider.dart';
import 'package:fluxer_app/features/ui/bottom_sheet/fluxer_bottom_sheet.dart';
import 'package:fluxer_app/features/ui/button/fluxer_button.dart';
import 'package:fluxer_app/features/ui/input/fluxer_input.dart';
import 'package:fluxer_app/features/ui/toast/fluxer_toast.dart';
import 'package:fluxer_app/features/ui/toast/toast_provider.dart';
import 'package:fluxer_app/l10n/generated/fluxer_localizations.dart';

/// Restore end-to-end encryption keys from the passphrase-encrypted backup made
/// on another device (web/RN). Drives [E2eeManager.restoreFromBackup].
class E2eeBackupRestoreSheet extends ConsumerStatefulWidget {
  const E2eeBackupRestoreSheet({super.key});

  static Future<void> show(BuildContext context, WidgetRef ref) {
    return FluxerBottomSheet.show<void>(
      context,
      title: FluxerLocalizations.of(context).e2eeRestoreTitle,
      useRootNavigator: true,
      builder: (_, _) => const E2eeBackupRestoreSheet(),
    );
  }

  @override
  ConsumerState<E2eeBackupRestoreSheet> createState() =>
      _E2eeBackupRestoreSheetState();
}

class _E2eeBackupRestoreSheetState
    extends ConsumerState<E2eeBackupRestoreSheet> {
  final _passphraseController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  /// Map a restore outcome to a user-facing error string (null = success).
  String? _errorFor(E2eeRestoreOutcome outcome, FluxerLocalizations l10n) {
    switch (outcome) {
      case E2eeRestoreOutcome.ok:
        return null;
      case E2eeRestoreOutcome.wrongPassphrase:
        return l10n.e2eeRestoreWrongPassphrase;
      case E2eeRestoreOutcome.noBackup:
        return l10n.e2eeRestoreNoBackup;
      case E2eeRestoreOutcome.corruptBackup:
        return l10n.e2eeRestoreCorrupt;
      case E2eeRestoreOutcome.noAccount:
        return l10n.e2eeRestoreNoAccount;
      case E2eeRestoreOutcome.wrongUser:
        return l10n.e2eeRestoreWrongUser;
    }
  }

  Future<void> _handleRestore() async {
    final l10n = FluxerLocalizations.of(context);
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) {
      setState(() => _error = l10n.e2eeRestorePassphraseRequired);
      return;
    }
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      setState(() => _error = l10n.e2eeRestoreNotSignedIn);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    E2eeRestoreResult result;
    try {
      result = await ref.read(e2eeManagerProvider).restoreFromBackup(
            userId: userId,
            passphrase: passphrase,
          );
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = l10n.e2eeRestoreFailed;
      });
      return;
    }

    if (!mounted) {
      return;
    }
    final error = _errorFor(result.outcome, l10n);
    if (error != null) {
      setState(() {
        _loading = false;
        _error = error;
      });
      return;
    }

    ref.read(toastProvider.notifier).show(
          FluxerToast(
            message: l10n.e2eeRestoreSuccess,
            variant: FluxerToastVariant.success,
          ),
        );
    Navigator.of(context).pop();
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
            l10n.e2eeRestoreDescription,
            style: TextStyle(fontSize: 14, color: colors.textPrimaryMuted),
          ),
          SizedBox(height: layout.s4),
          FluxerInput(
            controller: _passphraseController,
            label: l10n.e2eeRestorePassphraseLabel,
            hint: l10n.e2eeRestorePassphraseHint,
            obscureText: true,
            autofocus: true,
            enabled: !_loading,
            errorText: _error,
          ),
          SizedBox(height: layout.s4),
          FluxerButton.primary(
            onPressedAsync: _loading ? null : _handleRestore,
            label: l10n.e2eeRestoreButton,
            isLoading: _loading,
          ),
        ],
      ),
    );
  }
}
