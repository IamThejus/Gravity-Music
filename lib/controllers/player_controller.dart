// controllers/player_controller.dart
import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import '../services/autoplay_orchestrator.dart';
import '../services/library_service.dart';
import '../services/recommendation_service.dart';
import '../services/thumb_util.dart';

class ProgressBarState {
  final Duration current;
  final Duration buffered;
  final Duration total;
  const ProgressBarState({
    required this.current,
    required this.buffered,
    required this.total,
  });
}

enum PlayButtonState { paused, playing, loading }

class PlayerController extends GetxController {
  final AudioHandler audioHandler;
  PlayerController({required this.audioHandler});

  final currentSong        = Rxn<MediaItem>();
  final buttonState        = Rx<PlayButtonState>(PlayButtonState.paused);
  final progressBarState   = Rx<ProgressBarState>(
    const ProgressBarState(
      current: Duration.zero, buffered: Duration.zero, total: Duration.zero,
    ),
  );
  final errorMessage       = RxnString();
  final isLoopEnabled      = false.obs;
  final isShuffleEnabled   = false.obs;
  final isHighQuality      = true.obs;
  final cacheSongs         = false.obs;
  final isCurrentSongLiked = false.obs;
  final searchHistory      = <LibraryTrack>[].obs;
  final volume             = 100.0.obs;

  /// Sleep timer: when set, the time at which playback auto-pauses (null = off).
  final sleepTimerEnd      = Rxn<DateTime>();
  Timer? _sleepTimer;

  /// Watermark-driven queue refill. Created in onInit, stopped in onClose.
  late final AutoplayOrchestrator _autoplay;

  @override
  void onInit() {
    _loadSearchHistory();

    audioHandler.mediaItem.listen((item) {
      currentSong.value = item;
      if (item != null) {
        isCurrentSongLiked.value = LibraryService.isLiked(item.id);
        _saveSession();
      }
    });

    audioHandler.playbackState.listen((pbState) {
      final p = pbState.processingState;
      final PlayButtonState newButtonState;
      if (p == AudioProcessingState.loading ||
          p == AudioProcessingState.buffering) {
        newButtonState = PlayButtonState.loading;
      } else if (!pbState.playing) {
        newButtonState = PlayButtonState.paused;
      } else {
        newButtonState = PlayButtonState.playing;
      }
      buttonState.value = newButtonState;
    });

    AudioService.position.listen((pos) {
      final duration = currentSong.value?.duration ?? Duration.zero;
      final buffered = audioHandler.playbackState.value.bufferedPosition;
      progressBarState.value = ProgressBarState(
        current: pos, buffered: buffered, total: duration,
      );
    });

    final q = Hive.box('AppPrefs').get('streamingQuality') ?? 1;
    isHighQuality.value = q == 1;
    cacheSongs.value = Hive.box('AppPrefs').get('cacheSongs') ?? false;

    // Watermark-driven autoplay refill. Started AFTER the queue listeners
    // above so its own queue listener sees the same events. The callback
    // routes through addToQueue so QueueManager bookkeeping stays in sync.
    _autoplay = AutoplayOrchestrator(
      audioHandler: audioHandler,
      onTracksReady: (tracks) async {
        for (final t in tracks) {
          await addToQueue(t.videoId,
              title: t.title,
              artist: t.artist,
              thumbnail: t.thumbnail,
              duration: t.durationValue);
        }
      },
    );
    _autoplay.start();

    Future.delayed(const Duration(milliseconds: 500), _restoreSession);

    super.onInit();
  }

  @override
  void onClose() {
    _autoplay.stop();
    _sleepTimer?.cancel();
    super.onClose();
  }

  // ── Playback controls ─────────────────────────────────────────────────────

  void play()  => audioHandler.play();
  void pause() => audioHandler.pause();
  void next()  => audioHandler.skipToNext();
  void prev()  => audioHandler.skipToPrevious();
  void seek(Duration pos) => audioHandler.seek(pos);

