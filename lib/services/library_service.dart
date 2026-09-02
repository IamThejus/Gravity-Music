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

  /// When this track was added to the playlist it belongs to. Null for tracks
  /// saved before this field existed (and for liked songs, which keep their own
  /// ordering) — sorting treats null as "older than anything timestamped",
  /// which is true, and falls back to stored order among themselves.
  final DateTime? addedAt;

  const LibraryTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.duration,
    this.addedAt,
  });

  LibraryTrack copyWith({
    String? videoId,
    String? title,
    String? artist,
    String? thumbnail,
    String? duration,
    DateTime? addedAt,
  }) =>
      LibraryTrack(
        videoId: videoId ?? this.videoId,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        thumbnail: thumbnail ?? this.thumbnail,
        duration: duration ?? this.duration,
        addedAt: addedAt ?? this.addedAt,
      );

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
        // Omitted when null so existing rows round-trip byte-identically.
        if (addedAt != null) 'addedAt': addedAt!.millisecondsSinceEpoch,
      };

  factory LibraryTrack.fromMap(Map m) => LibraryTrack(
        videoId: m['videoId'] ?? '',
        title: m['title'] ?? '',
        artist: m['artist'] ?? '',
        thumbnail: m['thumbnail'] ?? '',
        duration: m['duration'] ?? '',
        addedAt: m['addedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(m['addedAt'] as int)
            : null,
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
      // Stamped so sorting is exact going forward; older entries fall back to
      // stored position (see PlaylistSort.apply's storedNewestFirst).
      final stamped =
          track.addedAt == null ? track.copyWith(addedAt: DateTime.now()) : track;
      liked.insert(0, stamped); // newest first
      _box.put('liked', liked.map((t) => t.toMap()).toList());
      _notify();
    }
  }

  /// Move a liked song within the stored (custom) order.
  static void reorderLiked(int oldIndex, int newIndex) {
    final liked = getLiked();
    if (oldIndex < 0 || oldIndex >= liked.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, liked.length - 1);
    if (newIndex == oldIndex) return;
    liked.insert(newIndex, liked.removeAt(oldIndex));
    _box.put('liked', liked.map((t) => t.toMap()).toList());
    _notify();
  }

  /// Liked songs share the per-playlist sort store under a reserved key — it
  /// can't collide with a real playlist id (those are epoch-millis strings).
  static const String likedSortKey = '__liked__';

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

  // ── Repointing a dead track ──────────────────────────────────────────────

  /// Point every library entry for [oldId] at [newId] instead, in place.
  ///
  /// Imported playlists store a videoId that a fuzzy title/artist match picked
  /// at import time; YouTube can later refuse that exact video while the same
  /// song is perfectly playable under a different id. TrackRematchService finds
  /// the replacement, and this persists it so the repair is permanent rather
  /// than repeated on every play.
  ///
  /// The user's own metadata (title, artist, position, addedAt) is preserved —
  /// only the id, and optionally the artwork/duration that came with the new
  /// match, are rewritten. Writing through the normal save paths means
  /// [onChanged] fires, so a signed-in user's cloud copy is pushed by the
  /// existing debounced sync; no separate remote write is needed here.
  ///
  /// If [newId] is already present alongside [oldId], the stale entry is
  /// dropped rather than duplicated.
  ///
  /// Returns the number of entries rewritten — 0 is normal and means the track
  /// isn't saved anywhere (playing from search, radio, or a generated mix).
  static int replaceVideoId(
    String oldId,
    String newId, {
    String? thumbnail,
    String? duration,
  }) {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return 0;
    var changed = 0;

    List<LibraryTrack> rewrite(List<LibraryTrack> tracks) {
      final alreadyHasNew = tracks.any((t) => t.videoId == newId);
      final out = <LibraryTrack>[];
      for (final t in tracks) {
        if (t.videoId != oldId) {
          out.add(t);
          continue;
        }
        changed++;
        // Collapse rather than duplicate when the replacement is already here.
        if (alreadyHasNew) continue;
        out.add(t.copyWith(
          videoId: newId,
          thumbnail: (thumbnail != null && thumbnail.isNotEmpty)
              ? thumbnail
              : null,
          duration:
              (duration != null && duration.isNotEmpty) ? duration : null,
        ));
      }
      return out;
    }

    final liked = getLiked();
    final before = changed;
    final newLiked = rewrite(liked);
    if (changed != before) {
      _box.put('liked', newLiked.map((t) => t.toMap()).toList());
      _notify();
    }

    final playlists = getPlaylists();
    final beforePl = changed;
    final newPls = [
      for (final p in playlists) p.copyWith(tracks: rewrite(p.tracks)),
    ];
    if (changed != beforePl) _savePlaylists(newPls);

    return changed;
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
    _clearPlaylistSort(id);
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
      // Stamp the add time here rather than at every call site, so "sort by
      // date added" works no matter where the track came from.
      final stamped = track.addedAt == null
          ? track.copyWith(addedAt: DateTime.now())
          : track;
      all[idx] = pl.copyWith(tracks: [...pl.tracks, stamped]);
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

  /// Move a track within a playlist. [oldIndex]/[newIndex] are positions in the
  /// playlist's stored (custom) order — callers showing a sorted view must map
  /// back to stored indices first, which is why drag is only offered in
  /// [PlaylistSort.custom].
  static void reorderPlaylistTracks(
      String playlistId, int oldIndex, int newIndex) {
    final all = getPlaylists();
    final idx = all.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final tracks = [...all[idx].tracks];
    if (oldIndex < 0 || oldIndex >= tracks.length) return;
    // ReorderableList reports newIndex in the pre-removal coordinate space.
    if (newIndex > oldIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, tracks.length - 1);
    if (newIndex == oldIndex) return;
    tracks.insert(newIndex, tracks.removeAt(oldIndex));
    all[idx] = all[idx].copyWith(tracks: tracks);
    _savePlaylists(all);
  }

  // ── Per-playlist sort preference ─────────────────────────────────────────
  //
  // Stored OUTSIDE LocalPlaylist (its own Hive key, keyed by playlist id) on
  // purpose: LocalPlaylist.toMap() is the cloud-sync payload, and the remote
  // `playlists` table has no column for this. Keeping it local means signing in
  // can't clobber the user's view preference, and sync needs no migration.

  static Map<String, String> _sortPrefs() {
    final raw = _box.get('playlistSort', defaultValue: <dynamic, dynamic>{});
    return Map<String, String>.from(raw as Map);
  }

  static PlaylistSort getPlaylistSort(String playlistId) =>
      PlaylistSort.fromKey(_sortPrefs()[playlistId]);

  static void setPlaylistSort(String playlistId, PlaylistSort sort) {
    final prefs = _sortPrefs();
    if (sort == PlaylistSort.custom) {
      prefs.remove(playlistId); // default — don't store noise
    } else {
      prefs[playlistId] = sort.key;
    }
    _box.put('playlistSort', prefs);
    // Deliberately no _notify(): this is a local view preference, not library
    // data, so it must not trigger a cloud push.
  }

  /// Drop a playlist's saved sort preference (called when it's deleted).
  static void _clearPlaylistSort(String playlistId) {
    final prefs = _sortPrefs()..remove(playlistId);
    _box.put('playlistSort', prefs);
  }
}

