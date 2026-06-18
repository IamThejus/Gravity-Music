// services/mixes_service.dart
//
// "Made For You" mixes — generated ENTIRELY on-device from the user's listening
// history (no Saragama /mixes endpoint). Each mix carries its full track list
// inline (so opening one needs no second request), keeping the Mix/MixTrack
// models and the home carousel / MixDetailScreen unchanged.
//
// Generation (capped, cached for 24h, invalidated when listening changes):
//   • New user (no history, no likes) → ONE Discovery Mix seeded from a small
//     built-in query pool, so the home isn't empty and listening can start.
//   • Established user:
//       – "{Artist} Mix" per top recent artist  (YtMusicService.radio seed)
//       – "Discovery Mix"  (radio of top seed, minus songs already known)
//       – "Repeat Rewind"  (most-played songs — local, no network)
//       – "Your Favorites" (liked songs — local, no network)
//       – "Throwback"      (songs played long ago — local, no network)
//
// Internally we build the same {mixes:{id:{title,image,trackCount,tracks[]}}}
// shape the old API used, so _parse / Mix.fromEntry are reused verbatim and the
// generated payload round-trips cleanly through CacheService.

import 'dart:math';

import 'cache_service.dart';
import 'library_service.dart';
import 'listening_history_service.dart';
import 'thumb_util.dart';
import 'yt_music_service.dart';

class MixTrack {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnail;
  final String duration;

  const MixTrack({
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
      if (parts.length == 3) {
        return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
      }
    } catch (_) {}
    return Duration.zero;
  }

  factory MixTrack.fromJson(Map<String, dynamic> json) => MixTrack(
        videoId: json['video_id'] ?? '',
        title: json['title'] ?? '',
        artist: json['artist'] ?? '',
        thumbnail: ThumbUtil.get(json['thumbnail'] ?? '', ThumbnailSize.tile),
        duration: json['duration'] ?? '',
      );
}

class Mix {
  final String id; // the map key, e.g. "focus"
  final String title;
  final String image; // saragama mood image URL (used as-is)
  final int trackCount;
  final List<MixTrack> tracks;

  const Mix({
    required this.id,
    required this.title,
    required this.image,
    required this.trackCount,
    required this.tracks,
  });

  factory Mix.fromEntry(String key, Map<String, dynamic> json) {
    final rawTracks = (json['tracks'] as List? ?? [])
        .map((e) => MixTrack.fromJson(Map<String, dynamic>.from(e)))
        .where((t) => t.videoId.isNotEmpty)
        .toList();
    return Mix(
      id: key,
      title: json['title'] ?? key,
      image: json['image'] ?? '',
      trackCount: json['trackCount'] ?? rawTracks.length,
      tracks: rawTracks,
    );
  }
}

class MixesService {
  static const _maxMixes = 6;
  static const _minMixTracks = 8; // don't surface a mix thinner than this
  static final _rng = Random();

  // Built-in seed queries for the cold-start Discovery Mix (no history yet).
  // Diverse across languages so first-run discovery isn't monocultural.
  static const _discoverySeeds = <String>[
    'top hits', 'trending songs', 'arijit singh', 'malayalam hit songs',
    'tamil hit songs', 'telugu hit songs', 'punjabi songs', 'the weeknd',
    'ed sheeran', 'english pop hits', 'bollywood hits', 'lofi beats',
  ];

  /// Returns the "Made For You" mixes, generated locally from listening history.
  ///
  /// Caching (persistent via CacheService, 24h TTL): a generated payload is
  /// cached together with a [_seedSignature]. A cache hit is reused only while
  /// fresh AND the signature still matches (i.e. listening hasn't changed).
  /// [forceRefresh] (pull-to-refresh) skips the cache and regenerates. On any
  /// generation error, falls back to the last cached payload of any age.
  static Future<List<Mix>> getMixes({bool forceRefresh = false}) async {
    final sig = _seedSignature();

    if (!forceRefresh) {
      final fresh = CacheService.getFreshMixes();
      if (fresh != null && fresh['sig'] == sig) return _parse(fresh);
    }

    try {
      final mixesMap = await _generate();
      final payload = <String, dynamic>{'mixes': mixesMap, 'sig': sig};
      if (mixesMap.isNotEmpty) CacheService.saveMixes(payload);
      return _parse(payload);
    } catch (_) {
      final any = CacheService.getAnyMixes();
      if (any != null) return _parse(any);
      return [];
    }
  }

  // ── Generation ───────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> _generate() async {
    final mixes = <String, dynamic>{};
    final liked = LibraryService.getLiked();

    // Cold start: no history and no likes → a single Discovery Mix so the user
    // has something to play; personalized mixes appear once they listen.
    if (!ListeningHistoryService.hasHistory && liked.isEmpty) {
      final disc = await _coldStartDiscovery();
      if (disc != null) mixes['discovery'] = disc;
      return mixes;
    }

    final knownIds = <String>{
      ...ListeningHistoryService.all().map((e) => e.videoId),
      ...liked.map((t) => t.videoId),
    };

    // Fetch each seed's radio once, reuse for both artist mixes and discovery.
    final seeds = ListeningHistoryService.distinctArtistSeeds(limit: 3);
    final radios = <String, List<YtMusicSong>>{};
    for (final s in seeds) {
      radios[s.videoId] = await YtMusicService.radio(s.videoId);
    }

