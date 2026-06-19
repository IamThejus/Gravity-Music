// services/import_service.dart
//
// Imports external (Spotify / Apple Music) playlists ENTIRELY on-device — no
// Saragama API. Two stages, same public surface as before so the import UI and
// background job are unchanged:
//   • details — scrape the playlist (title + artist per track) for a fast
//                preview (song names, count, ETA, playlist name).
//   • import  — scrape again (cached), then match every track to a YouTube
//                Music song and return resolved SearchResults (with videoIds).
//
// Scraping lives in PlaylistImporter; YouTube Music matching reuses the local
// YtMusicService. The /import result reuses SearchResult (title / videoId /
// artist[] / thumbnail / duration) so the rest of the pipeline is untouched.

import 'playlist_importer.dart';
import 'search_service.dart';
import 'yt_music_service.dart';

/// Friendly, user-facing failure during import (shown verbatim in the UI).
class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

/// Preview info shown before the import runs.
class PlaylistImportDetails {
  final int songCount;
  final int estimatedSeconds;
  final double estimatedMinutes;
  final List<String> songs;

  /// Playlist name scraped from the source — pre-fills the "Playlist Name"
  /// dialog.
  final String? name;

  const PlaylistImportDetails({
    required this.songCount,
    required this.estimatedSeconds,
    required this.estimatedMinutes,
    required this.songs,
    this.name,
  });
}

class ImportService {
  /// Stage 1: scrape + preview. Fast — track names only, no YouTube matching.
  static Future<PlaylistImportDetails> fetchDetails(String url) async {
    final playlist = await PlaylistImporter.fetch(url);
    // ~1s per song to match on YouTube Music (matches the old server estimate).
    final estSeconds = playlist.tracks.length.clamp(1, 600);
    final songNames = playlist.tracks
        .map((t) => t.artist.isEmpty ? t.title : '${t.title} — ${t.artist}')
        .toList();
    return PlaylistImportDetails(
      songCount: playlist.tracks.length,
      estimatedSeconds: estSeconds,
      estimatedMinutes: estSeconds / 60.0,
      songs: songNames,
      name: playlist.name,
    );
  }

  /// Stage 2: scrape (cached from the preview) then resolve each track to a
  /// YouTube Music song. [onProgress] fires after each track (done, total) so
  /// the import job can show real progress. Unmatched tracks are skipped.
  static Future<List<SearchResult>> importPlaylist(
    String url, {
    int estimatedSeconds = 60,
    void Function(int done, int total)? onProgress,
  }) async {
    final playlist = await PlaylistImporter.fetch(url);
    final tracks = playlist.tracks;
    if (tracks.isEmpty) {
      throw const ImportException(
          'No songs could be imported from this playlist.');
    }

    final results = <SearchResult>[];
    for (var i = 0; i < tracks.length; i++) {
      try {
        final matches = await YtMusicService.searchSongs(tracks[i].query);
        if (matches.isNotEmpty) {
          results.add(SearchResult.fromYtMusic(matches.first));
        }
      } catch (_) {
        // Skip a track that fails to match; keep importing the rest.
      }
      onProgress?.call(i + 1, tracks.length);
    }
    return results;
  }
}
