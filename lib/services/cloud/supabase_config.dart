// services/cloud/supabase_config.dart
//
// Static config for the optional Supabase cloud-sync backend. Fill these in
// from your Supabase project (Dashboard → Project Settings → API) and your
// Google Cloud OAuth setup.
//
// The anon key is SAFE to ship in the app — Row Level Security (see
// supabase/schema.sql) is what protects user data, not key secrecy.
//
// While these are left blank the app stays fully offline: SupabaseService.init()
// is a no-op and no sign-in / sync is attempted.

class SupabaseConfig {
  /// Supabase Project URL, e.g. https://abcdefgh.supabase.co
  static const String url = String.fromEnvironment('SUPABASE_URL',
      defaultValue: 'https://gethkypfuewzuuvoidob.supabase.co');

  /// Supabase anon/public key.
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY',
      defaultValue:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdldGhreXBmdWV3enV1dm9pZG9iIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIyMjIwOTAsImV4cCI6MjA5Nzc5ODA5MH0.NupZCmCGVSSd5J9QjDZX43qUVm2A3iIXiO4_tFyCJ_0');

  /// Google Cloud **Web** OAuth client ID (NOT the Android one). Passed to
  /// google_sign_in as serverClientId so the returned idToken is minted for an
  /// audience Supabase accepts. Set this same ID in Supabase → Authentication →
  /// Providers → Google → "Client IDs".
  static const String googleWebClientId = String.fromEnvironment(
      'GOOGLE_WEB_CLIENT_ID',
      defaultValue:
          '239990968712-tmvi2ol4j20bo1d5ep3ptc7bt1stkst8.apps.googleusercontent.com');

  /// True only when the minimum config needed to talk to Supabase is present.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// True when Google sign-in can be attempted (needs the web client ID too).
  static bool get canGoogleSignIn => isConfigured && googleWebClientId.isNotEmpty;
}
