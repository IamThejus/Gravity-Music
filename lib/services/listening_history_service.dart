// services/listening_history_service.dart
//
// Lightweight on-device listening history — the signal that powers the locally
// generated "Made For You" mixes. Every time a track starts, we upsert an entry
// keyed by videoId with a play count and first/last-played timestamps. This is
// richer than PlayerController.searchHistory (which keeps only the last ~10
// with no counts), so it can drive Repeat Rewind (most played), Throwback
// (played long ago), and artist-clustered Daily mixes.
//
// Stored in Hive box 'ListeningHistory' — one key per videoId:
//   { videoId, title, artist, thumbnail, duration, count, firstMs, lastMs }

import 'package:audio_service/audio_service.dart';
import 'package:hive/hive.dart';

class HistoryEntry {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnail;
  final String duration;
  final int count;
  final int firstMs;
  final int lastMs;

  const HistoryEntry({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.duration,
    required this.count,
    required this.firstMs,
    required this.lastMs,
  });

  factory HistoryEntry.fromMap(Map m) => HistoryEntry(
        videoId: m['videoId'] ?? '',
        title: m['title'] ?? '',
        artist: m['artist'] ?? '',
        thumbnail: m['thumbnail'] ?? '',
        duration: m['duration'] ?? '',
        count: m['count'] ?? 0,
        firstMs: m['firstMs'] ?? 0,
        lastMs: m['lastMs'] ?? 0,
      );

  /// Track shape used by the mix payload (mirrors MixTrack.fromJson).
  Map<String, dynamic> toTrackJson() => {
        'video_id': videoId,
        'title': title,
        'artist': artist,
        'thumbnail': thumbnail,
        'duration': duration,
      };
}

class ListeningHistoryService {
  static Box get _box => Hive.box('ListeningHistory');

  /// Records (or increments) a play. Called when a track becomes current.
  static void record(MediaItem item) {
    final id = item.id;
    if (id.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _box.get(id);
    final prevCount = existing is Map ? (existing['count'] as int? ?? 0) : 0;
    final firstMs =
        existing is Map ? (existing['firstMs'] as int? ?? now) : now;

    _box.put(id, {
      'videoId': id,
      'title': item.title,
      'artist': item.artist ?? '',
      'thumbnail': item.artUri?.toString() ?? '',
      'duration': _fmt(item.duration),
      'count': prevCount + 1,
      'firstMs': firstMs,
      'lastMs': now,
    });
  }

  static bool get hasHistory => _box.isNotEmpty;
  static int get size => _box.length;

  static List<HistoryEntry> all() => _box.values
      .whereType<Map>()
      .map((m) => HistoryEntry.fromMap(m))
      .where((e) => e.videoId.isNotEmpty)
      .toList();

  /// Most-played first (ties broken by most-recent). Powers Repeat Rewind.
  static List<HistoryEntry> topPlayed({int limit = 30}) {
    final list = all()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : b.lastMs.compareTo(a.lastMs);
      });
    return list.take(limit).toList();
  }

  /// Most-recently played first. Used for seeding.
  static List<HistoryEntry> recent({int limit = 30}) {
    final list = all()..sort((a, b) => b.lastMs.compareTo(a.lastMs));
    return list.take(limit).toList();
  }

  /// Played-long-ago first (least recently played). Powers Throwback.
  static List<HistoryEntry> throwback({int limit = 30}) {
    final list = all()..sort((a, b) => a.lastMs.compareTo(b.lastMs));
    return list.take(limit).toList();
  }

  /// One representative (most-recent) entry per distinct artist, newest first.
  /// Powers artist-clustered Daily / Artist mixes.
  static List<HistoryEntry> distinctArtistSeeds({int limit = 5}) {
    final seen = <String>{};
    final seeds = <HistoryEntry>[];
    for (final e in recent(limit: 60)) {
      final key = e.artist.trim().toLowerCase();
      if (key.isEmpty || seen.add(key)) {
        seeds.add(e);
        if (seeds.length >= limit) break;
      }
    }
    return seeds;
  }

  static String _fmt(Duration? d) {
    if (d == null || d == Duration.zero) return '';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
    return '$m:$s';
  }
}
