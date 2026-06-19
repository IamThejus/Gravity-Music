// ui/library/library_screen.dart
//
// Library tab + Liked Songs and Playlist detail screens. All data comes from
// the existing LibraryService (Hive-backed liked songs + local playlists) and
// playback is delegated to PlayerController.playAllMedia. No mock data.

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/import_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/playlist_download_controller.dart';
import '../../services/library_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../theme/glass.dart';
import '../shell/responsive.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import '../widgets/mini_player.dart';
import 'import_playlist.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _import = Get.find<ImportController>();
  Worker? _jobsWorker;

  void _refresh() => setState(() {});

  @override
  void initState() {
    super.initState();
    // Rebuild (coarsely) when an import is added / removed / fails, so its
    // placeholder tile appears or disappears. Per-tile progress updates ride
    // on the tile's own Obx, so this doesn't fire every animation frame.
    _jobsWorker = ever(_import.jobs, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _jobsWorker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the library box changes (e.g. a playlist created from
    // the Now Playing sheet) — this tab stays mounted, so without this it
    // would show stale data until manually refreshed.
    return ValueListenableBuilder(
      valueListenable: Hive.box('LibraryBox').listenable(),
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final liked = LibraryService.getLiked();
    final playlists = LibraryService.getPlaylists();
    final jobs = _import.jobs.toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.screenMargin,
                MediaQuery.of(context).padding.top + 16,
                AppSpacing.screenMargin,
                AppSpacing.stackMd),
            child: Row(
              children: [
                Expanded(child: Text('Library', style: AppText.heading(size: 32))),
                GlassIconButton(
                  icon: Icons.add_rounded,
                  onTap: () => _createPlaylist(context),
                ),
              ],
            ),
          ),
        ),
        // ── Quick-access rows ────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _LibraryRow(
            icon: Icons.favorite_rounded,
            iconColor: AppColors.accent,
            title: 'Liked Songs',
            subtitle: '${liked.length} songs',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LikedSongsScreen())),
          ),
        ),
        SliverToBoxAdapter(
          child: _LibraryRow(
            icon: Icons.download_done_rounded,
            iconColor: Colors.greenAccent,
            title: 'Downloads',
            subtitle: 'Saved for offline',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DownloadsScreen())),
          ),
        ),
        // ── Playlists grid ──────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin,
              AppSpacing.stackMd, AppSpacing.screenMargin, 0),
          sliver: SliverToBoxAdapter(
            child: SectionHeader(
              title: 'Playlists',
              action: GlassPillButton(
                icon: Icons.add_rounded,
                label: 'Import',
                onTap: () => showImportPlaylistSheet(context),
              ),
            ),
          ),
        ),
        if (playlists.isEmpty && jobs.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyState(
                icon: Icons.queue_music_rounded,
                title: 'No playlists yet',
                message: 'Tap + to create your first playlist.',
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenMargin),
            sliver: Builder(builder: (context) {
              final cols = gridColumns(MediaQuery.sizeOf(context).width);
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: AppSpacing.gutter,
                  mainAxisSpacing: AppSpacing.gutter,
                  childAspectRatio: 0.78,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) {
                    // In-progress imports render first as placeholder tiles, then
                    // the real playlists.
                    if (i < jobs.length) {
                      return _ImportingTile(job: jobs[i]);
                    }
                    final pl = playlists[i - jobs.length];
                    return Stack(
                      children: [
                        ArtCard(
                          imageUrl:
                              sizedThumb(pl.thumbnailUrl, ThumbnailSize.card),
                          title: pl.name,
                          subtitle: '${pl.tracks.length} songs',
                          size: double.infinity,
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    PlaylistDetailScreen(playlistId: pl.id)));
                            _refresh();
                          },
                        ),
                        // Small offline-download indicator over the cover's
                        // top-right corner (purely informational).
                        Positioned(
                          top: 8,
                          right: 8,
                          child: IgnorePointer(
                            child: _PlaylistDownloadBadge(playlistId: pl.id),
                          ),
                        ),
                      ],
                    );
                  },
                  childCount: jobs.length + playlists.length,
                ),
              );
            }),
          ),
        SliverToBoxAdapter(
            child: SizedBox(height: bottomDockInset(context))),
      ],
    );
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
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
    if (name != null && name.isNotEmpty) {
      LibraryService.createPlaylist(name);
      _refresh();
    }
  }
}

