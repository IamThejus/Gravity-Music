// ui/shell/floating_nav_bar.dart
//
// Apple-Music-style floating glass tab bar (DESIGN.md → Navigation). A pill
// container suspended above the content with a 30px blur and 12% border.
//
// Motion: a SINGLE accent pill glides between slots (AnimatedAlign + spring) —
// it is not four independent fading pills. The active icon scales up and its
// label fades + expands in. Everything reads its timing from AppMotion.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_theme.dart';
import '../theme/dynamic_color_controller.dart';
import '../theme/glass.dart';
import '../theme/motion.dart';

class NavDestination {
  final IconData icon;
  final String label;
  const NavDestination(this.icon, this.label);
}

const List<NavDestination> kNavDestinations = [
  NavDestination(Icons.home_rounded, 'Home'),
  NavDestination(Icons.search_rounded, 'Search'),
  NavDestination(Icons.library_music_rounded, 'Library'),
  NavDestination(Icons.queue_music_rounded, 'Queue'),
];

class FloatingNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const FloatingNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Get.find<DynamicColorController>();
    final n = kNavDestinations.length;
    // Alignment.x for the gliding pill: maps slot index → [-1, 1].
    final pillAlign = n == 1 ? 0.0 : (2 * currentIndex / (n - 1)) - 1.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.stackLg),
      child: GlassContainer(
        radius: AppRadius.pill,
        blur: 24,
        shadow: kGlassShadow,
        fill: AppColors.glassFill,
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, c) {
            final slotWidth = c.maxWidth / n;
            return SizedBox(
              height: 48,
              child: Stack(
                children: [
                  // ── The single gliding indicator pill ────────────────────
                  Obx(() => AnimatedAlign(
                        duration: AppMotion.standard,
                        curve: AppMotion.spring,
                        alignment: Alignment(pillAlign, 0),
                        child: Container(
                          width: slotWidth - 6,
                          height: 48,
                          decoration: BoxDecoration(
                            color: colors.accent.value.withOpacity(0.22),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(color: AppColors.glassBorder),
                          ),
                        ),
                      )),
                  // ── Tap targets (transparent — pill sits behind them) ────
                  Row(
                    children: List.generate(n, (i) {
                      return Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            AppHaptics.selection();
                            onTap(i);
                          },
                          child: _NavItem(
                            dest: kNavDestinations[i],
                            selected: i == currentIndex,
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A single nav slot: the icon scales up when active and its label fades +
/// expands in. No layout jumps — AnimatedSize handles the height change.
class _NavItem extends StatelessWidget {
  final NavDestination dest;
  final bool selected;
  const _NavItem({required this.dest, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedScale(
          scale: selected ? 1.06 : 0.92,
          duration: AppMotion.standard,
          curve: AppMotion.spring,
          child: Icon(
            dest.icon,
            size: 22,
            color: selected ? Colors.white : AppColors.textTertiary,
          ),
        ),
        AnimatedSize(
          duration: AppMotion.fast,
          curve: AppMotion.standardCurve,
          child: AnimatedOpacity(
            opacity: selected ? 1 : 0,
            duration: AppMotion.fast,
            curve: AppMotion.standardCurve,
            child: selected
                // Dedicated nav label: 10.5/w600 (was 9/w700) — more legible
                // and less cramped, with balanced spacing under the icon so the
                // icon+label read as one centred unit.
                ? Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(dest.label, style: AppText.navLabel()),
                  )
                : const SizedBox(width: 0, height: 0),
          ),
        ),
      ],
    );
  }
}
