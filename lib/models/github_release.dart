// models/github_release.dart
//
// Parsed shape of the GitHub Releases API `.../releases/latest` response.
// Only the fields the updater needs; defensively parsed so a shape change
// doesn't crash the check.

class GitHubReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size; // bytes

  const GitHubReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  factory GitHubReleaseAsset.fromJson(Map<String, dynamic> j) =>
      GitHubReleaseAsset(
        name: j['name'] as String? ?? '',
        downloadUrl: j['browser_download_url'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

class GitHubRelease {
  final String tagName; // e.g. v1.5.0
  final String version; // normalized, e.g. 1.5.0
  final String body; // release notes (markdown)
  final DateTime? publishedAt;
  final List<GitHubReleaseAsset> assets;

  const GitHubRelease({
    required this.tagName,
    required this.version,
    required this.body,
    required this.publishedAt,
    required this.assets,
  });

  factory GitHubRelease.fromJson(Map<String, dynamic> j) {
    final tag = j['tag_name'] as String? ?? '';
    final assets = (j['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GitHubReleaseAsset.fromJson)
        .toList();
    return GitHubRelease(
      tagName: tag,
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      body: (j['body'] as String? ?? '').trim(),
      publishedAt: DateTime.tryParse(j['published_at'] as String? ?? ''),
      assets: assets,
    );
  }

  /// The first `.apk` asset (name is NOT hardcoded — matched by extension), or
  /// null when the release ships no installable APK (e.g. desktop-only).
  GitHubReleaseAsset? get apkAsset {
    for (final a in assets) {
      if (a.name.toLowerCase().endsWith('.apk') && a.downloadUrl.isNotEmpty) {
        return a;
      }
    }
    return null;
  }
}
