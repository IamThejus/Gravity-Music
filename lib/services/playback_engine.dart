// services/playback_engine.dart
//
// Wraps the just_audio AudioPlayer + ConcatenatingAudioSource and owns the
// PlaybackPhase state machine. Knows nothing about audio_service queues,
// the customAction bus, or Hive — those stay in MyAudioHandler. The engine
// is the "what is the player doing right now and how do I drive it"
// boundary; the handler is the "audio_service contract + queue" boundary.
//
// Cross-class wiring uses two callbacks supplied at construction:
//   - shouldCacheSongs(): runtime check for the user's cache preference,
//     used by createSource() to choose LockCachingAudioSource vs plain URI.
//   - onTrackEnded(): fired when the engine detects the current source is
//     within 200ms of its duration during active playback. The handler
//     reacts by either looping or advancing the queue.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../util/log.dart';

// ── Playback state machine ──────────────────────────────────────────────────
// Single source of truth for "what is the player doing right now?"
// Mode flags (loop/shuffle/queueLoop/loudness) are intentionally NOT part
// of the phase — they are orthogonal to playback state.

enum PlaybackPhase {
  idle,        // no source loaded
  loading,     // resolving URL / preparing source
  buffering,   // source loaded, awaiting buffer (mid-playback rebuffer)
  ready,       // source loaded, paused or about to play
  playing,     // player.playing == true
  ended,       // current track at duration end, next-decision pending
  error,       // playback failed, recovery may follow
}

// Allowed transitions. Anything not listed here is logged as a warning but
// still applied — illegal transitions are bugs we want to see, not crash on.
const _legalTransitions = <PlaybackPhase, Set<PlaybackPhase>>{
  PlaybackPhase.idle: {
    PlaybackPhase.loading, PlaybackPhase.error,
  },
  PlaybackPhase.loading: {
    PlaybackPhase.buffering, PlaybackPhase.ready, PlaybackPhase.playing,
    PlaybackPhase.error, PlaybackPhase.idle,
  },
  PlaybackPhase.buffering: {
    PlaybackPhase.playing, PlaybackPhase.ready, PlaybackPhase.ended,
    PlaybackPhase.error, PlaybackPhase.loading,
  },
  PlaybackPhase.ready: {
    PlaybackPhase.playing, PlaybackPhase.loading, PlaybackPhase.buffering,
    PlaybackPhase.error, PlaybackPhase.idle,
  },
  PlaybackPhase.playing: {
    PlaybackPhase.buffering, PlaybackPhase.ready, PlaybackPhase.ended,
    PlaybackPhase.error, PlaybackPhase.loading,
  },
  PlaybackPhase.ended: {
    // ready = queue exhausted, source still loaded, now paused at end.
    PlaybackPhase.loading, PlaybackPhase.playing, PlaybackPhase.ready,
    PlaybackPhase.idle,
  },
  PlaybackPhase.error: {
    PlaybackPhase.loading, PlaybackPhase.idle,
  },
};

class PlaybackEngine {
  PlaybackEngine({
    required this.getCacheDir,
    required this.shouldCacheSongs,
    required this.onTrackEnded,
  });

  /// Closure so the engine doesn't need to wait for the temp directory at
  /// construction. The handler computes it asynchronously and the engine
  /// reads it lazily (only `createSource()` actually dereferences it).
  final String Function() getCacheDir;

  /// Runtime check for the user's "cache songs" preference. Read on every
  /// `createSource()` call so a toggle takes effect for the next track
  /// without restarting the engine.
  final bool Function() shouldCacheSongs;

  /// Fired when the current source reaches within 200ms of its duration
  /// during active playback. The engine has already transitioned phase to
  /// `ended` by the time this fires. The handler decides what's next
  /// (loop replay vs queue advance).
  final Future<void> Function() onTrackEnded;

  late final AudioPlayer player;
  final playList =
      ConcatenatingAudioSource(children: [], useLazyPreparation: false);

  PlaybackPhase _phase = PlaybackPhase.loading;
  PlaybackPhase get phase => _phase;

  /// True between requesting a source and the player being able to render
  /// audio. Kept derived (not a separate boolean) so it can't drift.
  bool get isSongLoading =>
      _phase == PlaybackPhase.loading || _phase == PlaybackPhase.buffering;