  void toggleLoop() {
    isLoopEnabled.value = !isLoopEnabled.value;
    audioHandler.setRepeatMode(
      isLoopEnabled.value
          ? AudioServiceRepeatMode.one
          : AudioServiceRepeatMode.none,
    );
  }

  void toggleShuffle() {
    isShuffleEnabled.value = !isShuffleEnabled.value;
    audioHandler.setShuffleMode(
      isShuffleEnabled.value
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
  }

  /// Called by the audio handler when it resets shuffle internally — e.g.
  /// playAllFrom / playShuffled replace the queue with ordered (or one-shot
  /// pre-shuffled) playback and turn the engine's shuffle mode off. Without
  /// this the UI toggle would stay lit while the engine plays in order.
  void syncShuffleDisabled() {
    if (!isShuffleEnabled.value) return;
    isShuffleEnabled.value = false;
  }

  void toggleQuality() {
    isHighQuality.value = !isHighQuality.value;
    Hive.box('AppPrefs').put('streamingQuality', isHighQuality.value ? 1 : 0);
  }

  void toggleCacheSongs() {
    cacheSongs.value = !cacheSongs.value;
    Hive.box('AppPrefs').put('cacheSongs', cacheSongs.value);
  }

  void clearQueue() => audioHandler.customAction('clearQueue');

  // ── Volume ────────────────────────────────────────────────────────────────

  void setVolume(double v) {
    volume.value = v.clamp(0, 100);
    audioHandler.customAction('setVolume', {'value': volume.value.round()});
  }

  // ── Sleep timer ───────────────────────────────────────────────────────────

  void setSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    sleepTimerEnd.value = DateTime.now().add(d);
    _sleepTimer = Timer(d, () {
      pause();
      sleepTimerEnd.value = null;
      _sleepTimer = null;
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEnd.value = null;
  }

  // ── Core play methods ─────────────────────────────────────────────────────

  Future<void> playVideoId(
    String videoId, {
    String? title,
    String? artist,
    String? thumbnail,
    Duration? duration,
  }) async {
    errorMessage.value = null;
    final song = MediaItem(
      id: videoId,
      title: title ?? videoId,
      artist: artist,
      artUri: _hiResArt(thumbnail),
      duration: duration,
      extras: {'url': ''},
    );
    await audioHandler.customAction('setSourceNPlay', {'mediaItem': song});
  }

  Future<void> addToQueue(
    String videoId, {
    String? title,
    String? artist,
    String? thumbnail,
    Duration? duration,
  }) async {
    final song = MediaItem(
      id: videoId,
      title: title ?? videoId,
      artist: artist,
      artUri: _hiResArt(thumbnail),
      duration: duration,
      extras: {'url': ''},
    );
    await audioHandler.addQueueItem(song);
  }

  Future<void> playWithRecommendations(
    String videoId, {
    String? title,
    String? artist,
    String? thumbnail,
    Duration? duration,
  }) async {
    // Kick off rec fetch BEFORE awaiting URL resolution so the queue
    // populates in parallel with playback start, not serially after it.
    // Without this, the queue stays at length 1 for as long as the URL
    // fetch takes — meaning "next" early in playback finds no next song
    // and seek-zero-pauses the current track (user-visible: replay).
    final recsFuture = RecommendationService.getRecommendations(videoId);

    await playVideoId(videoId,
        title: title, artist: artist, thumbnail: thumbnail, duration: duration);

    recsFuture.then((recs) {
      // If the user already navigated away to a different song, don't
      // pollute the new queue with stale recommendations.
      if (currentSong.value?.id != videoId) return;
      for (final r in recs) {
        addToQueue(r.videoId,
            title: r.title,
            artist: r.artist,
            thumbnail: r.thumbnail,
            duration: r.durationValue);
      }
    });
  }

  Future<void> playAllMedia(List<MediaItem> items, {int startIndex = 0}) async {
    if (items.isEmpty) return;
    final clampedIndex = startIndex.clamp(0, items.length - 1);
    await audioHandler.customAction('playAllFrom', {
      'items': items,
      'startIndex': clampedIndex,
    });
  }

  Future<void> playShuffledMedia(List<MediaItem> items) async {
    if (items.isEmpty) return;
    await audioHandler.customAction('playShuffled', {'items': items});
  }

  // ── Like / Unlike ─────────────────────────────────────────────────────────

  void toggleLike() {
    final song = currentSong.value;
    if (song == null) return;
    final track = LibraryTrack(
      videoId: song.id,
      title: song.title,
      artist: song.artist ?? '',
      thumbnail: song.artUri?.toString() ?? '',
      duration: song.duration != null ? _fmtDuration(song.duration!) : '',
    );
    LibraryService.toggleLike(track);
    isCurrentSongLiked.value = LibraryService.isLiked(song.id);
  }

  // ── Search History ────────────────────────────────────────────────────────

  void addToSearchHistory(LibraryTrack track) {
    final list = List<LibraryTrack>.from(searchHistory);
    list.removeWhere((t) => t.videoId == track.videoId);
    list.insert(0, track);
    if (list.length > 10) list.removeLast();
    searchHistory.assignAll(list);
    _saveSearchHistory();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    _saveSearchHistory();
  }

  void _loadSearchHistory() {
    final raw = Hive.box('AppPrefs').get('searchHistory', defaultValue: []) as List;
    searchHistory.assignAll(
      raw.map((e) => LibraryTrack.fromMap(Map.from(e))).toList(),
    );
  }

  void _saveSearchHistory() {
    Hive.box('AppPrefs').put(
      'searchHistory',
      searchHistory.map((t) => t.toMap()).toList(),
    );
  }

  // ── Session Save / Restore ────────────────────────────────────────────────

  void _saveSession() {
    try {
      final q   = audioHandler.queue.value;
      final idx = audioHandler.playbackState.value.queueIndex ?? 0;
      final pos = progressBarState.value.current.inMilliseconds;
      if (q.isEmpty) return;
      Hive.box('AppPrefs').put('session', {
        'queue': q.map((m) => {
          'id':       m.id,
          'title':    m.title,
          'artist':   m.artist ?? '',
          'artUri':   m.artUri?.toString() ?? '',
          'duration': m.duration?.inMilliseconds ?? 0,
        }).toList(),
        'index': idx,
        'position': pos,
      });
    } catch (_) {}
  }

  Future<void> _restoreSession() async {
    try {
      final saved = Hive.box('AppPrefs').get('session');
      if (saved == null || saved is! Map) return;
      final rawQueue = saved['queue'] as List? ?? [];
      if (rawQueue.isEmpty) return;
      final items = rawQueue.map<MediaItem>((m) => MediaItem(
        id: m['id'] ?? '',
        title: m['title'] ?? '',
        artist: m['artist'],
        artUri: (m['artUri'] as String).isNotEmpty
            ? Uri.tryParse(m['artUri'])
            : null,
        duration: Duration(milliseconds: m['duration'] as int? ?? 0),
        extras: {'url': ''},
      )).where((m) => m.id.isNotEmpty).toList();

      if (items.isEmpty) return;

      final index = (saved['index'] as int? ?? 0).clamp(0, items.length - 1);
      final posMs = saved['position'] as int? ?? 0;

      await audioHandler.customAction('restoreSession', {
        'items': items,
        'index': index,
        'positionMs': posMs,
      });
    } catch (_) {}
  }

  void notifyError(String msg) {
    errorMessage.value = msg;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Upgrades a (typically 96px) thumbnail URL to a high-res artwork URL for
  /// the MediaItem's artUri, which drives the media notification / lockscreen
  /// art. Display surfaces (mini-player, lists) downsize this again via
  /// ThumbUtil, so the larger URL costs nothing extra where small art is shown.
  Uri? _hiResArt(String? thumbnail) {
    if (thumbnail == null || thumbnail.isEmpty) return null;
    return Uri.tryParse(ThumbUtil.get(thumbnail, ThumbnailSize.art));
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}