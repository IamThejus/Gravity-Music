// services/playlist_importer.dart
//
// On-device playlist scrapers for Spotify and Apple Music — no Saragama API,
// no server, no Playwright (which can't run in a Flutter app). Everything is
// plain HTTP against the platforms' own public pages:
//
//   • Spotify — the open.spotify.com/embed/playlist/<id> page embeds a
//     `__NEXT_DATA__` JSON blob containing the playlist name, the first ~100
//     tracks (title + artist), AND an anonymous access token. If the embed hits
//     its 100-track cap, we use that token to page the rest from the Web API
//     (best-effort: if it rate-limits / the token is rejected, we keep the
//     first 100 and flag the result truncated).
//
//   • Apple Music — the playlist page embeds a `serialized-server-data` JSON
//     blob with the server-rendered track rows (title + artistName). Large
//     playlists are windowed by Apple; we take what's rendered and flag
//     truncation.
//
// Both return a [ScrapedPlaylist] of [ImportedTrack]s (title + artist). YouTube
// Music matching happens later, in ImportService.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'import_service.dart' show ImportException;
import 'yt_music_service.dart';

/// A single track extracted from an external playlist (pre-match).
class ImportedTrack {
  final String title;
  final String artist;

  /// Exact YouTube videoId, set only when the SOURCE is YouTube itself. When
  /// present, ImportService skips the fuzzy search-match step entirely — a YT
  /// playlist import is exact, where Spotify/Apple imports are best guesses.
  final String? videoId;
  final String thumbnail;
  final String duration;

  const ImportedTrack(
    this.title,
    this.artist, {
    this.videoId,
    this.thumbnail = '',
    this.duration = '',
  });

  /// True when this track already knows its YouTube id (no matching needed).
  bool get isResolved => videoId != null && videoId!.isNotEmpty;

  /// Query used to match this track on YouTube Music.
  String get query => artist.isEmpty ? title : '$title $artist';
}

/// Result of scraping an external playlist.
class ScrapedPlaylist {
  final String name;
  final List<ImportedTrack> tracks;

  /// True when the source had more tracks than we could extract on-device
  /// (e.g. a huge playlist whose tail needed an API call that rate-limited).
  final bool truncated;

  const ScrapedPlaylist({
    required this.name,
    required this.tracks,
    this.truncated = false,
  });
}

class PlaylistImporter {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // Short-lived cache so the preview (fetchDetails) and the background import
  // (importPlaylist) don't scrape the same URL twice.
  static final Map<String, ({ScrapedPlaylist playlist, DateTime ts})> _cache =
      {};
  static const _cacheTtl = Duration(minutes: 10);

  /// Routes a URL to the right scraper. Throws [ImportException] on bad URLs
  /// or unreachable pages.
  static Future<ScrapedPlaylist> fetch(String url) async {
    final cached = _cache[url];
    if (cached != null &&
        DateTime.now().difference(cached.ts) < _cacheTtl) {
      return cached.playlist;
    }

    final ScrapedPlaylist result;
    if (url.contains('spotify.com')) {
      result = await _spotify(url);
    } else if (url.contains('music.apple.com')) {
      result = await _apple(url);
    } else if (url.contains('youtube.com') || url.contains('youtu.be')) {
      // Covers music.youtube.com too (it contains "youtube.com").
      result = await _youtube(url);
    } else {
      throw const ImportException(
          'Only Spotify, Apple Music and YouTube playlist links are supported.');
    }

    if (result.tracks.isEmpty) {
      throw const ImportException(
          'No songs could be read from this playlist. It may be private.');
    }
    _cache[url] = (playlist: result, ts: DateTime.now());
    return result;
  }

  // ── Spotify ────────────────────────────────────────────────────────────────

  static final RegExp _spotifyId = RegExp(r'playlist[/:]([A-Za-z0-9]+)');

