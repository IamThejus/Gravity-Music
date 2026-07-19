// services/cloud/sync_service.dart
//
// Optional cloud sync of liked songs + playlists. The UI's single entry point
// for account + sync state (GetX controller). Offline-first: when not signed in
// (or cloud isn't configured) every method is a safe no-op and the app behaves
// exactly as before.
//
// Strategy (see supabase/schema.sql):
//   • Hive ('LibraryBox') stays the source of truth on-device.
//   • On any local library change → debounced full push (upsert all rows, then
//     delete remote rows no longer present locally). Full-state push is robust
//     and handles unlikes / deletes without per-op bookkeeping; the data is
//     KBs so the cost is negligible.
//   • On sign-in → pull remote, UNION into local by id (nothing lost across
//     devices), write merged back, then push so remote reflects the union too.

import 'dart:async';

import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../library_service.dart';
import 'auth_service.dart';
import 'supabase_config.dart';

enum SyncStatus { idle, syncing, error }

class SyncService extends GetxController {
  static SyncService get to => Get.find();

  final Rxn<User> user = Rxn<User>();
  final Rx<SyncStatus> status = SyncStatus.idle.obs;
  final RxnString lastError = RxnString();

  Timer? _debounce;
  bool _busy = false;
  StreamSubscription<AuthState>? _authSub;

  bool get isSignedIn => user.value != null;
  String? get email => user.value?.email;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void onInit() {
    super.onInit();
    if (!AuthService.instance.isReady) return; // cloud not configured → offline

    user.value = AuthService.instance.currentUser;

    // Push local changes (debounced) whenever the library mutates.
    LibraryService.onChanged = _schedulelPush;

    // React to sign-in / sign-out.
    _authSub = AuthService.instance.authStateChanges.listen((state) {
      final newUser = state.session?.user;
      final wasSignedIn = user.value != null;
      user.value = newUser;
      if (newUser != null && !wasSignedIn) {
        _fullSync(); // just signed in → merge both ways
      }
    });

    // Already signed in from a previous session → reconcile on launch.
    if (user.value != null) _fullSync();
  }

  // ── Account actions (UI calls these) ───────────────────────────────────────

  Future<void> signIn() async {
    final u = await AuthService.instance.signInWithGoogle();
    if (u == null) return; // user cancelled the account picker
    user.value = u;
    // Drive the sync EXPLICITLY rather than relying on the auth-state listener.
    // The listener only syncs when it observes a signed-out→signed-in edge; if
    // this assignment landed first (a microtask-ordering race) it saw
    // `wasSignedIn == true` and skipped _fullSync entirely — leaving the
    // account signed in with nothing pulled down from Supabase. _fullSync is
    // _busy-guarded, so whichever path gets there first wins and the other
    // no-ops.
    await _fullSync();
  }

  Future<void> signOut() async {
    await AuthService.instance.signOut();
    user.value = null;
  }

  /// Manual "Sync now" (pull-to-refresh / settings button).
  Future<void> syncNow() => _fullSync();

  // ── Sync internals ─────────────────────────────────────────────────────────

