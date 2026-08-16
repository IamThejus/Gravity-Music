// controllers/audio_effects_controller.dart
// Reactive audio-effect state: equalizer band gains, preset selection and
// enable flag, plus the mono downmix — with persistence and debounced
// application to the audio backend.
//
// The equalizer and mono share one controller rather than getting one each
// because on desktop they are not independent: both are written to mpv's
// single `af` property, so they have to be restored together at boot and
// re-composed on every change (see AudioEffects / buildFilterChain).
//
// The maths lives in services/equalizer.dart and the platform call in
// services/audio_effects.dart; this class only holds state and decides WHEN to
// apply. Applying is best-effort — a failure must never break playback.

import 'dart:async';

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../services/audio_effects.dart';
import '../services/equalizer.dart';

class AudioEffectsController extends GetxController {
  final enabled = false.obs;
  final bands = List<double>.filled(kEqFrequencies.length, 0.0).obs;
  final preset = 'Flat'.obs;

  /// Downmix both channels into each speaker. Desktop only — on Android this
  /// stays false and the UI points at the OS accessibility setting instead.
  final mono = false.obs;

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
    // If a debounced apply is still pending, a slider moved <150ms before
    // teardown would otherwise be silently lost (cancelled, never flushed).
    // Persist it now — no need to also push it to the backend, the process
    // is tearing down anyway.
    if (_applyTimer?.isActive ?? false) {
      _applyTimer?.cancel();
      _persist();
    }
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
        // Screen out non-finite values explicitly before clamp(): clamp()
        // does NOT leave NaN as NaN — `double.nan.clamp(-12.0, 12.0)` returns
        // 12.0 (the maximum), so an unguarded corrupt/NaN gain would silently
        // become a full +12 dB boost rather than being neutralized. Falling
        // back to 0.0 (flat) is the safe default for any non-finite value.
        final d = v is num ? v.toDouble() : double.nan;
        parsed.add(d.isFinite ? d.clamp(kEqMinGain, kEqMaxGain).toDouble() : 0.0);
      }
      bands.assignAll(parsed);
    }

    final storedPreset = _box.get('eqPreset');
    if (storedPreset is String && storedPreset.isNotEmpty) {
      preset.value = storedPreset;
    }

    mono.value = _box.get('monoAudio') == true;
  }

  void _persist() {
    _box.put('eqEnabled', enabled.value);
    _box.put('eqBands', bands.toList());
    _box.put('eqPreset', preset.value);
    _box.put('monoAudio', mono.value);
  }

  /// Push every effect's current state to the backend immediately. How it
  /// gets applied (one mpv filter chain on desktop, the device's own bands on
  /// Android) is AudioEffects' problem, not ours.
  Future<void> _applyNow() => AudioEffects.apply(
        bands: bands,
        equalizerEnabled: enabled.value,
        mono: mono.value,
      );

  /// Coalesce BOTH the Hive write and the mpv apply behind the debounce.
  /// Persisting per drag frame would fire dozens of Box.put calls a second —
  /// the same write-storm this project already had to fix for the volume
  /// slider. Losing <150ms of drag on a hard kill is the accepted trade.
  void _scheduleApply() {
    _applyTimer?.cancel();
    _applyTimer = Timer(_debounce, () {
      _persist();
      _applyNow();
    });
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

  void setMono(bool value) {
    mono.value = value;
    _persist();
    _applyNow(); // immediate: a toggle should be heard at once
  }

  void setBand(int index, double gain) {
    if (index < 0 || index >= bands.length) return;
    bands[index] = gain.clamp(kEqMinGain, kEqMaxGain).toDouble();
    preset.value = 'Custom'; // hand-tuning leaves the named preset
    _scheduleApply(); // persists AND applies once the drag settles
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
