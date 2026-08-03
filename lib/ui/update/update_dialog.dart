// ui/update/update_dialog.dart
//
// Material 3 "Update available" dialog, themed to Gravity's dark palette.
// Binds to UpdateController for live download progress. Actions: Skip this
// version / Later / Update Now — the last becomes a progress bar + Cancel while
// downloading, and a "grant permission" prompt if the OS blocks the install.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/update_controller.dart';
import '../../models/github_release.dart';
import '../app_theme.dart';

/// Shows the update dialog for [rel]. Barrier-dismissible; closing resets the
/// controller's transient download state.
void showUpdateDialog(GitHubRelease rel) {
  Get.dialog(_UpdateDialog(release: rel), barrierColor: Colors.black54)
      .whenComplete(() => UpdateController.to.resetPhase());
}

class _UpdateDialog extends StatelessWidget {
  final GitHubRelease release;
  const _UpdateDialog({required this.release});

  @override
  Widget build(BuildContext context) {
    final c = UpdateController.to;
    return Dialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(Icons.system_update_rounded,
                        color: AppColors.accent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Update available',
                            style: AppText.heading(size: 20)),
                        const SizedBox(height: 2),
                        Text('Gravity Music ${release.version} is available.',
                            style: AppText.subtitle(size: 13)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _VersionRow(current: c.currentVersion.value, latest: release.version),
              if (release.publishedAt != null) ...[
                const SizedBox(height: 6),
                Text('Released ${_fmtDate(release.publishedAt!)}',
                    style: AppText.caption()),
              ],
              const SizedBox(height: 18),
              Text("What's new", style: AppText.title(size: 15)),
              const SizedBox(height: 8),
              _Notes(body: release.body),
              const SizedBox(height: 12),
              // Live progress / errors / actions.
              Obx(() => _Footer(c: c, release: release)),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final local = d.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

class _VersionRow extends StatelessWidget {
  final String current;
  final String latest;
  const _VersionRow({required this.current, required this.latest});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _chip(current.isEmpty ? '—' : current, muted: true),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.arrow_forward_rounded,
              size: 16, color: AppColors.textTertiary),
        ),
        _chip(latest, muted: false),
      ],
    );
  }

  Widget _chip(String text, {required bool muted}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: muted
              ? AppColors.glassFill
              : AppColors.accent.withOpacity(0.18),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
              color: muted ? AppColors.glassBorder : AppColors.accent),
        ),
        child: Text(text,
            style: AppText.caption(
                color: muted ? AppColors.textSecondary : AppColors.accent)),
      );
}

class _Notes extends StatelessWidget {
  final String body;
  const _Notes({required this.body});

  @override
  Widget build(BuildContext context) {
    final text = body.isEmpty ? 'No release notes provided.' : body;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: Text(text,
              style: AppText.subtitle(size: 13).copyWith(height: 1.5)),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final UpdateController c;
  final GitHubRelease release;
  const _Footer({required this.c, required this.release});

  @override
  Widget build(BuildContext context) {
    switch (c.phase.value) {
      case UpdatePhase.downloading:
        final pct = (c.progress.value * 100).clamp(0, 100).toStringAsFixed(0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Downloading…', style: AppText.subtitle(size: 13)),
                Text('$pct%',
                    style: AppText.title(size: 13, color: AppColors.accent)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: c.progress.value == 0 ? null : c.progress.value,
                minHeight: 6,
                backgroundColor: AppColors.glassFill,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: c.cancelDownload,
                child: const Text('Cancel'),
              ),
            ),
          ],
        );

      case UpdatePhase.needsPermission:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(c.errorMessage.value ?? 'Permission required.',
                style: AppText.subtitle(size: 13)),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => Get.back(), child: const Text('Later')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    await c.openPermissionSettings();
                  },
                  child: const Text('Open settings'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: c.retryInstall,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        );

      case UpdatePhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(c.errorMessage.value ?? 'Something went wrong.',
                style: AppText.subtitle(size: 13, color: AppColors.accent)),
            const SizedBox(height: 8),
            _Actions(c: c, release: release, updateLabel: 'Retry'),
          ],
        );

      case UpdatePhase.done:
      case UpdatePhase.idle:
        return _Actions(c: c, release: release, updateLabel: 'Update Now');
    }
  }
}

class _Actions extends StatelessWidget {
  final UpdateController c;
  final GitHubRelease release;
  final String updateLabel;
  const _Actions({
    required this.c,
    required this.release,
    required this.updateLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TextButton(
          onPressed: () {
            c.ignoreVersion();
            Get.back();
          },
          child: Text('Skip this version',
              style: AppText.caption(color: AppColors.textTertiary)),
        ),
        const Spacer(),
        TextButton(onPressed: () => Get.back(), child: const Text('Later')),
        const SizedBox(width: 8),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent, foregroundColor: Colors.white),
          onPressed: () => c.downloadAndInstall(release),
          child: Text(updateLabel),
        ),
      ],
    );
  }
}
