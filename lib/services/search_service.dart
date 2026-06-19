// services/search_service.dart
//
// Search is resolved ON-DEVICE via the YouTube MUSIC catalog (YtMusicService) —
// no SaraGama API, no ytmusicapi, no Render endpoint. This removes the
// shared-server-IP variance (results reflect the user's own device/region,
// consistently) AND restores clean results: real song titles, real artist
// names, and square googleusercontent album art — same quality SaraGama gave,
// vs. youtube_explode's regular-YouTube video clutter.
//
// The public surface is unchanged: callers still get a SearchResult list from
// `autocomplete(query)`, so the search screen / import flow are untouched.
import 'thumb_util.dart';
import 'yt_music_service.dart';

class SearchResult {
  final String title;
  final String videoId;
  final List<String> artists;
  final String thumbnail;
  final String duration;

  const SearchResult({
    required this.title,
    required this.videoId,
    required this.artists,
    required this.thumbnail,
    required this.duration,
  });

  String get artistLine => artists.join(', ');

  Duration get durationValue {
    try {
      final parts = duration.split(':').map(int.parse).toList();
      if (parts.length == 2) return Duration(minutes: parts[0], seconds: parts[1]);
      if (parts.length == 3) return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    } catch (_) {}
    return Duration.zero;
  }

  /// Sizes a thumbnail for list-tile display (96px). YT Music album art is a
  /// square `googleusercontent` URL, which ThumbUtil resizes via its
  /// `=wW-hH-…` rewrite — so now-playing/notification art stays sharp too.
  static String _upgradeThumb(String url) =>
      ThumbUtil.get(url, ThumbnailSize.tile);

  /// Builds a SearchResult from an on-device YouTube Music song.
  factory SearchResult.fromYtMusic(YtMusicSong s) => SearchResult(
        title: s.title,
        videoId: s.videoId,
        artists: s.artists,
        thumbnail: _upgradeThumb(s.thumbnail),
        duration: s.duration,
      );

  /// Still used by the playlist-import flow (ImportService), which parses
  /// JSON track payloads. Search itself no longer goes through JSON.
  factory SearchResult.fromJson(Map<String, dynamic> json) => SearchResult(
        title: json['title'] ?? '',
        videoId: json['video_url'] ?? '',
        artists: List<String>.from(json['artist'] ?? []),
        thumbnail: _upgradeThumb(json['thumbnail'] ?? ''),
        duration: json['duration'] ?? '',
      );
}

class SearchService {
  static const _maxResults   = 20;         // results returned per query
  static const _maxCacheSize = 30;         // max distinct queries kept
  static const _ttlMinutes   = 15;         // cache entries expire after 15 min

  // LRU cache: query → (results, timestamp)
  // Using insertion-order iteration for LRU eviction.
  static final _cache =
      <String, ({List<SearchResult> results, DateTime ts})>{};

  static Future<List<SearchResult>> autocomplete(String query) async {
    final key = query.trim().toLowerCase();
    if (key.isEmpty) return [];

    // 1. Cache hit — return instantly if still fresh
    final cached = _cache[key];
    if (cached != null) {
      final age = DateTime.now().difference(cached.ts).inMinutes;
      if (age < _ttlMinutes) {
        // Move to end (most recently used)
        _cache.remove(key);
        _cache[key] = cached;
        return cached.results;
      } else {
        _cache.remove(key); // expired
      }
    }

    // 2. Cache miss — resolve on-device via the YouTube Music catalog.
    try {
      final songs = await YtMusicService.searchSongs(query.trim());
      final results = songs
          .take(_maxResults)
          .map(SearchResult.fromYtMusic)
          .where((r) => r.videoId.isNotEmpty)
          .toList();

      // 3. Store in cache, evict oldest if over limit
      if (_cache.length >= _maxCacheSize) {
        _cache.remove(_cache.keys.first); // remove LRU (first = oldest)
      }
      _cache[key] = (results: results, ts: DateTime.now());
      return results;
    } catch (_) {
      return [];
    }
  }

  /// Clear all cached search results (e.g. on low memory).
  static void clearCache() => _cache.clear();
}