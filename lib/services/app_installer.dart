// services/app_installer.dart
//
// Dart side of the `com.saragama/installer` MethodChannel (handled in
// MainActivity.kt). Android-only: hands a downloaded APK to the system package
// installer and manages the Android 8+ "install unknown apps" permission.
// Every method is a safe no-op off Android.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class AppInstaller {
  static const _channel = MethodChannel('com.saragama/installer');

  /// Whether the OS currently allows this app to install packages. On Android
  /// 8+ the user must grant "install unknown apps" once.
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "install unknown apps" settings for this app so the user
  /// can grant permission, then return and retry.
  static Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openInstallPermissionSettings');
    } catch (_) {}
  }

  /// Launch the package installer for the APK at [path]. Throws a
  /// [PlatformException] if the installer can't be started.
  static Future<void> installApk(String path) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('installApk', {'path': path});
  }
}
