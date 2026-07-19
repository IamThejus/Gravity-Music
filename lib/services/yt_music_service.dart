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

/// A YouTube Music album search hit — the *header* only (no track list yet).
/// The track list is fetched lazily via [YtMusicService.albumDetail] using
/// [browseId] (an `MPREb_…` id), mirroring how YT Music opens an album page.
class YtMusicAlbum {
  final String browseId; // MPREb_… — browse this to get the tracks
  final String title;
  final String artist;
  final String year;
  final String thumbnail; // square album cover (ThumbUtil-resizable)

  const YtMusicAlbum({
    required this.browseId,
    required this.title,
    required this.artist,
    required this.year,
    required this.thumbnail,
  });
}

/// A YouTube / YouTube Music playlist with its ordered track list.
///
/// Unlike the Spotify / Apple importers — which scrape (title, artist) strings
/// and must then *guess* the matching YouTube song — this carries real
/// `videoId`s, so importing a YT playlist is exact rather than fuzzy.
class YtMusicPlaylist {
  final String playlistId;
  final String title;
  final String thumbnail;
  final List<YtMusicSong> tracks;

  /// True when paging stopped at [YtMusicService._maxPlaylistPages] before the
  /// playlist ended, so [tracks] is a prefix of the real list.
  final bool truncated;

  const YtMusicPlaylist({
    required this.playlistId,
    required this.title,
    required this.thumbnail,
    required this.tracks,
    this.truncated = false,
  });
}

/// A fully-resolved album: the header metadata plus its ordered track list.
/// Returned by [YtMusicService.albumDetail].
class YtMusicAlbumDetail {
  final String browseId;
  final String title;
  final String artist;
  final String year;
  final String thumbnail;
  final List<YtMusicSong> tracks;

