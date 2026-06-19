// util/log.dart
//
// Lightweight verbose logging gated behind a single flag, used to trace the
// playback / stream-resolution pipeline when diagnosing issues.
//
// Enabled automatically in debug builds. In a release build, force it on with:
//   flutter run    --dart-define=GM_VERBOSE=true
//   flutter build  --dart-define=GM_VERBOSE=true
//
// Output format: `[GM/<tag>] <message>` on stdout (visible when the app is run
// from a terminal).

import 'package:flutter/foundation.dart';

/// Master verbose-logging switch. On in debug builds; overridable in release
/// via `--dart-define=GM_VERBOSE=true`.
const bool kVerboseLogging =
    bool.fromEnvironment('GM_VERBOSE', defaultValue: kDebugMode);

/// Logs `[GM/<tag>] <msg>` to stdout when [kVerboseLogging] is on; no-op
/// otherwise. [tag] groups related lines (e.g. 'url', 'engine', 'handler').
void logD(String tag, Object? msg) {
  if (kVerboseLogging) {
    // ignore: avoid_print
    print('[GM/$tag] $msg');
  }
}
