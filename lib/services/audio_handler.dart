// audio_handler.dart
// MyAudioHandler is the audio_service-facing layer:
//   - BaseAudioHandler + GetxServiceMixin (notification / lockscreen contract)
//   - queue / mediaItem / playbackState BehaviorSubjects
//   - customAction command bus (UI talks to playback only through here)
//   - URL resolution via checkNGetUrl() + isolate-backed YouTube fetching
//
// The actual player (AudioPlayer + ConcatenatingAudioSource), the
// PlaybackPhase state machine, the audio-source factory, loudness
// normalization, and the auto-advance trigger live in PlaybackEngine.
// The queue's permutation/shuffle/loop logic lives in QueueManager.
// Predictive recommendation refill lives in AutoplayOrchestrator
// (wired from PlayerController).

import 'dart:io';
import 'dart:isolate';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/hm_streaming_data.dart';
import '../services/background_task.dart';
import '../services/download_service.dart';
import '../services/playlist_download_service.dart';
import '../services/library_service.dart';
import '../services/playback_engine.dart';
import '../services/quality_prefs.dart';
import '../services/queue_manager.dart';
import '../services/stream_service.dart';
import '../services/thumb_util.dart';
import '../controllers/player_controller.dart';
import '../ui/ui_helpers.dart';
import '../util/log.dart';

