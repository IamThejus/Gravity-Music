// services/album_service.dart
//
// Thin layer over YtMusicService for ALBUMS — mirrors SearchService (songs).
// Search returns lightweight [Album] headers (browseId-addressable); opening
// one resolves its full track list on-device via YtMusicService.albumDetail and
// caches it for 24h in CacheBox (same TTL as playlist details). Tracks are
// modeled as SearchResult so they reuse the existing `toMediaItem()` /
// `toLibraryTrack()` adapters — album playback needs no new plumbing.

import 'cache_service.dart';
import 'search_service.dart';
import 'thumb_util.dart';
import 'yt_music_service.dart';

/// A lightweight album search hit — enough to render a tile. The track list is
/// fetched lazily (see [AlbumService.getAlbum]) so search stays cheap.
class Album {
  final String browseId; // MPREb_… — the album page id
  final String title;
  final String artist;
  final String year;
  final String thumbnail;

  const Album({
    required this.browseId,
    required this.title,
    required this.artist,
    required this.year,
    required this.thumbnail,
  });

  /// Subtitle line for a tile: "2021 • Artist" (either part may be absent).
  String get subtitle {
    if (year.isNotEmpty && artist.isNotEmpty) return '$year • $artist';
    return year.isNotEmpty ? year : artist;
  }

  factory Album.fromYtMusic(YtMusicAlbum a) => Album(
        browseId: a.browseId,
        title: a.title,
        artist: a.artist,
        year: a.year,
        thumbnail: ThumbUtil.get(a.thumbnail, ThumbnailSize.card),
      );

  Map<String, dynamic> toJson() => {
        'browseId': browseId,
        'title': title,
        'artist': artist,
        'year': year,
        'thumbnail': thumbnail,
      };

  factory Album.fromJson(Map<String, dynamic> json) => Album(
        browseId: json['browseId'] ?? '',
        title: json['title'] ?? '',
        artist: json['artist'] ?? '',
        year: json['year'] ?? '',
        thumbnail: json['thumbnail'] ?? '',
      );
}

/// A fully-resolved album: header metadata + its ordered track list. Tracks are
/// [SearchResult]s so the UI/player can reuse their existing MediaItem adapter.
class AlbumDetail {
  final String browseId;
  final String title;
  final String artist;
  final String year;
  final String thumbnail;
  final List<SearchResult> tracks;

  const AlbumDetail({
    required this.browseId,
    required this.title,
    required this.artist,
    required this.year,
    required this.thumbnail,
    required this.tracks,
  });

  int get trackCount => tracks.length;

  Map<String, dynamic> toJson() => {
        'browseId': browseId,
        'title': title,
        'artist': artist,
        'year': year,
        'thumbnail': thumbnail,
        'tracks': tracks
            .map((t) => {
                  'title': t.title,
                  'video_url': t.videoId,
                  'artist': t.artists,
                  'thumbnail': t.thumbnail,
                  'duration': t.duration,
                })
            .toList(),
      };

  factory AlbumDetail.fromJson(Map<String, dynamic> json) => AlbumDetail(
        browseId: json['browseId'] ?? '',
        title: json['title'] ?? '',
        artist: json['artist'] ?? '',
        year: json['year'] ?? '',
        thumbnail: json['thumbnail'] ?? '',
        tracks: (json['tracks'] as List? ?? [])
            .map((e) => SearchResult.fromJson(Map<String, dynamic>.from(e)))
            .where((t) => t.videoId.isNotEmpty)
            .toList(),
      );
}

class AlbumService {
  /// Searches the YT Music catalog for albums. Returns lightweight headers;
  /// empty list on any error (caller treats that as "no albums").
  static Future<List<Album>> search(String query) async {
    try {
      final albums = await YtMusicService.searchAlbums(query.trim());
      return albums
          .map(Album.fromYtMusic)
          .where((a) => a.browseId.isNotEmpty && a.title.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Resolves an album's full track list. Serves a fresh (≤24h) cache entry if
  /// present; otherwise browses on-device, caches the result, and returns it.
  /// Falls back to any stale cache entry when the network fetch fails, so a
  /// previously-opened album still works offline. Returns null if it has never
  /// been fetched and the network is unavailable.
  static Future<AlbumDetail?> getAlbum(String browseId) async {
    if (browseId.isEmpty) return null;

    final fresh = CacheService.getFreshAlbum(browseId);
    if (fresh != null) return AlbumDetail.fromJson(fresh);

    final detail = await YtMusicService.albumDetail(browseId);
    if (detail != null && detail.tracks.isNotEmpty) {
      final resolved = _fromYtMusic(detail);
      CacheService.saveAlbum(browseId, resolved.toJson());
      return resolved;
    }

    // Network failed — fall back to a stale cache entry if we have one.
    final any = CacheService.getAnyAlbum(browseId);
    if (any != null) return AlbumDetail.fromJson(any);
    return null;
  }

  static AlbumDetail _fromYtMusic(YtMusicAlbumDetail d) => AlbumDetail(
        browseId: d.browseId,
        title: d.title,
        artist: d.artist,
        year: d.year,
        thumbnail: ThumbUtil.get(d.thumbnail, ThumbnailSize.art),
        tracks: d.tracks
            .map((s) => SearchResult(
                  title: s.title,
                  videoId: s.videoId,
                  artists: s.artists,
                  thumbnail: ThumbUtil.get(s.thumbnail, ThumbnailSize.tile),
                  duration: s.duration,
                ))
            .where((t) => t.videoId.isNotEmpty)
            .toList(),
      );
}
