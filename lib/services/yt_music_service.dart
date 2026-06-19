// services/yt_music_service.dart
//
// On-device YouTube Music API client.
//
// Replaces the SaraGama API (which wrapped `ytmusicapi` on a Render server) by
// calling music.youtube.com's internal `youtubei` endpoints DIRECTLY from the
// device. No external server, no `ytmusicapi` dependency, no Render — so
// results are deterministic per-user (the device's own region) instead of
// varying with a shared server's IP.
//
// Unlike youtube_explode's regular-YouTube search (which returns videos, lyric
// re-uploads, covers, and channel names as "artists"), this hits the YouTube
// MUSIC catalog with the "Songs" filter, yielding clean Art Tracks: real song
// titles, real artist names, album, and square `googleusercontent` album art
// (which ThumbUtil can resize) — matching the quality SaraGama used to give.
//
// The response is a deeply-nested tree of `…Renderer` objects; parsing walks it
// defensively (recursive key collection + per-field guards) so a single shape
// change doesn't throw the whole result away.

import 'dart:convert';

import 'package:http/http.dart' as http;

class YtMusicSong {
  final String videoId;
  final String title;
  final List<String> artists;
  final String album;
  final String thumbnail; // square googleusercontent URL (ThumbUtil-resizable)
  final String duration; // "m:ss" / "h:mm:ss"

  const YtMusicSong({
    required this.videoId,
    required this.title,
    required this.artists,
    required this.album,
    required this.thumbnail,
    required this.duration,
  });
}

class YtMusicService {
  // The youtubei endpoints accept requests with NO innertube API key, so none
  // is stored here — keeping the source free of any Google-API-key-shaped
  // string that secret scanners flag (the public web-client key isn't a real
  // credential, but scanners pattern-match it regardless). Only the WEB_REMIX
  // client version is sent; if a stale version is ever rejected,
  // [_refreshConfig] scrapes a current one from the page.
  static const _defaultClientVersion = '1.20240101.01.00';

  // "Songs" filter param → returns Art Tracks (clean official audio) only.
  static const _songsParams = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // Client version refreshed from the music.youtube.com page ONLY after a
  // request fails (lazily, so the happy path is a single request). Lets a
  // rejected/stale client version self-heal without an app update.
  static String? _dynamicClientVersion;

  static String get _clientVersion =>
      _dynamicClientVersion ?? _defaultClientVersion;

  static final RegExp _durationRe = RegExp(r'^\d+(:\d{2})+$');

  /// Searches the YouTube Music catalog for songs. Returns clean Art-Track
  /// results, or an empty list on any error (caller treats that as no results).
  static Future<List<YtMusicSong>> searchSongs(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final first = await _search(q);
    if (first != null) return first;

    // The request failed (e.g. a stale client version was rejected). Refresh
    // the client version from the YT Music page once and retry. Failure-only.
    if (await _refreshConfig()) {
      final second = await _search(q);
      if (second != null) return second;
    }
    return [];
  }

