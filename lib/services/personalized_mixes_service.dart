// lib/services/personalized_mixes_service.dart
//
// Builds the home "Made For You" mixes from the user's TasteProfile + YouTube
// Music radio: one "Your <Artist> Mix" per top affinity artist, plus a
// "Discovery" mix biased toward new-to-you artists. Returns existing Mix
// objects so the home carousel + MixDetailScreen work unchanged. Returns []
// when there is no taste data or all radio calls fail (→ caller falls back to
// curated MixesService). Cached 24h.

import 'cache_service.dart';
import 'mixes_service.dart';
import 'taste_profile.dart';
import 'thumb_util.dart';
import 'yt_music_service.dart';

const int _tracksPerMix = 20;
const int _maxArtistMixes = 4;
const int _minMixTracks = 5;

/// Keeps only candidates whose every artist is NOT in [knownArtists].
List<YtMusicSong> filterDiscovery(
    List<YtMusicSong> candidates, Set<String> knownArtists) {
  return candidates
      .where((c) => c.artists.every((a) => !knownArtists.contains(a)))
      .toList();
}

MixTrack _toMixTrack(YtMusicSong s) => MixTrack(
      videoId: s.videoId,
      title: s.title,
      artist: s.artists.join(', '),
      thumbnail: ThumbUtil.get(s.thumbnail, ThumbnailSize.tile),
      duration: s.duration,
    );

class PersonalizedMixesService {
  static Future<List<Mix>> getMixes({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final fresh = CacheService.getFreshPersonalMixes();
      if (fresh != null) return _parse(fresh);
    }

    final profile = TasteProfile.current();
    if (profile.isEmpty) return const [];

    final mixes = <Mix>[];
    final seen = <String>{}; // videoIds across all mixes

    // Per-artist mixes.
    for (final seed in profile.topArtists(_maxArtistMixes)) {
      try {
        final songs = await YtMusicService.radio(seed.seedVideoId);
        final tracks = <MixTrack>[];
        for (final s in songs) {
          if (s.videoId.isEmpty || !seen.add(s.videoId)) continue;
          tracks.add(_toMixTrack(s));
          if (tracks.length >= _tracksPerMix) break;
        }
        if (tracks.length >= _minMixTracks) {
          mixes.add(Mix(
            id: 'pm_artist_${seed.artist}',
            title: 'Your ${seed.artist} Mix',
            image: ThumbUtil.get(tracks.first.thumbnail, ThumbnailSize.card),
            trackCount: tracks.length,
            tracks: tracks,
          ));
        }
      } catch (_) {/* skip this artist */}
    }

    // Discovery mix: radio from the top seed, keep new-to-you artists only.
    final top = profile.topArtists(1);
    if (top.isNotEmpty) {
      try {
        final songs = await YtMusicService.radio(top.first.seedVideoId);
        final fresh = filterDiscovery(songs, profile.knownArtists);
        final tracks = <MixTrack>[];
        for (final s in fresh) {
          if (s.videoId.isEmpty || !seen.add(s.videoId)) continue;
          tracks.add(_toMixTrack(s));
          if (tracks.length >= _tracksPerMix) break;
        }
        if (tracks.length >= _minMixTracks) {
          mixes.add(Mix(
            id: 'pm_discovery',
            title: 'Discovery',
            image: ThumbUtil.get(tracks.first.thumbnail, ThumbnailSize.card),
            trackCount: tracks.length,
            tracks: tracks,
          ));
        }
      } catch (_) {/* skip discovery */}
    }

    if (mixes.isEmpty) {
      final any = CacheService.getAnyPersonalMixes();
      return any != null ? _parse(any) : const [];
    }

    CacheService.savePersonalMixes(_serialize(mixes));
    return mixes;
  }

  static Map<String, dynamic> _serialize(List<Mix> mixes) => {
        'mixes': {
          for (final m in mixes)
            m.id: {
              'title': m.title,
              'image': m.image,
              'trackCount': m.trackCount,
              'tracks': m.tracks
                  .map((t) => {
                        'video_id': t.videoId,
                        'title': t.title,
                        'artist': t.artist,
                        'thumbnail': t.thumbnail,
                        'duration': t.duration,
                      })
                  .toList(),
            }
        }
      };

  static List<Mix> _parse(Map<String, dynamic> body) {
    final map = (body['mixes'] as Map?) ?? {};
    final out = <Mix>[];
    map.forEach((key, value) {
      if (value is Map) {
        final mix =
            Mix.fromEntry(key.toString(), Map<String, dynamic>.from(value));
        if (mix.tracks.isNotEmpty) out.add(mix);
      }
    });
    return out;
  }
}
