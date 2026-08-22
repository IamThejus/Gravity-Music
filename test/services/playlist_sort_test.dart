import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/library_service.dart';

LibraryTrack t(String id, {int? addedMs}) => LibraryTrack(
      videoId: id,
      title: id,
      artist: 'a',
      thumbnail: '',
      duration: '3:00',
      addedAt:
          addedMs == null ? null : DateTime.fromMillisecondsSinceEpoch(addedMs),
    );

List<String> ids(List<LibraryTrack> l) => l.map((e) => e.videoId).toList();

void main() {
  group('PlaylistSort.apply', () {
    final stored = [
      t('first', addedMs: 1000),
      t('second', addedMs: 3000),
      t('third', addedMs: 2000),
    ];

    test('custom returns the stored order untouched', () {
      expect(ids(PlaylistSort.custom.apply(stored)), ['first', 'second', 'third']);
    });

    test('newestAdded is descending by add time', () {
      expect(ids(PlaylistSort.newestAdded.apply(stored)),
          ['second', 'third', 'first']);
    });

    test('oldestAdded is ascending by add time', () {
      expect(ids(PlaylistSort.oldestAdded.apply(stored)),
          ['first', 'third', 'second']);
    });

    test('never mutates the input list', () {
      final input = [...stored];
      PlaylistSort.newestAdded.apply(input);
      expect(ids(input), ['first', 'second', 'third']);
    });

    test('empty and single-item lists are safe', () {
      expect(PlaylistSort.newestAdded.apply([]), isEmpty);
      expect(ids(PlaylistSort.newestAdded.apply([t('only')])), ['only']);
    });
  });

  group('legacy tracks with no addedAt', () {
    // Tracks saved before addedAt existed. They were appended, so stored order
    // is add order — they must stay in that order and rank as oldest.
    final mixed = [
      t('legacyA'),
      t('legacyB'),
      t('newer', addedMs: 5000),
    ];

    test('untimestamped tracks sort as the oldest, in add order', () {
      // legacyB was appended after legacyA, so newest-first puts it above.
      expect(ids(PlaylistSort.newestAdded.apply(mixed)),
          ['newer', 'legacyB', 'legacyA']);
      expect(ids(PlaylistSort.oldestAdded.apply(mixed)),
          ['legacyA', 'legacyB', 'newer']);
    });

    test('all-legacy playlist still reverses for newest-first', () {
      // Stored order IS add order for pre-addedAt playlists, so the feature
      // must be meaningful on them rather than a no-op.
      final all = [t('x'), t('y'), t('z')];
      expect(ids(PlaylistSort.oldestAdded.apply(all)), ['x', 'y', 'z']);
      expect(ids(PlaylistSort.newestAdded.apply(all)), ['z', 'y', 'x']);
    });

    test('equal timestamps keep stored order (sort is stable)', () {
      final tie = [t('p', addedMs: 7), t('q', addedMs: 7), t('r', addedMs: 7)];
      expect(ids(PlaylistSort.oldestAdded.apply(tie)), ['p', 'q', 'r']);
    });
  });

  group('liked songs store newest-first (insert at 0)', () {
    // Playlists append, liked songs prepend — apply() must be told, or legacy
    // liked entries sort backwards.
    final likedStored = [t('newest'), t('middle'), t('oldest')];

    test('newestAdded keeps stored order for untimestamped liked songs', () {
      expect(
          ids(PlaylistSort.newestAdded
              .apply(likedStored, storedNewestFirst: true)),
          ['newest', 'middle', 'oldest']);
    });

    test('oldestAdded reverses stored order for untimestamped liked songs', () {
      expect(
          ids(PlaylistSort.oldestAdded
              .apply(likedStored, storedNewestFirst: true)),
          ['oldest', 'middle', 'newest']);
    });

    test('the same list sorts the OPPOSITE way with playlist semantics', () {
      // Guards the flag actually doing something — this is the bug it prevents.
      expect(
          ids(PlaylistSort.newestAdded
              .apply(likedStored, storedNewestFirst: false)),
          ['oldest', 'middle', 'newest']);
    });

    test('real timestamps win over stored position', () {
      final mixed = [
        t('a', addedMs: 100),
        t('b', addedMs: 300),
        t('c', addedMs: 200),
      ];
      expect(
          ids(PlaylistSort.newestAdded.apply(mixed, storedNewestFirst: true)),
          ['b', 'c', 'a']);
    });

    test('custom is untouched regardless of the flag', () {
      expect(
          ids(PlaylistSort.custom.apply(likedStored, storedNewestFirst: true)),
          ['newest', 'middle', 'oldest']);
    });
  });

  group('PlaylistSort.fromKey', () {
    test('round-trips every value', () {
      for (final v in PlaylistSort.values) {
        expect(PlaylistSort.fromKey(v.key), v);
      }
    });

    test('unknown or null keys fall back to custom', () {
      expect(PlaylistSort.fromKey(null), PlaylistSort.custom);
      expect(PlaylistSort.fromKey('nonsense'), PlaylistSort.custom);
    });
  });

  group('LibraryTrack serialisation', () {
    test('addedAt round-trips through toMap/fromMap', () {
      final orig = t('id', addedMs: 1234567);
      final back = LibraryTrack.fromMap(orig.toMap());
      expect(back.addedAt, orig.addedAt);
    });

    test('null addedAt is omitted, so old rows round-trip unchanged', () {
      final map = t('id').toMap();
      expect(map.containsKey('addedAt'), isFalse);
      expect(LibraryTrack.fromMap(map).addedAt, isNull);
    });

    test('a pre-existing map without addedAt still parses', () {
      final legacy = {
        'videoId': 'v',
        'title': 'T',
        'artist': 'A',
        'thumbnail': '',
        'duration': '1:00',
      };
      expect(LibraryTrack.fromMap(legacy).addedAt, isNull);
      expect(LibraryTrack.fromMap(legacy).videoId, 'v');
    });
  });
}