  /// One search attempt. Returns the parsed list on a 200 response (an empty
  /// list is a legitimate "no results"), or `null` on any failure (non-200 /
  /// exception) so the caller can refresh the key and retry.
  static Future<List<YtMusicSong>?> _search(String query) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/search'
                '?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'Origin': 'https://music.youtube.com',
              'User-Agent': _ua,
            },
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': _clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'query': query,
              'params': _songsParams,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;
      return _parseSongs(jsonDecode(res.body));
    } catch (_) {
      return null;
    }
  }

  /// Returns the YouTube Music radio / "up next" queue for [videoId] — the same
  /// recommendation pool SaraGama's /recommendation endpoint produced (it
  /// wrapped this exact `next` call). The seed track itself is filtered out.
  /// Empty list on any failure. Uses the same lazy key-refresh-on-failure path
  /// as [searchSongs].
  static Future<List<YtMusicSong>> radio(String videoId) async {
    if (videoId.isEmpty) return [];

    final first = await _next(videoId);
    if (first != null) return first;

    if (await _refreshConfig()) {
      final second = await _next(videoId);
      if (second != null) return second;
    }
    return [];
  }

  /// One `next` attempt. Returns the parsed queue on a 200 (seed removed), or
  /// `null` on any failure so the caller can refresh the key and retry.
  static Future<List<YtMusicSong>?> _next(String videoId) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/next'
                '?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'Origin': 'https://music.youtube.com',
              'User-Agent': _ua,
            },
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': _clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'enablePersistentPlaylistPanel': true,
              'isAudioOnly': true,
              'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
              'videoId': videoId,
              'playlistId': 'RDAMVM$videoId', // video radio mix
              'params': 'wAEB', // radio
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;
      return _parseRadio(jsonDecode(res.body), videoId);
    } catch (_) {
      return null;
    }
  }

  static List<YtMusicSong> _parseRadio(dynamic data, String seedId) {
    final items = <dynamic>[];
    _collect(data, 'playlistPanelVideoRenderer', items);

    final songs = <YtMusicSong>[];
    final seen = <String>{seedId}; // drop the seed track itself
    for (final it in items) {
      if (it is! Map) continue;
      final song = _parseRadioItem(it);
      if (song != null && seen.add(song.videoId)) songs.add(song);
    }
    return songs;
  }

  static YtMusicSong? _parseRadioItem(Map item) {
    final videoId = item['videoId'];
    if (videoId is! String || videoId.isEmpty) return null;

    final title = _runsText(item['title']);
    if (title.isEmpty) return null;

    final artists = <String>[];
    var album = '';
    final byline = item['longBylineText'];
    if (byline is Map && byline['runs'] is List) {
      for (final r in byline['runs']) {
        if (r is! Map) continue;
        final pageType = _pageType(r);
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          artists.add((r['text'] ?? '').toString());
        } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album = (r['text'] ?? '').toString();
        }
      }
    }

    final duration = _runsText(item['lengthText']);

    final thumbLists = <dynamic>[];
    _collect(item['thumbnail'] ?? const {}, 'thumbnails', thumbLists);
    var thumbnail = '';
    for (final list in thumbLists) {
      if (list is List && list.isNotEmpty && list.last is Map) {
        thumbnail = (list.last['url'] ?? '').toString();
        if (thumbnail.isNotEmpty) break;
      }
    }

    return YtMusicSong(
      videoId: videoId,
      title: title,
      artists: artists,
      album: album,
      thumbnail: thumbnail,
      duration: duration,
    );
  }

  /// First run's text from a `{ runs: [...] }` text object.
  static String _runsText(dynamic textObj) {
    if (textObj is Map && textObj['runs'] is List) {
      final runs = textObj['runs'] as List;
      if (runs.isNotEmpty && runs.first is Map) {
        return (runs.first['text'] ?? '').toString();
      }
    }
    return '';
  }

  /// Returns plain (unsynced) lyrics for [videoId] from YouTube Music
  /// (source: Musixmatch), or '' if none. Two calls: `next` to find the song's
  /// Lyrics-tab browseId, then `browse` to fetch the text. Used as a fallback
  /// when lrclib has no (synced) lyrics — common for regional tracks.
  static Future<String> lyrics(String videoId) async {
    if (videoId.isEmpty) return '';
    try {
      // 1. Watch panel → locate the Lyrics tab's browseId.
      final nextRes = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/next'
                '?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'Origin': 'https://music.youtube.com',
              'User-Agent': _ua,
            },
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': _clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'videoId': videoId,
              'playlistId': 'RDAMVM$videoId',
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (nextRes.statusCode != 200) return '';

      final browseId = _lyricsBrowseId(jsonDecode(nextRes.body));
      if (browseId == null) return '';

      // 2. Browse the lyrics tab → extract the text.
      final brRes = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/browse'
                '?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'Origin': 'https://music.youtube.com',
              'User-Agent': _ua,
            },
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': _clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'browseId': browseId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (brRes.statusCode != 200) return '';

      return _lyricsText(jsonDecode(brRes.body));
    } catch (_) {
      return '';
    }
  }

  static String? _lyricsBrowseId(dynamic data) {
    final tabs = <dynamic>[];
    _collect(data, 'tabRenderer', tabs);
    for (final t in tabs) {
      if (t is! Map) continue;
      final bid = t['endpoint']?['browseEndpoint']?['browseId'];
      if (bid is String && bid.startsWith('MPLY')) return bid;
    }
    return null;
  }

  static String _lyricsText(dynamic data) {
    final shelves = <dynamic>[];
    _collect(data, 'musicDescriptionShelfRenderer', shelves);
    for (final s in shelves) {
      if (s is! Map) continue;
      final runs = s['description']?['runs'];
      if (runs is List && runs.isNotEmpty) {
        final text = runs
            .map((r) => r is Map ? (r['text'] ?? '').toString() : '')
            .join();
        if (text.trim().isNotEmpty) return text.trim();
      }
    }
    return '';
  }

  /// Scrapes the current WEB_REMIX client version from the music.youtube.com
  /// page config and caches it. Returns true if a *different* version was found
  /// (so the caller retries). Called only after a failed request — lets a
  /// rejected/stale client version self-heal without an app update. No API key
  /// is fetched or stored; requests are keyless.
  static Future<bool> _refreshConfig() async {
    try {
      final res = await http.get(
        Uri.parse('https://music.youtube.com/'),
        headers: const {'User-Agent': _ua, 'Cookie': 'CONSENT=YES+1'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;

      final ver = RegExp(r'"INNERTUBE_CLIENT_VERSION":\s*"([^"]+)"')
          .firstMatch(res.body)
          ?.group(1);
      if (ver != null && ver.isNotEmpty && ver != _clientVersion) {
        _dynamicClientVersion = ver;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Parsing ────────────────────────────────────────────────────────────────

  /// Recursively collects every value stored under [key] anywhere in the tree.
  /// Used instead of fixed paths so a structural shift in one branch doesn't
  /// break the whole parse.
  static void _collect(dynamic node, String key, List<dynamic> acc) {
    if (node is Map) {
      node.forEach((k, v) {
        if (k == key) acc.add(v);
        _collect(v, key, acc);
      });
    } else if (node is List) {
      for (final x in node) {
        _collect(x, key, acc);
      }
    }
  }

  static List<YtMusicSong> _parseSongs(dynamic data) {
    final items = <dynamic>[];
    _collect(data, 'musicResponsiveListItemRenderer', items);

    final songs = <YtMusicSong>[];
    final seen = <String>{};
    for (final it in items) {
      if (it is! Map) continue;
      final song = _parseItem(it);
      if (song != null && seen.add(song.videoId)) songs.add(song);
    }
    return songs;
  }

  static YtMusicSong? _parseItem(Map item) {
    // videoId — first watchEndpoint in the item that carries one.
    final watch = <dynamic>[];
    _collect(item, 'watchEndpoint', watch);
    String? videoId;
    for (final w in watch) {
      if (w is Map && w['videoId'] is String) {
        videoId = w['videoId'] as String;
        break;
      }
    }
    if (videoId == null || videoId.isEmpty) return null;

    final flex = item['flexColumns'];
    if (flex is! List || flex.isEmpty) return null;

    final title = _columnText(flex[0]);
    if (title.isEmpty) return null;

    // Subtitle row: artist(s) • album • duration, distinguished by pageType.
    final artists = <String>[];
    var album = '';
    var duration = '';
    if (flex.length > 1) {
      final runs = _columnRuns(flex[1]);
      for (final r in runs) {
        if (r is! Map) continue;
        final text = (r['text'] ?? '').toString();
        if (text.trim().isEmpty) continue;
        final pageType = _pageType(r);
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          artists.add(text);
        } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album = text;
        } else if (_durationRe.hasMatch(text.trim())) {
          duration = text.trim();
        }
      }
    }

    // Largest (last) thumbnail — square googleusercontent album art.
    final thumbLists = <dynamic>[];
    _collect(item['thumbnail'] ?? const {}, 'thumbnails', thumbLists);
    var thumbnail = '';
    for (final list in thumbLists) {
      if (list is List && list.isNotEmpty && list.last is Map) {
        thumbnail = (list.last['url'] ?? '').toString();
        if (thumbnail.isNotEmpty) break;
      }
    }

    return YtMusicSong(
      videoId: videoId,
      title: title,
      artists: artists,
      album: album,
      thumbnail: thumbnail,
      duration: duration,
    );
  }

  static List<dynamic> _columnRuns(dynamic column) {
    if (column is! Map) return const [];
    final runs = column['musicResponsiveListItemFlexColumnRenderer']?['text']
        ?['runs'];
    return runs is List ? runs : const [];
  }

  static String _columnText(dynamic column) {
    final runs = _columnRuns(column);
    if (runs.isNotEmpty && runs.first is Map) {
      return (runs.first['text'] ?? '').toString();
    }
    return '';
  }

  static String? _pageType(Map run) {
    final cfg = run['navigationEndpoint']?['browseEndpoint']
            ?['browseEndpointContextSupportedConfigs']
        ?['browseEndpointContextMusicConfig'];
    if (cfg is Map) return cfg['pageType'] as String?;
    return null;
  }
}