/// Placeholder tile for an in-progress (or failed) playlist import. Shows a
/// progress ring as the cover while importing; on failure becomes a tap-to-
/// retry tile with a dismiss button. Replaced by a real ArtCard once the
/// import resolves and saves a LocalPlaylist.
class _ImportingTile extends StatelessWidget {
  final ImportJob job;
  const _ImportingTile({required this.job});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final failed = job.failed.value;
      final progress = job.progress.value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: failed ? () => Get.find<ImportController>().retry(job) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Center(
                      child: failed
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.refresh_rounded,
                                    color: AppColors.textSecondaryHi, size: 34),
                                const SizedBox(height: 8),
                                Text('Tap to retry',
                                    style: AppText.caption(
                                        color: AppColors.textSecondaryHi)),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 46,
                                  height: 46,
                                  child: CircularProgressIndicator(
                                    value: progress <= 0 ? null : progress,
                                    strokeWidth: 3,
                                    color: AppColors.accent,
                                    backgroundColor: AppColors.glassFillActive,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text('${(progress * 100).round()}%',
                                    style: AppText.caption(
                                        color: AppColors.textSecondaryHi)),
                              ],
                            ),
                    ),
                    if (failed)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: GestureDetector(
                          onTap: () =>
                              Get.find<ImportController>().dismiss(job),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close_rounded,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.stackSm),
            Text(prettyTitle(job.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.title(size: 14)),
            Text(failed ? 'Import failed' : 'Importing…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.subtitle(size: 12)),
          ],
        ),
      );
    });
  }
}

/// Small offline-download indicator shown on a playlist tile's cover.
/// • downloading → a download arrow inside a circular progress ring (fraction
///   of songs fetched); • fully downloaded → a small "downloaded" check.
/// Nothing is shown when the playlist isn't downloaded at all.
class _PlaylistDownloadBadge extends StatelessWidget {
  final String playlistId;
  const _PlaylistDownloadBadge({required this.playlistId});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<PlaylistDownloadController>();
    return Obx(() {
      final downloading = c.isDownloading(playlistId);
      final downloaded = c.isDownloaded(playlistId);
      if (!downloading && !downloaded) return const SizedBox.shrink();

      return Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: downloading
            ? Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      value: c.progressFor(playlistId) <= 0
                          ? null
                          : c.progressFor(playlistId),
                      strokeWidth: 2,
                      color: AppColors.accent,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const Icon(Icons.arrow_downward_rounded,
                      size: 11, color: Colors.white),
                ],
              )
            : const Icon(Icons.download_done_rounded,
                size: 15, color: Colors.greenAccent),
      );
    });
  }
}

/// Playlist-detail app-bar action: download / downloading / downloaded.
/// Tapping starts a background download (or removes the offline copy when
/// already downloaded). Never blocks playback.
class _PlaylistDownloadAction extends StatelessWidget {
  final LocalPlaylist playlist;
  const _PlaylistDownloadAction({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<PlaylistDownloadController>();
    return Obx(() {
      if (c.isDownloading(playlist.id)) {
        final p = c.progressFor(playlist.id);
        return Padding(
          padding: const EdgeInsets.all(14),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              value: p <= 0 ? null : p,
              strokeWidth: 2,
              color: AppColors.accent,
              backgroundColor: Colors.white24,
            ),
          ),
        );
      }
      final downloaded = c.isDownloaded(playlist.id);
      return IconButton(
        icon: Icon(
          downloaded ? Icons.download_done_rounded : Icons.download_rounded,
          color: downloaded ? Colors.greenAccent : Colors.white,
        ),
        onPressed: () {
          if (downloaded) {
            c.removeDownload(playlist);
            Get.snackbar('Removed download',
                'Offline copy of “${playlist.name}” deleted',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: AppColors.card,
                colorText: AppColors.white,
                duration: const Duration(seconds: 2));
          } else {
            c.download(playlist);
            Get.snackbar('Downloading playlist',
                '“${playlist.name}” is downloading in the background',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: AppColors.card,
                colorText: AppColors.white,
                duration: const Duration(seconds: 3));
          }
        },
      );
    });
  }
}

class _LibraryRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LibraryRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenMargin, vertical: 6),
      child: GestureDetector(
        onTap: () {
          AppHaptics.light();
          onTap();
        },
        child: GlassContainer(
          radius: AppRadius.lg,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.title(size: 16)),
                    Text(subtitle, style: AppText.subtitle(size: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Liked Songs ────────────────────────────────────────────────────────────

class LikedSongsScreen extends StatelessWidget {
  const LikedSongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final liked = LibraryService.getLiked();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: AppColors.canvas,
            pinned: true,
            leading: const AppBackButton(),
            title: Text('Liked Songs', style: AppText.title(size: 18)),
            actions: [
              if (liked.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white, size: 30),
                  onPressed: () => pc.playAllMedia(
                      liked.map((t) => t.toMediaItem()).toList()),
                ),
            ],
          ),
          if (liked.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.favorite_border_rounded,
                title: 'No liked songs',
                message: 'Tap the heart on any track to save it here.',
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final t = liked[i];
                  return TrackTile(
                    imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.tile),
                    title: t.title,
                    subtitle: t.artist,
                    onTap: () => pc.playAllMedia(
                        liked.map((x) => x.toMediaItem()).toList(),
                        startIndex: i),
                  );
                },
                childCount: liked.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
        ),
      ),
    );
  }
}

