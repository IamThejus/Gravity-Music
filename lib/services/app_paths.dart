// services/app_paths.dart
//
// Single source of truth for the app's persistent-data base directory
// (Hive boxes, downloaded audio).
//
// On mobile we use the application documents directory — the app sandbox —
// to preserve the on-device data locations existing installs already use.
//
// On desktop, getApplicationDocumentsDirectory() resolves the user's
// ~/Documents folder by shelling out to `xdg-user-dir`, which (a) may not be
// installed and throws MissingPlatformDirectoryException, and (b) is the wrong
// place for application data. getApplicationSupportDirectory() returns the XDG
// data location (e.g. ~/.local/share/<app>) with no external tooling, so we
// use that on Linux/Windows/macOS.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ensure libmpv's on-disk cache directory exists (desktop only).
///
/// media_kit drives libmpv with `cache-on-disk=yes` hardcoded; its cache lives
/// in $XDG_CACHE_HOME/mpv (falling back to ~/.cache/mpv). The embedded libmpv
/// does not create this directory itself — when absent, mpv logs
/// "Failed to create file cache" and the following seek(0) fails, breaking
/// skip/auto-advance/loop. Creating it up front is idempotent and cheap.
void ensureMpvCacheDir() {
  final env = Platform.environment;
  final cacheHome = (env['XDG_CACHE_HOME']?.isNotEmpty ?? false)
      ? env['XDG_CACHE_HOME']!
      : '${env['HOME']}/.cache';
  final dir = Directory('$cacheHome/mpv');
  if (!dir.existsSync()) dir.createSync(recursive: true);
}

/// Base directory for app-persistent data, chosen per platform. The returned
/// directory is guaranteed to exist.
Future<Directory> appDataDirectory() async {
  final Directory dir;
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    dir = await getApplicationSupportDirectory();
  } else {
    dir = await getApplicationDocumentsDirectory();
  }
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}
