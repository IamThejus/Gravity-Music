// services/download_service.dart
//
// Offline downloads: resolves a YouTube audio stream, saves the bytes to a
// permanent file in the app documents directory, and records metadata in the
// Hive box 'DownloadsBox'. Downloaded tracks play with NO network by being
// surfaced to the audio handler's checkNGetUrl() as a file:// URL.
//
// Mirrors LibraryService's static, Hive-backed style. Pure enough to test
// without booting the audio handler. Reactive UI state lives in
// DownloadController, not here.
//
// Schema (DownloadsBox):
//   'tracks' → List<Map>   each: {videoId,title,artist,thumbnail,duration,
//                                 path, loudnessDb}

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../models/hm_streaming_data.dart';
import 'app_paths.dart';
import 'background_task.dart';
import 'library_service.dart';

/// Thrown by [DownloadService.download] when the caller cancels a download in
/// flight (via the `isCancelled` callback). Lets callers distinguish a
/// user cancellation from a real failure.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();
}

class DownloadService {
  static Box get _box => Hive.box('DownloadsBox');

  // ── Metadata ───────────────────────────────────────────────────────────────

  static List<Map> _rawList() =>
      (_box.get('tracks', defaultValue: <Map>[]) as List).cast<Map>();

  static List<LibraryTrack> getDownloads() =>
      _rawList().map((m) => LibraryTrack.fromMap(Map.from(m))).toList();

  static bool isDownloaded(String videoId) =>
      _rawList().any((m) => m['videoId'] == videoId);

  static Map? _metaFor(String videoId) {
    for (final m in _rawList()) {
      if (m['videoId'] == videoId) return m;
    }
    return null;
  }

  /// file:// URL for offline playback, or null if not downloaded / file gone.
  /// The audio handler returns this from checkNGetUrl so playback never hits
  /// the network for a downloaded track.
  static String? playbackUrlFor(String videoId) {
    final m = _metaFor(videoId);
    final path = m?['path'] as String?;
    if (path == null || !File(path).existsSync()) return null;
    return 'file://$path';
  }

  /// Stored per-track loudness (for normalization parity with streaming).
  static double loudnessFor(String videoId) =>
      (_metaFor(videoId)?['loudnessDb'] as num?)?.toDouble() ?? 0.0;

  static void _saveMeta(LibraryTrack t, String path, double loudnessDb) {
    final list = _rawList().where((m) => m['videoId'] != t.videoId).toList();
    list.insert(0, {...t.toMap(), 'path': path, 'loudnessDb': loudnessDb});
    _box.put('tracks', list);
  }

  static Future<void> remove(String videoId) async {
    final m = _metaFor(videoId);
    final path = m?['path'] as String?;
    if (path != null) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    _box.put(
        'tracks', _rawList().where((x) => x['videoId'] != videoId).toList());
  }

  // ── Download ───────────────────────────────────────────────────────────────

  static Future<String> _downloadsDir() async {
    final base = await appDataDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// Resolve [track]'s audio stream (in an isolate, like normal playback),
  /// stream the bytes to disk reporting [onProgress] (0..1), then persist
  /// metadata. Writes to a .part file first and renames on success so a
  /// half-finished download is never treated as complete.
  static Future<void> download(
    LibraryTrack track, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final videoId = track.videoId;

    // Resolve a fresh stream URL off the UI thread.
    final token = RootIsolateToken.instance!;
    final json = await Isolate.run(() => getStreamInfo(videoId, token));
    final data = HMStreamingData.fromJson(json);
    if (!data.playable || data.audio == null) {
      throw Exception(
          data.statusMSG.isEmpty ? 'Stream unavailable' : data.statusMSG);
    }
    final audio = data.audio!;

    final dir = await _downloadsDir();
    final file = File('$dir/$videoId.m4a');
    final part = File('$dir/$videoId.m4a.part');

    final client = http.Client();
    IOSink? sink;
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(audio.url)));
      final total = resp.contentLength ?? audio.size;
      sink = part.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        // Abort mid-stream if the user cancelled. The catch below deletes the
        // partial file and the exception propagates as a cancellation.
        if (isCancelled?.call() ?? false) {
          throw const DownloadCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close();
    }

    _saveMeta(track, file.path, audio.loudnessDb);
    onProgress?.call(1.0);
  }
}
