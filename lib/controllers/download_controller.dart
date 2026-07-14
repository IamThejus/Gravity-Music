// controllers/download_controller.dart
//
// Reactive layer over DownloadService. Exposes the completed-download list and
// per-track in-flight progress so the UI can show spinners / progress bars and
// the Downloads screen updates live. All persistence/file work is delegated to
// DownloadService.

import 'package:get/get.dart';

import '../services/download_service.dart';
import '../services/library_service.dart';
import '../ui/app_theme.dart';

class DownloadController extends GetxController {
  /// Completed downloads (newest first).
  final downloads = <LibraryTrack>[].obs;

  /// Tracks currently downloading (for display, newest first).
  final downloading = <LibraryTrack>[].obs;

  /// videoId → 0..1 while a download is in flight. Absent when idle/done.
  final progress = <String, double>{}.obs;

  /// IDs the user asked to cancel; the in-flight download loop polls this and
  /// aborts. Cleared in [startDownload]'s finally block.
  final _cancelled = <String>{};

  @override
  void onInit() {
    super.onInit();
    reload();
  }

  void reload() => downloads.assignAll(DownloadService.getDownloads());

  bool isDownloaded(String videoId) => DownloadService.isDownloaded(videoId);
  bool isDownloading(String videoId) => progress.containsKey(videoId);

  Future<void> startDownload(LibraryTrack track) async {
    final id = track.videoId;
    if (isDownloaded(id) || isDownloading(id)) return;

    progress[id] = 0.0;
    downloading.insert(0, track);
    try {
      await DownloadService.download(
        track,
        onProgress: (p) => progress[id] = p,
        isCancelled: () => _cancelled.contains(id),
      );
      reload();
      Get.snackbar('Downloaded', '“${track.title}” saved for offline',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.card,
          colorText: AppColors.white);
    } on DownloadCancelledException {
      // User cancelled — no error toast.
    } catch (e) {
      Get.snackbar('Download failed', 'Could not download “${track.title}”',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.card,
          colorText: AppColors.white);
    } finally {
      _cancelled.remove(id);
      progress.remove(id);
      downloading.removeWhere((t) => t.videoId == id);
    }
  }

  /// Cancel an in-flight download. The download loop aborts on its next chunk,
  /// deletes the partial file, and the tile disappears from the Downloads list.
  void cancelDownload(String videoId) {
    if (progress.containsKey(videoId)) _cancelled.add(videoId);
  }

  Future<void> delete(String videoId) async {
    await DownloadService.remove(videoId);
    reload();
  }
}