  static Future<ScrapedPlaylist> _spotify(String url) async {
    final id = _spotifyId.firstMatch(url)?.group(1);
    if (id == null) {
      throw const ImportException(
          'That doesn’t look like a valid Spotify playlist link.');
    }

    final res = await http.get(
      Uri.parse('https://open.spotify.com/embed/playlist/$id'),
      headers: const {'User-Agent': _ua},
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw const ImportException(
          'Couldn’t open this Spotify playlist. It may be private or removed.');
    }

    final data = _jsonInScript(res.body, 'id="__NEXT_DATA__"');
    if (data == null) {
      throw const ImportException('Couldn’t read this Spotify playlist.');
    }

    final name = _firstString(data, 'name') ?? 'Imported Playlist';
    final list = _firstList(data, 'trackList') ?? const [];
    final tracks = <ImportedTrack>[];
    for (final t in list) {
      if (t is! Map) continue;
      final title = (t['title'] ?? '').toString().trim();
      final artist = (t['subtitle'] ?? '').toString().trim();
      if (title.isNotEmpty) tracks.add(ImportedTrack(title, artist));
    }

    // Embed caps at 100. If we hit it, the playlist is likely larger — pull the
    // full, authoritative list from the Web API using the embedded token.
    var truncated = false;
    if (tracks.length >= 100) {
      final token = _firstString(data, 'accessToken');
      final full = token == null ? null : await _spotifyApiTracks(id, token);
      if (full != null && full.length >= tracks.length) {
        tracks
          ..clear()
          ..addAll(full);
      } else {
        truncated = true; // token rejected / rate-limited — keep the first 100
      }
    }

    return ScrapedPlaylist(name: name, tracks: tracks, truncated: truncated);
  }

