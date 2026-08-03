// services/update_service.dart
//
// Talks to the GitHub Releases API to find the latest release, and reports the
// installed version. Pure service — no UI, no state. All failures surface as
// [UpdateException] with a friendly, user-showable message.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/github_release.dart';

/// A user-facing update error. `.message` is safe to show in a snackbar/dialog.
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

class UpdateService {
  static const _owner = 'IamThejus';
  static const _repo = 'Gravity-Music';
  static const _latestApi =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Public releases page (used on desktop, where in-app APK install doesn't
  /// apply, and as a fallback link).
  static const releasesPageUrl =
      'https://github.com/$_owner/$_repo/releases/latest';

  /// Fetch the latest published release. Throws [UpdateException] on network /
  /// API / rate-limit / parse failure.
  static Future<GitHubRelease> fetchLatest() async {
    final http.Response res;
    try {
      res = await http.get(
        Uri.parse(_latestApi),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const UpdateException('The update check timed out — try again later.');
    } catch (_) {
      throw const UpdateException('No internet connection.');
    }

    switch (res.statusCode) {
      case 200:
        break;
      case 403:
      case 429:
        throw const UpdateException(
            'GitHub is rate-limiting update checks — try again later.');
      case 404:
        throw const UpdateException('No releases found yet.');
      default:
        throw UpdateException('Update check failed (HTTP ${res.statusCode}).');
    }

    try {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return GitHubRelease.fromJson(json);
    } catch (_) {
      throw const UpdateException('Could not read the release information.');
    }
  }

  /// The installed app version (e.g. `1.5.0`), from the platform package info.
  static Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;
}
