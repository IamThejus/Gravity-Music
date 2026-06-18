// controllers/import_controller.dart
//
// Background playlist import. Lets the playlist-import flow return the user to
// the Library immediately instead of holding them on a full-screen progress
// bar: each in-flight import is tracked as an [ImportJob] and rendered as a
// placeholder tile in the Library grid (progress ring as the cover). When the
// import resolves, the job saves a normal LocalPlaylist via LibraryService
// (which the Library grid already observes through the LibraryBox listener)
// and removes its placeholder. Failures stay on-screen as a retry/dismiss
// tile so nothing is silently lost.
//
// Progress is REAL now: the local import matches tracks to YouTube Music one
// by one, so importPlaylist reports (done, total) and the job's progress ring
// reflects actual matching progress, snapping to 100% on save.

import 'package:get/get.dart';

import '../services/import_service.dart';
import '../services/library_service.dart';
import '../services/search_service.dart';
import '../ui/ui_helpers.dart';

/// A single in-progress (or failed) playlist import, rendered as a placeholder
/// tile in the Library. All fields the UI watches are reactive.
class ImportJob {
  final String id;
  final String url;
  final String name;
  final int songCount;
  final int estimatedSeconds;

  final RxDouble progress; // 0..1, simulated
  final RxBool failed;
  final RxString error;

  ImportJob({
    required this.id,
    required this.url,
    required this.name,
    required this.songCount,
    required this.estimatedSeconds,
  })  : progress = 0.0.obs,
        failed = false.obs,
        error = ''.obs;
}

class ImportController extends GetxController {
  /// In-flight + failed imports. Mutated on add / remove only (coarse); the
  /// frequent per-job progress updates ride on [ImportJob.progress].
  final jobs = <ImportJob>[].obs;

  /// Begin a background import and return immediately. The caller can pop back
  /// to the Library; the placeholder tile takes over from here.
  void startImport({
    required String url,
    required String name,
    required int songCount,
    required int estimatedSeconds,
  }) {
    final job = ImportJob(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: url,
      name: name,
      songCount: songCount,
      estimatedSeconds: estimatedSeconds,
    );
    jobs.add(job);
    _run(job);
  }

  /// Retry a failed job in place (keeps its tile/position).
  void retry(ImportJob job) {
    if (!jobs.contains(job)) return;
    _run(job);
  }

  /// Remove a job's placeholder tile (used to dismiss a failed import).
  void dismiss(ImportJob job) {
    jobs.remove(job);
  }

  void _run(ImportJob job) {
    job.failed.value = false;
    job.error.value = '';
    // Small non-zero value so the ring shows immediate activity while the
    // playlist is being scraped (before per-track matching progress starts).
    job.progress.value = 0.02;
    _doImport(job);
  }

  Future<void> _doImport(ImportJob job) async {
    try {
      final songs = await ImportService.importPlaylist(
        job.url,
        estimatedSeconds: job.estimatedSeconds,
        onProgress: (done, total) {
          if (job.failed.value || total == 0) return;
          // Real matching progress; reserve the last sliver for the save step.
          job.progress.value = (done / total * 0.97).clamp(0.02, 0.97);
        },
      );
      if (songs.isEmpty) {
        throw const ImportException(
            'No songs could be imported from this playlist.');
      }

      // Funnel into the EXISTING playlist architecture — identical to a
      // manually-created or foreground-imported playlist from here on.
      final tracks =
          songs.map((SearchResult s) => s.toLibraryTrack()).toList();
      LibraryService.createPlaylistWithTracks(job.name, tracks);

      job.progress.value = 1.0;
      // The real playlist now lives in LibraryBox; the Library grid renders it
      // via the box listener. Drop the placeholder.
      jobs.remove(job);

      Get.snackbar(
        'Playlist imported',
        '“${job.name}” was added to your library.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } on ImportException catch (e) {
      _fail(job, e.message);
    } catch (_) {
      _fail(job, 'Import failed. Tap to retry.');
    }
  }

  void _fail(ImportJob job, String msg) {
    job.failed.value = true;
    job.error.value = msg;
  }
}