  /// Pages the full track list from Spotify's Web API. Returns null on the
  /// first failure (e.g. 429 / expired token) so the caller falls back to the
  /// embed window. Gentle pacing to avoid tripping the rate limiter.
  static Future<List<ImportedTrack>?> _spotifyApiTracks(
      String id, String token) async {
    final out = <ImportedTrack>[];
    var offset = 0;
    const limit = 100;
    while (true) {
      final uri = Uri.parse('https://api.spotify.com/v1/playlists/$id/tracks')
          .replace(queryParameters: {
        'offset': '$offset',
        'limit': '$limit',
        'fields': 'total,items(track(name,artists(name)))',
      });
      final res = await http.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'User-Agent': _ua,
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null; // bail → caller keeps embed window

      final body = json.decode(res.body) as Map<String, dynamic>;
      final items = (body['items'] as List?) ?? const [];
      if (items.isEmpty) break;
      for (final it in items) {
        if (it is! Map) continue;
        final track = it['track'];
        if (track is! Map) continue;
        final title = (track['name'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final artists = (track['artists'] as List?)
                ?.map((a) => a is Map ? (a['name'] ?? '').toString() : '')
                .where((s) => s.isNotEmpty)
                .join(', ') ??
            '';
        out.add(ImportedTrack(title, artists));
      }
      offset += items.length;
      final total = body['total'] as int?;
      if (items.length < limit || (total != null && offset >= total)) break;
      await Future.delayed(const Duration(milliseconds: 120));
    }
    return out;
  }

  // ── YouTube / YouTube Music ──────────────────────────────────────────────
  //
  // No HTML scraping here: the app already speaks youtubei, so a YT playlist is
  // fetched through YtMusicService and arrives with real videoIds. That makes
  // this the only EXACT importer — Spotify/Apple tracks still have to be
  // guessed at by search, and a wrong guess is invisible to the user.

  static Future<ScrapedPlaylist> _youtube(String url) async {
    final id = _youtubeListId(url);
    if (id == null) {
      throw const ImportException(
          'That YouTube link doesn’t contain a playlist. Copy a link with a '
          '“list=” in it (Share → Copy link from a playlist).');
    }

    final pl = await YtMusicService.playlist(id);
    if (pl == null) {
      throw const ImportException(
          'Couldn’t open this YouTube playlist. It may be private or removed.');
    }

    final tracks = pl.tracks
        .map((t) => ImportedTrack(
              t.title,
              t.artists.join(', '),
              videoId: t.videoId,
              thumbnail: t.thumbnail,
              duration: t.duration,
            ))
        .toList();

    return ScrapedPlaylist(
      name: pl.title,
      tracks: tracks,
      truncated: pl.truncated,
    );
  }

  /// Pulls the `list=` id out of any YouTube/YT-Music playlist URL form.
  static String? _youtubeListId(String url) {
    final fromQuery = Uri.tryParse(url)?.queryParameters['list'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    // Fallback for unencoded / nonstandard links the Uri parser trips on.
    final m = RegExp(r'[?&]list=([A-Za-z0-9_-]+)').firstMatch(url);
    final id = m?.group(1);
    return (id == null || id.isEmpty) ? null : id;
  }

  // ── Apple Music ──────────────────────────────────────────────────────────

  static Future<ScrapedPlaylist> _apple(String url) async {
    final res = await http.get(
      Uri.parse(url),
      headers: const {'User-Agent': _ua},
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw const ImportException(
          'Couldn’t open this Apple Music playlist. It may be private or removed.');
    }

    final data = _jsonInScript(res.body, 'id="serialized-server-data"');
    if (data == null) {
      throw const ImportException('Couldn’t read this Apple Music playlist.');
    }

    // Track rows are the dicts carrying BOTH a title and an artistName plus a
    // play action (distinguishes songs from headers / related shelves).
    final tracks = <ImportedTrack>[];
    _appleWalk(data, tracks);

    final name = _metaContent(res.body, 'og:title') ?? 'Imported Playlist';
    final trackCount = _firstInt(data, 'trackCount');
    final truncated = trackCount != null && trackCount > tracks.length;

    return ScrapedPlaylist(name: name, tracks: tracks, truncated: truncated);
  }

  static void _appleWalk(dynamic node, List<ImportedTrack> out) {
    if (node is Map) {
      final hasTitle = node['title'] is String;
      final hasArtist = node['artistName'] is String;
      final isRow = node.containsKey('playAction') ||
          node.containsKey('trackNumber');
      if (hasTitle && hasArtist && isRow) {
        final title = (node['title'] as String).trim();
        final artist = (node['artistName'] as String).trim();
        if (title.isNotEmpty) out.add(ImportedTrack(title, artist));
      }
      for (final v in node.values) {
        _appleWalk(v, out);
      }
    } else if (node is List) {
      for (final x in node) {
        _appleWalk(x, out);
      }
    }
  }

  // ── Shared parsing helpers ─────────────────────────────────────────────────

  /// Extracts and decodes the JSON inside `<script ...marker...>JSON</script>`.
  static dynamic _jsonInScript(String html, String marker) {
    final start = html.indexOf(marker);
    if (start == -1) return null;
    final open = html.indexOf('>', start);
    final close = html.indexOf('</script>', open);
    if (open == -1 || close == -1) return null;
    try {
      return json.decode(html.substring(open + 1, close));
    } catch (_) {
      return null;
    }
  }

  /// Reads `<meta property="X" content="Y">` (used for the Apple playlist name).
  static String? _metaContent(String html, String property) {
    final re = RegExp(
        '<meta[^>]*property="$property"[^>]*content="([^"]*)"',
        caseSensitive: false);
    final m = re.firstMatch(html);
    final v = m?.group(1)?.trim();
    return (v == null || v.isEmpty) ? null : _unescapeHtml(v);
  }

  static String _unescapeHtml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// First value stored under [key] anywhere in the tree (depth-first).
  static String? _firstString(dynamic node, String key) {
    final acc = <dynamic>[];
    _collect(node, key, acc, stopAtFirst: true);
    final v = acc.isEmpty ? null : acc.first;
    return v is String && v.isNotEmpty ? v : null;
  }

  static int? _firstInt(dynamic node, String key) {
    final acc = <dynamic>[];
    _collect(node, key, acc, stopAtFirst: true);
    final v = acc.isEmpty ? null : acc.first;
    return v is int ? v : null;
  }

  static List? _firstList(dynamic node, String key) {
    final acc = <dynamic>[];
    _collect(node, key, acc, stopAtFirst: true);
    final v = acc.isEmpty ? null : acc.first;
    return v is List ? v : null;
  }

  static void _collect(dynamic node, String key, List<dynamic> acc,
      {bool stopAtFirst = false}) {
    if (acc.isNotEmpty && stopAtFirst) return;
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key) {
          acc.add(entry.value);
          if (stopAtFirst) return;
        }
        _collect(entry.value, key, acc, stopAtFirst: stopAtFirst);
        if (acc.isNotEmpty && stopAtFirst) return;
      }
    } else if (node is List) {
      for (final x in node) {
        _collect(x, key, acc, stopAtFirst: stopAtFirst);
        if (acc.isNotEmpty && stopAtFirst) return;
      }
    }
  }
}
