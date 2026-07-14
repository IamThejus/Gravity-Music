// ui/now_playing/now_playing_screen.dart
//
// Full-screen player. Pure UI over the existing PlayerController /
// LyricsController / MyAudioHandler — no playback logic is duplicated here.
// The artwork uses a Hero (tag `np-art`) shared with the mini-player so the
// expand/collapse transition is a true shared-element morph.

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/lyrics_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/library_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../theme/dynamic_color_controller.dart';
import '../theme/glass.dart';
import '../theme/motion.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';

const String kNowPlayingArtTag = 'np-art';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final colors = Get.find<DynamicColorController>();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      // Never let the soft keyboard (e.g. still open from Search during the
      // expand transition) squeeze the body — it caused a transient overflow.
      resizeToAvoidBottomInset: false,
      body: Obx(() {
        // Dynamic wash from album art bleeding into pure black (Z0 layer).
        final base = colors.base.value;
        return AnimatedContainer(
          duration: AppMotion.large,
          curve: AppMotion.emphasized,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base, AppColors.canvas, Colors.black],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                _PlayerBody(pc: pc),
                _LyricsOverlay(),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _PlayerBody extends StatefulWidget {
  final PlayerController pc;
  const _PlayerBody({required this.pc});

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody>
    with SingleTickerProviderStateMixin {
  // One controller drives a single GROUPED reveal: the top bar and the whole
  // control cluster fade + rise in unison (not a 5-stage cascade) while the
  // artwork morphs in via the Hero. Presenting the controls together — rather
  // than staggering them in over 600ms — is the Apple-Music move: the screen
  // reads "ready" almost immediately instead of waiting for the last row.
  // 300ms total = a ~60ms lead (Interval start 0.2) so it begins as the art
  // lands, then a 240ms decelerate reveal.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..forward();

  late final Animation<double> _content = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.2, 1.0, curve: AppMotion.decelerate),
  );

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  /// Fade + gentle 8px rise, shared by every revealed group so they move as
  /// one (a grouped reveal, not a cascade).
  Widget _reveal(Widget child) {
    return AnimatedBuilder(
      animation: _content,
      child: child,
      builder: (_, c) => Opacity(
        opacity: _content.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - _content.value.clamp(0.0, 1.0)) * 8),
          child: c,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pc = widget.pc;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenMargin),
      child: Column(
        children: [
          _reveal(_TopBar()),
          // ── Artwork (flexible — shrinks on short heights, no overflow) ─
          // Not staggered: it morphs in from the mini-player via the Hero.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.stackMd),
              child: Center(
                child: Obx(() {
                  final art = sizedThumb(
                      pc.currentSong.value?.artUri?.toString(),
                      ThumbnailSize.art);
                  return AspectRatio(
                    aspectRatio: 1,
                    child: Hero(
                      tag: kNowPlayingArtTag,
                      // Match the mini-player Hero: straight-line morph (no arc)
                      // so push and pop both expand/contract the art directly.
                      createRectTween: (begin, end) =>
                          RectTween(begin: begin, end: end),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.xl),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x66000000),
                                blurRadius: 44,
                                offset: Offset(0, 20)),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: art.isEmpty
                            ? Container(
                                color: AppColors.card,
                                child: const Icon(Icons.music_note_rounded,
                                    size: 80, color: AppColors.textTertiary))
                            : CachedNetworkImage(
                                imageUrl: art,
                                fit: BoxFit.cover,
                                // Artwork is drawn at most ~screen-width; cap the
                                // decode there instead of the source resolution.
                                memCacheWidth: (MediaQuery.sizeOf(context).width *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .round()
                                    .clamp(1, 2048)),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          // ── Controls cluster — revealed as ONE group (title, seek bar,
          //    transport, secondary actions move in unison) ───────────────
          _reveal(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() {
                  final song = pc.currentSong.value;
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(prettyTitle(song?.title ?? 'Nothing playing'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.heading(size: 26)),
                            const SizedBox(height: 4),
                            Text(prettyTitle(song?.artist ?? ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.subtitle(
                                    size: 16,
                                    color: AppColors.textSecondaryHi)),
                          ],
                        ),
                      ),
                      Obx(() => GlassIconButton(
                            icon: pc.isCurrentSongLiked.value
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            iconColor: pc.isCurrentSongLiked.value
                                ? AppColors.accent
                                : Colors.white,
                            onTap: pc.toggleLike,
                          )),
                    ],
                  );
                }),
                const SizedBox(height: AppSpacing.stackMd),
                _SeekBar(pc: pc),
                const SizedBox(height: AppSpacing.stackSm),
                _Controls(pc: pc),
                const SizedBox(height: AppSpacing.stackMd),
                _SecondaryBar(pc: pc),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.gutter),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GlassIconButton(
          icon: Icons.keyboard_arrow_down_rounded,
          iconSize: 26,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Text('NOW PLAYING',
              textAlign: TextAlign.center, style: AppText.label()),
        ),
        GlassIconButton(
          icon: Icons.more_horiz_rounded,
          onTap: () => _showMoreSheet(context),
        ),
      ],
    );
  }

  void _showQualitySheet(BuildContext context) {
    final pc = Get.find<PlayerController>();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassContainer(
        radius: AppRadius.xl,
        fill: AppColors.card.withOpacity(0.7),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
        child: Obx(() {
          final options = pc.currentQualityOptions();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Streaming quality',
                      style: AppText.title(size: 16)),
                ),
              ),
              const SizedBox(height: 8),
              if (options.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Only one quality is available for this track.',
                        style: AppText.subtitle()),
                  ),
                )
              else
                ...options.map((opt) => ListTile(
                      leading: Icon(
                        opt.selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: opt.selected
                            ? AppColors.accent
                            : AppColors.textSecondaryHi,
                      ),
                      title: Text(opt.label, style: AppText.title(size: 15)),
                      trailing:
                          Text(opt.detail, style: AppText.subtitle()),
                      onTap: () {
                        if (!opt.selected) pc.setQuality(opt.pref);
                        Navigator.pop(context);
                      },
                    )),
            ],
          );
        }),
      ),
    );
  }

  void _showMoreSheet(BuildContext context) {
    final pc = Get.find<PlayerController>();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassContainer(
        radius: AppRadius.xl,
        fill: AppColors.card.withOpacity(0.7),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded, color: Colors.white),
              title: Text('Add to playlist', style: AppText.title(size: 15)),
              onTap: () {
                Navigator.pop(context);
                final song = pc.currentSong.value;
                if (song != null) showAddToPlaylistSheet(context, song);
              },
            ),
            Obx(() {
              final dc = Get.find<DownloadController>();
              final song = pc.currentSong.value;
              final id = song?.id ?? '';
              final done = dc.isDownloaded(id);
              final busy = dc.isDownloading(id);
              return ListTile(
                leading: Icon(
                  done
                      ? Icons.download_done_rounded
                      : Icons.download_rounded,
                  color: done ? Colors.greenAccent : Colors.white,
                ),
                title: Text(
                    done
                        ? 'Downloaded'
                        : busy
                            ? 'Downloading…'
                            : 'Download',
                    style: AppText.title(size: 15)),
                trailing: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : (done
                        ? Text('Tap to remove', style: AppText.subtitle())
                        : null),
                onTap: () {
                  if (song == null) return;
                  final track = LibraryTrack(
                    videoId: song.id,
                    title: song.title,
                    artist: song.artist ?? '',
                    thumbnail: song.artUri?.toString() ?? '',
                    duration:
                        song.duration != null ? fmtDuration(song.duration!) : '',
                  );
                  if (done) {
                    dc.delete(id);
                    Navigator.pop(context);
                  } else if (!busy) {
                    Navigator.pop(context);
                    dc.startDownload(track);
                  }
                },
              );
            }),
            ListTile(
              leading: const Icon(Icons.high_quality_rounded, color: Colors.white),
              title: Text('Streaming quality', style: AppText.title(size: 15)),
              trailing: Obx(() => Text(
                  pc.currentQualityLabel(),
                  style: AppText.subtitle())),
              onTap: () {
                Navigator.pop(context);
                _showQualitySheet(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined, color: Colors.white),
              title: Text('Sleep timer', style: AppText.title(size: 15)),
              onTap: () {
                Navigator.pop(context);
                pc.setSleepTimer(const Duration(minutes: 30));
                Get.snackbar('Sleep timer', 'Playback will pause in 30 min',
                    snackPosition: SnackPosition.BOTTOM,
                    backgroundColor: AppColors.card,
                    colorText: Colors.white);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_remove_rounded, color: Colors.white),
              title: Text('Clear queue', style: AppText.title(size: 15)),
              onTap: () {
                pc.clearQueue();
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  final PlayerController pc;
  const _SeekBar({required this.pc});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final colors = Get.find<DynamicColorController>();
    return Obx(() {
      final bar = widget.pc.progressBarState.value;
      final total = bar.total.inMilliseconds.toDouble();
      final pos = bar.current.inMilliseconds.toDouble().clamp(0, total);
      final value = _dragValue ?? (total > 0 ? pos : 0);
      final remaining = bar.total - bar.current;

      return Column(
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: colors.accent.value,
              inactiveTrackColor: AppColors.glassFillActive,
              thumbColor: Colors.white,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              min: 0,
              max: total > 0 ? total : 1,
              value: value.toDouble(),
              onChanged: total > 0
                  ? (v) => setState(() => _dragValue = v)
                  : null,
              onChangeEnd: (v) {
                widget.pc.seek(Duration(milliseconds: v.round()));
                setState(() => _dragValue = null);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(fmtDuration(bar.current), style: AppText.caption()),
                Text('-${fmtDuration(remaining.isNegative ? Duration.zero : remaining)}',
                    style: AppText.caption()),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _Controls extends StatelessWidget {
  final PlayerController pc;
  const _Controls({required this.pc});

  @override
  Widget build(BuildContext context) {
    final colors = Get.find<DynamicColorController>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Obx(() => _IconBtn(
              icon: Icons.shuffle_rounded,
              active: pc.isShuffleEnabled.value,
              activeColor: colors.accent.value,
              onTap: pc.toggleShuffle,
            )),
        _IconBtn(icon: Icons.skip_previous_rounded, size: 40, onTap: pc.prev),
        // ── Play / Pause hero button ──────────────────────────────────
        Obx(() {
          final state = pc.buttonState.value;
          return GestureDetector(
            onTap: () {
              AppHaptics.medium();
              state == PlayButtonState.playing ? pc.pause() : pc.play();
            },
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 24,
                      offset: Offset(0, 8)),
                ],
              ),
              child: state == PlayButtonState.loading
                  ? const Padding(
                      padding: EdgeInsets.all(22),
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.black))
                  : Icon(
                      state == PlayButtonState.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.black,
                      size: 40),
            ),
          );
        }),
        _IconBtn(icon: Icons.skip_next_rounded, size: 40, onTap: pc.next),
        Obx(() => _IconBtn(
              icon: Icons.repeat_one_rounded,
              active: pc.isLoopEnabled.value,
              activeColor: colors.accent.value,
              onTap: pc.toggleLoop,
            )),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final bool active;
  final Color activeColor;

  const _IconBtn({
    required this.icon,
    required this.onTap,
    this.size = 28,
    this.active = false,
    this.activeColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () {
        AppHaptics.light();
        onTap();
      },
      icon: Icon(icon,
          size: size,
          color: active ? activeColor : AppColors.textSecondaryHi),
    );
  }
}

class _SecondaryBar extends StatelessWidget {
  final PlayerController pc;
  const _SecondaryBar({required this.pc});

  @override
  Widget build(BuildContext context) {
    final lyrics = Get.find<LyricsController>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Obx(() => GlassIconButton(
              icon: Icons.lyrics_outlined,
              iconColor: lyrics.isAvailable.value
                  ? Colors.white
                  : AppColors.textTertiary,
              onTap: () {
                if (!lyrics.isAvailable.value) {
                  Get.snackbar('Lyrics', 'No lyrics found for this track',
                      snackPosition: SnackPosition.BOTTOM,
                      backgroundColor: AppColors.card,
                      colorText: Colors.white);
                  return;
                }
                lyrics.openLyrics();
              },
            )),
        GlassIconButton(
          icon: Icons.cast_rounded,
          onTap: () => Get.snackbar('Cast', 'Casting is coming soon',
              snackPosition: SnackPosition.BOTTOM,
              backgroundColor: AppColors.card,
              colorText: Colors.white),
        ),
        GlassIconButton(
          icon: Icons.queue_music_rounded,
          onTap: () => showQueueSheet(context),
        ),
      ],
    );
  }
}

// ── Lyrics overlay ───────────────────────────────────────────────────────────

class _LyricsOverlay extends StatefulWidget {
  @override
  State<_LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends State<_LyricsOverlay> {
  final lyrics = Get.find<LyricsController>();
  final pc = Get.find<PlayerController>();
  late final Worker _posWorker;
  late final Worker _activeWorker;
  late final Worker _openWorker;
  late final Worker _modeWorker;
  final ItemScrollController _itemScroll = ItemScrollController();

  // Where the active line sits vertically in the full-list view: 0 = top,
  // 1 = bottom. 0.4 keeps the current line just above centre so a few upcoming
  // lines stay visible.
  static const double _activeAlignment = 0.4;

  @override
  void initState() {
    super.initState();
    // Keep the active line in sync with playback while open. Registered ONCE
    // here (previously this lived in build(), leaking a listener per rebuild).
    _posWorker = ever(pc.progressBarState, (ProgressBarState s) {
      if (lyrics.isOpen.value) lyrics.updatePlaybackPosition(s.current);
    });
    // Auto-centre the active line. ScrollablePositionedList scrolls by INDEX,
    // so it works for any line height and even when the target is off-screen
    // (e.g. after a seek) — unlike the old fixed-pixel math.
    _activeWorker = ever(lyrics.activeIndex, (int i) {
      if (!lyrics.isOpen.value || !lyrics.hasSynced.value) return;
      if (lyrics.focusMode.value) return; // focus view has no scroll list
      if (i < 0 || !_itemScroll.isAttached) return;
      _itemScroll.scrollTo(
        index: i,
        alignment: _activeAlignment,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    });
    // Centre immediately when the sheet is opened or the user switches back to
    // the full list — the per-line auto-scroll above only fires on the *next*
    // line change, which could leave the current line off-centre for seconds.
    _openWorker = ever(lyrics.isOpen, (bool open) {
      if (open) _centerNow();
    });
    _modeWorker = ever(lyrics.focusMode, (_) => _centerNow());
  }

  /// Jump (no animation) so the current line is centred right after a build.
  /// Reads activeIndex non-reactively (we're inside a worker callback, not an
  /// Obx), so it never creates a spurious dependency.
  void _centerNow() {
    if (!lyrics.hasSynced.value || lyrics.focusMode.value) return;
    final i = lyrics.activeIndex.value;
    if (i < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_itemScroll.isAttached) {
        _itemScroll.jumpTo(index: i, alignment: _activeAlignment);
      }
    });
  }

  @override
  void dispose() {
    _posWorker.dispose();
    _activeWorker.dispose();
    _openWorker.dispose();
    _modeWorker.dispose();
    // Leaving Now Playing (swipe-back / minimise to the mini-player pops this
    // route) must not leave the lyrics tab "open" — otherwise it reappears the
    // next time the screen is opened. Reset so lyrics only show on explicit tap.
    lyrics.closeLyrics();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!lyrics.isOpen.value) return const SizedBox.shrink();
      return Positioned.fill(
        child: GlassContainer(
          radius: 0,
          blur: 28,
          border: false,
          fill: Colors.black.withOpacity(0.55),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Row(
                  children: [
                    Expanded(child: Text('LYRICS', style: AppText.label())),
                    // Mode toggle — only meaningful for synced lyrics.
                    Obx(() => lyrics.hasSynced.value
                        ? Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GlassIconButton(
                              icon: lyrics.focusMode.value
                                  ? Icons.notes_rounded // → show full lyrics
                                  : Icons
                                      .center_focus_strong_rounded, // → focus line
                              onTap: () {
                                AppHaptics.light();
                                lyrics.toggleFocusMode();
                              },
                            ),
                          )
                        : const SizedBox.shrink()),
                    GlassIconButton(
                        icon: Icons.close_rounded, onTap: lyrics.closeLyrics),
                  ],
                ),
              ),
              Expanded(
                child: Obx(() {
                  // Plain (unsynced) lyrics: scrollable text block, no highlight.
                  if (!lyrics.hasSynced.value) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.stackLg),
                      child: Text(
                        lyrics.plainLyrics.value.isEmpty
                            ? 'No lyrics available'
                            : lyrics.plainLyrics.value,
                        style: AppText.title(size: 20, color: Colors.white70),
                      ),
                    );
                  }
                  // Synced lyrics: focus view (current line only) or full list.
                  // This Obx rebuilds only on hasSynced/focusMode; per-line
                  // reactivity to activeIndex lives in the inner Obx below.
                  return lyrics.focusMode.value
                      ? _focusLyrics()
                      : _fullLyrics();
                }),
              ),
            ],
          ),
        ),
      );
    });
  }

  // ── Full scrolling lyrics ─────────────────────────────────────────────────
  // Every line advances through the whole song; the current line is centred
  // (see _activeAlignment) and highlighted. Each line wraps its style in its
  // OWN Obx so it recolors reactively when activeIndex changes — the list's
  // itemBuilder is called lazily, so reads here are NOT tracked by the parent
  // Obx; a per-line Obx is what makes the highlight actually update.
  Widget _fullLyrics() {
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScroll,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.stackLg, vertical: 80),
      itemCount: lyrics.parsedLyrics.length,
      itemBuilder: (_, i) {
        return Obx(() {
          final active = i == lyrics.activeIndex.value;
          final accent = Get.find<DynamicColorController>().accent.value;
          return InkWell(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            // Tap a line to seek playback to that line's time.
            onTap: () {
              AppHaptics.light();
              pc.seek(lyrics.parsedLyrics[i].timestamp);
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                textAlign: TextAlign.center,
                style: AppText.heading(size: active ? 28 : 21).copyWith(
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  color: active ? accent : Colors.white.withOpacity(0.28),
                  height: 1.25,
                  shadows: active
                      ? [Shadow(color: accent.withOpacity(0.45), blurRadius: 18)]
                      : null,
                ),
                child: Text(
                  lyrics.parsedLyrics[i].text,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        });
      },
    );
  }

  // ── Focus view (current line only) ────────────────────────────────────────
  // Shows just the active line, large and centred, with the previous/next
  // lines faint above and below for context. No scrolling, so the current
  // line is always dead-centre and unmissable.
  Widget _focusLyrics() {
    return Obx(() {
      final i = lyrics.activeIndex.value;
      final accent = Get.find<DynamicColorController>().accent.value;
      final lines = lyrics.parsedLyrics;

      Widget lineAt(int idx, {required bool active}) {
        if (idx < 0 || idx >= lines.length) return const SizedBox(height: 24);
        return AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          style: AppText.heading(size: active ? 30 : 19).copyWith(
            fontWeight: active ? FontWeight.w800 : FontWeight.w500,
            color: active ? accent : Colors.white.withOpacity(0.30),
            height: 1.3,
            shadows: active
                ? [Shadow(color: accent.withOpacity(0.5), blurRadius: 24)]
                : null,
          ),
          textAlign: TextAlign.center,
          child: Text(lines[idx].text, textAlign: TextAlign.center),
        );
      }

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.stackLg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (i < 0)
              Text('♪',
                  textAlign: TextAlign.center,
                  style: AppText.heading(size: 40)
                      .copyWith(color: Colors.white.withOpacity(0.3)))
            else ...[
              lineAt(i - 1, active: false),
              const SizedBox(height: 22),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  AppHaptics.light();
                  pc.seek(lines[i].timestamp);
                },
                child: lineAt(i, active: true),
              ),
              const SizedBox(height: 22),
              lineAt(i + 1, active: false),
            ],
          ],
        ),
      );
    });
  }
}

