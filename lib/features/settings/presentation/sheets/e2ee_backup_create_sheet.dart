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

/// Minimum backup passphrase length, matching the web writer.
const int _kMinPassphrase = 8;

/// Create + upload an encrypted backup of this device's E2EE keys. Drives
/// [E2eeManager.buildAndUploadBackup].
class E2eeBackupCreateSheet extends ConsumerStatefulWidget {
  const E2eeBackupCreateSheet({super.key});

  static Future<void> show(BuildContext context, WidgetRef ref) {
    return FluxerBottomSheet.show<void>(
      context,
      title: FluxerLocalizations.of(context).e2eeBackupCreateTitle,
      useRootNavigator: true,
      builder: (_, _) => const E2eeBackupCreateSheet(),
    );
  }

  @override
  ConsumerState<E2eeBackupCreateSheet> createState() =>
      _E2eeBackupCreateSheetState();
}

class _E2eeBackupCreateSheetState extends ConsumerState<E2eeBackupCreateSheet> {
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _handleCreate() async {
    final l10n = FluxerLocalizations.of(context);
    final passphrase = _passphraseController.text;
    if (passphrase.length < _kMinPassphrase) {
      setState(() => _error = l10n.e2eeBackupTooShort);
      return;
    }
    if (passphrase != _confirmController.text) {
      setState(() => _error = l10n.e2eeBackupMismatch);
      return;
    }
    final manager = ref.read(e2eeManagerProvider);
    final userId = ref.read(currentUserIdProvider);
    if (userId == null || !manager.isReady) {
      setState(() => _error = l10n.e2eeBackupNotReady);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await manager.buildAndUploadBackup(userId: userId, passphrase: passphrase);
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = l10n.e2eeBackupCreateFailed;
      });
      return;
    }

    if (!mounted) {
      return;
    }
    ref.read(toastProvider.notifier).show(
          FluxerToast(
            message: l10n.e2eeBackupCreateSuccess,
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
            l10n.e2eeBackupCreateDescription,
            style: TextStyle(fontSize: 14, color: colors.textPrimaryMuted),
          ),
          SizedBox(height: layout.s4),
          FluxerInput(
            controller: _passphraseController,
            label: l10n.e2eeBackupPassphraseLabel,
            obscureText: true,
            autofocus: true,
            enabled: !_loading,
            errorText: _error,
          ),
          SizedBox(height: layout.s3),
          FluxerInput(
            controller: _confirmController,
            label: l10n.e2eeBackupConfirmLabel,
            obscureText: true,
            enabled: !_loading,
          ),
          SizedBox(height: layout.s4),
          FluxerButton.primary(
            onPressedAsync: _loading ? null : _handleCreate,
            label: l10n.e2eeBackupCreateButton,
            isLoading: _loading,
          ),
        ],
      ),
    );
  }
}
