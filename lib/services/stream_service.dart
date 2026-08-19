// stream_service.dart
// Resolves a video ID into playable audio stream formats.
//
// ── Why this is shaped the way it is ────────────────────────────────────────
// YouTube now returns HTTP 403 for any stream URL whose `n` query parameter has
// not been correctly deciphered (it used to merely throttle). Deciphering `n`
// means executing YouTube's player JavaScript, which we do not want to do
// on-device.
//
// The way out is to use clients that never emit an `n` parameter at all:
// VISIONOS (Apple Vision Pro) and ANDROID_VR (Quest) hand back direct,
// ready-to-play URLs. Metrolist and Musify independently converged on the same
// choice, which is a good sign it is the durable one.
//
// PRIMARY path — call youtubei `/player` ourselves with those clients:
//   • one small `sw.js_data` fetch for visitorData (cached by the caller, see
//     MyAudioHandler.checkNGetUrl) plus one `/player` POST
//   • NO 1.2 MB watch-page download, so it is fast and easy on rate limits
//   • the response carries per-format `loudnessDb`, which volume_mixer.dart
//     needs — youtube_explode_dart does not expose it
//   • visitorData is what stops YouTube answering LOGIN_REQUIRED; without it
//     many tracks fail even though the client itself is accepted
//
// FALLBACK path — youtube_explode_dart. It fetches the watch page, so it
// carries a fuller session and can recover tracks the direct path cannot. It is
// slower and yields no loudness (normalization degrades to a no-op for those
// tracks, which volume_mixer already handles), so it is genuinely a fallback.
//
// If playback breaks again, suspect in this order: (1) the client version
// strings below have gone stale — refresh them from Metrolist's
// YouTubeClient.kt or Musify's youtube_explode_dart fork; (2) YouTube started
// requiring a PO token for these clients too; (3) the `n` situation changed.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yed;

import '../util/log.dart';

// ── youtubei clients ────────────────────────────────────────────────────────

/// A youtubei client context. Only clients needing neither signature
/// deciphering nor a PO token belong here — anything else yields URLs we cannot
/// play. The ordering below is Metrolist's, which is field-proven.
class _YtClient {
  final String name;
  final String version;
  final String id;
  final String userAgent;
  final String osName;
  final String osVersion;
  final String deviceMake;
  final String deviceModel;
  final int? androidSdkVersion;

  const _YtClient({
    required this.name,
    required this.version,
    required this.id,
    required this.userAgent,
    required this.osName,
    required this.osVersion,
    required this.deviceMake,
    required this.deviceModel,
    this.androidSdkVersion,
  });

  Map<String, dynamic> context(String? visitorData) => {
        'clientName': name,
        'clientVersion': version,
        'deviceMake': deviceMake,
        'deviceModel': deviceModel,
        'userAgent': userAgent,
        'osName': osName,
        'osVersion': osVersion,
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
        if (androidSdkVersion != null) 'androidSdkVersion': androidSdkVersion,
        if (visitorData != null) 'visitorData': visitorData,
      };
}

const _visionOsUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';

const _visionOs = _YtClient(
  name: 'VISIONOS',
  version: '1.02',
  id: '101',
  userAgent: _visionOsUserAgent,
  osName: 'visionOS',
  osVersion: '26.5.23O471',
  deviceMake: 'Apple',
  deviceModel: 'RealityDevice17,1',
);

// Two ANDROID_VR builds on purpose: when Google retires one version string the
// other has historically kept working. Same trick Metrolist uses.
const _androidVr165 = _YtClient(
  name: 'ANDROID_VR',
  version: '1.65.10',
  id: '28',
  userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
  osName: 'Android',
  osVersion: '12L',
  deviceMake: 'Oculus',
  deviceModel: 'Quest 3',
  androidSdkVersion: 32,
);

const _androidVr143 = _YtClient(
  name: 'ANDROID_VR',
  version: '1.43.32',
  id: '28',
  userAgent: 'com.google.android.apps.youtube.vr.oculus/1.43.32 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
  osName: 'Android',
  osVersion: '12L',
  deviceMake: 'Oculus',
  deviceModel: 'Quest 3',
  androidSdkVersion: 32,
);

const _clientChain = [_visionOs, _androidVr165, _androidVr143];

const _playerUrl =
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';
const _swJsDataUrl = 'https://www.youtube.com/sw.js_data';

