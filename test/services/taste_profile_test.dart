import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/library_service.dart';
import 'package:saragama/services/taste_profile.dart';

LibraryTrack t(String id, String artist) =>
    LibraryTrack(videoId: id, title: id, artist: artist, thumbnail: '', duration: '3:00');

void main() {
  test('isEmpty when no signals', () {
    final p = TasteProfile.build(liked: [], history: [], playlistTracks: []);
    expect(p.isEmpty, isTrue);
    expect(p.topArtists(4), isEmpty);
    expect(p.scoreFor('Anyone'), 0.0);
  });

  test('liked outweighs history outweighs playlist; scores normalized to 0..1', () {
    final p = TasteProfile.build(
      liked: [t('a1', 'Alpha')],
      history: [t('b1', 'Beta')],
      playlistTracks: [t('c1', 'Gamma')],
    );
    expect(p.artistAffinity['Alpha'], 1.0); // top normalizes to 1
    expect(p.artistAffinity['Beta']! < 1.0, isTrue);
    expect(p.artistAffinity['Beta']! > p.artistAffinity['Gamma']!, isTrue);
  });

  test('multi-artist field splits and credits each member', () {
    final p = TasteProfile.build(
      liked: [t('a1', 'Alpha, Beta & Gamma')],
      history: [], playlistTracks: [],
    );
    expect(p.artistAffinity.containsKey('Alpha'), isTrue);
    expect(p.artistAffinity.containsKey('Beta'), isTrue);
    expect(p.artistAffinity.containsKey('Gamma'), isTrue);
    expect(p.scoreFor('Beta, Zeta'), greaterThan(0.0)); // max of members
  });

  test('topArtists ordered by score with a seed videoId', () {
    final p = TasteProfile.build(
      liked: [t('a1', 'Alpha'), t('a2', 'Alpha'), t('b1', 'Beta')],
      history: [], playlistTracks: [],
    );
    final top = p.topArtists(2);
    expect(top.first.artist, 'Alpha');
    expect(top.first.seedVideoId, anyOf('a1', 'a2'));
    expect(top.length, 2);
  });

  test('history recency: earlier index counts more', () {
    final recent = TasteProfile.build(liked: [], history: [t('r', 'Recent'), t('o', 'Old')], playlistTracks: []);
    expect(recent.artistAffinity['Recent']! > recent.artistAffinity['Old']!, isTrue);
  });
}