// ── Playlist detail ──────────────────────────────────────────────────────────

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  LocalPlaylist? get _playlist {
    final all = LibraryService.getPlaylists();
    final i = all.indexWhere((p) => p.id == widget.playlistId);
    return i == -1 ? null : all[i];
  }

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final pl = _playlist;

    if (pl == null) {
      return const Scaffold(
        backgroundColor: AppColors.canvas,
        body: Center(child: Text('Playlist not found')),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: AppColors.canvas,
            pinned: true,
            expandedHeight: 280,
            leading: const AppBackButton(),
            actions: [
              _PlaylistDownloadAction(playlist: pl),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded,
                    color: Colors.white),
                onPressed: () {
                  LibraryService.deletePlaylist(pl.id);
                  Navigator.pop(context);
                },
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenMargin, 80, AppSpacing.screenMargin, 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ArtImage(
                        url: sizedThumb(pl.thumbnailUrl, ThumbnailSize.card),
                        size: 150,
                        radius: AppRadius.lg),
                    const SizedBox(height: 12),
                    Text(pl.name,
                        style: AppText.heading(size: 24),
                        textAlign: TextAlign.center),
                    Text('${pl.tracks.length} songs',
                        style: AppText.subtitle(size: 13)),
                  ],
                ),
              ),
            ),
          ),
          if (pl.tracks.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.playlist_add_rounded,
                title: 'Empty playlist',
                message: 'Add songs from the player’s “…” menu.',
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 8,
                    AppSpacing.screenMargin, AppSpacing.gutter),
                child: Row(
                  children: [
                    Expanded(
                      child: PrimaryButton(
                        label: 'Play',
                        icon: Icons.play_arrow_rounded,
                        onTap: () => pc.playAllMedia(
                            pl.tracks.map((t) => t.toMediaItem()).toList()),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.gutter),
                    Expanded(
                      child: SecondaryButton(
                        label: 'Shuffle',
                        icon: Icons.shuffle_rounded,
                        onTap: () => pc.playShuffledMedia(
                            pl.tracks.map((t) => t.toMediaItem()).toList()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final t = pl.tracks[i];
                  return TrackTile(
                    imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.tile),
                    title: t.title,
                    subtitle: t.artist,
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline_rounded,
                          color: AppColors.textTertiary),
                      onPressed: () {
                        LibraryService.removeTrackFromPlaylist(
                            pl.id, t.videoId);
                        setState(() {});
                      },
                    ),
                    onTap: () => pc.playAllMedia(
                        pl.tracks.map((x) => x.toMediaItem()).toList(),
                        startIndex: i),
                  );
                },
                childCount: pl.tracks.length,
              ),
            ),
          ],
          SliverToBoxAdapter(
              child: SizedBox(height: bottomDockInset(context))),
        ],
        ),
      ),
    );
  }
}

// ── Downloads ────────────────────────────────────────────────────────────────

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final dc = Get.find<DownloadController>();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: Obx(() {
          final downloads = dc.downloads;
          final downloading = dc.downloading;

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: AppColors.canvas,
                pinned: true,
                leading: const AppBackButton(),
                title: Text('Downloads', style: AppText.title(size: 18)),
                actions: [
                  if (downloads.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.play_circle_fill_rounded,
                          color: Colors.white, size: 30),
                      onPressed: () => pc.playAllMedia(
                          downloads.map((t) => t.toMediaItem()).toList()),
                    ),
                ],
              ),

              // ── Play / Shuffle ──────────────────────────────────────────
              if (downloads.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin,
                        8, AppSpacing.screenMargin, AppSpacing.gutter),
                    child: Row(
                      children: [
                        Expanded(
                          child: PrimaryButton(
                            label: 'Play',
                            icon: Icons.play_arrow_rounded,
                            onTap: () => pc.playAllMedia(downloads
                                .map((t) => t.toMediaItem())
                                .toList()),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.gutter),
                        Expanded(
                          child: SecondaryButton(
                            label: 'Shuffle',
                            icon: Icons.shuffle_rounded,
                            onTap: () => pc.playShuffledMedia(downloads
                                .map((t) => t.toMediaItem())
                                .toList()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── In-progress downloads ───────────────────────────────────
              if (downloading.isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final t = downloading[i];
                      return Obx(() {
                        final p = dc.progress[t.videoId] ?? 0.0;
                        return TrackTile(
                          imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.tile),
                          title: t.title,
                          subtitle:
                              'Downloading… ${(p * 100).clamp(0, 100).toStringAsFixed(0)}%',
                          trailing: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              value: p == 0 ? null : p,
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          ),
                          onTap: () {},
                        );
                      });
                    },
                    childCount: downloading.length,
                  ),
                ),

              // ── Completed downloads / empty state ───────────────────────
              if (downloads.isEmpty && downloading.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.download_rounded,
                    title: 'No downloads yet',
                    message:
                        'Tap the “…” menu on a song and choose Download to\nsave it for offline listening.',
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final t = downloads[i];
                      return TrackTile(
                        imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.tile),
                        title: t.title,
                        subtitle: t.artist,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: AppColors.textTertiary),
                          onPressed: () => dc.delete(t.videoId),
                        ),
                        onTap: () => pc.playAllMedia(
                            downloads.map((x) => x.toMediaItem()).toList(),
                            startIndex: i),
                      );
                    },
                    childCount: downloads.length,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          );
        }),
      ),
    );
  }
}
