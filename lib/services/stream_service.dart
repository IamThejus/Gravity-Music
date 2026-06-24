// stream_service.dart
// Mirrors HarmonyMusic's StreamProvider logic exactly.
// Fetches audio-only stream manifests from YouTube via youtube_explode_dart.

import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../util/log.dart';

class StreamProvider {
  final bool playable;
  final List<Audio>? audioFormats;
  final String statusMSG;

  StreamProvider({
    required this.playable,
    this.audioFormats,
    this.statusMSG = '',
  });

 static Future<StreamProvider> fetch(String videoId) async {
    final yt = YoutubeExplode();
    
    logD('stream', 'fetch($videoId): requesting manifest…');
    try {
      final res = await yt.videos.streamsClient.getManifest(videoId);
      final audio = res.audioOnly;
      logD('stream', 'fetch($videoId): OK — ${audio.length} audio formats '
          '(itags: ${audio.map((e) => e.tag).toList()})');
      return StreamProvider(
          playable: true,
          statusMSG: "OK",
          audioFormats: audio
              .map((e) => Audio(
                  itag: e.tag,
                  audioCodec:
                      e.audioCodec.contains('mp') ? Codec.mp4a : Codec.opus,
                  bitrate: e.bitrate.bitsPerSecond,
                  duration: e.duration ?? 0,
                  loudnessDb: e.loudnessDb,
                  url: e.url.toString(),
                  size: e.size.totalBytes))
              .toList());

    } catch (e, st) {
      logD('stream', 'fetch($videoId): FAILED — ${e.runtimeType}: $e');
      logD('stream', st.toString());
      if (e is SocketException) {
        return StreamProvider(playable: false, statusMSG: 'Network error');
      } else if (e is VideoUnplayableException) {
        return StreamProvider(
            playable: false, statusMSG: e.reason ?? 'Video is unplayable');
      } else if (e is VideoRequiresPurchaseException) {
        return StreamProvider(
            playable: false, statusMSG: 'Video requires purchase');
      } else if (e is VideoUnavailableException) {
        return StreamProvider(playable: false, statusMSG: 'Video unavailable');
      } else if (e is YoutubeExplodeException) {
        return StreamProvider(playable: false, statusMSG: e.message);
      } else {
        return StreamProvider(
            playable: false, statusMSG: 'Unknown error: $e');
      }
    } finally {
      yt.close();
    }
  }

  // ── Quality ranking ───────────────────────────────────────────────────────

  /// All audio formats, deduped to one entry per (codec, kbps) tier and sorted
  /// by bitrate descending — index 0 is the best stream. At equal bitrates Opus
  /// wins (160kbps Opus is perceptually better than 128kbps AAC). YouTube often
  /// returns duplicate/DRC variants at the same bitrate; collapsing them keeps
  /// the user-facing quality list clean.
  List<Audio> get rankedFormats {
    final list = audioFormats;
    if (list == null || list.isEmpty) return const [];
    final seen = <String>{};
    final unique = <Audio>[];
    for (final a in list) {
      final key = '${a.audioCodec}_${(a.bitrate / 1000).round()}';
      if (seen.add(key)) unique.add(a);
    }
    unique.sort((a, b) {
      final cmp = b.bitrate.compareTo(a.bitrate);
      if (cmp != 0) return cmp;
      // Same bitrate: Opus > AAC
      if (a.audioCodec == Codec.opus && b.audioCodec != Codec.opus) return -1;
      if (b.audioCodec == Codec.opus && a.audioCodec != Codec.opus) return 1;
      return 0;
    });
    return unique;
  }

  /// Serialised form used for Hive caching & Isolate return value. Stores the
  /// full ranked format list so the player can offer a per-track quality picker
  /// and pick any tier on demand (not just a pre-baked low/high pair).
  Map<String, dynamic> get hmStreamingData => {
        'playable': playable,
        'statusMSG': statusMSG,
        'formats': rankedFormats.map((a) => a.toJson()).toList(),
      };
}

// ── Audio model ────────────────────────────────────────────────────────────

class Audio {
  final int itag;
  final Codec audioCodec;
  final int bitrate;
  final int duration; // milliseconds
  final int size;
  final double loudnessDb;
  final String url;

  Audio({
    required this.itag,
    required this.audioCodec,
    required this.bitrate,
    required this.duration,
    required this.loudnessDb,
    required this.url,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        'itag': itag,
        'audioCodec': audioCodec.toString(),
        'bitrate': bitrate,
        'loudnessDb': loudnessDb,
        'url': url,
        'approxDurationMs': duration,
        'size': size,
      };

  factory Audio.fromJson(Map<String, dynamic> json) => Audio(
        itag: json['itag'],
        audioCodec: (json['audioCodec'] as String).contains('mp4a')
            ? Codec.mp4a
            : Codec.opus,
        bitrate: json['bitrate'] ?? 0,
        duration: json['approxDurationMs'] ?? 0,
        loudnessDb: (json['loudnessDb'] as num?)?.toDouble() ?? 0.0,
        url: json['url'],
        size: json['size'] ?? 0,
      );
}

enum Codec { mp4a, opus }