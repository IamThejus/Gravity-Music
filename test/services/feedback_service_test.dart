import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/cloud/feedback_service.dart';

// Validation runs before any network/Supabase call, so these exercise the
// guard rails without a backend. The happy path needs a live Supabase project
// and is covered manually.
void main() {
  group('FeedbackService.submit validation', () {
    test('rejects an empty message', () {
      expect(
        () => FeedbackService.submit(message: '   '),
        throwsA(isA<FeedbackException>().having(
            (e) => e.message, 'message', contains('write a message'))),
      );
    });

    test('rejects an over-long message', () {
      expect(
        () => FeedbackService.submit(
            message: 'x' * (FeedbackService.maxMessageLength + 1)),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', contains('too long'))),
      );
    });

    test('a valid message gets past validation to the availability check', () {
      // Supabase is not initialised in tests, so this is the next guard.
      expect(
        () => FeedbackService.submit(name: 'Thejus', message: 'Great app'),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', contains('Gravity server'))),
      );
    });

    test('blank name is allowed — it is stored as NULL, not rejected', () {
      expect(
        () => FeedbackService.submit(name: '  ', message: 'Anonymous note'),
        throwsA(isA<FeedbackException>()
            .having((e) => e.message, 'message', isNot(contains('name')))),
      );
    });

    test('FeedbackException surfaces its message via toString', () {
      expect(const FeedbackException('boom').toString(), 'boom');
    });
  });
}
