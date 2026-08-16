// services/system_settings.dart
//
// Thin Dart side of the `com.saragama/system_settings` MethodChannel (handled
// in MainActivity.kt) for opening Android system settings screens we cannot
// change ourselves.
//
// Currently one use: mono audio. Android provides it globally under
// Accessibility, and toggling it programmatically needs WRITE_SECURE_SETTINGS
// — a signature permission only grantable over adb — so the honest thing an
// app can do is take the user there. Desktop applies mono in-app instead
// (see AudioEffects.isMonoSupported), so nothing here runs off Android.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../util/log.dart';

class SystemSettings {
  static const _channel = MethodChannel('com.saragama/system_settings');

  /// Open Android's Accessibility settings, where the system-wide "Mono
  /// audio" switch lives. No-op off Android. Best-effort: a device without
  /// the screen simply does nothing rather than throwing at the caller.
  static Future<void> openAccessibility() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } catch (e) {
      logD('settings', 'openAccessibility failed: $e');
    }
  }
}
