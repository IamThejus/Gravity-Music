// Covers persisting a repaired videoId, and the hook that carries it to the
// cloud. LibraryService.onChanged is what SyncService subscribes to for its
// debounced full-state push, so "does the swap sync?" reduces here to "does
// the swap fire onChanged?" — the push itself is SyncService's existing,
// already-exercised path.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:saragama/services/library_service.dart';

LibraryTrack _t(String id, {String title = 'Thakilu Pukilu', DateTime? added}) =>
    LibraryTrack(
      videoId: id,
      title: title,
      artist: 'M. G. Sreekumar',
      thumbnail: 'https://example.test/$id.jpg',
      duration: '4:20',
      addedAt: added,
    );

void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('gm_lib_test');
    Hive.init(dir.path);
  });

  setUp(() async {
    if (!Hive.isBoxOpen('LibraryBox')) await Hive.openBox('LibraryBox');
    await Hive.box('LibraryBox').clear();
    LibraryService.onChanged = null;
  });

  tearDownAll(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  void seedPlaylist(List<LibraryTrack> tracks) {
    Hive.box('LibraryBox').put('playlists', [
      LocalPlaylist(
        id: 'pl1',
        name: 'Indie Pop Mix',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        tracks: tracks,
      ).toMap(),
    ]);
  }

  test('repoints the track inside a playlist, keeping everything else',
      () async {
    final added = DateTime.fromMillisecondsSinceEpoch(5000);
    seedPlaylist([_t('KEEP0000001', title: 'A'), _t('DEAD0000001', added: added)]);

    final n = LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001');

    expect(n, 1);
    final tracks = LibraryService.getPlaylists().single.tracks;
    expect(tracks.map((t) => t.videoId), ['KEEP0000001', 'GOOD0000001']);
    // Position, user-visible metadata and the sort timestamp all survive.
    expect(tracks[1].title, 'Thakilu Pukilu');
    expect(tracks[1].artist, 'M. G. Sreekumar');
    expect(tracks[1].addedAt, added);
  });

  test('adopts the replacement artwork and duration when given', () {
    seedPlaylist([_t('DEAD0000001')]);

    LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001',
        thumbnail: 'https://example.test/new.jpg', duration: '3:59');

    final t = LibraryService.getPlaylists().single.tracks.single;
    expect(t.thumbnail, 'https://example.test/new.jpg');
    expect(t.duration, '3:59');
  });

  test('keeps the old artwork when the replacement carries none', () {
    seedPlaylist([_t('DEAD0000001')]);

    LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001',
        thumbnail: '', duration: '');

    final t = LibraryService.getPlaylists().single.tracks.single;
    expect(t.thumbnail, 'https://example.test/DEAD0000001.jpg');
    expect(t.duration, '4:20');
  });

  test('repoints a liked song too', () {
    LibraryService.like(_t('DEAD0000001'));

    final n = LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001');

    expect(n, 1);
    expect(LibraryService.isLiked('GOOD0000001'), isTrue);
    expect(LibraryService.isLiked('DEAD0000001'), isFalse);
  });

  test('collapses rather than duplicating when the replacement is already in '
      'the same playlist', () {
    seedPlaylist([_t('GOOD0000001'), _t('DEAD0000001')]);

    LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001');

    expect(LibraryService.getPlaylists().single.tracks.map((t) => t.videoId),
        ['GOOD0000001']);
  });

  test('rewrites every playlist the dead track appears in', () {
    Hive.box('LibraryBox').put('playlists', [
      LocalPlaylist(
              id: 'a',
              name: 'A',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1),
              tracks: [_t('DEAD0000001')])
          .toMap(),
      LocalPlaylist(
              id: 'b',
              name: 'B',
              createdAt: DateTime.fromMillisecondsSinceEpoch(2),
              tracks: [_t('DEAD0000001')])
          .toMap(),
    ]);

    expect(LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001'), 2);
    for (final p in LibraryService.getPlaylists()) {
      expect(p.tracks.single.videoId, 'GOOD0000001');
    }
  });

  group('cloud sync trigger', () {
    test('fires onChanged so a signed-in user gets the corrected id pushed',
        () {
      seedPlaylist([_t('DEAD0000001')]);
      var pushes = 0;
      LibraryService.onChanged = () => pushes++;

      LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001');

      expect(pushes, greaterThan(0));
    });

    test('does not fire when the track is not in the library at all', () {
      // Playing from search / radio / a generated mix: nothing to persist, and
      // firing here would push an unchanged library on every unplayable track.
      seedPlaylist([_t('OTHER000001')]);
      var pushes = 0;
      LibraryService.onChanged = () => pushes++;

      expect(LibraryService.replaceVideoId('DEAD0000001', 'GOOD0000001'), 0);
      expect(pushes, 0);
    });

    test('ignores a no-op swap', () {
      seedPlaylist([_t('DEAD0000001')]);
      var pushes = 0;
      LibraryService.onChanged = () => pushes++;

      expect(LibraryService.replaceVideoId('DEAD0000001', 'DEAD0000001'), 0);
      expect(LibraryService.replaceVideoId('', 'GOOD0000001'), 0);
      expect(LibraryService.replaceVideoId('DEAD0000001', ''), 0);
      expect(pushes, 0);
    });
  });
}
