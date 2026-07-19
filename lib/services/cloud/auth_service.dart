// services/cloud/auth_service.dart
//
// Optional cloud auth for sync. Wraps Supabase Auth + native Google sign-in.
//
// Offline-first: if SupabaseConfig isn't filled in, init() is a no-op and every
// method is a safe no-op / false — the app runs exactly as before with no
// account. Sign-in is OPT-IN; nothing here ever blocks startup or playback.
//
// Google sign-in uses the NATIVE google_sign_in flow (no browser redirect) on
// Android/iOS: get an idToken from Google, hand it to Supabase via
// signInWithIdToken. Desktop (Linux/Windows) is not supported by google_sign_in
// 7.x's authenticate(); a browser OAuth fallback can be added later.

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static bool _initialized = false;

  /// Initialize Supabase. Call once in main() before runApp. No-op (and leaves
  /// [isReady] false) when the project isn't configured yet.
  static Future<void> init() async {
    if (!SupabaseConfig.isConfigured) return;
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    _initialized = true;
  }

  /// True when Supabase was initialized (config present).
  bool get isReady => _initialized;

  SupabaseClient get _client => Supabase.instance.client;

  /// The signed-in user, or null when signed out / not configured.
  User? get currentUser => _initialized ? _client.auth.currentUser : null;
  bool get isSignedIn => currentUser != null;

  /// Emits on every sign-in / sign-out so the UI and SyncService can react.
  Stream<AuthState> get authStateChanges =>
      _initialized ? _client.auth.onAuthStateChange : const Stream.empty();

  /// Native Google sign-in → Supabase session. Returns the User on success.
  /// Throws [AuthException] with a friendly message on failure; the caller
  /// surfaces it (e.g. a snackbar). Returns null if the user cancels.
  Future<User?> signInWithGoogle() async {
    if (!_initialized) {
      throw const AuthException('Cloud sync is not configured.');
    }
    if (!SupabaseConfig.canGoogleSignIn) {
      throw const AuthException('Google sign-in is not configured.');
    }

    final google = GoogleSignIn.instance;
    if (!google.supportsAuthenticate()) {
      throw const AuthException(
          'Google sign-in isn\'t supported on this platform yet.');
    }

    await google.initialize(serverClientId: SupabaseConfig.googleWebClientId);

    final GoogleSignInAccount account;
    try {
      account = await google.authenticate(scopeHint: const ['email']);
    } on GoogleSignInException catch (e) {
      // Always log the raw failure — Android's Credential Manager reports a
      // CONFIG mismatch (unregistered SHA-1 for this package's OAuth client)
      // with the same `canceled` code it uses when the user dismisses the
      // sheet. Swallowing that silently made a broken signing key look like
      // "the button does nothing"; logcat now always shows the real reason.
      debugPrint('[auth] GoogleSignInException '
          'code=${e.code} description=${e.description}');
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      if (e.code == GoogleSignInExceptionCode.clientConfigurationError ||
          e.code == GoogleSignInExceptionCode.providerConfigurationError) {
        throw AuthException(
            'Google sign-in is misconfigured for this build — check that this '
            'app\'s signing SHA-1 is registered on the Android OAuth client. '
            '(${e.description ?? e.code})');
      }
      throw AuthException('Google sign-in failed: ${e.description ?? e.code}');
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      // Almost always the serverClientId isn't the *Web* client ID, or this
      // build's SHA-1 isn't on the Android OAuth client.
      throw const AuthException(
          'Google sign-in returned no ID token — the OAuth client for this '
          'build looks misconfigured (check the signing SHA-1 and that '
          'GOOGLE_WEB_CLIENT_ID is the Web client ID).');
    }

    final res = await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
    return res.user;
  }

  /// Sign out of both Supabase and Google.
  Future<void> signOut() async {
    if (!_initialized) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    await _client.auth.signOut();
  }
}
