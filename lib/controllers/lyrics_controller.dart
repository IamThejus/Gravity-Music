// controllers/lyrics_controller.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../services/yt_music_service.dart';

class LyricLine {
  final Duration timestamp;
  final String text;
  const LyricLine({required this.timestamp, required this.text});
}

class _CachedLyrics {
  final bool hasSynced;
  final List<LyricLine> lines;
  final String plain;
  const _CachedLyrics({required this.hasSynced, required this.lines, required this.plain});
}

class LyricsController extends GetxController {
  final isLoading    = false.obs;
  final isAvailable  = false.obs;
  final isOpen       = false.obs;
  final hasSynced    = false.obs;
  final activeIndex  = (-1).obs;
  final parsedLyrics = <LyricLine>[].obs;
  final plainLyrics  = ''.obs;
  final dominantColor = const Color(0xFF1C1A2E).obs;

  final Map<String, _CachedLyrics> _lyricsCache = {};
  final Map<String, Color>         _colorCache  = {};

  String?  _currentTrackId;
  Timer?   _throttleTimer;
  Duration _lastPosition = Duration.zero;

  @override
  void onClose() {
    _throttleTimer?.cancel();
    super.onClose();
  }

  Future<void> fetchLyrics({
    required String trackId,
    required String title,
    required String artist,
    String? thumbnailUrl,
  }) async {
    if (trackId == _currentTrackId) return;
    _currentTrackId = trackId;

    isAvailable.value  = false;
    hasSynced.value    = false;
    activeIndex.value  = -1;
    parsedLyrics.clear();
    plainLyrics.value  = '';
    _lastPosition      = Duration.zero;

    if (_colorCache.containsKey(trackId)) {
      dominantColor.value = _colorCache[trackId]!;
    } else {
      dominantColor.value = const Color(0xFF1C1A2E);
      if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
        _extractColor(trackId, thumbnailUrl);
      }
    }

    if (_lyricsCache.containsKey(trackId)) {
      _applyCache(_lyricsCache[trackId]!);
      return;
    }