class StreamProvider {
  final bool playable;
  final List<Audio>? audioFormats;
  final String statusMSG;

  /// visitorData actually used for this fetch, so the caller can cache it and
  /// hand it back next time instead of re-fetching sw.js_data every track.
  final String? visitorData;

  StreamProvider({
    required this.playable,
    this.audioFormats,
    this.statusMSG = '',
    this.visitorData,
  });

  /// Resolve [videoId]. Pass a previously returned [visitorData] to skip the
  /// sw.js_data round-trip.
  static Future<StreamProvider> fetch(String videoId,
      {String? visitorData}) async {
    logD('stream', 'fetch($videoId): requesting manifest…');

    var visitor = visitorData;
    if (visitor == null) {
      visitor = await _fetchVisitorData();
      logD(
          'stream',
          'fetch($videoId): visitorData '
              '${visitor == null ? "unavailable" : "acquired"}');
    }

    // ── Primary: direct youtubei /player ────────────────────────────────────
    var lastStatus = '';
    for (final client in _clientChain) {
      try {
        final formats = await _playerFormats(videoId, client, visitor);
        if (formats.isNotEmpty) {
          logD(
              'stream',
              'fetch($videoId): OK via ${client.name} ${client.version} — '
                  '${formats.length} audio formats '
                  '(itags: ${formats.map((e) => e.itag).toList()})');
          return StreamProvider(
            playable: true,
            statusMSG: 'OK',
            audioFormats: formats,
            visitorData: visitor,
          );
        }
      } on _PlayerStatusException catch (e) {
        lastStatus = e.status;
        logD('stream',
            'fetch($videoId): ${client.name} ${client.version} -> ${e.status}');
      } on SocketException {
        return StreamProvider(
            playable: false, statusMSG: 'Network error', visitorData: visitor);
      } catch (e) {
        logD('stream',
            'fetch($videoId): ${client.name} failed — ${e.runtimeType}: $e');
      }
    }

    // ── Fallback: youtube_explode_dart (watch page = fuller session) ────────
    logD(
        'stream',
        'fetch($videoId): direct path exhausted (last="$lastStatus") — '
            'falling back to youtube_explode_dart');
    return _fetchViaExplode(videoId, visitor, lastStatus);
  }