  const YtMusicAlbumDetail({
    required this.browseId,
    required this.title,
    required this.artist,
    required this.year,
    required this.thumbnail,
    required this.tracks,
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

  // "Albums" filter param → returns album cards (browseId-addressable pages)
  // instead of songs. Same shape as the songs param with the type byte flipped
  // (II→IY), matching YT Music's own search-chip request.
  static const _albumsParams = 'EgWKAQIYAWoMEA4QChADEAQQCRAF';

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
  static final RegExp _yearRe = RegExp(r'^\d{4}$');

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

  /// One song-search attempt. Returns the parsed list on a 200 response (an
  /// empty list is a legitimate "no results"), or `null` on any failure
  /// (non-200 / exception) so the caller can refresh the key and retry.
  static Future<List<YtMusicSong>?> _search(String query) async {
    final data = await _postSearch(query, _songsParams);
    if (data == null) return null;
    try {
      return _parseSongs(data);
    } catch (_) {
      return null;
    }
  }

  /// POSTs one youtubei search request with the given filter [params] and
  /// returns the decoded JSON body, or `null` on any failure (non-200 /
  /// exception). Shared by the song and album search paths — they differ only
  /// in the filter param and how the response is parsed.
  static Future<dynamic> _postSearch(String query, String params) async {
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
              'params': params,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;
      return jsonDecode(res.body);
    } catch (_) {
      return null;
    }
  }

  /// Searches the YouTube Music catalog for albums. Returns album *headers*
  /// (browse them via [albumDetail] to get tracks), or an empty list on any
  /// error. Uses the same lazy key-refresh-on-failure path as [searchSongs].
  static Future<List<YtMusicAlbum>> searchAlbums(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final first = await _searchAlbums(q);
    if (first != null) return first;

    if (await _refreshConfig()) {
      final second = await _searchAlbums(q);
      if (second != null) return second;
    }
    return [];
  }

  /// One album-search attempt. `null` on failure so the caller can refresh the
  /// client version and retry.
  static Future<List<YtMusicAlbum>?> _searchAlbums(String query) async {
    final data = await _postSearch(query, _albumsParams);
    if (data == null) return null;
    try {
      return _parseAlbums(data);
    } catch (_) {
      return null;
    }
  }

  /// Fetches a single album's full track list + header metadata by browsing its
  /// [browseId] (an `MPREb_…` id from [searchAlbums]). Returns `null` on any
  /// error. Same lazy key-refresh-on-failure path as the other endpoints.
  static Future<YtMusicAlbumDetail?> albumDetail(String browseId) async {
    if (browseId.isEmpty) return null;

    final first = await _browseAlbum(browseId);
    if (first != null) return first;

    if (await _refreshConfig()) {
      final second = await _browseAlbum(browseId);
      if (second != null) return second;
    }
    return null;
  }

  /// One album-browse attempt. Returns the parsed album on a 200, or `null` on
  /// any failure so the caller can refresh the key and retry.
  static Future<YtMusicAlbumDetail?> _browseAlbum(String browseId) async {
    try {
      final res = await http
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

      if (res.statusCode != 200) return null;
      return _parseAlbumDetail(jsonDecode(res.body), browseId);
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

  // ── Playlists ──────────────────────────────────────────────────────────────

  /// Safety cap on continuation pages (~100 tracks each) so a pathological
  /// playlist can't page forever.
  static const _maxPlaylistPages = 20;

  /// Fetches a YouTube / YouTube Music playlist by its `list=` id, following
  /// continuations until the playlist ends or [_maxPlaylistPages] is hit.
  /// Returns null on any failure.
  static Future<YtMusicPlaylist?> playlist(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) return null;

    final first = await _browsePlaylist(id);
    if (first != null) return first;

    if (await _refreshConfig()) {
      final second = await _browsePlaylist(id);
      if (second != null) return second;
    }
    return null;
  }

  static Future<YtMusicPlaylist?> _browsePlaylist(String playlistId) async {
    try {
      // YT Music addresses a playlist page as browseId "VL" + playlistId.
      final browseId =
          playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';

      final firstBody = await _postBrowse({'browseId': browseId});
      if (firstBody == null) return null;

      var title = '';
      var cover = '';
      final headers = <dynamic>[];
      _collect(firstBody, 'musicResponsiveHeaderRenderer', headers);
      if (headers.isEmpty) {
        _collect(firstBody, 'musicDetailHeaderRenderer', headers);
      }
      if (headers.isNotEmpty && headers.first is Map) {
        final h = headers.first as Map;
        title = _runsText(h['title']);
        cover = _largestThumb(h['thumbnail']);
      }

      final tracks = <YtMusicSong>[];
      final seen = <String>{};
      var token = _collectTracks(firstBody, tracks, seen);

      // Follow continuations for playlists longer than the first page.
      var pages = 1;
      while (token != null && pages < _maxPlaylistPages) {
        final next = await _postBrowse({'continuation': token});
        if (next == null) break;
        final before = tracks.length;
        token = _collectTracks(next, tracks, seen);
        pages++;
        if (tracks.length == before) break; // no progress — stop
      }

      if (title.isEmpty && tracks.isEmpty) return null;

      return YtMusicPlaylist(
        playlistId: playlistId,
        title: title.isEmpty ? 'Imported Playlist' : title,
        thumbnail: cover,
        tracks: tracks,
        truncated: token != null && pages >= _maxPlaylistPages,
      );
    } catch (_) {
      return null;
    }
  }

  /// Appends every track row found in [data] to [tracks] (deduped by [seen]) and
  /// returns the next continuation token, or null when there isn't one.
  static String? _collectTracks(
      dynamic data, List<YtMusicSong> tracks, Set<String> seen) {
    final items = <dynamic>[];
    _collect(data, 'musicResponsiveListItemRenderer', items);
    for (final it in items) {
      if (it is! Map) continue;
      final t = _parseTrackRow(it, '', '');
      if (t != null && seen.add(t.videoId)) tracks.add(t);
    }
    return _continuationToken(data);
  }

  /// Current shape nests the token under continuationItemRenderer; the legacy
  /// shape used nextContinuationData. Both are checked.
  static String? _continuationToken(dynamic data) {
    final cont = <dynamic>[];
    _collect(data, 'continuationItemRenderer', cont);
    for (final c in cont) {
      if (c is! Map) continue;
      final tok = c['continuationEndpoint']?['continuationCommand']?['token'];
      if (tok is String && tok.isNotEmpty) return tok;
    }
    final legacy = <dynamic>[];
    _collect(data, 'nextContinuationData', legacy);
    for (final c in legacy) {
      if (c is! Map) continue;
      final tok = c['continuation'];
      if (tok is String && tok.isNotEmpty) return tok;
    }
    return null;
  }

  /// POSTs one youtubei `browse` request with [extra] merged into the body.
  /// Returns the decoded JSON, or null on any failure.
  static Future<dynamic> _postBrowse(Map<String, dynamic> extra) async {
    try {
      final res = await http
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
              ...extra,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) return null;
      return jsonDecode(res.body);
    } catch (_) {
      return null;
    }
  }

  // ── Album parsing ──────────────────────────────────────────────────────────

  static List<YtMusicAlbum> _parseAlbums(dynamic data) {
    final items = <dynamic>[];
    _collect(data, 'musicResponsiveListItemRenderer', items);

    final albums = <YtMusicAlbum>[];
    final seen = <String>{};
    for (final it in items) {
      if (it is! Map) continue;
      final album = _parseAlbumItem(it);
      if (album != null && seen.add(album.browseId)) albums.add(album);
    }
    return albums;
  }

  static YtMusicAlbum? _parseAlbumItem(Map item) {
    // browseId — the album's own browse endpoint (MPREb_… / pageType ALBUM).
    final navs = <dynamic>[];
    _collect(item, 'browseEndpoint', navs);
    String? browseId;
    for (final n in navs) {
      if (n is! Map) continue;
      final bid = n['browseId'];
      if (bid is! String || bid.isEmpty) continue;
      final pageType = n['browseEndpointContextSupportedConfigs']
              ?['browseEndpointContextMusicConfig']?['pageType'];
      if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' || bid.startsWith('MPREb')) {
        browseId = bid;
        break;
      }
    }
    if (browseId == null) return null;

    final flex = item['flexColumns'];
    if (flex is! List || flex.isEmpty) return null;

    final title = _columnText(flex[0]);
    if (title.isEmpty) return null;

    // Subtitle row: "Album • Artist • Year" (or "Single • Artist • Year").
    var artist = '';
    var year = '';
    if (flex.length > 1) {
      final runs = _columnRuns(flex[1]);
      for (final r in runs) {
        if (r is! Map) continue;
        final text = (r['text'] ?? '').toString().trim();
        if (text.isEmpty || text == '•') continue;
        if (_pageType(r) == 'MUSIC_PAGE_TYPE_ARTIST') {
          if (artist.isEmpty) artist = text;
        } else if (_yearRe.hasMatch(text)) {
          year = text;
        }
      }
      // Fallback when the artist run carries no pageType: take the first run
      // that isn't the type label ("Album"/"Single"/"EP") or the year.
      if (artist.isEmpty) {
        for (final r in runs) {
          if (r is! Map) continue;
          final text = (r['text'] ?? '').toString().trim();
          if (text.isEmpty || text == '•' || _yearRe.hasMatch(text)) continue;
          final low = text.toLowerCase();
          if (low == 'album' || low == 'single' || low == 'ep') continue;
          artist = text;
          break;
        }
      }
    }

    return YtMusicAlbum(
      browseId: browseId,
      title: title,
      artist: artist,
      year: year,
      thumbnail: _largestThumb(item['thumbnail']),
    );
  }