    isLoading.value = true;
    try {
      // YouTube titles/artists are noisy ("Song (Official Video)", "A, B, C",
      // "Artist - Topic"). lrclib matches near-exactly, so a raw query almost
      // always returns []. Clean the inputs, then try progressively fuzzier
      // strategies until one yields lyrics.
      final cleanTitle = _cleanTitle(title);
      final cleanArtist = _cleanArtist(artist);

      final strategies = <Map<String, String>>[
        if (cleanTitle.isNotEmpty && cleanArtist.isNotEmpty)
          {'track_name': cleanTitle, 'artist_name': cleanArtist},
        if (cleanTitle.isNotEmpty && cleanArtist.isNotEmpty)
          {'q': '$cleanTitle $cleanArtist'},
        if (cleanTitle.isNotEmpty) {'q': cleanTitle},
      ];

      for (final params in strategies) {
        final uri =
            Uri.parse('https://lrclib.net/api/search').replace(queryParameters: params);
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        if (trackId != _currentTrackId) return; // user moved on
        if (res.statusCode != 200) continue;

        final List data = json.decode(res.body) as List;
        final parsed = _parseBestResult(data);
        if (parsed.lines.isNotEmpty || parsed.plain.isNotEmpty) {
          _lyricsCache[trackId] = parsed;
          _applyCache(parsed);
          return;
        }
      }

      // lrclib had nothing — fall back to YouTube Music (plain, unsynced;
      // source: Musixmatch). Covers regional tracks lrclib lacks.
      final ytmPlain = await YtMusicService.lyrics(trackId);
      if (trackId != _currentTrackId) return; // user moved on
      if (ytmPlain.isNotEmpty) {
        final fallback =
            _CachedLyrics(hasSynced: false, lines: const [], plain: ytmPlain);
        _lyricsCache[trackId] = fallback;
        _applyCache(fallback);
        return;
      }

      // Nothing anywhere — cache the miss so we don't refetch.
      const empty = _CachedLyrics(hasSynced: false, lines: [], plain: '');
      _lyricsCache[trackId] = empty;
      _applyCache(empty);
    } catch (_) {
    } finally {
      if (trackId == _currentTrackId) isLoading.value = false;
    }
  }

  /// Strips YouTube cruft from a track title so lrclib can match it.
  static String _cleanTitle(String raw) {
    var t = raw;
    // Remove bracketed segments: (Official Video), [4K], {Lyrics}, etc.
    t = t.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
    // Remove "feat./ft./featuring ..." up to a separator.
    t = t.replaceAll(
        RegExp(r'\b(feat|ft|featuring)\b.*$', caseSensitive: false), ' ');
    // Remove common promo keywords left outside brackets.
    t = t.replaceAll(
        RegExp(
            r'\b(official\s*(music\s*)?video|official\s*audio|lyric\s*video|lyrics|visuali[sz]er|audio|hd|4k|mv|remaster(ed)?|explicit)\b',
            caseSensitive: false),
        ' ');
    // Drop a trailing "| ..." channel/promo tail.
    t = t.split('|').first;
    return _squish(t);
  }

  /// Reduces a possibly multi-artist / channel string to a primary artist.
  static String _cleanArtist(String raw) {
    var a = raw.split(RegExp(r'[,&/]|feat\.?|ft\.?', caseSensitive: false)).first;
    a = a.replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), ' ');
    a = a.replaceAll(RegExp(r'\bVEVO\b', caseSensitive: false), ' ');
    a = a.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
    return _squish(a);
  }

  /// Collapses whitespace and trims stray separators.
  static String _squish(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^[\s\-|]+|[\s\-|]+$'), '').trim();

  void updatePlaybackPosition(Duration position) {
    _lastPosition = position;
    if (_throttleTimer?.isActive ?? false) return;
    _throttleTimer = Timer(
      const Duration(milliseconds: 200),
      () => _syncIndex(_lastPosition),
    );
  }

  void openLyrics() => isOpen.value = true;
  void closeLyrics() {
    isOpen.value      = false;
    activeIndex.value = -1;
    _lastPosition     = Duration.zero;
  }

  Future<void> _extractColor(String trackId, String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (trackId != _currentTrackId || res.statusCode != 200) return;
      final bytes = res.bodyBytes;
      if (bytes.length < 100) return;
      int r = 0, g = 0, b = 0, n = 0;
      final step = (bytes.length ~/ 200).clamp(3, 300);
      for (int i = 0; i < bytes.length - 2; i += step) {
        r += bytes[i]; g += bytes[i + 1]; b += bytes[i + 2]; n++;
      }
      if (n == 0) return;
      final color = Color.fromARGB(
        255,
        ((r / n) * 0.25).round().clamp(0, 100),
        ((g / n) * 0.25).round().clamp(0, 100),
        ((b / n) * 0.25).round().clamp(0, 100),
      );
      _colorCache[trackId] = color;
      if (trackId == _currentTrackId) dominantColor.value = color;
    } catch (_) {}
  }

  void _applyCache(_CachedLyrics c) {
    hasSynced.value    = c.hasSynced;
    parsedLyrics.assignAll(c.lines);
    plainLyrics.value  = c.plain;
    isAvailable.value  = c.lines.isNotEmpty || c.plain.isNotEmpty;
  }

  _CachedLyrics _parseBestResult(List data) {
    Map<String, dynamic>? best;
    int bestScore = -1;
    for (final item in data) {
      final map    = Map<String, dynamic>.from(item as Map);
      final plain  = (map['plainLyrics']  as String? ?? '').trim();
      final synced = (map['syncedLyrics'] as String? ?? '').trim();
      if (plain.isEmpty && synced.isEmpty) continue;
      final score  = (synced.isNotEmpty ? 10000 : 0) + plain.length;
      if (score > bestScore) { bestScore = score; best = map; }
    }
    if (best == null) return const _CachedLyrics(hasSynced: false, lines: [], plain: '');
    final syncedRaw = (best['syncedLyrics'] as String? ?? '').trim();
    final plainRaw  = (best['plainLyrics']  as String? ?? '').trim();
    if (syncedRaw.isNotEmpty) {
      final lines = _parseLrc(syncedRaw);
      if (lines.isNotEmpty) {
        return _CachedLyrics(hasSynced: true, lines: lines, plain: plainRaw);
      }
    }
    return _CachedLyrics(hasSynced: false, lines: [], plain: plainRaw);
  }

  List<LyricLine> _parseLrc(String raw) {
    final lines = <LyricLine>[];
    final regex = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]\s*(.+)');
    for (final row in raw.split('\n')) {
      final m = regex.firstMatch(row.trim());
      if (m == null) continue;
      final mm   = int.tryParse(m.group(1) ?? '') ?? 0;
      final ss   = int.tryParse(m.group(2) ?? '') ?? 0;
      final frac = m.group(3) ?? '0';
      final ms   = frac.length <= 2
          ? int.parse(frac) * (frac.length == 1 ? 100 : 10)
          : int.parse(frac.substring(0, 3));
      final text = (m.group(4) ?? '').trim();
      if (text.isEmpty) continue;
      lines.add(LyricLine(
        timestamp: Duration(minutes: mm, seconds: ss, milliseconds: ms),
        text: text,
      ));
    }
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  void _syncIndex(Duration pos) {
    if (!hasSynced.value || parsedLyrics.isEmpty) return;
    final lines = parsedLyrics;
    int lo = 0, hi = lines.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].timestamp <= pos) { result = mid; lo = mid + 1; }
      else { hi = mid - 1; }
    }
    // Only publish the active line. The lyrics view owns the (variable-height)
    // auto-centering via ScrollablePositionedList, keyed off this index — the
    // old fixed-height scroll math here drifted the active line off-centre.
    if (result != activeIndex.value) activeIndex.value = result;
  }
}