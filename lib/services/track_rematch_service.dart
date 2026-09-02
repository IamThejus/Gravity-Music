// services/track_rematch_service.dart
//
// Finds a working replacement videoId for a saved track YouTube refuses to
// play, so one bad entry no longer stops a playlist.
//
// Why this exists: Spotify/Apple imports have no videoIds of their own, so
// ImportService *guesses* one per track by searching YouTube Music for
// "<title> <artist>" and taking the first hit (import_service.dart). That
// guess can land on a video YouTube won't serve — verified in the wild: the
// stored id returned UNPLAYABLE from every client in the chain while the same
// song played fine under a different id. Re-importing the playlist fixed it,
// because the match simply ran again. This service does that repair per-track
// and automatically.
//
// Two rules keep it honest:
//
//   • Only UNPLAYABLE triggers a re-match. A rate limit or a network error
//     says nothing about the video, and searching for alternatives while
//     YouTube is already refusing requests makes things strictly worse.
//   • A candidate is only accepted once it has actually RESOLVED. Searching
//     alone proves nothing — the whole failure mode being repaired is a
//     search result that doesn't play. The resolved stream is handed back so
//     the caller plays it immediately instead of resolving twice.
//
// The swap is persisted by LibraryService.replaceVideoId, which fires
// onChanged and therefore rides the existing debounced cloud push. There is
// no separate Supabase write here.

import '../models/hm_streaming_data.dart';
import '../util/log.dart';
import 'thumb_util.dart';
import 'yt_music_service.dart';

/// A verified replacement: [videoId] resolved successfully and [stream] is
/// that resolution, ready to play.
class RematchResult {
  final String videoId;
  final String title;

  /// Normalised to [ThumbnailSize.tile], the same tier every other saved track
  /// stores (see SearchResult.fromYtMusic). The raw search-renderer thumbnail
  /// is `=w60-h60`, so storing it verbatim would leave this one track's
  /// artwork visibly softer than the rest of the library.
  final String thumbnail;
  final String duration;
  final HMStreamingData stream;

  const RematchResult({
    required this.videoId,
    required this.title,
    required this.thumbnail,
    required this.duration,
    required this.stream,
  });
}

class TrackRematchService {
  /// How many search hits to try resolving before giving up. Each attempt is a
  /// real resolve, so this is a direct multiplier on worst-case latency and on
  /// requests sent to YouTube — deliberately small.
  static const int maxCandidates = 3;

  /// Ids we've already failed to repair this session. Prevents a track with no
  /// working match from re-searching on every single play.
  static final Set<String> _giveUp = <String>{};

  /// In-flight repairs keyed by the bad id, so the prefetch path and the
  /// playback path can't both search for the same track at once.
  static final Map<String, Future<RematchResult?>> _inFlight = {};

  /// Clears session state. Tests only.
  static void resetForTest() {
    _giveUp.clear();
    _inFlight.clear();
  }

  /// True when [lastStatus] means "this video is unavailable" as opposed to
  /// "we couldn't reach YouTube right now". Only the former is worth repairing.
  static bool shouldRematch(String lastStatus) => lastStatus == 'UNPLAYABLE';

  /// Look for a playable stand-in for [badVideoId].
  ///
  /// [resolve] is injected rather than imported so this stays testable and so
  /// the caller's caching/visitorData handling is reused verbatim.
  /// Returns null when nothing suitable is found; never throws.
  static Future<RematchResult?> find({
    required String title,
    required String artist,
    required String badVideoId,
    required Future<HMStreamingData> Function(String videoId) resolve,
    Future<List<YtMusicSong>> Function(String query)? search,
  }) {
    if (title.trim().isEmpty) return Future.value(null);
    if (_giveUp.contains(badVideoId)) {
      logD('rematch', '$badVideoId: already failed this session — skipping');
      return Future.value(null);
    }
    final existing = _inFlight[badVideoId];
    if (existing != null) return existing;

    // NB: block body, not an arrow. `_inFlight.remove()` returns the removed
    // future — which is this very future — and whenComplete awaits a returned
    // future, so the arrow form makes it wait on itself and never completes.
    final future = _find(
      title,
      artist,
      badVideoId,
      resolve,
      search ?? YtMusicService.searchSongs,
    ).whenComplete(() {
      _inFlight.remove(badVideoId);
    });
    _inFlight[badVideoId] = future;
    return future;
  }

  static Future<RematchResult?> _find(
    String title,
    String artist,
    String badVideoId,
    Future<HMStreamingData> Function(String videoId) resolve,
    Future<List<YtMusicSong>> Function(String query) search,
  ) async {
    final query = artist.trim().isEmpty ? title : '$title $artist';
    logD('rematch', '$badVideoId: searching for "$query"');

    List<YtMusicSong> hits;
    try {
      hits = await search(query);
    } catch (e) {
      logD('rematch', '$badVideoId: search failed — $e');
      return null;
    }

    var tried = 0;
    for (final hit in hits) {
      if (tried >= maxCandidates) break;
      if (hit.videoId.isEmpty || hit.videoId == badVideoId) continue;
      if (!_plausibleMatch(title, hit.title)) {
        logD('rematch',
            '$badVideoId: skipping "${hit.title}" — title too different');
        continue;
      }
      tried++;
      try {
        final stream = await resolve(hit.videoId);
        if (stream.playable) {
          logD('rematch',
              '$badVideoId -> ${hit.videoId} ("${hit.title}") — verified');
          return RematchResult(
            videoId: hit.videoId,
            title: hit.title,
            thumbnail: ThumbUtil.get(hit.thumbnail, ThumbnailSize.tile),
            duration: hit.duration,
            stream: stream,
          );
        }
        logD('rematch',
            '$badVideoId: candidate ${hit.videoId} not playable '
            '(${stream.lastStatus.isEmpty ? stream.statusMSG : stream.lastStatus})');
      } catch (e) {
        logD('rematch', '$badVideoId: candidate ${hit.videoId} threw — $e');
      }
    }

    logD('rematch', '$badVideoId: no working replacement found');
    _giveUp.add(badVideoId);
    return null;
  }

  /// Cheap guard against silently swapping in the wrong song. The swap is
  /// persisted and invisible to the user, so a bad match is worse than no
  /// match — but the check stays loose because YouTube Music titles carry
  /// suffixes the source platform doesn't ("(From \"Film\")", "- Remastered",
  /// feature credits). Requires that most of the shorter title's words appear
  /// in the longer one.
  static bool _plausibleMatch(String original, String candidate) {
    final a = _tokens(original);
    final b = _tokens(candidate);
    if (a.isEmpty || b.isEmpty) return false;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length <= b.length ? b : a;
    final hits = shorter.where(longer.contains).length;
    return hits / shorter.length >= 0.6;
  }

  static Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toSet();
}