  void _schedulelPush() {
    if (!isSignedIn) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _push);
  }

  /// Pull remote, union into local, then push the merged result.
  Future<void> _fullSync() async {
    if (!isSignedIn || _busy) return;
    _busy = true;
    status.value = SyncStatus.syncing;
    try {
      await _pullAndMerge();
      await _pushRows();
      status.value = SyncStatus.idle;
      lastError.value = null;
    } catch (e) {
      status.value = SyncStatus.error;
      lastError.value = e.toString();
    } finally {
      _busy = false;
    }
  }

  Future<void> _push() async {
    if (!isSignedIn || _busy) return;
    _busy = true;
    status.value = SyncStatus.syncing;
    try {
      await _pushRows();
      status.value = SyncStatus.idle;
      lastError.value = null;
    } catch (e) {
      status.value = SyncStatus.error;
      lastError.value = e.toString();
    } finally {
      _busy = false;
    }
  }

  Future<void> _pullAndMerge() async {
    final uid = user.value!.id;

    // Liked songs: local order first, then remote-only extras.
    final remoteLikedRows =
        await _db.from('liked_songs').select().eq('user_id', uid) as List;
    final mergedLiked = <String, LibraryTrack>{};
    for (final t in LibraryService.getLiked()) {
      mergedLiked[t.videoId] = t;
    }
    for (final r in remoteLikedRows) {
      final t = _likedFromRow(Map<String, dynamic>.from(r));
      mergedLiked.putIfAbsent(t.videoId, () => t);
    }
    LibraryService.replaceLiked(mergedLiked.values.toList());

    // Playlists: local wins on id conflict; append remote-only playlists.
    final remotePlRows =
        await _db.from('playlists').select().eq('user_id', uid) as List;
    final mergedPls = <String, LocalPlaylist>{};
    for (final p in LibraryService.getPlaylists()) {
      mergedPls[p.id] = p;
    }
    for (final r in remotePlRows) {
      final p = _playlistFromRow(Map<String, dynamic>.from(r));
      mergedPls.putIfAbsent(p.id, () => p);
    }
    LibraryService.replacePlaylists(mergedPls.values.toList());
  }

  /// Upsert all local rows, then delete remote rows that no longer exist
  /// locally (handles unlikes / playlist deletions).
  Future<void> _pushRows() async {
    final uid = user.value!.id;

    // ── Liked songs ──
    final liked = LibraryService.getLiked();
    if (liked.isEmpty) {
      await _db.from('liked_songs').delete().eq('user_id', uid);
    } else {
      await _db.from('liked_songs').upsert(liked
          .map((t) => {
                'user_id': uid,
                'video_id': t.videoId,
                'title': t.title,
                'artist': t.artist,
                'thumbnail': t.thumbnail,
                'duration': t.duration,
              })
          .toList());
      final ids = liked.map((t) => t.videoId).join(',');
      await _db
          .from('liked_songs')
          .delete()
          .eq('user_id', uid)
          .not('video_id', 'in', '($ids)');
    }

    // ── Playlists ──
    final pls = LibraryService.getPlaylists();
    if (pls.isEmpty) {
      await _db.from('playlists').delete().eq('user_id', uid);
    } else {
      await _db.from('playlists').upsert(pls
          .map((p) => {
                'user_id': uid,
                'id': p.id,
                'name': p.name,
                'created_at': p.createdAt.toIso8601String(),
                'tracks': p.tracks.map((t) => t.toMap()).toList(),
                'updated_at': DateTime.now().toIso8601String(),
              })
          .toList());
      final ids = pls.map((p) => p.id).join(',');
      await _db
          .from('playlists')
          .delete()
          .eq('user_id', uid)
          .not('id', 'in', '($ids)');
    }
  }

  LibraryTrack _likedFromRow(Map<String, dynamic> r) => LibraryTrack(
        videoId: r['video_id'] ?? '',
        title: r['title'] ?? '',
        artist: r['artist'] ?? '',
        thumbnail: r['thumbnail'] ?? '',
        duration: r['duration'] ?? '',
      );

  LocalPlaylist _playlistFromRow(Map<String, dynamic> r) => LocalPlaylist(
        id: r['id'] ?? '',
        name: r['name'] ?? '',
        createdAt: DateTime.tryParse(r['created_at'] ?? '') ?? DateTime.now(),
        tracks: (r['tracks'] as List? ?? [])
            .map((t) => LibraryTrack.fromMap(Map.from(t)))
            .toList(),
      );

  @override
  void onClose() {
    _debounce?.cancel();
    _authSub?.cancel();
    LibraryService.onChanged = null;
    super.onClose();
  }
}

/// Convenience used by main.dart to only register the controller when cloud
/// sync is actually configured.
bool get cloudSyncConfigured => SupabaseConfig.isConfigured;
