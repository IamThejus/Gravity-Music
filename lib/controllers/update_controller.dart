// controllers/update_controller.dart
//
// GetX orchestration for the in-app updater. Single entry point for both the
// silent startup check and the manual "Check for updates" in Settings. Holds
// the reactive download state the update dialog binds to. Reuses UpdateService
// (GitHub), ApkDownloadService (streamed download), AppInstaller (native), and
// Hive AppPrefs (ignored version). No UI here — the dialog is shown via
// Get.dialog by callers / checkOnStartup.

import 'dart:async';

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../models/github_release.dart';
import '../services/apk_download_service.dart';
import '../services/app_installer.dart';
import '../services/update_service.dart';
import '../services/version_comparator.dart';
import '../ui/update/update_dialog.dart';

enum UpdatePhase { idle, downloading, needsPermission, error, done }

class UpdateController extends GetxController {
  static UpdateController get to => Get.find();

  /// The newer release found by the last check (null = none / up to date).
  final available = Rxn<GitHubRelease>();
  final currentVersion = ''.obs;

  /// Download / install lifecycle for the dialog to bind to.
  final phase = UpdatePhase.idle.obs;
  final progress = 0.0.obs; // 0..1
  final errorMessage = RxnString();

  bool _promptedThisLaunch = false;
  bool _cancelRequested = false;

  static const _ignoredKey = 'ignoredUpdateVersion';
  Box get _prefs => Hive.box('AppPrefs');

  // ── Checks ─────────────────────────────────────────────────────────────────

  /// Silent, non-blocking startup check. Shows the update dialog at most once
  /// per launch, only for a newer, non-ignored version, only on Android
  /// (in-app APK install is Android-only). All failures are swallowed.
  Future<void> checkOnStartup() async {
    if (_promptedThisLaunch || !GetPlatform.isAndroid) return;
    try {
      final rel = await _fetchIfNewer();
      if (rel == null) return;
      final ignored = _prefs.get(_ignoredKey) as String?;
      if (ignored != null &&
          VersionComparator.compare(rel.version, ignored) <= 0) {
        return; // user asked to skip this (or an older) version
      }
      _promptedThisLaunch = true;
      showUpdateDialog(rel);
    } catch (_) {
      // Startup check is best-effort — never surface an error here.
    }
  }

  /// Manual check (Settings). Returns the newer release, or null when already
  /// up to date. Throws [UpdateException] (friendly message) on failure so the
  /// caller can show it.
  Future<GitHubRelease?> checkManual() async {
    errorMessage.value = null;
    final rel = await _fetchIfNewer();
    return rel;
  }

  /// Fetch latest + compare with the installed version. Returns the release
  /// only when it's strictly newer AND ships an installable APK.
  Future<GitHubRelease?> _fetchIfNewer() async {
    currentVersion.value = await UpdateService.currentVersion();
    final rel = await UpdateService.fetchLatest();
    if (rel.apkAsset == null) {
      available.value = null;
      return null;
    }
    final newer = VersionComparator.isNewer(rel.version, currentVersion.value);
    available.value = newer ? rel : null;
    return available.value;
  }

  // ── Download + install ──────────────────────────────────────────────────────

  /// Download the release APK (reporting [progress]) and launch the installer.
  /// Drives [phase]/[errorMessage] for the dialog. Never throws.
  Future<void> downloadAndInstall(GitHubRelease rel) async {
    final asset = rel.apkAsset;
    if (asset == null) {
      phase.value = UpdatePhase.error;
      errorMessage.value = 'This release has no APK to install.';
      return;
    }

    _cancelRequested = false;
    errorMessage.value = null;
    progress.value = 0;
    phase.value = UpdatePhase.downloading;

    String path;
    try {
      path = await ApkDownloadService.download(
        asset.downloadUrl,
        fileName: asset.name,
        onProgress: (p) => progress.value = p,
        isCancelled: () => _cancelRequested,
      );
    } on ApkDownloadCancelled {
      phase.value = UpdatePhase.idle;
      return;
    } on UpdateException catch (e) {
      phase.value = UpdatePhase.error;
      errorMessage.value = e.message;
      return;
    } catch (_) {
      phase.value = UpdatePhase.error;
      errorMessage.value = 'Download failed. Please try again.';
      return;
    }

    // Android 8+ needs the one-time "install unknown apps" grant.
    if (!await AppInstaller.canInstall()) {
      phase.value = UpdatePhase.needsPermission;
      errorMessage.value =
          'Allow Gravity Music to install apps, then tap Update again.';
      _pendingApkPath = path;
      return;
    }

    await _launchInstaller(path);
  }

  String? _pendingApkPath;

  /// After the user returns from the permission screen, retry the install
  /// without re-downloading if we already have the APK.
  Future<void> retryInstall() async {
    final path = _pendingApkPath;
    if (path == null) return;
    if (!await AppInstaller.canInstall()) {
      errorMessage.value =
          'Still not allowed — enable "install unknown apps" for Gravity Music.';
      return;
    }
    await _launchInstaller(path);
  }

  Future<void> _launchInstaller(String path) async {
    try {
      await AppInstaller.installApk(path);
      phase.value = UpdatePhase.done; // system installer takes over
    } catch (_) {
      phase.value = UpdatePhase.error;
      errorMessage.value = 'Could not start the installer.';
    }
  }

  Future<void> openPermissionSettings() =>
      AppInstaller.openInstallPermissionSettings();

  void cancelDownload() => _cancelRequested = true;

  /// "Skip this version" — don't prompt again for this (or older) version.
  void ignoreVersion() {
    final v = available.value?.version;
    if (v != null) _prefs.put(_ignoredKey, v);
  }

  /// Reset the transient download state when the dialog closes.
  void resetPhase() {
    phase.value = UpdatePhase.idle;
    progress.value = 0;
    errorMessage.value = null;
    _cancelRequested = false;
  }
}
