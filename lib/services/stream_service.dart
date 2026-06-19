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

  // ── Quality selectors (mirrors HarmonyMusic exactly) ──────────────────────

  /// Best overall: prefer Opus 160kbps (251) or AAC 128kbps (140)
  Audio? get highestQualityAudio => audioFormats?.lastWhere(
        (a) => a.itag == 251 || a.itag == 140,
        orElse: () => audioFormats!.first,
      );

  /// Lowest data usage: Opus 70kbps (249) or AAC 48kbps (139)
  Audio? get lowQualityAudio => audioFormats?.lastWhere(
        (a) => a.itag == 249 || a.itag == 139,
        orElse: () => audioFormats!.first,
      );

  /// Serialised form used for Hive caching & Isolate return value
  Map<String, dynamic> get hmStreamingData => {
        'playable': playable,
        'statusMSG': statusMSG,
        'lowQualityAudio': lowQualityAudio?.toJson(),
        'highQualityAudio': highestQualityAudio?.toJson(),
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