Future<AudioHandler> initAudioService() async {
  return AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ytplayer.audio',
      androidNotificationChannelName: 'Gravity Music',
      // Monochrome status-bar icon (res/drawable/ic_stat_music.xml). Without
      // this, audio_service falls back to the full-color launcher icon, which
      // Android flattens to a solid white square in the notification.
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// Check if a stream URL has expired (30-minute safety buffer).
/// Mirrors HarmonyMusic's isExpired() util.
bool _isUrlExpired(String url) {
  final match = RegExp(r'expire=(\d+)').firstMatch(url);
  if (match != null) {
    final epoch = int.parse(match.group(1)!);
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1800 >= epoch;
  }
  return true; // assume expired if no expiry found
}

// ── MyAudioHandler ─────────────────────────────────────────────────────────

class MyAudioHandler extends BaseAudioHandler with GetxServiceMixin {
  dynamic currentIndex;
  late String? currentSongUrl;

  /// Playback mode flag (loop ONE track on natural end). Orthogonal to the
  /// queue-loop flag (which lives on QueueManager). Persisted in Hive.
  bool loopModeEnabled = false;

  /// Temp-dir path used by LockCachingAudioSource. Computed asynchronously
  /// in [_initCacheDir]; empty until then. The engine reads it lazily via
  /// the `getCacheDir` callback and falls back to a plain URI source when
  /// it's still empty.
  String _cacheDir = '';

  // ── Queue state ───────────────────────────────────────────────────────
  // Owned by QueueManager. Backward-compat getters for any historical
  // call site that reads these as instance fields on MyAudioHandler.
  final _queueMgr = QueueManager();
  bool get shuffleModeEnabled => _queueMgr.shuffleEnabled;
  bool get queueLoopModeEnabled => _queueMgr.queueLoopEnabled;

  // ── Playback engine ───────────────────────────────────────────────────
  // Owns the AudioPlayer, the ConcatenatingAudioSource, the PlaybackPhase
  // state machine, the auto-advance listener, and the source factory.
  late final PlaybackEngine _engine;

  /// Backward-compat re-exports of engine state. UI / external readers can
  /// keep using these field names; they delegate to the engine now.
  PlaybackPhase get phase => _engine.phase;
  bool get isSongLoading => _engine.isSongLoading;
  bool get isPlayingUsingLockCachingSource =>
      _engine.isPlayingUsingLockCachingSource;
  bool get loudnessNormalizationEnabled =>
      _engine.loudnessNormalizationEnabled;
  set loudnessNormalizationEnabled(bool v) =>
      _engine.loudnessNormalizationEnabled = v;

  MyAudioHandler() {
    _engine = PlaybackEngine(
      getCacheDir: () => _cacheDir,
      shouldCacheSongs: () => Get.find<PlayerController>().cacheSongs.isTrue,
      onTrackEnded: _triggerNext,
    );
    _engine.init();

    _notifyAboutPlaybackEvents();
    _listenForDurationChanges();

    final prefs = Hive.box('AppPrefs');
    loopModeEnabled = prefs.get('loopMode') ?? false;
    _queueMgr.shuffleEnabled = prefs.get('shuffleMode') ?? false;
    _queueMgr.queueLoopEnabled = prefs.get('queueLoopMode') ?? false;
    _engine.loudnessNormalizationEnabled =
        prefs.get('loudnessNormalization') ?? false;

    // Fire-and-forget. Until this resolves, the engine's createSource()
    // sees an empty cacheDir and falls back to plain URI sources. By the
    // time the first URL fetch completes the temp dir is ready.
    _initCacheDir();
  }

  Future<void> _initCacheDir() async {
    _cacheDir = (await getTemporaryDirectory()).path;
    final dir = Directory('$_cacheDir/cachedSongs/');
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  // ── Playback event broadcasting ────────────────────────────────────────────
  // Bridges the AudioPlayer's PlaybackEvent stream into audio_service's
  // playbackState subject. The notification + lockscreen controls render
  // off this subject, so we must keep it current.

  void _notifyAboutPlaybackEvents() {
    _engine.player.playbackEventStream.listen(
      (PlaybackEvent event) {
        final playing = _engine.player.playing;
        playbackState.add(playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: isSongLoading
              ? AudioProcessingState.loading
              : {
                  ProcessingState.idle: AudioProcessingState.idle,
                  ProcessingState.loading: AudioProcessingState.loading,
                  ProcessingState.buffering: AudioProcessingState.buffering,
                  ProcessingState.ready: AudioProcessingState.ready,
                  ProcessingState.completed: AudioProcessingState.completed,
                }[_engine.player.processingState]!,
          playing: playing,
          updatePosition: _engine.player.position,
          bufferedPosition: _engine.player.bufferedPosition,
          speed: _engine.player.speed,
          queueIndex: currentIndex,
        ));
      },
      onError: (Object e, StackTrace st) async {
        logD('handler', 'playbackEvent error — ${e.runtimeType}: $e '
            '(index=$currentIndex) → re-fetching fresh URL');
        // On any playback error, re-fetch a fresh URL (same recovery as HarmonyMusic)
        final curPos = _engine.player.position;
        await _engine.player.stop();
        customAction('playByIndex', {'index': currentIndex, 'newUrl': true});
        await _engine.player.seek(curPos, index: 0);
      },
    );
  }

  // The auto-advance trigger lives on the engine. When the engine detects
  // the current source is within 200ms of duration during active playback,
  // it transitions phase to 'ended' and invokes this callback. We then
  // decide whether to loop the current source or advance the queue.
  Future<void> _triggerNext() async {
    if (loopModeEnabled) {
      await _engine.player.seek(Duration.zero);
      if (!_engine.player.playing) _engine.player.play();
      _engine.setPhase(PlaybackPhase.playing, reason: 'loop replay');
      return;
    }
    await skipToNext();
    // Phase is advanced inside playByIndex when the new source is ready,
    // or set to 'ready' by skipToNext's exhausted-queue branch.
  }

  void _listenForDurationChanges() {
    _engine.player.durationStream.listen((duration) async {
      final currQueue = queue.value;
      if (currentIndex == null || currQueue.isEmpty || duration == null) return;
      final currentSong = currQueue[currentIndex];
      if (currentSong.duration == null || currentIndex == 0) {
        mediaItem.add(currentSong.copyWith(duration: duration));
      }
    });
  }

  // ── Queue management ───────────────────────────────────────────────────────

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    // Dedup against the current queue. Two recommendation paths
    // (playWithRecommendations and AutoplayOrchestrator) can race on the
    // same seed and both try to append the same list — without this
    // filter, songs end up repeated in identical order. Also filters
    // dupes within the incoming batch itself.
    final existingIds = queue.value.map((m) => m.id).toSet();
    final filtered = <MediaItem>[];
    for (final item in mediaItems) {
      if (existingIds.add(item.id)) filtered.add(item);
    }
    if (filtered.isEmpty) return;
    final newQueue = queue.value..addAll(filtered);
    queue.add(newQueue);
    _queueMgr.onItemsAdded(filtered);
  }

  @override
  Future<void> addQueueItem(MediaItem item) async {
    // Silently skip if this track is already queued. See addQueueItems
    // comment for the race this prevents.
    if (queue.value.any((m) => m.id == item.id)) return;
    _queueMgr.onItemsAdded([item]);
    final newQueue = queue.value..add(item);
    queue.add(newQueue);
  }

  @override
  Future<void> removeQueueItem(MediaItem item) async {
    _queueMgr.onItemRemoved(item.id);
    final currQueue = queue.value;
    final currSong = mediaItem.value;
    final idx = currQueue.indexOf(item);
    if (currentIndex > idx) currentIndex -= 1;
    currQueue.remove(item);
    queue.add(currQueue);
    mediaItem.add(currSong);
  }

  @override
  Future<void> updateQueue(List<MediaItem> items) async {
    final newQueue = queue.value..replaceRange(0, queue.value.length, items);
    queue.add(newQueue);
  }

  // ── Playback controls ─────────────────────────────────────────────────────

  @override
  Future<void> play() async {
    if (currentSongUrl == null) {
      await customAction('playByIndex', {'index': currentIndex});
      return;
    }
    await _engine.player.play();
    _engine.setPhase(PlaybackPhase.playing, reason: 'user play');
  }

  @override
  Future<void> pause() async {
    await _engine.player.pause();
    // Only transition if we were actually playing — pause from non-playing
    // states (loading, ended) is a no-op for phase.
    if (_engine.phase == PlaybackPhase.playing) {
      _engine.setPhase(PlaybackPhase.ready, reason: 'user pause');
    }
  }

  @override
  Future<void> seek(Duration position) => _engine.player.seek(position);

  @override
  Future<void> stop() async {
    await _engine.player.stop();
    _engine.setPhase(PlaybackPhase.idle, reason: 'user stop');
    return super.stop();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    await customAction('playByIndex', {'index': index});
  }

  @override
  Future<void> skipToNext() async {
    final index = _getNextSongIndex();
    if (index != currentIndex) {
      if (_engine.player.position != Duration.zero) {
        await _engine.player.seek(Duration.zero);
      }
      await customAction('playByIndex', {'index': index});
      return;
    }
    // Queue exhausted. Behavior depends on what triggered the skip:
    //   - phase == ended: song ended naturally, queue is out of tracks.
    //     Pause and reset to start so the user can replay.
    //   - otherwise: user pressed "next" mid-playback with no next track.
    //     Do nothing — keep playing. Restarting the current song is a
    //     confusing default ("I asked for forward, you went backward").
    if (_engine.phase == PlaybackPhase.ended) {
      await _engine.player.pause();
      await _engine.player.seek(Duration.zero);
      _engine.setPhase(PlaybackPhase.ready,
          reason: 'queue exhausted at end of song');
    }
  }

  // How far into the current track "previous" restarts it instead of going
  // back a song. Standard music-player behavior (Spotify/Apple use ~3s).
  static const _prevRestartThresholdMs = 3000;

  @override
  Future<void> skipToPrevious() async {
    // If we're past the threshold, restart the current song rather than
    // jumping back. Await the seek so the position/progress bar is actually
    // at zero before we return (an un-awaited seek can flash the old time).
    if (_engine.player.position.inMilliseconds > _prevRestartThresholdMs) {
      await _engine.player.seek(Duration.zero);
      return;
    }
    await _engine.player.seek(Duration.zero);
    final index = _getPrevSongIndex();
    if (index != currentIndex) {
      await customAction('playByIndex', {'index': index});
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async {
    loopModeEnabled = mode != AudioServiceRepeatMode.none;
    Hive.box('AppPrefs').put('loopMode', loopModeEnabled);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) async {
    if (mode == AudioServiceShuffleMode.none) {
      _queueMgr.disableShuffle();
    } else {
      _queueMgr.enableShuffle(queue.value, currentIndex);
    }
    Hive.box('AppPrefs').put('shuffleMode', _queueMgr.shuffleEnabled);
  }

  // ── Index helpers ─────────────────────────────────────────────────────────

  // Navigation delegates to QueueManager. QueueManager returns null when
  // the queue is exhausted; we preserve the legacy "return currentIndex
  // on exhaustion" contract here because skipToNext/skipToPrevious rely
  // on the index==currentIndex check to detect that case.
  int _getNextSongIndex() {
    return _queueMgr.nextIndex(queue.value, currentIndex) ?? currentIndex;
  }

  int _getPrevSongIndex() {
    return _queueMgr.prevIndex(queue.value, currentIndex) ?? currentIndex;
  }

  // ── Prefetch next song URL ────────────────────────────────────────────────
  // Called after playByIndex so the next song's URL is already in Hive
  // cache when the user skips or the song ends — zero loading delay.

  void _prefetchNext() {
    try {
      final q = queue.value;
      // Shuffle-aware peek (non-mutating) so we warm the cache for the song
      // that will ACTUALLY play next, not just currentIndex + 1.
      final nextIdx = _queueMgr.peekNextIndex(q, currentIndex);
      if (nextIdx == null || nextIdx < 0 || nextIdx >= q.length) return;
      final nextId = q[nextIdx].id;
      // Fire and forget — just warms the cache
      checkNGetUrl(nextId).catchError((_) {});
    } catch (_) {}
  }

  // ── URL resolution — mirrors HarmonyMusic's checkNGetUrl() ───────────────
  // Priority: cached file → downloaded file → cached URL → fresh Isolate fetch

  Future<HMStreamingData> checkNGetUrl(String videoId,
      {bool generateNewUrl = false}) async {
    logD('url', 'checkNGetUrl($videoId) start');
    final urlCacheBox = Hive.box('SongsUrlCache');
    final qualityPref = readQualityPref();

    // 0. Offline download — highest priority. If the track is downloaded,
    //    play straight off disk and never touch the network.
    final offlineUrl = DownloadService.playbackUrlFor(videoId);
    if (offlineUrl != null) {
      return HMStreamingData(
        playable: true,
        statusMSG: 'OK',
        formats: [
          Audio(
            itag: 140,
            audioCodec: Codec.mp4a,
            bitrate: 0,
            duration: 0,
            loudnessDb: DownloadService.loudnessFor(videoId),
            url: offlineUrl,
            size: 0,
          ),
        ],
      );
    }

    // 0b. Playlist offline download — same offline-first benefit, but stored
    //     separately so it never shows up in the Downloads tab.
    final playlistOfflineUrl = PlaylistDownloadService.playbackUrlFor(videoId);
    if (playlistOfflineUrl != null) {
      return HMStreamingData(
        playable: true,
        statusMSG: 'OK',
        formats: [
          Audio(
            itag: 140,
            audioCodec: Codec.mp4a,
            bitrate: 0,
            duration: 0,
            loudnessDb: PlaylistDownloadService.loudnessFor(videoId),
            url: playlistOfflineUrl,
            size: 0,
          ),
        ],
      );
    }

    // 1. Check if URL is cached and still valid
    if (urlCacheBox.containsKey(videoId) && !generateNewUrl) {
      final cached = urlCacheBox.get(videoId);
      if (cached is Map && !_isUrlExpired(_cachedUrl(cached))) {
        final data = HMStreamingData.fromJson(Map<String, dynamic>.from(cached));
        data.setQualityPref(qualityPref);
        return data;
      }
    }

    // 2. Fetch fresh from YouTube in a background Isolate (same as HarmonyMusic)
    logD('url', 'checkNGetUrl($videoId): cache miss — fetching in isolate '
        '(newUrl=$generateNewUrl)');
    final token = RootIsolateToken.instance!;
    final Map<String, dynamic> json;
    try {
      json = await Isolate.run(() => getStreamInfo(videoId, token));
    } catch (e, st) {
      logD('url', 'checkNGetUrl($videoId): ISOLATE THREW — ${e.runtimeType}: $e');
      logD('url', st.toString());
      rethrow;
    }
    final data = HMStreamingData.fromJson(json);
    final url = data.audio?.url ?? '';
    logD('url', 'checkNGetUrl($videoId): playable=${data.playable} '
        'status="${data.statusMSG}" hasUrl=${url.isNotEmpty}');

    if (data.playable) {
      urlCacheBox.put(videoId, json);
    }

    data.setQualityPref(qualityPref);
    return data;
  }

  /// Pull any stream URL out of a cached entry to run the expiry check against.
  /// Handles both the current `formats` list shape and the legacy low/high one.
  String _cachedUrl(Map cached) {
    final formats = cached['formats'];
    if (formats is List && formats.isNotEmpty) {
      return (formats.first as Map?)?['url'] ?? '';
    }
    return cached['highQualityAudio']?['url'] ??
        cached['lowQualityAudio']?['url'] ??
        '';
  }

  // ── Android Auto browsing ──────────────────────────────────────────────────
  // audio_service already runs a MediaBrowserService (the AudioService declared
  // in AndroidManifest extends MediaBrowserServiceCompat) and exposes it to
  // Android Auto via the MediaBrowserService intent-filter + the car meta-data
  // in the manifest. So Android Auto support is purely a matter of answering the
  // browse tree here — there is NO second player and NO second service. A song
  // tapped in the car routes through the same customAction('playAllFrom') the
  // in-app UI uses, so the queue / engine / playbackState are identical and the
  // phone and car stay in sync automatically (it's one ExoPlayer).
  //
  // Tree (mirrors the app's Library → Playlists):
  //   root           → [ "Playlists" ]
  //   playlists      → one browsable node per LocalPlaylist
  //   playlist/<id>  → one playable node per track
  static const _rootId = 'root';
  static const _playlistsId = 'playlists';
  static const _playlistPrefix = 'playlist/';
  static const _songPrefix = 'song/';

  LocalPlaylist? _playlistById(String id) {
    for (final p in LibraryService.getPlaylists()) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    // Top level: a single "Playlists" folder (mirrors the in-app structure).
    if (parentMediaId == _rootId) {
      return [
        const MediaItem(id: _playlistsId, title: 'Playlists', playable: false),
      ];
    }

    // The "Playlists" folder: one browsable node per saved playlist.
    if (parentMediaId == _playlistsId) {
      return LibraryService.getPlaylists()
          .map((p) => MediaItem(
                id: '$_playlistPrefix${p.id}',
                title: p.name,
                playable: false,
                artUri: p.thumbnailUrl.isNotEmpty
                    ? Uri.tryParse(
                        ThumbUtil.get(p.thumbnailUrl, ThumbnailSize.card))
                    : null,
              ))
          .toList();
    }

    // A specific playlist: its tracks, each playable.
    if (parentMediaId.startsWith(_playlistPrefix)) {
      final id = parentMediaId.substring(_playlistPrefix.length);
      final playlist = _playlistById(id);
      if (playlist == null) return [];
      return playlist.tracks
          .map((t) => MediaItem(
                // Encode the playlist context so playFromMediaId can rebuild the
                // queue from the right playlist (queue items themselves still use
                // the bare videoId via toMediaItem()).
                id: '$_songPrefix$id/${t.videoId}',
                title: prettyTitle(t.title),
                artist: t.artist,
                duration:
                    t.durationValue == Duration.zero ? null : t.durationValue,
                artUri: t.thumbnail.isNotEmpty
                    ? Uri.tryParse(
                        ThumbUtil.get(t.thumbnail, ThumbnailSize.art))
                    : null,
                playable: true,
              ))
          .toList();
    }

    return const [];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    if (mediaId == _playlistsId) {
      return const MediaItem(
          id: _playlistsId, title: 'Playlists', playable: false);
    }
    if (mediaId.startsWith(_playlistPrefix)) {
      final p = _playlistById(mediaId.substring(_playlistPrefix.length));
      if (p != null) {
        return MediaItem(id: mediaId, title: p.name, playable: false);
      }
    }
    return null;
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    // Only song nodes are playable: 'song/<playlistId>/<videoId>'.
    if (!mediaId.startsWith(_songPrefix)) return;
    final rest = mediaId.substring(_songPrefix.length);
    final sep = rest.indexOf('/');
    if (sep == -1) return;
    final playlistId = rest.substring(0, sep);
    final videoId = rest.substring(sep + 1);

    final playlist = _playlistById(playlistId);
    if (playlist == null || playlist.tracks.isEmpty) return;

    final items = playlist.tracks.map((t) => t.toMediaItem()).toList();
    var startIndex =
        playlist.tracks.indexWhere((t) => t.videoId == videoId);
    if (startIndex < 0) startIndex = 0;

    // Exact same path the in-app "play this playlist from this track" uses —
    // one queue, one engine, one playbackState shared with the phone UI.
    await customAction(
        'playAllFrom', {'items': items, 'startIndex': startIndex});
  }

  // ── customAction — internal command bus ───────────────────────────────────
  // All complex operations go through here (mirrors HarmonyMusic's pattern).

  @override
  Future<void> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    switch (name) {

      // ── Play a song by queue index ──────────────────────────────────────
      case 'playByIndex':
        final songIndex = extras!['index'] as int;
        currentIndex = songIndex;
        final isNewUrl = extras['newUrl'] ?? false;
        final song = queue.value[currentIndex];

        // Set phase BEFORE teardown awaits. _playList.clear() emits
        // ProcessingState.completed (just_audio treats an emptied
        // ConcatenatingAudioSource as "all consumed"). If we set phase
        // after, the canonical track-end listener fires on that spurious
        // completed and causes a double-advance.
        _engine.setPhase(PlaybackPhase.loading, reason: 'playByIndex start');

        // ── Stop current playback IMMEDIATELY so old song never bleeds ──
        // Pause + clear BEFORE the async URL fetch. Without this,
        // just_audio keeps playing the old source while we await
        // checkNGetUrl(), causing the old song to bleed briefly.
        await _engine.player.pause();
        await _engine.clearForReload();
        currentSongUrl = null;
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.loading,
          playing: false,
        ));
        mediaItem.add(song);

        // Fetch URL (cached or fresh) — now happens with player fully stopped
        final streamInfo =
            await checkNGetUrl(song.id, generateNewUrl: isNewUrl);

        // Guard: user may have skipped again while we were fetching
        if (songIndex != currentIndex) return;

        if (!streamInfo.playable) {
          currentSongUrl = null;
          _engine.setPhase(PlaybackPhase.error,
              reason: 'playByIndex unplayable');
          Get.find<PlayerController>().notifyError(streamInfo.statusMSG);
          playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorMessage: streamInfo.statusMSG,
          ));
          return;
        }

        currentSongUrl = song.extras!['url'] = streamInfo.audio!.url;
        await _engine.loadCurrent(_engine.createSource(song));

        _engine.setPhase(PlaybackPhase.ready,
            reason: 'playByIndex source ready');
        playbackState
            .add(playbackState.value.copyWith(queueIndex: currentIndex));

        if (_engine.loudnessNormalizationEnabled) {
          _engine.normalizeVolume(streamInfo.audio!.loudnessDb);
        }

        await _engine.player.play();
        _engine.setPhase(PlaybackPhase.playing,
            reason: 'playByIndex playing');

        // Silently prefetch the next song's URL into cache
        _prefetchNext();
        break;

      // ── Load a single song and play immediately ─────────────────────────
      case 'setSourceNPlay':
        final song = extras!['mediaItem'] as MediaItem;
        _engine.setPhase(PlaybackPhase.loading,
            reason: 'setSourceNPlay start');
        currentIndex = 0;
        await _engine.clearForReload();
        mediaItem.add(song);
        queue.add([song]);

        final streamInfo = await checkNGetUrl(song.id);

        if (!streamInfo.playable) {
          currentSongUrl = null;
          // Debug aid: log the YouTube URL of the song that failed to play so
          // unplayable (removed / region-locked / private) videos can be
          // identified. Compiled out of release builds.


          _engine.setPhase(PlaybackPhase.error,
              reason: 'setSourceNPlay unplayable');
          Get.find<PlayerController>().notifyError(streamInfo.statusMSG);
          // Broadcast the error state so the UI leaves the loading spinner.
          // Without this, isSongLoading keeps the last-pushed processingState
          // pinned to `loading` (no further playbackEvent fires after this
          // early return), so a tapped-but-unplayable song spins forever.
          // The other play paths (playByIndex/playAllFrom/playShuffled) already
          // do this; setSourceNPlay was the one that didn't.
          playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            playing: false,
            errorMessage: streamInfo.statusMSG,
          ));
          return;
        }

        currentSongUrl = song.extras!['url'] = streamInfo.audio!.url;
        await _engine.loadCurrent(_engine.createSource(song));
        _engine.setPhase(PlaybackPhase.ready,
            reason: 'setSourceNPlay source ready');

        if (_engine.loudnessNormalizationEnabled) {
          _engine.normalizeVolume(streamInfo.audio!.loudnessDb);
        }

        await _engine.player.play();
        _engine.setPhase(PlaybackPhase.playing,
            reason: 'setSourceNPlay playing');
        break;

      // ── Reorder queue ───────────────────────────────────────────────────
      case 'reorderQueue':
        final oldIndex = extras!['oldIndex'] as int;
        int newIndex = extras['newIndex'] as int;
        if (oldIndex < newIndex) newIndex--;
        final q = queue.value;
        final current = q[currentIndex];
        final item = q.removeAt(oldIndex);
        q.insert(newIndex, item);
        currentIndex = q.indexOf(current);
        queue.add(q);
        mediaItem.add(current);
        break;

      // ── Insert next in queue ────────────────────────────────────────────
      case 'addPlayNextItem':
        final song = extras!['mediaItem'] as MediaItem;
        final q = queue.value;
        q.insert(currentIndex + 1, song);
        queue.add(q);
        _queueMgr.onItemInsertedAfterCurrent(song.id);
        break;

      // ── Clear all but current ───────────────────────────────────────────
      case 'clearQueue':
        customAction('reorderQueue',
            {'oldIndex': currentIndex, 'newIndex': 0});
        final q = queue.value;
        q.removeRange(1, q.length);
        queue.add(q);
        _queueMgr.onClearedExceptCurrent(q.first.id);
        break;

      // ── Dismiss the player entirely ─────────────────────────────────────
      // Stops playback and tears the whole session down: empties the queue and
      // nulls the current media item so the mini-player disappears and the
      // screen reclaims the space. Playback resumes only when the user starts
      // something new. (PlayerController also clears the saved session so this
      // survives a restart.)
      case 'dismissPlayer':
        // pause() not stop() — see playAllFrom for why stop() bleeds the last
        // position into the next track. clearForReload() empties the source so
        // playback is silenced while the player stays alive (resetting the
        // timeline to 0 when the user next plays something).
        await _engine.player.pause();
        await _engine.clearForReload();
        _engine.setPhase(PlaybackPhase.idle, reason: 'dismissPlayer');
        currentSongUrl = null;
        currentIndex = 0;
        queue.add([]);
        mediaItem.add(null);
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
        ));
        break;

      // ── Toggle loudness normalisation ───────────────────────────────────
      case 'toggleLoudnessNormalization':
        _engine.loudnessNormalizationEnabled = extras!['enable'] as bool;
        Hive.box('AppPrefs').put(
            'loudnessNormalization', _engine.loudnessNormalizationEnabled);
        if (!_engine.loudnessNormalizationEnabled) {
          _engine.player.setVolume(1.0);
        }
        break;

      // ── Toggle queue loop ───────────────────────────────────────────────
      case 'toggleQueueLoop':
        _queueMgr.queueLoopEnabled = extras!['enable'] as bool;
        Hive.box('AppPrefs').put('queueLoopMode', _queueMgr.queueLoopEnabled);
        break;

      // ── Set volume (0–100) ──────────────────────────────────────────────
      case 'setVolume':
        _engine.player.setVolume((extras!['value'] as int) / 100);
        break;

      // ── Reload current track at the newly-selected quality ──────────────
      // Re-resolves the current song's URL against the updated qualityPref and
      // swaps the source in place, restoring playback position so the switch
      // feels seamless. No-op when nothing is loaded.
      case 'reloadCurrentQuality':
        if (currentIndex < 0 || currentIndex >= queue.value.length) break;
        final item = queue.value[currentIndex];
        final reloadIndex = currentIndex;
        final wasPlaying = _engine.player.playing;
        final pos = _engine.player.position;

        await _engine.player.pause();
        await _engine.clearForReload();

        // The disk cache (LockCachingAudioSource) is keyed by videoId only, so
        // it holds bytes at the OLD quality. Drop it so the new tier is fetched
        // and re-cached. Downloaded/offline files aren't cached this way.
        try {
          final cacheFile =
              File('${_engine.getCacheDir()}/cachedSongs/${item.id}.mp3');
          if (await cacheFile.exists()) await cacheFile.delete();
        } catch (_) {}

        final streamInfo =
            await checkNGetUrl(item.id, generateNewUrl: true);

        // Guard: user may have skipped while we were fetching.
        if (reloadIndex != currentIndex) break;
        if (!streamInfo.playable || streamInfo.audio == null) {
          _engine.setPhase(PlaybackPhase.error,
              reason: 'reloadCurrentQuality unplayable');
          break;
        }

        currentSongUrl = item.extras!['url'] = streamInfo.audio!.url;
        await _engine.loadCurrent(_engine.createSource(item));
        await _engine.player.seek(pos);
        if (_engine.loudnessNormalizationEnabled) {
          _engine.normalizeVolume(streamInfo.audio!.loudnessDb);
        }
        if (wasPlaying) await _engine.player.play();
        break;

      // ── Restore saved session on app start ─────────────────────────────
      case 'restoreSession':
        final items = extras!['items'] as List<MediaItem>;
        final restoreIndex = extras['index'] as int;
        final posMs = extras['positionMs'] as int? ?? 0;
        if (items.isEmpty) break;

        // Rebuild queue without playing yet
        queue.add(items);
        currentIndex = restoreIndex;
        mediaItem.add(items[restoreIndex]);

        _engine.setPhase(PlaybackPhase.loading,
            reason: 'restoreSession start');
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.loading,
        ));

        final restoreStream = await checkNGetUrl(items[restoreIndex].id);
        if (!restoreStream.playable) {
          _engine.setPhase(PlaybackPhase.error,
              reason: 'restoreSession unplayable');
          break;
        }

        currentSongUrl = items[restoreIndex].extras!['url'] =
            restoreStream.audio!.url;
        await _engine.clearForReload();
        await _engine.loadCurrent(_engine.createSource(items[restoreIndex]));
        _engine.setPhase(PlaybackPhase.ready,
            reason: 'restoreSession source ready');
        playbackState.add(playbackState.value.copyWith(
          queueIndex: restoreIndex,
          processingState: AudioProcessingState.ready,
        ));
        // Seek to saved position but don't auto-play — user resumes manually
        await _engine.player.seek(Duration(milliseconds: posMs));
        _prefetchNext();
        break;

      // ── Replace queue with given items and play from index ─────────────
      case 'playAllFrom':
        final rawItems = extras!['items'] as List;
        final items = rawItems.cast<MediaItem>();
        if (items.isEmpty) break;

        var startIndex = extras['startIndex'] as int? ?? 0;
        if (startIndex < 0 || startIndex >= items.length) {
          startIndex = 0;
        }

        // Set phase BEFORE teardown awaits (see playByIndex for rationale).
        _engine.setPhase(PlaybackPhase.loading,
            reason: 'playAllFrom start');

        // Reset queue state for ordered playback (clears shuffle, etc.)
        _queueMgr.reset();
        Hive.box('AppPrefs').put('shuffleMode', false);
        Get.find<PlayerController>().syncShuffleDisabled();

        // Pause (NOT stop) before clearing the source. stop() releases the
        // platform player and retains the last position; the subsequent
        // play() then resumes the NEW track from the OLD track's position
        // (or, if it overruns the shorter track, somewhere mid/ahead). pause()
        // keeps the player alive so clear()+add() resets the timeline to 0 —
        // the same pattern playByIndex/setSourceNPlay use without the bug.
        await _engine.player.pause();
        await _engine.clearForReload();

        queue.add(items);
        currentIndex = startIndex;
        final currentItem = items[startIndex];
        mediaItem.add(currentItem);
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.loading,
          playing: false,
        ));

        final streamInfo = await checkNGetUrl(currentItem.id);
        if (!streamInfo.playable) {
          currentSongUrl = null;
          _engine.setPhase(PlaybackPhase.error,
              reason: 'playAllFrom unplayable');
          Get.find<PlayerController>().notifyError(streamInfo.statusMSG);
          playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorMessage: streamInfo.statusMSG,
          ));
          break;
        }

        currentSongUrl = currentItem.extras!['url'] = streamInfo.audio!.url;
        await _engine.loadCurrent(_engine.createSource(currentItem));

        _engine.setPhase(PlaybackPhase.ready,
            reason: 'playAllFrom source ready');
        playbackState.add(playbackState.value.copyWith(
          queueIndex: currentIndex,
          processingState: AudioProcessingState.ready,
        ));

        if (_engine.loudnessNormalizationEnabled) {
          _engine.normalizeVolume(streamInfo.audio!.loudnessDb);
        }

        await _engine.player.play();
        _engine.setPhase(PlaybackPhase.playing,
            reason: 'playAllFrom playing');
        _prefetchNext();
        break;

      // ── Replace queue with shuffled items and play ─────────────────────
      case 'playShuffled':
        final rawShuffleItems = extras!['items'] as List;
        final shuffleItems = rawShuffleItems.cast<MediaItem>();
        if (shuffleItems.isEmpty) break;

        // Set phase BEFORE teardown awaits (see playByIndex for rationale).
        _engine.setPhase(PlaybackPhase.loading,
            reason: 'playShuffled start');

        // This is a one-shot shuffled queue; do not enable global shuffle mode.
        _queueMgr.reset();
        Hive.box('AppPrefs').put('shuffleMode', false);
        Get.find<PlayerController>().syncShuffleDisabled();

        // pause() not stop() — see playAllFrom for why stop() bleeds the
        // previous track's seek position into the new one.
        await _engine.player.pause();
        await _engine.clearForReload();

        queue.add(shuffleItems);
        currentIndex = 0;
        final firstItem = shuffleItems.first;
        mediaItem.add(firstItem);
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.loading,
          playing: false,
        ));

        final shuffleStream = await checkNGetUrl(firstItem.id);
        if (!shuffleStream.playable) {
          currentSongUrl = null;
          _engine.setPhase(PlaybackPhase.error,
              reason: 'playShuffled unplayable');
          Get.find<PlayerController>().notifyError(shuffleStream.statusMSG);
          playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorMessage: shuffleStream.statusMSG,
          ));
          break;
        }

        currentSongUrl = firstItem.extras!['url'] = shuffleStream.audio!.url;
        await _engine.loadCurrent(_engine.createSource(firstItem));

        _engine.setPhase(PlaybackPhase.ready,
            reason: 'playShuffled source ready');
        playbackState.add(playbackState.value.copyWith(
          queueIndex: currentIndex,
          processingState: AudioProcessingState.ready,
        ));

        if (_engine.loudnessNormalizationEnabled) {
          _engine.normalizeVolume(shuffleStream.audio!.loudnessDb);
        }

        await _engine.player.play();
        _engine.setPhase(PlaybackPhase.playing,
            reason: 'playShuffled playing');
        _prefetchNext();
        break;

      // ── Dispose ─────────────────────────────────────────────────────────
      case 'dispose':
        await _engine.dispose();
        super.stop();
        break;

      default:
        break;
    }
  }
}
