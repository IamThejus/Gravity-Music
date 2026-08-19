// services/cloud/feedback_service.dart
//
// Sends user feedback to Supabase. Deliberately account-free: feedback works
// whether or not the user has ever signed in, so it writes to `public.feedback`
// (insert-only for the anon role, rate-limited per install — see
// supabase/schema.sql) rather than to the auth.uid()-scoped sync tables.
//
// ── What gets sent ─────────────────────────────────────────────────────────
// Only what the user typed, plus the minimum needed to act on it:
//
//   • name          — exactly what they typed, or NULL if left blank
//   • message       — exactly what they typed
//   • installation_id — the anonymous per-install UUID (see installation_id.dart)
//   • app_version, platform — so a bug report can be tied to a build
//
// Nothing is collected implicitly: no listening history, no video IDs, no
// stream URLs (those carry the user's IP), no logs, no account identifiers.
// This is an ALLOWLIST by construction — the payload below is built field by
// field, so nothing can leak in by being added to some shared context object.
// Keep it that way.

import 'dart:io' show Platform;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../util/log.dart';
import '../installation_id.dart';
import 'auth_service.dart';
import 'supabase_config.dart';

/// Thrown with a message that is safe to show the user as-is.
class FeedbackException implements Exception {
  final String message;
  const FeedbackException(this.message);
  @override
  String toString() => message;
}

class FeedbackService {
  FeedbackService._();

  /// Max message length — mirrors the CHECK constraint in schema.sql so the
  /// user is told locally instead of getting a database error.
  static const int maxMessageLength = 4000;
  static const int maxNameLength = 80;

  /// True when feedback can be submitted at all. False keeps the entry point
  /// hidden rather than showing a form that cannot work.
  static bool get isAvailable =>
      SupabaseConfig.isConfigured && AuthService.instance.isReady;

  /// Submit [message], optionally attributed to [name].
  ///
  /// A blank [name] is stored as SQL NULL, not the string "Anonymous" — the
  /// display wording belongs to whoever reads the table, and NULL keeps "chose
  /// not to say" distinguishable from someone actually called Anonymous.
  static Future<void> submit({String? name, required String message}) async {
    final trimmedMessage = message.trim();
    if (trimmedMessage.isEmpty) {
      throw const FeedbackException('Please write a message first.');
    }
    if (trimmedMessage.length > maxMessageLength) {
      throw const FeedbackException(
          'That message is too long — please shorten it.');
    }
    if (!isAvailable) {
      throw const FeedbackException(
          'Feedback needs a connection to the Gravity server. Try again later.');
    }

    final trimmedName = name?.trim();

    try {
      await Supabase.instance.client.from('feedback').insert({
        'installation_id': installationId(),
        'name': (trimmedName == null || trimmedName.isEmpty)
            ? null
            : trimmedName.substring(
                0, trimmedName.length.clamp(0, maxNameLength)),
        'message': trimmedMessage,
        'app_version': await _appVersion(),
        'platform': Platform.operatingSystem,
      });
      logD('feedback', 'submitted (${trimmedMessage.length} chars, '
          'named=${trimmedName != null && trimmedName.isNotEmpty})');
    } on PostgrestException catch (e) {
      logD('feedback', 'submit failed — ${e.code}: ${e.message}');
      // The rate-limit trigger and the message CHECK constraint BOTH raise
      // SQLSTATE 23514, so match on the trigger's distinctive text rather than
      // the code — otherwise a constraint failure would be reported as a rate
      // limit. (Blank/over-long messages are already caught client-side above,
      // so reaching the constraint means a bug worth reporting honestly.)
      if (e.message.toLowerCase().contains('rate limit')) {
        throw const FeedbackException(
            "You've sent a few messages already — please try again later.");
      }
      throw const FeedbackException(
          "Couldn't send your feedback. Please try again.");
    } catch (e) {
      logD('feedback', 'submit failed — ${e.runtimeType}: $e');
      throw const FeedbackException(
          "Couldn't send your feedback. Check your connection and try again.");
    }
  }

  static String? _versionCache;
  static Future<String> _appVersion() async =>
      _versionCache ??= (await PackageInfo.fromPlatform()).version;
}
