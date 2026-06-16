// services/playlist_download_service.dart
//
// Offline PLAYLIST downloads — distinct from the per-track Downloads tab.
// Songs downloaded as part of a playlist are saved to a separate directory
// ('playlist_downloads/') and recorded in their own Hive keys, so they:
//   • play offline (surfaced to checkNGetUrl as a file:// URL), but
//   • do NOT appear in the Downloads tab (which reads DownloadsBox 'tracks').
//
// A song already present as an individual download (DownloadService) is reused
// as-is and never downloaded twice — see [isResolvable].
//
// Schema (DownloadsBox):
//   'pdtracks'    → Map<videoId, {path, loudnessDb}>   flat file index
//   'pdplaylists' → Map<playlistId, {name, videoIds:[...]}>  download intent
//
// All file/Hive work is static & synchronous-ish here; reactive UI state lives
// in PlaylistDownloadController.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../models/hm_streaming_data.dart';
import 'app_paths.dart';
import 'background_task.dart';
import 'download_service.dart';
import 'library_service.dart';

class PlaylistDownloadService {
  static Box get _box => Hive.box('DownloadsBox');

  // ── Registries ─────────────────────────────────────────────────────────────

  static Map _tracks() => Map.of(_box.get('pdtracks', defaultValue: {}) as Map);
  static Map _playlists() =>
      Map.of(_box.get('pdplaylists', defaultValue: {}) as Map);

  static void _putTracks(Map m) => _box.put('pdtracks', m);
  static void _putPlaylists(Map m) => _box.put('pdplaylists', m);

  // ── Offline playback lookup (consulted by checkNGetUrl) ──────────────────────

  /// file:// URL for a playlist-downloaded track, or null if not present.
  static String? playbackUrlFor(String videoId) {
    final m = _tracks()[videoId] as Map?;
    final path = m?['path'] as String?;
    if (path == null || !File(path).existsSync()) return null;
    return 'file://$path';
  }

  static double loudnessFor(String videoId) =>
      ((_tracks()[videoId] as Map?)?['loudnessDb'] as num?)?.toDouble() ?? 0.0;

  /// True if this track can already play offline — either via a playlist
  /// download or an individual (Downloads tab) download.
  static bool isResolvable(String videoId) {
    final m = _tracks()[videoId] as Map?;
    final path = m?['path'] as String?;
    if (path != null && File(path).existsSync()) return true;
    return DownloadService.playbackUrlFor(videoId) != null;
  }

  // ── Playlist registry / status ───────────────────────────────────────────────

  static void registerPlaylist(String id, String name, List<String> videoIds) {
    final pls = _playlists();
    pls[id] = {'name': name, 'videoIds': videoIds};
    _putPlaylists(pls);
  }

  static bool isRegistered(String id) => _playlists().containsKey(id);

  static List<String> registeredIds() =>
      _playlists().keys.map((e) => e.toString()).toList();

  static List<String> _videoIds(String id) =>
      ((_playlists()[id] as Map?)?['videoIds'] as List?)
          ?.map((e) => e.toString())
          .toList() ??
      const [];

  /// How many of a registered playlist's tracks are available offline.
  static int downloadedCount(String id) {
    var c = 0;
    for (final v in _videoIds(id)) {
      if (isResolvable(v)) c++;
    }
    return c;
  }

  static int trackTotal(String id) => _videoIds(id).length;

  /// Fully downloaded = every member track resolves offline.
  static bool isFullyDownloaded(String id) {
    final ids = _videoIds(id);
    if (ids.isEmpty) return false;
    return ids.every(isResolvable);
  }

  // ── Download a single track into the playlist store ──────────────────────────

  static Future<String> _dir() async {
    final base = await appDataDirectory();
    final dir = Directory('${base.path}/playlist_downloads');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// Resolve [track]'s audio stream (in an isolate) and stream the bytes to a
  /// file in the playlist-downloads dir, then record it in 'pdtracks'. Skips
  /// the network entirely if the track is already resolvable. Writes to a
  /// .part file and renames on success so a half-finished file is never used.
  static Future<void> downloadTrack(LibraryTrack track) async {
    final videoId = track.videoId;
    if (isResolvable(videoId)) return;

    final token = RootIsolateToken.instance!;
    final json = await Isolate.run(() => getStreamInfo(videoId, token));
    final data = HMStreamingData.fromJson(json);
    if (!data.playable || data.audio == null) {
      throw Exception(
          data.statusMSG.isEmpty ? 'Stream unavailable' : data.statusMSG);
    }
    final audio = data.audio!;

    final dir = await _dir();
    final file = File('$dir/$videoId.m4a');
    final part = File('$dir/$videoId.m4a.part');

    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(audio.url)));
      final sink = part.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (e) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close();
    }

    final tracks = _tracks();
    tracks[videoId] = {'path': file.path, 'loudnessDb': audio.loudnessDb};
    _putTracks(tracks);
  }

  // ── Remove a playlist's offline copy ─────────────────────────────────────────

  /// Delete a playlist's downloaded files + registry entry. A track file is
  /// only deleted if no OTHER registered playlist still references it (cheap
  /// ref-count); individual Downloads-tab files are never touched.
  static Future<void> removePlaylist(String id) async {
    final ids = _videoIds(id);
    final pls = _playlists()..remove(id);
    _putPlaylists(pls);

    // Which video IDs are still referenced by some other registered playlist?
    final stillReferenced = <String>{};
    for (final other in pls.values) {
      final vids = (other as Map)['videoIds'] as List? ?? const [];
      stillReferenced.addAll(vids.map((e) => e.toString()));
    }

    final tracks = _tracks();
    for (final v in ids) {
      if (stillReferenced.contains(v)) continue;
      final m = tracks[v] as Map?;
      final path = m?['path'] as String?;
      if (path != null) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
      tracks.remove(v);
    }
    _putTracks(tracks);
  }
}
