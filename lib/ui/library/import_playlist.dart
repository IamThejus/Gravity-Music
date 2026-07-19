// ui/library/import_playlist.dart
//
// Playlist Import flow (Spotify / Apple Music / YouTube → Gravity Music):
//   1. URL bottom sheet            → showImportPlaylistSheet()
//   2. Preview screen              → ImportPreviewScreen (count, ETA, songs)
//   3. "Playlist name" dialog      → _promptPlaylistName()
//   4. Simulated-progress screen   → ImportProgressScreen
//   5. Saves a normal LocalPlaylist and opens PlaylistDetailScreen.
//
// Everything funnels into the existing playlist architecture (LibraryService +
// SearchResult.toLibraryTrack), so an imported playlist is identical to a
// hand-made one. UI uses the existing design tokens / shared widgets.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/import_controller.dart';
import '../../services/import_service.dart';
import '../app_theme.dart';
import '../theme/glass.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import '../widgets/mini_player.dart';

// ── Step 1: paste-URL bottom sheet ───────────────────────────────────────────

void showImportPlaylistSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ImportUrlSheet(rootContext: context),
  );
}

class _ImportUrlSheet extends StatefulWidget {
  /// The screen context (not the sheet's) used to push the preview screen.
  final BuildContext rootContext;
  const _ImportUrlSheet({required this.rootContext});

  @override
  State<_ImportUrlSheet> createState() => _ImportUrlSheetState();
}

class _ImportUrlSheetState extends State<_ImportUrlSheet> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final url = _controller.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Paste a playlist link to continue.');
      return;
    }
    if (!url.contains('spotify.com') &&
        !url.contains('music.apple.com') &&
        !url.contains('youtube.com') &&
        !url.contains('youtu.be')) {
      setState(() => _error =
          'Only Spotify, Apple Music and YouTube playlist links are supported.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await ImportService.fetchDetails(url);
      if (!mounted) return;
      if (details.songCount == 0 || details.songs.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'This playlist looks empty — nothing to import.';
        });
        return;
      }
      Navigator.of(context).pop(); // close sheet
      if (!widget.rootContext.mounted) return;
      Navigator.of(widget.rootContext).push(MaterialPageRoute(
        builder: (_) => ImportPreviewScreen(url: url, details: details),
      ));
    } on ImportException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Lift above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: GlassContainer(
        radius: AppRadius.xl,
        blur: 30,
        fill: AppColors.card.withOpacity(0.72),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            Text('Import Playlist', style: AppText.heading(size: 22)),
            const SizedBox(height: 4),
            Text('Paste a Spotify, Apple Music or YouTube playlist link.\n'
                'YouTube links import exactly — others are matched by search.',
                style: AppText.subtitle(size: 14)),
            const SizedBox(height: AppSpacing.gutter),
            GlassContainer(
              radius: AppRadius.lg,
              fill: AppColors.glassFill,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded,
                      color: AppColors.textTertiary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_loading,
                      style: AppText.title(size: 14),
                      cursorColor: Colors.white,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _continue(),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 14),
                        border: InputBorder.none,
                        hintText: 'https://music.youtube.com/playlist?list=…',
                        hintStyle: AppText.subtitle(size: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: AppText.subtitle(size: 13, color: AppColors.accent)),
            ],
            const SizedBox(height: AppSpacing.gutter),
            _loading
                ? const _LoadingButton(label: 'Fetching playlist…')
                : PrimaryButton(
                    label: 'Continue',
                    icon: Icons.arrow_forward_rounded,
                    onTap: _continue,
                  ),
          ],
        ),
      ),
    );
  }
}

/// Disabled primary-button look with a spinner, for in-flight actions.
class _LoadingButton extends StatelessWidget {
  final String label;
  const _LoadingButton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white)),
          const SizedBox(width: 10),
          Text(label, style: AppText.button()),
        ],
      ),
    );
  }
}

// ── Step 2/3: preview screen ────────────────────────────────────────────────

class ImportPreviewScreen extends StatelessWidget {
  final String url;
  final PlaylistImportDetails details;
  const ImportPreviewScreen(
      {super.key, required this.url, required this.details});

  String _eta() {
    final s = details.estimatedSeconds;
    if (s <= 0) return 'a few moments';
    if (s < 60) return 'about $s seconds';
    final m = (s / 60).round();
    return 'about $m ${m == 1 ? 'minute' : 'minutes'}';
  }

  Future<void> _startImport(BuildContext context) async {
    final name = await _promptPlaylistName(
      context,
      initial: details.name ?? 'Imported Playlist',
    );
    if (name == null || name.isEmpty) return;
    if (!context.mounted) return;

    // Kick the import off in the background and return the user to the Library
    // immediately — importing must never hold them from listening to music.
    Get.find<ImportController>().startImport(
      url: url,
      name: name,
      songCount: details.songCount,
      estimatedSeconds: details.estimatedSeconds,
    );

    Navigator.of(context).pop(); // back to Library
    Get.snackbar(
      'Importing playlist',
      '“$name” will appear in your library shortly.',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 3),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: AppColors.canvas,
              pinned: true,
              leading: const AppBackButton(),
              title: Text('Import Playlist', style: AppText.title(size: 18)),
            ),
            // ── Summary ───────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 8,
                    AppSpacing.screenMargin, AppSpacing.stackSm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(details.name ?? 'Playlist preview',
                        style: AppText.heading(size: 26)),
                    const SizedBox(height: 6),
                    Text('${details.songCount} songs',
                        style: AppText.subtitle(
                            size: 15, color: AppColors.textSecondaryHi)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.schedule_rounded,
                            size: 15, color: AppColors.textTertiary),
                        const SizedBox(width: 6),
                        Text('Estimated import time: ${_eta()}',
                            style: AppText.subtitle(size: 13)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.gutter),
                    PrimaryButton(
                      label: 'Import',
                      icon: Icons.download_rounded,
                      onTap: () => _startImport(context),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.stackMd),
                child: SectionHeader(title: 'Songs'),
              ),
            ),
            // ── Song-name list ────────────────────────────────────────────
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final song = details.songs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.screenMargin, vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6, right: 12),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                                color: AppColors.textTertiary,
                                shape: BoxShape.circle),
                          ),
                        ),
                        Expanded(
                          child: Text(prettyTitle(song),
                              style: AppText.title(size: 14)),
                        ),
                      ],
                    ),
                  );
                },
                childCount: details.songs.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}

// ── Step 4: name dialog ─────────────────────────────────────────────────────

Future<String?> _promptPlaylistName(BuildContext context,
    {required String initial}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text('Playlist name', style: AppText.title(size: 18)),
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
            child: const Text('Import')),
      ],
    ),
  );
}

// Step 5/6 (the old full-screen ImportProgressScreen) is gone — imports now run
// in the background via ImportController and surface as placeholder tiles in
// the Library grid, so the user is never held on a progress screen.
