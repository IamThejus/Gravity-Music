// background_task.dart
// Mirrors HarmonyMusic's background_task.dart.
// This function is called via Isolate.run() so the main UI thread is never blocked.

import 'package:flutter/services.dart';
import 'stream_service.dart';

/// Called from an isolate. Returns a serialisable Map so it can cross isolate
/// boundaries — same pattern as HarmonyMusic.
///
/// [visitorData] is the anonymous youtubei session id from a previous fetch.
/// Each Isolate.run() spawns a fresh isolate, so nothing can be cached in
/// memory here; the caller holds it in AppPrefs and passes it back in, which
/// saves a sw.js_data round-trip per track.
Future<Map<String, dynamic>> getStreamInfo(
    String videoId, RootIsolateToken token,
    [String? visitorData]) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final provider =
      await StreamProvider.fetch(videoId, visitorData: visitorData);
  return provider.hmStreamingData;
}
