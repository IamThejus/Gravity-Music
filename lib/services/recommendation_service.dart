// services/recommendation_service.dart
//
// "Up next" / autoplay recommendations resolved ON-DEVICE via the YouTube Music
// radio queue (YtMusicService.radio → the `next` endpoint), replacing the
// SaraGama /recommendation endpoint — which itself just proxied this exact
// call, so the results match (verified against SaraGama: same song pool, clean
// titles, real artists, square googleusercontent art).
//
// Public surface is unchanged: `getRecommendations(videoId)` still returns a
// RecommendedTrack list, so PlayerController.playWithRecommendations and the
// AutoplayOrchestrator are untouched.
import 'taste_profile.dart';
import 'thumb_util.dart';
import 'yt_music_service.dart';

/// Re-orders radio [candidates] by the user's [profile] without dropping any
/// (discovery preserved). Lower sort key = earlier. Cold start (empty profile)
/// returns the list unchanged. Candidates in [recentlyPlayedIds] are demoted.
List<RecommendedTrack> rerankByTaste(
  List<RecommendedTrack> candidates,
  TasteProfile profile,
  Set<String> recentlyPlayedIds,
) {
  if (profile.isEmpty) return candidates;
  const affinityWeight = 5.0; // up to 5 positions of lift for a loved artist
  const freshnessPenalty = 3.0; // push a just-played track down
  final indexed = <({RecommendedTrack track, double key})>[];
  for (var i = 0; i < candidates.length; i++) {
    final t = candidates[i];
    var key = i.toDouble();
    key -= affinityWeight * profile.scoreFor(t.artist);
    if (recentlyPlayedIds.contains(t.videoId)) key += freshnessPenalty;
    indexed.add((track: t, key: key));
  }
  // Dart's List.sort is NOT guaranteed stable, so the key already encodes the
  // original index i as the tiebreaker — equal-affinity tracks keep their
  // radio order without relying on sort stability.
  indexed.sort((a, b) => a.key.compareTo(b.key));
  return indexed.map((e) => e.track).toList();
}

class RecommendedTrack {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnail;
  final String duration;

  const RecommendedTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.duration,
  });

  Duration get durationValue {
    try {
      final parts = duration.split(':').map(int.parse).toList();
      if (parts.length == 2) return Duration(minutes: parts[0], seconds: parts[1]);
      if (parts.length == 3) return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    } catch (_) {}
    return Duration.zero;
  }

  /// Builds a RecommendedTrack from an on-device YouTube Music radio song.
  /// Square googleusercontent art → ThumbUtil resizes it, so now-playing /
  /// notification art stays sharp.
  factory RecommendedTrack.fromYtMusic(YtMusicSong s) => RecommendedTrack(
        videoId: s.videoId,
        title: s.title,
        artist: s.artists.join(', '),
        thumbnail: ThumbUtil.get(s.thumbnail, ThumbnailSize.tile),
        duration: s.duration,
      );
}

class RecommendationService {
  static const _ttlMinutes = 60; // recommendations don't change within an hour
  static const _maxResults = 25; // cap the related list we keep per seed

  // In-memory cache: videoId → (tracks, timestamp)
  // Recommendations are per-video so a simple map is sufficient — no LRU
  // needed since the number of unique played videos per session is small.
  static final _cache =
      <String, ({List<RecommendedTrack> tracks, DateTime ts})>{};

  static Future<List<RecommendedTrack>> getRecommendations(
      String videoId) async {
    if (videoId.isEmpty) return [];

    // 1. Return cached recommendations if still fresh
    final cached = _cache[videoId];
    if (cached != null) {
      final age = DateTime.now().difference(cached.ts).inMinutes;
      if (age < _ttlMinutes) return cached.tracks;
      _cache.remove(videoId); // stale, remove
    }

    // 2. Resolve on-device: the YouTube Music radio queue for this seed.
    try {
      final songs = await YtMusicService.radio(videoId);
      final tracks = songs
          .take(_maxResults)
          .map(RecommendedTrack.fromYtMusic)
          .where((t) => t.videoId.isNotEmpty)
          .toList();

      // Personalize: reorder by the user's taste (no-op on cold start).
      final profile = TasteProfile.current();
      final ranked = rerankByTaste(tracks, profile, recentlyPlayedVideoIds());

      _cache[videoId] = (tracks: ranked, ts: DateTime.now());
      return ranked;
    } catch (_) {
      return [];
    }
  }

  static void clearCache() => _cache.clear();
}