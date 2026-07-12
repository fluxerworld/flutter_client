import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluxer_app/features/chat/service/composer_mention_controller.dart';
import 'package:fluxer_app/features/ui/input/inline_token_clipboard.dart';
import 'package:fluxer_app/features/ui/input/inline_token_text_editing_controller.dart';

class InlineTokenPasteFormatter extends TextInputFormatter {
  InlineTokenPasteFormatter({required this.controller});

  final InlineTokenTextEditingController controller;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text == oldValue.text) {
      return newValue;
    }
    final int replacedLength =
        oldValue.selection.end - oldValue.selection.start;
    final int insertedLength =
        newValue.text.length - oldValue.text.length + replacedLength;
    if (insertedLength <= 1) {
      return newValue;
    }
    // Don't treat a whole-word IME commit (which carries a live composing
    // region) as a paste; only clipboard/drop pastes have composing cleared.
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final String pastedText = extractInsertedText(oldValue, newValue);
    final String sanitized = stripPrivateUseCharacters(pastedText);
    if (sanitized.isEmpty) {
      return oldValue;
    }
    final String displayFragment = controller.wireToDisplayFragment(sanitized);
    final int start = oldValue.selection.start;
    final int end = oldValue.selection.end;
    final String newText = oldValue.text.replaceRange(
      start,
      end,
      displayFragment,
    );
    return oldValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start + displayFragment.length,
      ),
      composing: TextRange.empty,
    );
  }

  static String extractInsertedText(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final int start = oldValue.selection.start;
    final int end = oldValue.selection.end;
    final int tailStart =
        start + (newValue.text.length - oldValue.text.length + (end - start));
    if (start >= 0 && tailStart <= newValue.text.length && tailStart >= start) {
      return newValue.text.substring(start, tailStart);
    }
    return newValue.text;
  }
}

class ComposerMentionPasteFormatter extends TextInputFormatter {
  ComposerMentionPasteFormatter({required this.controller});

  final ComposerMentionController controller;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text == oldValue.text) {
      return newValue;
    }
    final int replacedLength =
        oldValue.selection.end - oldValue.selection.start;
    final int insertedLength =
        newValue.text.length - oldValue.text.length + replacedLength;
    if (insertedLength <= 1) {
      return newValue;
    }
    // A whole-word IME commit (glide typing, word prediction, autocorrect) also
    // arrives as insertedLength > 1, but carries a live composing region; only a
    // real clipboard/drop paste has composing cleared. Without this bail a typed
    // word is misclassified as a paste and the post-frame callback re-inserts it
    // -> "can can you you". Composing is the reliable discriminator.
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final String pastedText = InlineTokenPasteFormatter.extractInsertedText(
      oldValue,
      newValue,
    );
    final String sanitized = stripPrivateUseCharacters(pastedText);
    if (sanitized.isEmpty) {
      return oldValue;
    }
    final TextEditingValue pendingValue = newValue;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (controller.value != pendingValue) {
        return;
      }
      final int start = oldValue.selection.start;
      final int end = oldValue.selection.end;
      final String displayFragment = await controller
          .mentionWireToDisplayFragment(sanitized);
      if (displayFragment == sanitized) {
        // Nothing to chip (plain typed word that reached here with composing
        // already cleared — e.g. a prediction/autocorrect commit). Leave the
        // committed value untouched instead of re-inserting it. This is the
        // definitive guard against word-doubling.
        return;
      }
      final String newText = controller.text.replaceRange(
        start,
        end,
        displayFragment,
      );
      controller.value = oldValue.copyWith(
        text: newText,
        selection: TextSelection.collapsed(
          offset: start + displayFragment.length,
        ),
        composing: TextRange.empty,
      );
    });
    return newValue;
  }
}
