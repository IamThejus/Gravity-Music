// services/library_service.dart
// All local library CRUD — liked songs + custom playlists.
// Everything stored in Hive box 'LibraryBox'.
//
// Schema:
//   'liked'     → List<Map>   each map: {videoId,title,artist,thumbnail,duration}
//   'playlists' → List<Map>   each map: {id,name,createdAt,tracks:List<Map>}

import 'package:hive/hive.dart';

// ── Track model ────────────────────────────────────────────────────────────

class LibraryTrack {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnail;
  final String duration;

  const LibraryTrack({
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

  Map<String, dynamic> toMap() => {
        'videoId': videoId,
        'title': title,
        'artist': artist,
        'thumbnail': thumbnail,
        'duration': duration,
      };

  factory LibraryTrack.fromMap(Map m) => LibraryTrack(
        videoId: m['videoId'] ?? '',
        title: m['title'] ?? '',
        artist: m['artist'] ?? '',
        thumbnail: m['thumbnail'] ?? '',
        duration: m['duration'] ?? '',
      );
}

// ── Playlist model ─────────────────────────────────────────────────────────

class LocalPlaylist {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<LibraryTrack> tracks;

  const LocalPlaylist({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.tracks,
  });

  String get thumbnailUrl =>
      tracks.isNotEmpty ? tracks.first.thumbnail : '';

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'tracks': tracks.map((t) => t.toMap()).toList(),
      };

  factory LocalPlaylist.fromMap(Map m) => LocalPlaylist(
        id: m['id'] ?? '',
        name: m['name'] ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] ?? 0),
        tracks: (m['tracks'] as List? ?? [])
            .map((t) => LibraryTrack.fromMap(Map.from(t)))
            .toList(),
      );

  LocalPlaylist copyWith({String? name, List<LibraryTrack>? tracks}) =>
      LocalPlaylist(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        tracks: tracks ?? this.tracks,
      );
}

// ── LibraryService ─────────────────────────────────────────────────────────

class LibraryService {
  static Box get _box => Hive.box('LibraryBox');

  /// Fired after any local mutation (like/unlike, playlist create/edit/delete).
  /// SyncService subscribes to push changes to the cloud (debounced). Null when
  /// cloud sync is off, so this stays a zero-cost no-op for offline users.
  static void Function()? onChanged;
  static void _notify() => onChanged?.call();

  // ── Liked Songs ──────────────────────────────────────────────────────────

  static List<LibraryTrack> getLiked() {
    final raw = _box.get('liked', defaultValue: []) as List;
    return raw.map((e) => LibraryTrack.fromMap(Map.from(e))).toList();
  }

  static bool isLiked(String videoId) {
    return getLiked().any((t) => t.videoId == videoId);
  }

  static void like(LibraryTrack track) {
    final liked = getLiked();
    if (!liked.any((t) => t.videoId == track.videoId)) {
      liked.insert(0, track); // newest first
      _box.put('liked', liked.map((t) => t.toMap()).toList());
      _notify();
    }
  }

  static void unlike(String videoId) {
    final liked = getLiked()..removeWhere((t) => t.videoId == videoId);
    _box.put('liked', liked.map((t) => t.toMap()).toList());
    _notify();
  }

  /// Overwrite the entire liked list (used by sync's merge-on-login). Does NOT
  /// fire [onChanged] — the sync layer pushes explicitly after merging, so this
  /// avoids a redundant push loop.
  static void replaceLiked(List<LibraryTrack> tracks) {
    _box.put('liked', tracks.map((t) => t.toMap()).toList());
  }

  static void toggleLike(LibraryTrack track) {
    isLiked(track.videoId) ? unlike(track.videoId) : like(track);
  }

  // ── Playlists ────────────────────────────────────────────────────────────

  static List<LocalPlaylist> getPlaylists() {
    final raw = _box.get('playlists', defaultValue: []) as List;
    return raw.map((e) => LocalPlaylist.fromMap(Map.from(e))).toList();
  }

  static void _savePlaylists(List<LocalPlaylist> playlists) {
    _box.put('playlists', playlists.map((p) => p.toMap()).toList());
    _notify();
  }

  /// Overwrite all playlists (used by sync's merge-on-login). Does NOT fire
  /// [onChanged] (see [replaceLiked]).
  static void replacePlaylists(List<LocalPlaylist> playlists) {
    _box.put('playlists', playlists.map((p) => p.toMap()).toList());
  }

  static LocalPlaylist createPlaylist(String name) {
    final pl = LocalPlaylist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
      tracks: [],
    );
    final all = getPlaylists()..insert(0, pl);
    _savePlaylists(all);
    return pl;
  }

  /// Creates a playlist pre-populated with [tracks] in a single write (used by
  /// playlist import — avoids one box write per track). Duplicate video IDs are
  /// dropped, order preserved.
  static LocalPlaylist createPlaylistWithTracks(
      String name, List<LibraryTrack> tracks) {
    final seen = <String>{};
    final unique = <LibraryTrack>[];
    for (final t in tracks) {
      if (t.videoId.isNotEmpty && seen.add(t.videoId)) unique.add(t);
    }
    final pl = LocalPlaylist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
      tracks: unique,
    );
    final all = getPlaylists()..insert(0, pl);
    _savePlaylists(all);
    return pl;
  }

  static void deletePlaylist(String id) {
    final all = getPlaylists()..removeWhere((p) => p.id == id);
    _savePlaylists(all);
  }

  static void renamePlaylist(String id, String newName) {
    final all = getPlaylists();
    final idx = all.indexWhere((p) => p.id == id);
    if (idx != -1) all[idx] = all[idx].copyWith(name: newName);
    _savePlaylists(all);
  }

  static void addTrackToPlaylist(String playlistId, LibraryTrack track) {
    final all = getPlaylists();
    final idx = all.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final pl = all[idx];
    if (!pl.tracks.any((t) => t.videoId == track.videoId)) {
      all[idx] = pl.copyWith(tracks: [...pl.tracks, track]);
      _savePlaylists(all);
    }
  }

  static void removeTrackFromPlaylist(String playlistId, String videoId) {
    final all = getPlaylists();
    final idx = all.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final pl = all[idx];
    all[idx] = pl.copyWith(
        tracks: pl.tracks.where((t) => t.videoId != videoId).toList());
    _savePlaylists(all);
  }
}