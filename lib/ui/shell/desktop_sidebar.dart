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
  const DesktopSidebar(
      {super.key, required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Get.find<DynamicColorController>();
    return Container(
      width: 220,
      color: AppColors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Text('Gravity Music', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
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
  final Color Function() accent;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.dest,
    required this.selected,
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
    final bg = active
        ? widget.accent().withOpacity(0.22)
        : (_hover ? Colors.white.withOpacity(0.06) : Colors.transparent);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color: bg, borderRadius: BorderRadius.circular(AppRadius.md)),
          child: Row(children: [
            Icon(widget.dest.icon, size: 22,
                color: active ? Colors.white : AppColors.textTertiary),
            const SizedBox(width: 14),
            Text(widget.dest.label, style: TextStyle(
                fontSize: 14,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? Colors.white : AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }
}