/// How a playlist's tracks are ordered on screen. [custom] is the stored order
/// — what drag-and-drop edits; the others are views over it and leave the
/// stored order untouched.
enum PlaylistSort {
  custom('custom', 'Custom order'),
  newestAdded('newest', 'Newest added'),
  oldestAdded('oldest', 'Oldest added');

  final String key;
  final String label;
  const PlaylistSort(this.key, this.label);

  static PlaylistSort fromKey(String? key) => values.firstWhere(
        (v) => v.key == key,
        orElse: () => PlaylistSort.custom,
      );

  /// Apply this ordering to [tracks] without mutating the input.
  ///
  /// Tracks saved before `addedAt` existed have no timestamp, but their stored
  /// position still encodes add order (adds append). So each such track gets a
  /// synthetic key of `index - length`: always negative, therefore always older
  /// than any real epoch timestamp, while preserving their relative sequence.
  /// That makes "Newest added" correctly reverse a legacy playlist instead of
  /// leaving it untouched.
  /// [storedNewestFirst] describes what stored position means for tracks with
  /// no timestamp. Playlists append (index 0 = oldest), but liked songs are
  /// inserted at the front (index 0 = newest), so the synthetic key has to be
  /// flipped for them or legacy liked songs sort backwards.
  List<LibraryTrack> apply(List<LibraryTrack> tracks,
      {bool storedNewestFirst = false}) {
    if (this == PlaylistSort.custom) return tracks;
    final n = tracks.length;
    final indexed = List.generate(n, (i) {
      final ms = tracks[i].addedAt?.millisecondsSinceEpoch;
      final synthetic = storedNewestFirst ? -i : (i - n);
      return (i, tracks[i], ms ?? synthetic);
    });
    indexed.sort((a, b) {
      var cmp = a.$3.compareTo(b.$3);
      if (this == PlaylistSort.newestAdded) cmp = -cmp;
      // Only reachable for identical real timestamps; keep stored order there
      // (Dart's List.sort is not stable on its own).
      if (cmp == 0) cmp = a.$1.compareTo(b.$1);
      return cmp;
    });
    return [for (final e in indexed) e.$2];
  }
}