// ── Queue bottom sheet ─────────────────────────────────────────────────────

void showQueueSheet(BuildContext context) {
  final pc = Get.find<PlayerController>();
  final handler = pc.audioHandler;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => GlassContainer(
        radius: AppRadius.xl,
        blur: 24,
        fill: AppColors.card.withOpacity(0.72),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: SheetHandle(),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenMargin),
              child: Row(
                children: [
                  Text('Up Next', style: AppText.heading(size: 20)),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<MediaItem>>(
                stream: handler.queue,
                initialData: handler.queue.value,
                builder: (_, snap) {
                  final queue = snap.data ?? const [];
                  if (queue.isEmpty) {
                    return const EmptyState(
                      icon: Icons.queue_music_rounded,
                      title: 'Queue is empty',
                      message: 'Songs you play will show up here.',
                    );
                  }
                  return StreamBuilder<MediaItem?>(
                    stream: handler.mediaItem,
                    initialData: handler.mediaItem.value,
                    builder: (_, curSnap) {
                      final currentId = curSnap.data?.id;
                      return ListView.builder(
                        controller: scrollCtrl,
                        itemCount: queue.length,
                        itemBuilder: (_, i) {
                          final item = queue[i];
                          return TrackTile(
                            imageUrl: sizedThumb(
                                item.artUri?.toString(), ThumbnailSize.tile),
                            title: item.title,
                            subtitle: item.artist ?? '',
                            active: item.id == currentId,
                            trailing: item.id == currentId
                                ? Icon(Icons.equalizer_rounded,
                                    color: Get.find<DynamicColorController>()
                                        .accent
                                        .value)
                                : null,
                            onTap: () => handler.skipToQueueItem(i),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ── Add-to-playlist sheet ───────────────────────────────────────────────────

/// Bottom sheet to add [song] to one of the user's local playlists (or a new
/// one). Backed entirely by the existing LibraryService — no new storage.
void showAddToPlaylistSheet(BuildContext context, MediaItem song) {
  final track = LibraryTrack(
    videoId: song.id,
    title: song.title,
    artist: song.artist ?? '',
    thumbnail: song.artUri?.toString() ?? '',
    duration: song.duration != null ? fmtDuration(song.duration!) : '',
  );

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final playlists = LibraryService.getPlaylists();
        return GlassContainer(
          radius: AppRadius.xl,
          blur: 24,
          fill: AppColors.card.withOpacity(0.72),
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text('Add to playlist', style: AppText.heading(size: 20)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: AppColors.glassFill,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Icon(Icons.add_rounded, color: Colors.white),
                ),
                title: Text('New playlist', style: AppText.title(size: 15)),
                onTap: () async {
                  final name = await _promptNewPlaylistName(sheetCtx);
                  if (name == null || name.isEmpty) return;
                  final pl = LibraryService.createPlaylist(name);
                  LibraryService.addTrackToPlaylist(pl.id, track);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  Get.snackbar('Added', 'Added to "${pl.name}"',
                      snackPosition: SnackPosition.BOTTOM,
                      backgroundColor: AppColors.card,
                      colorText: Colors.white);
                },
              ),
              if (playlists.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('No playlists yet — create one above.',
                      style: AppText.subtitle(size: 13)),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (_, i) {
                      final pl = playlists[i];
                      final contains =
                          pl.tracks.any((t) => t.videoId == track.videoId);
                      return TrackTile(
                        imageUrl:
                            sizedThumb(pl.thumbnailUrl, ThumbnailSize.tile),
                        title: pl.name,
                        subtitle: '${pl.tracks.length} songs',
                        trailing: contains
                            ? const Icon(Icons.check_circle_rounded,
                                color: Colors.white)
                            : const Icon(Icons.add_circle_outline_rounded,
                                color: AppColors.textTertiary),
                        onTap: () {
                          if (contains) {
                            Navigator.pop(sheetCtx);
                            Get.snackbar('Already added',
                                'This song is already in "${pl.name}"',
                                snackPosition: SnackPosition.BOTTOM,
                                backgroundColor: AppColors.card,
                                colorText: Colors.white);
                            return;
                          }
                          LibraryService.addTrackToPlaylist(pl.id, track);
                          Navigator.pop(sheetCtx);
                          Get.snackbar('Added', 'Added to "${pl.name}"',
                              snackPosition: SnackPosition.BOTTOM,
                              backgroundColor: AppColors.card,
                              colorText: Colors.white);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// Small "name your playlist" dialog reused by the add-to-playlist sheet.
Future<String?> _promptNewPlaylistName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text('New playlist', style: AppText.title(size: 18)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: AppText.title(size: 15),
        decoration: const InputDecoration(hintText: 'Playlist name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create')),
      ],
    ),
  );
}