  /// Whether the currently-loaded source is a LockCachingAudioSource.
  /// Used by call sites that need to know if the disk cache is engaged.
  bool isPlayingUsingLockCachingSource = false;

  /// When on, volumes are adjusted per-track using the loudnessDb from
  /// HMStreamingData so quiet/loud tracks render at similar levels.
  bool loudnessNormalizationEnabled = false;

  /// Periodic sync-read of player.position. Catches the "just_audio stalls
  /// at dur-1s without ever emitting completed or further position updates"
  /// failure mode that listener-based detection alone can't see. Cancelled
  /// in dispose().
  Timer? _stallTimer;

  /// Boot the engine: create the AudioPlayer with our buffer config, attach
  /// the (empty) playlist source, and start the auto-advance listener.
  /// Idempotent — calling twice would re-listen, so callers should call once.
  void init() {
    player = AudioPlayer(
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          // Reduced from 120s → 30s. Saves ~2MB per skip vs old behaviour.
          // bufferForPlaybackDuration kept at original 50ms — critical for
          // LockCachingAudioSource compatibility (higher values cause a
          // position/duration race that triggers infinite song-skip loops).
          minBufferDuration: Duration(seconds: 20),
          maxBufferDuration: Duration(seconds: 30),
          bufferForPlaybackDuration: Duration(milliseconds: 50),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 2),
        ),
      ),
    );

    // Mobile uses the (initially empty) ConcatenatingAudioSource, populated via
    // playList.add() on each track change. Desktop (media_kit) does NOT reliably
    // reload a mutated ConcatenatingAudioSource — the first track plays but
    // subsequent clear()/add() swaps produce no audio — so on desktop each track
    // is loaded with setAudioSource() instead (see loadCurrent/clearForReload).
    if (!_isDesktop) {
      try {
        player.setAudioSource(playList);
      } catch (_) {
        // Setting an empty concatenating source throws on some platforms;
        // ignore — the first add() will succeed.
      }
    }

    _listenForTrackEnd();
  }

  /// True on desktop platforms, where media_kit backs just_audio.
  static final bool _isDesktop =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Stop the current track before loading the next. Mobile empties the
  /// ConcatenatingAudioSource; desktop pauses (setAudioSource will replace the
  /// source in [loadCurrent], so there is nothing to empty).
  Future<void> clearForReload() async {
    if (_isDesktop) {
      await player.pause();
    } else {
      await playList.clear();
    }
  }

  /// Load [source] as the current (single) track. Mobile appends to the
  /// ConcatenatingAudioSource; desktop replaces the player's source outright,
  /// which media_kit reloads reliably on every track change.
  Future<void> loadCurrent(AudioSource source) async {
    if (_isDesktop) {
      await player.setAudioSource(source);
    } else {
      await playList.add(source);
    }
  }

  /// Transition the phase, logging illegal moves but applying them anyway
  /// so we see real race conditions instead of crashing on them.
  void setPhase(PlaybackPhase next, {String? reason}) {
    if (next == _phase) return;
    final legal = _legalTransitions[_phase]?.contains(next) ?? false;
    logD('engine', '$_phase -> $next'
        '${reason != null ? " ($reason)" : ""}${legal ? "" : " [ILLEGAL]"}');
    if (!legal) {
      // ignore: avoid_print
      print('[phase] illegal transition: $_phase -> $next'
          '${reason != null ? " ($reason)" : ""}');
    }
    _phase = next;
  }

  /// Build an AudioSource for the given MediaItem. Uses
  /// LockCachingAudioSource (transparent disk cache) when the user's cache
  /// preference is on; falls back to a plain URI source otherwise. Also
  /// updates `isPlayingUsingLockCachingSource` as a side effect.
  AudioSource createSource(MediaItem item) {
    final url = item.extras!['url'] as String;
    // Locally-downloaded file → play straight off disk, no caching layer and
    // no network. (LockCachingAudioSource is for caching *remote* streams, so
    // it must not be used for an already-local file.)
    if (url.startsWith('file://')) {
      isPlayingUsingLockCachingSource = false;
      return AudioSource.uri(
          Uri.file(url.replaceFirst('file://', '')), tag: item);
    }
    if (shouldCacheSongs() && url.startsWith('http')) {
      isPlayingUsingLockCachingSource = true;
      return LockCachingAudioSource(
        Uri.parse(url),
        cacheFile: File('${getCacheDir()}/cachedSongs/${item.id}.mp3'),
        tag: item,
      );
    }
    isPlayingUsingLockCachingSource = false;
    return AudioSource.uri(Uri.parse(url), tag: item);
  }

  /// Set volume according to a loudness target of -5 dBFS, given the
  /// track's measured loudnessDb. Formula: vol = 10^((-5 - loudnessDb)/20).
  void normalizeVolume(double loudnessDb) {
    final diff = -5.0 - loudnessDb;
    final vol = pow(10.0, diff / 20.0).toDouble().clamp(0.0, 1.0);
    player.setVolume(vol);
  }

  /// End-of-track detection. Two triggers, de-duplicated by the phase guard
  /// in [_onPossibleEnd]:
  ///
  ///   1. positionStream reaches dur - 200ms during active playback. Fires
  ///      reliably when the player keeps emitting position updates through
  ///      the end of the track.
  ///
  ///   2. processingStateStream emits 'completed' AND the current position
  ///      is within 2s of duration. The position check is what makes this
  ///      safe vs the bug fixed in Step 2: ConcatenatingAudioSource.clear()
  ///      during a user-initiated track change also emits 'completed', but
  ///      with position at 0 (or far from the old duration), so the guard
  ///      rejects it.
  ///
  /// We need both triggers because just_audio sometimes stops emitting on
  /// positionStream before pos reaches dur-200 (final emission can be at
  /// dur-800ms or earlier), in which case (1) never fires and (2) is the
  /// only path that advances the queue.
  /// How close to duration the last position emission must come to count as
  /// end-of-track via the position stream. just_audio sometimes stops
  /// emitting position updates ~1s before the audio actually ends AND never
  /// transitions to ProcessingState.completed (the player just stalls). A
  /// 1.5s window is loose enough to catch that stall but still far enough
  /// from mid-song positions to never fire spuriously — a song's position
  /// in the middle is many seconds below dur - 1500.
  static const _positionEndWindowMs = 1500;

  void _listenForTrackEnd() {
    player.positionStream.listen((pos) async {
      if (_phase != PlaybackPhase.playing && _phase != PlaybackPhase.buffering) {
        return;
      }
      final dur = player.duration;
      if (dur == null || dur.inSeconds == 0) return;
      if (pos.inMilliseconds >= dur.inMilliseconds - _positionEndWindowMs) {
        await _onPossibleEnd(via: 'positionStream');
      }
    });

    player.processingStateStream.listen((state) async {
      if (state != ProcessingState.completed) return;
      if (_phase != PlaybackPhase.playing && _phase != PlaybackPhase.buffering) {
        return;
      }
      final pos = player.position;
      final dur = player.duration;
      if (dur == null || dur.inMilliseconds == 0) return;
      // Genuine end-of-track has position close to duration; spurious
      // 'completed' from clear() during track-change has position far
      // from duration (either old source's clear position or new source's
      // freshly-loaded 0).
      if (pos.inMilliseconds < dur.inMilliseconds - 2000) return;
      await _onPossibleEnd(via: 'processingState.completed');
    });

    // Trigger 3: periodic stall-check. positionStream sometimes stops
    // emitting BEFORE position enters the end window — last emission lands
    // at e.g. dur-3s and then nothing fires, even while the player thinks
    // it's still playing and position has crept further. The listeners
    // above can't see that because they only run on stream emissions.
    // Reading `player.position` synchronously returns the latest value
    // regardless. We check every 1s; mid-song reads are nowhere near the
    // window so the check is cheap.
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_phase != PlaybackPhase.playing && _phase != PlaybackPhase.buffering) {
        return;
      }
      final dur = player.duration;
      if (dur == null || dur.inSeconds == 0) return;
      final pos = player.position;
      if (pos.inMilliseconds >= dur.inMilliseconds - _positionEndWindowMs) {
        _onPossibleEnd(via: 'stall-check timer');
      }
    });
  }

  Future<void> _onPossibleEnd({required String via}) async {
    if (_phase == PlaybackPhase.ended) return; // already handling
    setPhase(PlaybackPhase.ended, reason: 'track ended via $via');
    await onTrackEnded();
  }

  Future<void> dispose() async {
    _stallTimer?.cancel();
    _stallTimer = null;
    setPhase(PlaybackPhase.idle, reason: 'engine dispose');
    await player.dispose();
  }
}