    // 1. "{Artist} Mix" per recent artist (network: reused radio).
    for (final s in seeds) {
      if (mixes.length >= _maxMixes) break;
      final radio = radios[s.videoId] ?? const [];
      if (radio.length >= _minMixTracks) {
        mixes['mix_${s.videoId}'] = _entry(
          title: '${_firstArtist(s.artist)} Mix',
          image: s.thumbnail,
          tracks: radio.map(_trackFromSong).toList(),
        );
      }
    }

    // 2. Discovery Mix — radio of the top seed, minus songs already known.
    if (mixes.length < _maxMixes && seeds.isNotEmpty) {
      final radio = radios[seeds.first.videoId] ?? const [];
      final fresh =
          radio.where((s) => !knownIds.contains(s.videoId)).toList();
      if (fresh.length >= _minMixTracks) {
        mixes['discovery'] = _entry(
          title: 'Discovery Mix',
          image: fresh.first.thumbnail,
          tracks: fresh.map(_trackFromSong).toList(),
        );
      }
    }

    // 3. Repeat Rewind — most-played songs (local; needs real repeats).
    if (mixes.length < _maxMixes) {
      final repeats =
          ListeningHistoryService.topPlayed(limit: 30).where((e) => e.count >= 2);
      final tracks = repeats.map((e) => e.toTrackJson()).toList();
      if (tracks.length >= _minMixTracks) {
        mixes['rewind'] = _entry(
          title: 'Repeat Rewind',
          image: tracks.first['thumbnail'] as String,
          tracks: tracks,
        );
      }
    }

    // 4. Your Favorites — liked songs (local).
    if (mixes.length < _maxMixes && liked.length >= 5) {
      final shuffled = List.of(liked)..shuffle(_rng);
      mixes['favorites'] = _entry(
        title: 'Your Favorites',
        image: shuffled.first.thumbnail,
        tracks: shuffled.map(_trackFromLibrary).toList(),
      );
    }

    // 5. Throwback — songs played long ago (local; needs enough history).
    if (mixes.length < _maxMixes && ListeningHistoryService.size >= 20) {
      final old = ListeningHistoryService.throwback(limit: 25);
      if (old.length >= _minMixTracks) {
        mixes['throwback'] = _entry(
          title: 'Throwback',
          image: old.first.thumbnail,
          tracks: old.map((e) => e.toTrackJson()).toList(),
        );
      }
    }

    return mixes;
  }

  /// First-run discovery: pick a random seed query, search it, then build a mix
  /// from that song's radio (more varied than raw search results). Returns null
  /// if nothing resolves (home stays on its blank welcome state).
  static Future<Map<String, dynamic>?> _coldStartDiscovery() async {
    final queries = List.of(_discoverySeeds)..shuffle(_rng);
    for (final q in queries.take(3)) {
      final hits = await YtMusicService.searchSongs(q);
      if (hits.isEmpty) continue;
      final radio = await YtMusicService.radio(hits.first.videoId);
      final tracks = (radio.length >= _minMixTracks ? radio : hits)
          .map(_trackFromSong)
          .toList();
      if (tracks.length >= _minMixTracks) {
        return _entry(
          title: 'Discovery Mix',
          image: tracks.first['thumbnail'] as String,
          tracks: tracks,
        );
      }
    }
    return null;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static Map<String, dynamic> _entry({
    required String title,
    required String image,
    required List<Map<String, dynamic>> tracks,
  }) =>
      {
        'title': title,
        // Card-sized art for the carousel (ThumbUtil resizes googleusercontent).
        'image': ThumbUtil.get(image, ThumbnailSize.card),
        'trackCount': tracks.length,
        'tracks': tracks,
      };

  static Map<String, dynamic> _trackFromSong(YtMusicSong s) => {
        'video_id': s.videoId,
        'title': s.title,
        'artist': s.artists.join(', '),
        'thumbnail': s.thumbnail,
        'duration': s.duration,
      };

  static Map<String, dynamic> _trackFromLibrary(LibraryTrack t) => {
        'video_id': t.videoId,
        'title': t.title,
        'artist': t.artist,
        'thumbnail': t.thumbnail,
        'duration': t.duration,
      };

  static String _firstArtist(String artist) {
    final first = artist.split(RegExp(r'[,&]|feat\.?|ft\.?')).first.trim();
    return first.isEmpty ? 'Daily' : first;
  }

  /// Signature of the listening state — changes when mixes should regenerate.
  static String _seedSignature() {
    final top = ListeningHistoryService.topPlayed(limit: 8)
        .map((e) => '${e.videoId}:${e.count}')
        .join(',');
    final likes = LibraryService.getLiked().length;
    return 'h${ListeningHistoryService.size}|l$likes|$top';
  }

  /// Parses a {mixes:{id:{title,image,trackCount,tracks[]}}} payload into Mixes.
  static List<Mix> _parse(Map<String, dynamic> body) {
    final mixesMap = (body['mixes'] as Map?) ?? {};
    final mixes = <Mix>[];
    mixesMap.forEach((key, value) {
      if (value is Map) {
        final mix =
            Mix.fromEntry(key.toString(), Map<String, dynamic>.from(value));
        if (mix.tracks.isNotEmpty) mixes.add(mix);
      }
    });
    return mixes;
  }

  static void clearCache() => CacheService.clearMixes();
}