  /// Anonymous session id. Without it YouTube answers LOGIN_REQUIRED for many
  /// tracks even when the client itself is accepted. Best-effort: a null result
  /// just means we try without one.
  static Future<String?> _fetchVisitorData() async {
    try {
      final res = await http.get(Uri.parse(_swJsDataUrl), headers: {
        'User-Agent': _visionOsUserAgent,
        'Content-Type': 'application/json',
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      var body = res.body;
      if (body.startsWith(")]}'")) body = body.substring(4);
      final decoded = jsonDecode(body);
      return decoded[0][2][0][0][13] as String?;
    } catch (e) {
      logD('stream', 'visitorData fetch failed — ${e.runtimeType}: $e');
      return null;
    }
  }

  /// One `/player` POST. Throws [_PlayerStatusException] when YouTube refuses
  /// the video (LOGIN_REQUIRED, UNPLAYABLE, …) so the caller tries the next
  /// client.
  static Future<List<Audio>> _playerFormats(
      String videoId, _YtClient client, String? visitorData) async {
    final res = await http
        .post(
          Uri.parse(_playerUrl),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': client.userAgent,
            'X-Youtube-Client-Name': client.id,
            'X-Youtube-Client-Version': client.version,
            'Origin': 'https://www.youtube.com',
            'Sec-Fetch-Mode': 'navigate',
            if (visitorData != null) 'X-Goog-Visitor-Id': visitorData,
          },
          body: jsonEncode({
            'context': {'client': client.context(visitorData)},
            'videoId': videoId,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode == 429) {
      throw const _PlayerStatusException('Rate limited');
    }
    if (res.statusCode != 200) {
      throw _PlayerStatusException('HTTP ${res.statusCode}');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final status =
        (json['playabilityStatus'] as Map?)?['status']?.toString() ?? 'UNKNOWN';

    final adaptive =
        ((json['streamingData'] as Map?)?['adaptiveFormats'] as List?) ??
            const [];

    final formats = <Audio>[];
    for (final raw in adaptive) {
      if (raw is! Map) continue;
      final mime = raw['mimeType']?.toString() ?? '';
      if (!mime.startsWith('audio')) continue;
      final url = raw['url']?.toString();
      // No `url` means this format is SABR-only (server-side ABR) and cannot be
      // played from a plain URL — skip it rather than crash on it.
      if (url == null || url.isEmpty) continue;

      formats.add(Audio(
        itag: (raw['itag'] as num?)?.toInt() ?? 0,
        audioCodec: mime.contains('mp4a') ? Codec.mp4a : Codec.opus,
        bitrate: (raw['bitrate'] as num?)?.toInt() ?? 0,
        duration: int.tryParse(raw['approxDurationMs']?.toString() ?? '') ?? 0,
        loudnessDb: (raw['loudnessDb'] as num?)?.toDouble() ?? 0.0,
        url: url,
        size: int.tryParse(raw['contentLength']?.toString() ?? '') ?? 0,
      ));
    }

    if (formats.isEmpty && status != 'OK') {
      throw _PlayerStatusException(status);
    }
    return formats;
  }

  /// Fallback resolver — same client preference, but routed through
  /// youtube_explode_dart so the watch page supplies a fuller session.
  static Future<StreamProvider> _fetchViaExplode(
      String videoId, String? visitor, String lastStatus) async {
    final yt = yed.YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(
        videoId,
        ytClients: [_explodeVisionOs, yed.YoutubeApiClient.androidVr],
      );
      final audio = manifest.audioOnly;
      logD('stream', 'fetch($videoId): fallback OK — ${audio.length} formats');
      return StreamProvider(
        playable: true,
        statusMSG: 'OK',
        visitorData: visitor,
        audioFormats: audio
            .map((e) => Audio(
                  itag: e.tag,
                  audioCodec:
                      e.audioCodec.contains('mp') ? Codec.mp4a : Codec.opus,
                  bitrate: e.bitrate.bitsPerSecond,
                  duration: 0,
                  // Not exposed by youtube_explode_dart. 0 dB means "unknown",
                  // which volume_mixer treats as no attenuation.
                  loudnessDb: 0.0,
                  url: e.url.toString(),
                  size: e.size.totalBytes,
                ))
            .toList(),
      );
    } catch (e, st) {
      logD('stream', 'fetch($videoId): FALLBACK FAILED — ${e.runtimeType}: $e');
      logD('stream', st.toString());
      return StreamProvider(
          playable: false,
          statusMSG: _describe(e, lastStatus),
          visitorData: visitor);
    } finally {
      yt.close();
    }
  }

  /// User-facing failure text. Deliberately also covers [Error] and not just
  /// [Exception]: the extraction library can throw TypeError internally when
  /// YouTube changes shape, and "Null check operator used on a null value" is
  /// not something a listener should ever be shown.
  static String _describe(Object e, String lastStatus) {
    if (e is SocketException) return 'Network error';
    if (e is yed.VideoRequiresPurchaseException) {
      return 'This track requires purchase';
    }
    if (e is yed.VideoUnplayableException) {
      return lastStatus == 'LOGIN_REQUIRED'
          ? 'YouTube is asking this device to sign in — try again shortly'
          : 'This track is unavailable';
    }
    if (e is yed.VideoUnavailableException) return 'This track is unavailable';
    if (e is yed.RequestLimitExceededException) {
      return 'Too many requests to YouTube — wait a moment and retry';
    }
    if (e is yed.YoutubeExplodeException) {
      return lastStatus.isNotEmpty
          ? 'Playback source unavailable ($lastStatus)'
          : 'Playback source unavailable';
    }
    // Includes TypeError and friends thrown inside the extraction library.
    return 'Playback source unavailable — try again';
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
        if (visitorData != null) 'visitorData': visitorData,
      };
}

/// VISIONOS for the fallback library, which takes its own client type.
const _explodeVisionOs = yed.YoutubeApiClient({
  'context': {
    'client': {
      'clientName': 'VISIONOS',
      'clientVersion': '1.02',
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice17,1',
      'userAgent': _visionOsUserAgent,
      'osName': 'visionOS',
      'osVersion': '26.5.23O471',
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
  },
}, _playerUrl);

/// YouTube refused the video for this client (LOGIN_REQUIRED, UNPLAYABLE, …).
class _PlayerStatusException implements Exception {
  final String status;
  const _PlayerStatusException(this.status);
  @override
  String toString() => 'PlayerStatus($status)';
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