  static YtMusicAlbumDetail? _parseAlbumDetail(dynamic data, String browseId) {
    // ── Header: title / artist / year / cover ──
    final headers = <dynamic>[];
    _collect(data, 'musicResponsiveHeaderRenderer', headers); // current shape
    if (headers.isEmpty) {
      _collect(data, 'musicDetailHeaderRenderer', headers); // legacy shape
    }

    var title = '';
    var artist = '';
    var year = '';
    var cover = '';
    if (headers.isNotEmpty && headers.first is Map) {
      final h = headers.first as Map;
      title = _runsText(h['title']);
      // Newer header exposes the artist as `straplineTextOne`.
      artist = _runsText(h['straplineTextOne']);
      final subRuns = h['subtitle']?['runs'];
      if (subRuns is List) {
        for (final r in subRuns) {
          if (r is! Map) continue;
          final text = (r['text'] ?? '').toString().trim();
          if (_yearRe.hasMatch(text)) year = text;
          if (artist.isEmpty && _pageType(r) == 'MUSIC_PAGE_TYPE_ARTIST') {
            artist = text;
          }
        }
      }
      cover = _largestThumb(h['thumbnail']);
    }

    // ── Tracks ── (album rows are musicResponsiveListItemRenderer inside the
    // track shelf; related-album carousels use musicTwoRowItemRenderer, so they
    // aren't picked up here).
    final items = <dynamic>[];
    _collect(data, 'musicResponsiveListItemRenderer', items);
    final tracks = <YtMusicSong>[];
    final seen = <String>{};
    for (final it in items) {
      if (it is! Map) continue;
      final t = _parseTrackRow(it, cover, artist);
      if (t != null && seen.add(t.videoId)) tracks.add(t);
    }

    if (title.isEmpty && tracks.isEmpty) return null;

    return YtMusicAlbumDetail(
      browseId: browseId,
      title: title,
      artist: artist,
      year: year,
      thumbnail: cover,
      tracks: tracks,
    );
  }

