// ui/settings/feedback_dialog.dart
//
// "Send feedback" form — an optional name plus a message, posted to Supabase by
// FeedbackService. Styled to match update_dialog.dart (Gravity's dark palette,
// AppRadius.xl corners, accent-tinted leading icon).
//
// Leaving the name blank is a first-class choice, not an edge case: the field
// says so, and the service stores NULL for it.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../services/cloud/feedback_service.dart';
import '../app_theme.dart';

/// Shows the feedback form. Not barrier-dismissible while sending, so a tap
/// outside can't discard a message mid-flight.
void showFeedbackDialog() {
  Get.dialog(const FeedbackDialogBody(), barrierColor: Colors.black54);
}

/// The dialog itself. Public only so widget tests can pump it directly —
/// callers should use [showFeedbackDialog].
@visibleForTesting
class FeedbackDialogBody extends StatefulWidget {
  const FeedbackDialogBody({super.key});

  @override
  State<FeedbackDialogBody> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialogBody> {
  final _name = TextEditingController();
  final _message = TextEditingController();
  final _messageFocus = FocusNode();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _message.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await FeedbackService.submit(name: _name.text, message: _message.text);
      if (!mounted) return;
      Get.back();
      Get.snackbar('Thanks!', 'Your feedback has been sent.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.card,
          colorText: AppColors.white,
          duration: const Duration(seconds: 3));
    } on FeedbackException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl)),
      // Do NOT add MediaQuery.viewInsets here: Dialog already computes
      // `viewInsets + insetPadding` internally, so adding the keyboard height
      // again subtracts it twice and squashes the dialog to a sliver.
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          // Header and actions are pinned; only the fields scroll when the
          // keyboard leaves too little room, so Send stays reachable without
          // scrolling the form.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(Icons.forum_rounded,
                        color: AppColors.accent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Send feedback', style: AppText.title(size: 18)),
                        const SizedBox(height: 2),
                        Text('Ideas, bugs, anything at all',
                            style: AppText.subtitle()),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Field(
                        controller: _name,
                        enabled: !_sending,
                        hint: 'Name (optional)',
                        maxLength: FeedbackService.maxNameLength,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _messageFocus.requestFocus(),
                      ),
                      const SizedBox(height: 12),
                      _Field(
                        controller: _message,
                        focusNode: _messageFocus,
                        enabled: !_sending,
                        hint: 'What would you like to tell us?',
                        maxLength: FeedbackService.maxMessageLength,
                        maxLines: 5,
                        minLines: 3,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Sent with your app version and platform so we can look '
                        'into it. Nothing about what you listen to is included.',
                        style: AppText.caption(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.error_outline_rounded,
                                color: AppColors.accent, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!,
                                  style: AppText.subtitle(
                                      color: AppColors.accent)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _sending ? null : () => Get.back(),
                    child: Text('Cancel',
                        style:
                            AppText.button(color: AppColors.textSecondaryHi)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending ? null : _send,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      disabledBackgroundColor: AppColors.elevated,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 12),
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppColors.white))
                        : Text('Send',
                            style: AppText.button(color: AppColors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final int maxLength;
  final int maxLines;
  final int? minLines;
  final bool enabled;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const _Field({
    required this.controller,
    required this.hint,
    required this.maxLength,
    this.focusNode,
    this.maxLines = 1,
    this.minLines,
    this.enabled = true,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      maxLines: maxLines,
      minLines: minLines,
      maxLength: maxLength,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: AppText.title(size: 15),
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppText.subtitle(color: AppColors.textTertiary),
        counterText: '', // length is a guard rail, not a writing prompt
        filled: true,
        fillColor: AppColors.glassFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.accent),
        ),
      ),
    );
  }
}
