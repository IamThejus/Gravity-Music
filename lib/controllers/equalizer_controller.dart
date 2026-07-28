// controllers/equalizer_controller.dart
// Reactive equalizer state: band gains, preset selection, enable flag, plus
// persistence and debounced application to the audio backend.
//
// The maths lives in services/equalizer.dart and the platform call in
// services/audio_effects.dart; this class only holds state and decides WHEN to
// apply. Applying is best-effort — a failure must never break playback.

import 'dart:async';

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../services/audio_effects.dart';
import '../services/equalizer.dart';

class EqualizerController extends GetxController {
  final enabled = false.obs;
  final bands = List<double>.filled(kEqFrequencies.length, 0.0).obs;
  final preset = 'Flat'.obs;

  /// Slider drags fire continuously; rebuilding and pushing a filter graph on
  /// every frame would swap mpv's chain dozens of times a second. Coalesce.
  Timer? _applyTimer;
  static const _debounce = Duration(milliseconds: 150);

  Box get _box => Hive.box('AppPrefs');

  @override
  void onInit() {
    super.onInit();
    _restore();
    _applyNow();
  }

  @override
  void onClose() {
    _applyTimer?.cancel();
    super.onClose();
  }

  /// Read persisted state, falling back to defaults on anything malformed —
  /// corrupt preferences must not prevent the app from starting.
  void _restore() {
    enabled.value = _box.get('eqEnabled') == true;

    final stored = _box.get('eqBands');
    if (stored is List && stored.length == kEqFrequencies.length) {
      final parsed = <double>[];
      for (final v in stored) {
        parsed.add(v is num
            ? v.toDouble().clamp(kEqMinGain, kEqMaxGain).toDouble()
            : 0.0);
      }
      bands.assignAll(parsed);
    }

    final storedPreset = _box.get('eqPreset');
    if (storedPreset is String && storedPreset.isNotEmpty) {
      preset.value = storedPreset;
    }
  }

  void _persist() {
    _box.put('eqEnabled', enabled.value);
    _box.put('eqBands', bands.toList());
    _box.put('eqPreset', preset.value);
  }

  /// Rebuild the chain and push it to the backend immediately.
  Future<void> _applyNow() async {
    final chain = buildEqualizerChain(bands, enabled: enabled.value);
    await AudioEffects.applyEqualizer(chain);
  }

  void _scheduleApply() {
    _applyTimer?.cancel();
    _applyTimer = Timer(_debounce, _applyNow);
  }

  /// Re-assert the current chain. Called on track change: at boot the mpv
  /// player may not exist yet, so the initial apply can be a no-op. Applying
  /// again is idempotent and cheap.
  Future<void> reapply() => _applyNow();

  void setEnabled(bool value) {
    enabled.value = value;
    _persist();
    _applyNow(); // immediate: a toggle should be heard at once
  }

  void setBand(int index, double gain) {
    if (index < 0 || index >= bands.length) return;
    bands[index] = gain.clamp(kEqMinGain, kEqMaxGain).toDouble();
    preset.value = 'Custom'; // hand-tuning leaves the named preset
    _persist();
    _scheduleApply();
  }

  void applyPreset(String name) {
    final values = kEqPresets[name];
    if (values == null) return;
    bands.assignAll(values);
    preset.value = name;
    _persist();
    _applyNow();
  }

  void reset() => applyPreset('Flat');
}
