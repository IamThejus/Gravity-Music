import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/queue_manager.dart';

MediaItem m(String id) => MediaItem(id: id, title: id);

/// Mirrors the flat-queue mutations MyAudioHandler performs around
/// QueueManager, so these tests exercise the real end-to-end ordering the user
/// hears — not just QueueManager's internals in isolation.
class Harness {
  final QueueManager qm = QueueManager();
  List<MediaItem> queue = [];
  int currentIndex = 0;

  List<String> get ids => queue.map((i) => i.id).toList();
  String get currentId => queue[currentIndex].id;

  void playAll(List<String> songIds, {int start = 0}) {
    qm.reset();
    queue = songIds.map(m).toList();
    currentIndex = start;
    qm.pruneConsumed(queue, currentIndex);
  }

  void enableShuffle() => qm.enableShuffle(queue, currentIndex);

  void addToQueue(String id) => _userInsert(id, front: false);
  void playNext(String id) => _userInsert(id, front: true);

  void _userInsert(String id, {required bool front}) {
    if (qm.isUserQueued(id)) {
      final existing = queue.indexWhere((i) => i.id == id);
      if (existing > currentIndex) queue.removeAt(existing);
    }
    final pos = front
        ? (currentIndex + 1).clamp(0, queue.length)
        : qm.userQueueInsertIndex(queue, currentIndex);
    queue.insert(pos, m(id));
    qm.onUserEnqueued(id, front: front);
  }

  /// Recommendations append to the very end (autoplay tail).
  void appendAutoplay(List<String> recIds) {
    for (final id in recIds) {
      if (queue.any((i) => i.id == id)) continue;
      qm.onItemsAdded([m(id)]);
      queue.add(m(id));
    }
  }

  /// One "skip to next" / auto-advance step. Returns false when exhausted.
  bool advance() {
    final n = qm.nextIndex(queue, currentIndex);
    if (n == null || n == currentIndex) return false;
    currentIndex = n;
    qm.pruneConsumed(queue, currentIndex);
    return true;
  }

  /// Tap a specific queue row (skipToQueueItem).
  void jumpTo(int index) {
    currentIndex = index;
    qm.pruneConsumed(queue, currentIndex);
  }
}

