// ui/theme/dynamic_color_controller.dart
//
// Derives a per-track accent + deep base color from the current album art
// (DESIGN.md "Dynamic Accent"). Subscribes to PlayerController.currentSong
// and runs palette_generator off the cached artwork image. UI widgets just
// `Obx` on `accent` / `base` to tint backgrounds, glows, and controls.
//
// Reuses the already-cached CachedNetworkImage provider so no extra network
// fetch is incurred for art the player notification already downloaded.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../controllers/player_controller.dart';
import '../../services/thumb_util.dart';

class DynamicColorController extends GetxController {
  static const _fallbackAccent = Color(0xFF7C6FF0);
  static const _fallbackBase = Color(0xFF12121A);

  final accent = _fallbackAccent.obs;
  final base = _fallbackBase.obs;

  final _cache = <String, ({Color accent, Color base})>{};
  String? _currentId;

  @override
  void onInit() {
    super.onInit();
    final pc = Get.find<PlayerController>();
    // Prime from whatever is already playing, then track changes.
    _updateFor(pc.currentSong.value?.id, pc.currentSong.value?.artUri?.toString());
    ever<dynamic>(pc.currentSong, (song) {
      _updateFor(song?.id as String?, song?.artUri?.toString());
    });
  }

  Future<void> _updateFor(String? id, String? artUrl) async {
    if (id == null) return;
    if (id == _currentId) return;
    _currentId = id;

    final cached = _cache[id];
    if (cached != null) {
      accent.value = cached.accent;
      base.value = cached.base;
      return;
    }
    if (artUrl == null || artUrl.isEmpty) {
      accent.value = _fallbackAccent;
      base.value = _fallbackBase;
      return;
    }

    // PaletteGenerator must run on the UI isolate (it needs a decoded
    // ui.Image), and its decode+quantize is a several-ms synchronous spike.
    // Defer it past the track-change / Now-Playing-open animation so that
    // spike never collides with an animating frame. Results are cached per
    // id, so this runs at most once per track; the small delay is invisible
    // (the wash fades in over a 450ms AnimatedContainer regardless). Colors
    // and parameters are unchanged, so the palette result is identical.
    await Future.delayed(const Duration(milliseconds: 400));
    if (id != _currentId) return; // user moved on while we waited

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(ThumbUtil.get(artUrl, ThumbnailSize.tile)),
        size: const Size(120, 120),
        maximumColorCount: 16,
      );
      if (id != _currentId) return; // user moved on while we computed

      final raw = palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          palette.dominantColor?.color ??
          _fallbackAccent;

      final tunedAccent = _vivid(raw);
      final tunedBase = _deepen(raw);
      _cache[id] = (accent: tunedAccent, base: tunedBase);
      accent.value = tunedAccent;
      base.value = tunedBase;
    } catch (_) {
      accent.value = _fallbackAccent;
      base.value = _fallbackBase;
    }
  }

  /// Push a raw artwork color into a saturated, mid-light accent so it reads
  /// well on near-black surfaces regardless of how muddy the source is.
  Color _vivid(Color c) {
    final h = HSLColor.fromColor(c);
    return h
        .withSaturation(h.saturation.clamp(0.45, 1.0))
        .withLightness(h.lightness.clamp(0.5, 0.68))
        .toColor();
  }

  /// Deep, desaturated version of the accent used as the Now-Playing wash.
  Color _deepen(Color c) {
    final h = HSLColor.fromColor(c);
    return h
        .withSaturation((h.saturation * 0.55).clamp(0.0, 0.6))
        .withLightness(0.10)
        .toColor();
  }
}
