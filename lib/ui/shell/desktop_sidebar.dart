// lib/ui/shell/desktop_sidebar.dart
//
// Left navigation rail for the desktop shell. Reuses kNavDestinations so the
// nav set stays in sync with the mobile bottom bar. Hover highlight + active
// accent tint.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_theme.dart';
import '../theme/dynamic_color_controller.dart';
import 'floating_nav_bar.dart' show kNavDestinations, NavDestination;

class DesktopSidebar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// When true, render a slim icon-only rail (narrow window) instead of the
  /// full labelled sidebar.
  final bool collapsed;

  const DesktopSidebar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Get.find<DynamicColorController>();
    // Width is NOT animated: it must switch in lock-step with the item body
    // (collapsed icon vs icon+label). Animating the width let the container be
    // momentarily narrow while the expanded body was already showing, which
    // overflowed the row. Snapping avoids that entirely.
    return Container(
      width: collapsed ? 72 : 220,
      color: AppColors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand: full wordmark when expanded, a compact accent mark when
          // collapsed (centred in the rail so it lines up with the nav icons).
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 0 : 20, vertical: 24),
            child: collapsed
                ? Center(
                    child: Obx(() => Icon(Icons.graphic_eq_rounded,
                        color: colors.accent.value, size: 24)))
                : const Text('Gravity Music',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
          ),
          for (var i = 0; i < kNavDestinations.length; i++)
            // The active item's tint tracks the per-track dynamic accent, so
            // wrap in Obx to rebuild when DynamicColorController.accent changes
            // (matching the gliding pill in FloatingNavBar).
            Obx(() {
              final accent = colors.accent.value;
              return _SidebarItem(
                dest: kNavDestinations[i],
                selected: i == currentIndex,
                collapsed: collapsed,
                accent: () => accent,
                onTap: () => onTap(i),
              );
            }),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final NavDestination dest;
  final bool selected;
  final bool collapsed;
  final Color Function() accent;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.dest,
    required this.selected,
    required this.collapsed,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final collapsed = widget.collapsed;
    final bg = active
        ? widget.accent().withOpacity(0.22)
        : (_hover ? Colors.white.withOpacity(0.06) : Colors.transparent);
    final iconColor = active ? Colors.white : AppColors.textTertiary;

    Widget body = collapsed
        ? Center(child: Icon(widget.dest.icon, size: 22, color: iconColor))
        : Row(children: [
            Icon(widget.dest.icon, size: 22, color: iconColor),
            const SizedBox(width: 14),
            Flexible(
              child: Text(widget.dest.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color:
                          active ? Colors.white : AppColors.textSecondary)),
            ),
          ]);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: EdgeInsets.symmetric(
              horizontal: collapsed ? 10 : 12, vertical: 3),
          padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 14, vertical: 12),
          decoration: BoxDecoration(
              color: bg, borderRadius: BorderRadius.circular(AppRadius.md)),
          // A tooltip gives the collapsed rail its labels back on hover.
          child: collapsed
              ? Tooltip(message: widget.dest.label, child: body)
              : body,
        ),
      ),
    );
  }
}
