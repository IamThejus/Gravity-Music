// services/apk_download_service.dart
//
// Streams the update APK to a temp file with progress + cancellation, mirroring
// DownloadService's proven pattern: write to a `.part` file, rename on success,
// and always clean up a partial file on cancel/failure. Lives under the app
// cache dir (`updates/`) — which the FileProvider (res/xml/file_paths.xml)
// exposes so the package installer can read it.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart' show UpdateException;

/// Thrown when the caller cancels the download mid-stream (via `isCancelled`).
class ApkDownloadCancelled implements Exception {
  const ApkDownloadCancelled();
}

class ApkDownloadService {
  /// Download [url] to `<cache>/updates/[fileName]`, reporting [onProgress]
  /// (0..1). Returns the finished file path. Throws [ApkDownloadCancelled] on
  /// cancel or [UpdateException]/IO error on failure — the partial `.part`
  /// file is deleted in every non-success path.
  static Future<String> download(
    String url, {
    required String fileName,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/$fileName');
    final part = File('${dir.path}/$fileName.part');

    final client = http.Client();
    IOSink? sink;
    try {
      final resp =
          await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        throw UpdateException('Download failed (HTTP ${resp.statusCode}).');
      }
      final total = resp.contentLength ?? 0;
      sink = part.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        if (isCancelled?.call() ?? false) {
          throw const ApkDownloadCancelled();
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
      onProgress?.call(1.0);
      return file.path;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close();
    }
  }
}
