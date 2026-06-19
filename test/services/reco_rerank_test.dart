// test/services/reco_rerank_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/library_service.dart';
import 'package:saragama/services/recommendation_service.dart';
import 'package:saragama/services/taste_profile.dart';

RecommendedTrack rt(String id, String artist) =>
    RecommendedTrack(videoId: id, title: id, artist: artist, thumbnail: '', duration: '3:00');
LibraryTrack lt(String id, String artist) =>
    LibraryTrack(videoId: id, title: id, artist: artist, thumbnail: '', duration: '3:00');

void main() {
  final profile = TasteProfile.build(
    liked: [lt('x', 'Loved')], history: [], playlistTracks: []);

  test('empty profile returns candidates unchanged', () {
    final cands = [rt('1', 'A'), rt('2', 'B')];
    final empty = TasteProfile.build(liked: [], history: [], playlistTracks: []);
    expect(rerankByTaste(cands, empty, {}).map((t) => t.videoId).toList(),
        ['1', '2']);
  });

  test('affinity reorders the loved artist up, drops nothing', () {
    final cands = [rt('1', 'Other'), rt('2', 'Other2'), rt('3', 'Loved')];
    final out = rerankByTaste(cands, profile, {});
    expect(out.first.artist, 'Loved');
    expect(out.map((t) => t.videoId).toSet(), {'1', '2', '3'}); // same set
    expect(out.length, 3);
  });

  test('recently-played candidate is demoted', () {
    final cands = [rt('1', 'Loved'), rt('2', 'Loved')];
    final out = rerankByTaste(cands, profile, {'1'}); // 1 was just played
    expect(out.first.videoId, '2');
  });
}