  /// Parses one track row from an album or playlist page (both use
  /// `musicResponsiveListItemRenderer`). Album rows frequently omit their own
  /// thumbnail (they share the album cover) and list the artist as plain text,
  /// so both fall back to [cover] / [albumArtist]; playlist rows normally carry
  /// their own and simply ignore the fallbacks.
  static YtMusicSong? _parseTrackRow(
      Map item, String cover, String albumArtist) {
    // videoId — first watchEndpoint, else the row's playlistItemData.
    final watch = <dynamic>[];
    _collect(item, 'watchEndpoint', watch);
    String? videoId;
    for (final w in watch) {
      if (w is Map && w['videoId'] is String) {
        videoId = w['videoId'] as String;
        break;
      }
    }
    if (videoId == null || videoId.isEmpty) {
      final pid = item['playlistItemData']?['videoId'];
      if (pid is String && pid.isNotEmpty) videoId = pid;
    }
    if (videoId == null || videoId.isEmpty) return null;

    final flex = item['flexColumns'];
    if (flex is! List || flex.isEmpty) return null;

    final title = _columnText(flex[0]);
    if (title.isEmpty) return null;

    // Artists — prefer ARTIST-typed runs; else the first non-duration run.
    final artists = <String>[];
    if (flex.length > 1) {
      final runs = _columnRuns(flex[1]);
      for (final r in runs) {
        if (r is! Map) continue;
        final text = (r['text'] ?? '').toString().trim();
        if (text.isEmpty || text == '•') continue;
        if (_pageType(r) == 'MUSIC_PAGE_TYPE_ARTIST') artists.add(text);
      }
      if (artists.isEmpty) {
        for (final r in runs) {
          if (r is! Map) continue;
          final text = (r['text'] ?? '').toString().trim();
          if (text.isEmpty || text == '•' || _durationRe.hasMatch(text)) {
            continue;
          }
          artists.add(text);
          break;
        }
      }
    }
    if (artists.isEmpty && albumArtist.isNotEmpty) artists.add(albumArtist);

    // Duration — album rows carry it in fixedColumns; fall back to any flex run.
    var duration = '';
    final fixed = item['fixedColumns'];
    if (fixed is List) {
      for (final c in fixed) {
        final t = _fixedColumnText(c).trim();
        if (_durationRe.hasMatch(t)) {
          duration = t;
          break;
        }
      }
    }
    if (duration.isEmpty) {
      for (final c in flex) {
        for (final r in _columnRuns(c)) {
          if (r is! Map) continue;
          final t = (r['text'] ?? '').toString().trim();
          if (_durationRe.hasMatch(t)) {
            duration = t;
            break;
          }
        }
        if (duration.isNotEmpty) break;
      }
    }

    var thumbnail = _largestThumb(item['thumbnail']);
    if (thumbnail.isEmpty) thumbnail = cover;

    return YtMusicSong(
      videoId: videoId,
      title: title,
      artists: artists,
      album: '',
      thumbnail: thumbnail,
      duration: duration,
    );
  }

  /// Largest (last) thumbnail URL anywhere under [node], or '' if none.
  static String _largestThumb(dynamic node) {
    final lists = <dynamic>[];
    _collect(node ?? const {}, 'thumbnails', lists);
    for (final list in lists) {
      if (list is List && list.isNotEmpty && list.last is Map) {
        final url = (list.last['url'] ?? '').toString();
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }

  static String _fixedColumnText(dynamic column) {
    if (column is! Map) return '';
    final runs = column['musicResponsiveListItemFixedColumnRenderer']?['text']
        ?['runs'];
    if (runs is List && runs.isNotEmpty && runs.first is Map) {
      return (runs.first['text'] ?? '').toString();
    }
    return '';
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
