// Covers the "repair a dead videoId" path: an imported playlist stores an id
// picked by a fuzzy title/artist match, and YouTube can later refuse that
// exact video while the same song plays fine under a different id.

import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/models/hm_streaming_data.dart';
import 'package:saragama/services/track_rematch_service.dart';
import 'package:saragama/services/yt_music_service.dart';

YtMusicSong _song(String id, String title) => YtMusicSong(
      videoId: id,
      title: title,
      artists: const ['M. G. Sreekumar'],
      album: '',
      thumbnail: 'https://example.test/$id.jpg',
      duration: '4:20',
    );

HMStreamingData _ok() => HMStreamingData(playable: true, statusMSG: 'OK');
HMStreamingData _dead() =>
    HMStreamingData(playable: false, statusMSG: 'This track is unavailable', lastStatus: 'UNPLAYABLE');

void main() {
  setUp(TrackRematchService.resetForTest);

  group('shouldRematch', () {
    test('only a definitive UNPLAYABLE is worth repairing', () {
      expect(TrackRematchService.shouldRematch('UNPLAYABLE'), isTrue);
    });

    test('a rate limit or network failure says nothing about the video', () {
      // Searching for alternatives while YouTube is already refusing requests
      // makes the throttling worse, and the original id may be perfectly fine.
      expect(TrackRematchService.shouldRematch('RATE_LIMITED'), isFalse);
      expect(TrackRematchService.shouldRematch('LOGIN_REQUIRED'), isFalse);
      expect(TrackRematchService.shouldRematch(''), isFalse);
    });
  });

  group('find', () {
    test('adopts the first candidate that actually resolves', () async {
      final resolved = <String>[];
      final r = await TrackRematchService.find(
        title: 'Thakilu Pukilu',
        artist: 'M. G. Sreekumar',
        badVideoId: 'DEAD0000001',
        search: (_) async => [_song('CAND0000001', 'Thakilu Pukilu')],
        resolve: (id) async {
          resolved.add(id);
          return _ok();
        },
      );
      expect(r, isNotNull);
      expect(r!.videoId, 'CAND0000001');
      expect(resolved, ['CAND0000001']);
      // The verified stream rides along so the caller doesn't resolve twice.
      expect(r.stream.playable, isTrue);
    });

    test('normalises the search thumbnail off the raw w60 tier', () async {
      // YouTube Music's search renderer returns =w60-h60 art. Stored verbatim,
      // a repaired track's notification/lockscreen image renders ~9x softer
      // than every other track, which is exactly what shipped first.
      final r = await TrackRematchService.find(
        title: 'Song',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async => [
          YtMusicSong(
            videoId: 'CAND0000001',
            title: 'Song',
            artists: const [],
            album: '',
            thumbnail:
                'https://yt3.googleusercontent.com/abc=w60-h60-l90-rj',
            duration: '4:20',
          )
        ],
        resolve: (_) async => _ok(),
      );
      expect(r!.thumbnail, contains('w96-h96'));
      expect(r.thumbnail, isNot(contains('w60-h60')));
    });

    test('a search hit that does not resolve is not accepted', () async {
      // The whole failure being repaired is a search result that will not
      // play, so "it was in the results" cannot be the acceptance test.
      final r = await TrackRematchService.find(
        title: 'Thakilu Pukilu',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async => [
          _song('BADCAND0001', 'Thakilu Pukilu'),
          _song('GOODCAND001', 'Thakilu Pukilu'),
        ],
        resolve: (id) async => id == 'GOODCAND001' ? _ok() : _dead(),
      );
      expect(r!.videoId, 'GOODCAND001');
    });

    test('never re-adopts the id that just failed', () async {
      final r = await TrackRematchService.find(
        title: 'Thakilu Pukilu',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async => [_song('DEAD0000001', 'Thakilu Pukilu')],
        resolve: (_) async => _ok(),
      );
      expect(r, isNull);
    });

    test('rejects a hit whose title is a different song', () async {
      // The swap is silent and persisted, so a wrong match is worse than none.
      var resolveCalls = 0;
      final r = await TrackRematchService.find(
        title: 'Thakilu Pukilu',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async => [_song('OTHER000001', 'Completely Other Song')],
        resolve: (_) async {
          resolveCalls++;
          return _ok();
        },
      );
      expect(r, isNull);
      expect(resolveCalls, 0, reason: 'should not spend a resolve on it');
    });

    test('tolerates YouTube Music title suffixes', () async {
      final r = await TrackRematchService.find(
        title: 'Thakilu Pukilu',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async =>
            [_song('CAND0000001', 'Thakilu Pukilu (From "Ravanaprabhu")')],
        resolve: (_) async => _ok(),
      );
      expect(r, isNotNull);
    });

    test('stops after maxCandidates so one dead track cannot spiral',
        () async {
      var resolveCalls = 0;
      final r = await TrackRematchService.find(
        title: 'Song',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async =>
            [for (var i = 0; i < 10; i++) _song('CAND000000$i', 'Song')],
        resolve: (_) async {
          resolveCalls++;
          return _dead();
        },
      );
      expect(r, isNull);
      expect(resolveCalls, TrackRematchService.maxCandidates);
    });

    test('gives up only once per session for the same dead id', () async {
      var searches = 0;
      Future<RematchResult?> attempt() => TrackRematchService.find(
            title: 'Song',
            artist: '',
            badVideoId: 'DEAD0000001',
            search: (_) async {
              searches++;
              return [_song('CAND0000001', 'Song')];
            },
            resolve: (_) async => _dead(),
          );
      expect(await attempt(), isNull);
      expect(await attempt(), isNull);
      expect(searches, 1, reason: 'second play must not re-search');
    });

    test('concurrent callers share one repair', () async {
      // The prefetch path and the playback path can both hit the same dead
      // track; they must not both search and resolve.
      var searches = 0;
      Future<RematchResult?> attempt() => TrackRematchService.find(
            title: 'Song',
            artist: '',
            badVideoId: 'DEAD0000001',
            search: (_) async {
              searches++;
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return [_song('CAND0000001', 'Song')];
            },
            resolve: (_) async => _ok(),
          );
      final results = await Future.wait([attempt(), attempt(), attempt()]);
      expect(searches, 1);
      expect(results.map((r) => r!.videoId).toSet(), {'CAND0000001'});
    });

    test('a search failure is swallowed, not thrown at the player', () async {
      final r = await TrackRematchService.find(
        title: 'Song',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async => throw Exception('offline'),
        resolve: (_) async => _ok(),
      );
      expect(r, isNull);
    });

    test('an empty title is not searchable', () async {
      var searches = 0;
      final r = await TrackRematchService.find(
        title: '   ',
        artist: '',
        badVideoId: 'DEAD0000001',
        search: (_) async {
          searches++;
          return [];
        },
        resolve: (_) async => _ok(),
      );
      expect(r, isNull);
      expect(searches, 0);
    });
  });
}
