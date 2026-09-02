import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/cloud/feedback_service.dart';

// Validation runs before any network/Supabase call, so these exercise the
// guard rails without a backend. The happy path needs a live Supabase project
// and is covered manually.
void main() {
  group('FeedbackService.submit validation', () {
    test('rejects an empty message', () {
      expect(
        () => FeedbackService.submit(
            name: 'Thejus', category: FeedbackCategory.other, message: '   '),
        throwsA(isA<FeedbackException>().having(
            (e) => e.message, 'message', contains('write a message'))),
      );
    });

    test('rejects an over-long message', () {
      expect(
        () => FeedbackService.submit(
            name: 'Thejus',
            category: FeedbackCategory.bug,
            message: 'x' * (FeedbackService.maxMessageLength + 1)),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', contains('too long'))),
      );
    });

    test('rejects a blank name', () {
      expect(
        () => FeedbackService.submit(
            name: '  ',
            category: FeedbackCategory.idea,
            message: 'A perfectly good idea'),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', contains('name'))),
      );
    });

    test('checks the name before the message, so the first empty field is the '
        'one reported', () {
      expect(
        () => FeedbackService.submit(
            name: '', category: FeedbackCategory.other, message: ''),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', contains('name'))),
      );
    });

    test('a valid submission gets past validation to the availability check',
        () {
      // Supabase is not initialised in tests, so this is the next guard.
      expect(
        () => FeedbackService.submit(
            name: 'Thejus',
            category: FeedbackCategory.idea,
            message: 'Great app'),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', contains('Gravity server'))),
      );
    });

    test('FeedbackException surfaces its message via toString', () {
      expect(const FeedbackException('boom').toString(), 'boom');
    });
  });

  group('FeedbackCategory', () {
    test('wire values match the schema.sql CHECK constraint', () {
      // supabase/schema.sql: check (category in ('idea', 'bug', 'other')).
      // Postgres rejects the insert outright if these ever drift apart.
      expect(FeedbackCategory.values.map((c) => c.wire).toSet(),
          {'idea', 'bug', 'other'});
    });

    test('every category has a label to show next to its radio', () {
      for (final c in FeedbackCategory.values) {
        expect(c.label, isNotEmpty);
      }
    });
  });
}
