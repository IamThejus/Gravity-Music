// ui/queue/queue_screen.dart
//
// "Queue" tab — a live, sectioned view of the playback queue from the existing
// MyAudioHandler (queue + mediaItem BehaviorSubjects). Sections mirror the
// playback model: Now playing → Next in queue (the user-added songs) → Next up
// (context + autoplay). Only upcoming songs are shown. Rows swipe left to
// remove, long-press for actions, tap to jump. No queue state is duplicated —
// user-section membership comes from handler.userQueuedIds.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/audio_handler.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../theme/dynamic_color_controller.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import '../widgets/track_actions.dart';

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final handler = pc.audioHandler;
    final colors = Get.find<DynamicColorController>();

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 16,
                AppSpacing.screenMargin, AppSpacing.gutter),
            child: Row(
              children: [
                Expanded(child: Text('Queue', style: AppText.heading(size: 32))),
                GestureDetector(
                  onTap: () {
                    AppHaptics.selection();
                    pc.clearQueue();
                  },
                  child: Text('Clear',
                      style: AppText.caption(color: AppColors.textSecondaryHi)),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<MediaItem>>(
              stream: handler.queue,
              initialData: handler.queue.value,
              builder: (_, snap) {
                final queue = snap.data ?? const <MediaItem>[];
                if (queue.isEmpty) {
                  return const EmptyState(
                    icon: Icons.queue_music_rounded,
                    title: 'Nothing queued',
                    message: 'Play a song to build your queue.',
                  );
                }
                return StreamBuilder<MediaItem?>(
                  stream: handler.mediaItem,
                  initialData: handler.mediaItem.value,
                  builder: (_, curSnap) {
                    final currentId = curSnap.data?.id;
                    return _QueueList(
                      queue: queue,
                      currentId: currentId,
                      userIds: handler is MyAudioHandler
                          ? handler.userQueuedIds.toSet()
                          : const <String>{},
                      accent: colors.accent.value,
                      onJump: handler.skipToQueueItem,
                      onRemove: handler.removeQueueItem,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueList extends StatelessWidget {
  final List<MediaItem> queue;
  final String? currentId;
  final Set<String> userIds;
  final Color accent;
  final void Function(int index) onJump;
  final Future<void> Function(MediaItem item) onRemove;

  const _QueueList({
    required this.queue,
    required this.currentId,
    required this.userIds,
    required this.accent,
    required this.onJump,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final curIdx = currentId == null
        ? -1
        : queue.indexWhere((m) => m.id == currentId);

    // Upcoming indices split into the user section and the rest, in queue order.
    final upcoming = [
      for (var i = curIdx + 1; i < queue.length; i++) i,
    ];
    final userUpcoming = upcoming.where((i) => userIds.contains(queue[i].id));
    final restUpcoming = upcoming.where((i) => !userIds.contains(queue[i].id));

    final rows = <Widget>[];
    if (curIdx != -1) {
      rows.add(_header('Now playing'));
      rows.add(_tile(context, curIdx, isCurrent: true));
    }
    final userList = userUpcoming.toList();
    if (userList.isNotEmpty) {
      rows.add(_header('Next in queue'));
      rows.addAll(userList.map((i) => _tile(context, i)));
    }
    final restList = restUpcoming.toList();
    if (restList.isNotEmpty) {
      rows.add(_header(userList.isEmpty && curIdx == -1 ? 'Queue' : 'Next up'));
      rows.addAll(restList.map((i) => _tile(context, i)));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.bottomDock),
      children: rows,
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenMargin, 14, AppSpacing.screenMargin, 6),
        child: Text(text.toUpperCase(), style: AppText.label()),
      );

  Widget _tile(BuildContext context, int index, {bool isCurrent = false}) {
    final item = queue[index];
    final tile = TrackTile(
      key: ValueKey('q-${item.id}-$index'),
      imageUrl: sizedThumb(item.artUri?.toString(), ThumbnailSize.tile),
      title: item.title,
      subtitle: item.artist ?? '',
      active: isCurrent,
      trailing: isCurrent
          ? Icon(Icons.equalizer_rounded, color: accent, size: 20)
          : null,
      onTap: () => onJump(index),
      onLongPress: () => showTrackActionsSheet(
        context,
        videoId: item.id,
        title: item.title,
        artist: item.artist ?? '',
        thumbnail: item.artUri?.toString() ?? '',
        duration: item.duration,
      ),
    );

    // The current song can't be swiped away; upcoming rows swipe left to remove.
    if (isCurrent) return tile;
    return Dismissible(
      key: ValueKey('qd-${item.id}-$index'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        AppHaptics.light();
        onRemove(item);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.screenMargin + 6),
        color: AppColors.accent.withOpacity(0.16),
        child: const Icon(Icons.remove_circle_outline_rounded,
            color: AppColors.accent),
      ),
      child: tile,
    );
  }
}
