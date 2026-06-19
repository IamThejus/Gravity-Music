// test/services/personalized_mixes_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/personalized_mixes_service.dart';
import 'package:saragama/services/yt_music_service.dart';

YtMusicSong s(String id, List<String> artists) => YtMusicSong(
    videoId: id,
    title: id,
    artists: artists,
    album: '',
    thumbnail: '',
    duration: '3:00');

void main() {
  test('filterDiscovery keeps only tracks whose artists are all unknown', () {
    final cands = [s('1', ['Known']), s('2', ['New']), s('3', ['New', 'Known'])];
    final out = filterDiscovery(cands, {'Known'});
    expect(out.map((e) => e.videoId).toList(), ['2']); // 1 and 3 touch Known
  });
}
