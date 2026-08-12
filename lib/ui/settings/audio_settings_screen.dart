// ui/settings/audio_settings_screen.dart
// The app's first settings surface. Hosts the equalizer (desktop only, since
// AudioEffects is a no-op elsewhere) and the loudness-normalization toggle,
// which had no UI at all before this screen existed.

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../../controllers/equalizer_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/audio_effects.dart';
import '../../services/equalizer.dart';
import '../app_theme.dart';
import '../theme/glass.dart';

class AudioSettingsScreen extends StatelessWidget {
  const AudioSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Audio', style: AppText.title(size: 20)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenMargin),
        children: [
          const _NormalizationTile(),
          if (AudioEffects.isEqualizerSupported) ...[
            const SizedBox(height: AppSpacing.gutter),
            const _EqualizerSection(),
          ],
        ],
      ),
    );
  }
}

class _NormalizationTile extends StatefulWidget {
  const _NormalizationTile();

  @override
  State<_NormalizationTile> createState() => _NormalizationTileState();
}

class _NormalizationTileState extends State<_NormalizationTile> {
  late bool _on = Hive.box('AppPrefs').get('loudnessNormalization') == true;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      radius: AppRadius.lg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: AppColors.accent,
        title: Text('Loudness normalization', style: AppText.title(size: 16)),
        subtitle: Text(
          'Even out volume differences between tracks',
          style: AppText.title(size: 13, color: AppColors.textTertiary),
        ),
        value: _on,
        onChanged: (v) {
          setState(() => _on = v);
          Get.find<PlayerController>()
              .audioHandler
              .customAction('toggleLoudnessNormalization', {'enable': v});
        },
      ),
    );
  }
}

class _EqualizerSection extends StatelessWidget {
  const _EqualizerSection();

  static String _label(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

  @override
  Widget build(BuildContext context) {
    final eq = Get.find<EqualizerController>();
    return GlassContainer(
      radius: AppRadius.lg,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Obx(() => Row(
                children: [
                  Expanded(
                    child: Text('Equalizer', style: AppText.title(size: 16)),
                  ),
                  Switch(
                    activeThumbColor: AppColors.accent,
                    value: eq.enabled.value,
                    onChanged: eq.setEnabled,
                  ),
                ],
              )),
          const SizedBox(height: 8),
          // Presets
          SizedBox(
            height: 40,
            child: Obx(() {
              final names = kEqPresets.keys.toList();
              // Read the observable SYNCHRONOUSLY here, not inside itemBuilder.
              // ListView calls itemBuilder lazily, so a read in there happens
              // after this closure returns and Obx tracks nothing — GetX then
              // throws ObxError, which a release build renders as a blank grey
              // box. (Same trap as the lyrics list: lazy builders don't count.)
              final current = eq.preset.value;
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: names.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final name = names[i];
                  final selected = current == name;
                  return ChoiceChip(
                    label: Text(name),
                    selected: selected,
                    onSelected: (_) => eq.applyPreset(name),
                    backgroundColor: AppColors.card,
                    selectedColor: AppColors.accent,
                    labelStyle: AppText.title(
                      size: 13,
                      color: selected ? Colors.white : AppColors.textTertiary,
                    ),
                  );
                },
              );
            }),
          ),
          const SizedBox(height: 12),
          // Bands
          SizedBox(
            height: 190,
            child: Row(
              children: List.generate(kEqFrequencies.length, (i) {
                return Expanded(
                  child: Obx(() => Column(
                        children: [
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                min: kEqMinGain,
                                max: kEqMaxGain,
                                value: eq.bands[i],
                                activeColor: AppColors.accent,
                                onChanged: eq.enabled.value
                                    ? (v) => eq.setBand(i, v)
                                    : null,
                              ),
                            ),
                          ),
                          Text(
                            _label(kEqFrequencies[i]),
                            style: AppText.title(
                                size: 10, color: AppColors.textTertiary),
                          ),
                        ],
                      )),
                );
              }),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: eq.reset,
              child: Text('Reset', style: AppText.title(size: 13)),
            ),
          ),
        ],
      ),
    );
  }
}
