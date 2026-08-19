// services/heartbeat_service.dart
//
// Anonymous "listening now" heartbeat for the website's public stats
// (🎧 listening now / 📱 total installations). Privacy-first by design:
//
//   WHAT IS SENT (and the ONLY thing the backend stores):
//     • a random installation UUID  — generated on-device, meaningless outside
//       this app; exists solely so one install isn't double-counted
//     • platform                    — "android" / "linux" / "windows"
//     • app version                 — e.g. "1.4.0"
//   (the backend additionally keeps first-seen / last-heartbeat timestamps)
//
//   WHAT IS NEVER SENT OR STORED:
//     songs, artists, playlists, listening history, search history, user
//     identity, accounts/emails, device identifiers (Android ID, IMEI, MAC,
//     advertising ID, serial), or location. IP addresses are not persisted by
//     the backend. The UUID is NOT derived from any hardware identifier — it
//     is pure Random.secure() output, so it cannot be tied back to a person
//     or device.
//
// The heartbeat runs ONLY while music is actively PLAYING — never on app
// open, browsing, search, pause, stop, or buffering — because its sole
// purpose is to count listeners *currently* playing music. It observes the
// EXISTING PlayerController.buttonState (which already folds audio_service's
// playing/buffering states); no second playback listener is created.
//
// Timing: one beat immediately when playback starts, then every 60s while
// playing; the timer stops the moment playback leaves the playing state.
// All network failures are swallowed silently (no snackbars/dialogs/logs in
// release) — the next scheduled beat is the retry.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../controllers/player_controller.dart';
import 'installation_id.dart';

class HeartbeatService extends GetxController {
  static const _endpoint =
      'https://gravity-heartbeat.gravitymusic.workers.dev/api/v1/heartbeat';
  static const _interval = Duration(seconds: 60);

  /// AppPrefs key holding the anonymous installation UUID. Written exactly
  /// once per install; only cleared by uninstall / clear-data (which is the
  /// intended behaviour — a wiped app is a "new" anonymous install).

  Timer? _timer;
  Worker? _stateWorker;
  bool _sending = false;
  String? _versionCache;

  @override
  void onInit() {
    super.onInit();
    final pc = Get.find<PlayerController>();
    // Reuse the existing reactive playback state — buttonState is `playing`
    // only during genuine playback (loading/buffering map to `loading`), which
    // is exactly the "actively listening" condition the heartbeat needs.
    _stateWorker = ever<PlayButtonState>(pc.buttonState, (state) {
      state == PlayButtonState.playing ? _start() : _stop();
    });
    // Session restore may already be mid-playback by the time we register.
    if (pc.buttonState.value == PlayButtonState.playing) _start();
  }

  /// Start beating: one immediate beat, then every [_interval]. Idempotent —
  /// repeated `playing` events can never stack a second timer.
  void _start() {
    if (_timer != null) return;
    _send();
    _timer = Timer.periodic(_interval, (_) => _send());
  }

  /// Stop beating immediately (pause/stop/buffer/track-gap).
  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _send() async {
    if (_sending) return; // never overlap requests if one is slow
    _sending = true;
    try {
      await http
          .post(
            Uri.parse(_endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'installation_id': installationId(),
              'platform': Platform.operatingSystem,
              'app_version': await _appVersion(),
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Deliberately silent: analytics must never interrupt playback or
      // surface errors to the user. The next 60s beat retries naturally.
    } finally {
      _sending = false;
    }
  }


  /// App version read from the platform package info (single source of truth
  /// with pubspec.yaml — never hardcoded). Cached after the first read.
  Future<String> _appVersion() async =>
      _versionCache ??= (await PackageInfo.fromPlatform()).version;

  @override
  void onClose() {
    _stateWorker?.dispose();
    _stop();
    super.onClose();
  }
}

