// ui/widgets/track_actions.dart
//
// Shared "song actions" bottom sheet — the single place the queue actions
// (Play next / Add to queue) and Add-to-playlist live, so every song row across
// the app (search, playlist, album, liked, downloads, queue, home) opens the
// same menu on long-press. Routes to PlayerController.playNext /
// addToUserQueue — neither interrupts the current track.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../now_playing/now_playing_screen.dart' show showAddToPlaylistSheet;
import '../theme/glass.dart';
import '../ui_helpers.dart';

/// Wraps a song row so swiping it RIGHT adds the track to the user queue. The
/// row springs back — it's an action, not a dismissal — and never interrupts
/// what's playing. Use across song lists (search, playlist, liked, album,
/// downloads) for one consistent gesture; pair with a long-press →
/// [showTrackActionsSheet] for the full menu.
class SwipeToQueue extends StatelessWidget {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnail;
  final Duration? duration;

  /// A value unique within the list (usually the item index) so the underlying
  /// Dismissible gets a stable, collision-free key even if a song repeats.
  final Object slot;
  final Widget child;

  const SwipeToQueue({
    super.key,
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.slot,
    required this.child,
    this.duration,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('swq-$videoId-$slot'),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        AppHaptics.medium();
        Get.find<PlayerController>().addToUserQueue(videoId,
            title: title,
            artist: artist,
            thumbnail: thumbnail,
            duration: duration);
        Get.snackbar('Added to queue', '“${prettyTitle(title)}” added',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: AppColors.card,
            colorText: AppColors.white,
            duration: const Duration(seconds: 2));
        return false; // keep the row — this is an action, not a removal
      },
      background: const _QueueSwipeBg(),
      child: child,
    );
  }
}

/// The accent reveal shown behind a row while it's swiped right to enqueue.
class _QueueSwipeBg extends StatelessWidget {
  const _QueueSwipeBg();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: AppSpacing.screenMargin + 6),
      color: AppColors.accent.withOpacity(0.18),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.queue_music_rounded, color: AppColors.accent),
          const SizedBox(width: 8),
          Text('Add to queue',
              style: AppText.title(size: 13, color: AppColors.accent)),
        ],
      ),
    );
  }
}

/// Opens the actions sheet for a single track. All fields mirror what the
/// play/enqueue APIs need; [duration] is optional.
void showTrackActionsSheet(
  BuildContext context, {
  required String videoId,
  required String title,
  required String artist,
  required String thumbnail,
  Duration? duration,
}) {
  final pc = Get.find<PlayerController>();

  void toast(String heading, String body) => Get.snackbar(
        heading,
        body,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.card,
        colorText: AppColors.white,
        duration: const Duration(seconds: 2),
      );

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => GlassContainer(
      radius: AppRadius.xl,
      fill: AppColors.card.withOpacity(0.72),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(),
          const SizedBox(height: 8),
          // Track header
          ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                width: 46,
                height: 46,
                color: AppColors.glassFill,
                child: thumbnail.isEmpty
                    ? const Icon(Icons.music_note_rounded,
                        color: AppColors.textTertiary)
                    : Image.network(sizedThumb(thumbnail, ThumbnailSize.tile),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.music_note_rounded,
                            color: AppColors.textTertiary)),
              ),
            ),
            title: Text(prettyTitle(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.title(size: 15)),
            subtitle: Text(prettyTitle(artist),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.subtitle(size: 13)),
          ),
          const Divider(height: 8, color: AppColors.glassBorder),
          ListTile(
            leading:
                const Icon(Icons.playlist_play_rounded, color: Colors.white),
            title: Text('Play next', style: AppText.title(size: 15)),
            onTap: () {
              Navigator.pop(sheetCtx);
              pc.playNext(videoId,
                  title: title,
                  artist: artist,
                  thumbnail: thumbnail,
                  duration: duration);
              toast('Playing next', '“${prettyTitle(title)}” is up next');
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
            title: Text('Add to queue', style: AppText.title(size: 15)),
            onTap: () {
              Navigator.pop(sheetCtx);
              pc.addToUserQueue(videoId,
                  title: title,
                  artist: artist,
                  thumbnail: thumbnail,
                  duration: duration);
              toast('Added to queue', '“${prettyTitle(title)}” added');
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.playlist_add_rounded, color: Colors.white),
            title: Text('Add to playlist', style: AppText.title(size: 15)),
            onTap: () {
              Navigator.pop(sheetCtx);
              showAddToPlaylistSheet(
                context,
                MediaItem(
                  id: videoId,
                  title: title,
                  artist: artist,
                  artUri: thumbnail.isNotEmpty ? Uri.tryParse(thumbnail) : null,
                  duration: duration,
                  extras: {'url': ''},
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}
