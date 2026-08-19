// ui/settings/settings_screen.dart
//
// Settings screen. Currently hosts "Check for updates" (the manual entry point
// to the GitHub in-app updater); a natural home for future app settings.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/update_controller.dart';
import '../../services/update_service.dart';
import '../app_theme.dart';
import '../theme/glass.dart';
import '../update/update_dialog.dart';
import '../widgets/mini_player.dart';
import 'feedback_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    UpdateService.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final rel = await UpdateController.to.checkManual();
      if (!mounted) return;
      if (rel != null) {
        showUpdateDialog(rel);
      } else {
        _toast("You're up to date.");
      }
    } on UpdateException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Update check failed.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _toast(String msg) => Get.snackbar('Updates', msg,
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: AppColors.card,
      colorText: AppColors.white,
      duration: const Duration(seconds: 2));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 8,
                    AppSpacing.screenMargin, AppSpacing.gutter),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    Text('Settings', style: AppText.heading(size: 28)),
                  ],
                ),
              ),
              const _SectionLabel('About'),
              _SettingTile(
                icon: Icons.system_update_rounded,
                iconColor: AppColors.accent,
                title: 'Check for updates',
                subtitle: _version.isEmpty
                    ? 'Gravity Music'
                    : 'Gravity Music v$_version',
                trailing: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.accent))
                    : const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textTertiary),
                onTap: _checkForUpdates,
              ),
              // Always shown, never gated on Supabase being ready: this screen
              // can be built before the post-first-frame cloud init finishes,
              // and a bare Get.isRegistered/isReady check never re-evaluates
              // (the same trap that once hid the Library account row). If the
              // backend isn't up, FeedbackService says so in the dialog.
              _SettingTile(
                icon: Icons.forum_rounded,
                iconColor: AppColors.accent,
                title: 'Send feedback',
                subtitle: 'Ideas, bugs, anything at all',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textTertiary),
                onTap: showFeedbackDialog,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenMargin + 4, 8, AppSpacing.screenMargin, 8),
        child: Text(text.toUpperCase(), style: AppText.label()),
      );
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _SettingTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
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
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}