void main() {
  group('user queue ordering (no shuffle)', () {
    test('Add to queue inserts after current, ahead of context', () {
      final h = Harness()..playAll(['A', 'B', 'C', 'D', 'E'], start: 1); // cur B
      h.addToQueue('X');
      h.addToQueue('Y');
      expect(h.ids, ['A', 'B', 'X', 'Y', 'C', 'D', 'E']);
      expect(h.qm.userQueuedIds, ['X', 'Y']);
    });

    test('playback order is Current → User → Context', () {
      final h = Harness()..playAll(['A', 'B', 'C', 'D', 'E'], start: 1);
      h.addToQueue('X');
      h.addToQueue('Y');
      final order = <String>[h.currentId];
      while (h.advance()) {
        order.add(h.currentId);
      }
      expect(order, ['B', 'X', 'Y', 'C', 'D', 'E']);
    });

    test('Play next inserts at the FRONT of the user section', () {
      final h = Harness()..playAll(['A', 'B', 'C'], start: 1); // cur B
      h.addToQueue('X');
      h.addToQueue('Y');
      h.playNext('Z');
      expect(h.ids, ['A', 'B', 'Z', 'X', 'Y', 'C']);
      expect(h.qm.userQueuedIds, ['Z', 'X', 'Y']);
    });

    test('autoplay appends AFTER context; user queue still jumps ahead', () {
      final h = Harness()..playAll(['A', 'B'], start: 0); // cur A, context B
      h.appendAutoplay(['R1', 'R2']);
      h.addToQueue('X');
      expect(h.ids, ['A', 'X', 'B', 'R1', 'R2']);
      final order = <String>[h.currentId];
      while (h.advance()) {
        order.add(h.currentId);
      }
      expect(order, ['A', 'X', 'B', 'R1', 'R2']);
    });

    test('re-adding a queued song moves it to the end of the user section', () {
      final h = Harness()..playAll(['A', 'B'], start: 0);
      h.addToQueue('X');
      h.addToQueue('Y');
      h.addToQueue('X'); // move X after Y
      expect(h.ids, ['A', 'Y', 'X', 'B']);
      expect(h.qm.userQueuedIds, ['Y', 'X']);
    });
  });

  group('consumption', () {
    test('advancing onto a user song consumes it', () {
      final h = Harness()..playAll(['A', 'B'], start: 0);
      h.addToQueue('X');
      expect(h.qm.isUserQueued('X'), isTrue);
      h.advance(); // onto X
      expect(h.currentId, 'X');
      expect(h.qm.isUserQueued('X'), isFalse);
    });

    test('jumping past user songs prunes them', () {
      final h = Harness()..playAll(['A', 'B', 'C'], start: 1); // cur B
      h.addToQueue('X');
      h.addToQueue('Y'); // [A,B,X,Y,C]
      h.jumpTo(4); // tap C directly
      expect(h.currentId, 'C');
      expect(h.qm.userQueuedIds, isEmpty);
    });
  });

  group('shuffle exemption', () {
    test('user queue plays next in order even with shuffle on', () {
      final h = Harness()..playAll(['A', 'B', 'C', 'D', 'E'], start: 0);
      h.enableShuffle();
      h.addToQueue('X');
      h.addToQueue('Y');
      // First two advances must be the user queue, in order.
      h.advance();
      expect(h.currentId, 'X');
      h.advance();
      expect(h.currentId, 'Y');
      // Then playback resumes within the shuffled context (never a user song).
      h.advance();
      expect(['A', 'B', 'C', 'D', 'E'].contains(h.currentId), isTrue);
    });

    test('user-queued ids are kept OUT of the shuffle permutation', () {
      final h = Harness()..playAll(['A', 'B', 'C'], start: 0);
      h.addToQueue('X'); // queued before shuffle is toggled
      h.enableShuffle();
      expect(h.qm.shuffledIds.contains('X'), isFalse);
      h.addToQueue('Y'); // queued after shuffle is on
      expect(h.qm.shuffledIds.contains('Y'), isFalse);
    });

    test('peekPrevIndex previews the previous track without mutating', () {
      final h = Harness()..playAll(['A', 'B', 'C'], start: 1); // cur B
      final peek = h.qm.peekPrevIndex(h.queue, h.currentIndex);
      expect(peek, 0); // A
      // Non-mutating: shuffle cursor untouched (still not shuffled here).
      expect(h.qm.shuffleIndex, 0);
      expect(h.qm.peekPrevIndex(h.queue, 0), isNull); // nothing before first
    });

    test('peekNextIndex also honours the user queue', () {
      final h = Harness()..playAll(['A', 'B', 'C'], start: 0);
      h.enableShuffle();
      h.addToQueue('X');
      final peek = h.qm.peekNextIndex(h.queue, h.currentIndex);
      expect(peek, isNotNull);
      expect(h.queue[peek!].id, 'X');
    });
  });

  group('lifecycle', () {
    test('reset / new queue clears the user section', () {
      final h = Harness()..playAll(['A', 'B'], start: 0);
      h.addToQueue('X');
      expect(h.qm.userQueuedIds, isNotEmpty);
      h.playAll(['P', 'Q'], start: 0);
      expect(h.qm.userQueuedIds, isEmpty);
    });

    test('removing a song drops it from the user section', () {
      final h = Harness()..playAll(['A', 'B'], start: 0);
      h.addToQueue('X');
      h.qm.onItemRemoved('X');
      expect(h.qm.isUserQueued('X'), isFalse);
    });

    test('restoreUserQueue re-seeds the section', () {
      final qm = QueueManager();
      qm.restoreUserQueue(['X', 'Y']);
      expect(qm.userQueuedIds, ['X', 'Y']);
    });
  });
}
