import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/cloud/feedback_service.dart';
import 'package:saragama/ui/settings/feedback_dialog.dart';

/// Regression test for: "the feedback form shortens when the keyboard is
/// engaged, I need to scroll the form to click Send."
///
/// Cause: the dialog passed `40 + MediaQuery.viewInsets.bottom` as its
/// insetPadding. Flutter's Dialog already computes
/// `MediaQuery.viewInsetsOf(context) + insetPadding` internally (see
/// material/dialog.dart), so the keyboard height was subtracted twice and the
/// dialog collapsed.
///
/// The invariant that must hold is **insetPadding is independent of
/// viewInsets**. Asserting that directly is what catches a reintroduction;
/// asserting rendered geometry does not, because the squeeze shows up as a
/// compressed scroll area rather than an off-screen button.
void main() {
  const phone = Size(1080, 2400);
  const dpr = 3.0;
  const keyboard = EdgeInsets.only(bottom: 340); // logical px

  Future<EdgeInsets> pumpWith(
      WidgetTester tester, EdgeInsets viewInsets) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(viewInsets: viewInsets),
          child: const FeedbackDialogBody(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return tester.widget<Dialog>(find.byType(Dialog)).insetPadding as EdgeInsets;
  }

  testWidgets('insetPadding does not grow when the keyboard opens',
      (tester) async {
    final closed = await pumpWith(tester, EdgeInsets.zero);
    final open = await pumpWith(tester, keyboard);

    expect(open, closed,
        reason: 'insetPadding grew with the keyboard — Dialog already adds '
            'viewInsets, so this double-counts it and collapses the dialog');
    expect(open.bottom, lessThan(keyboard.bottom),
        reason: 'insetPadding.bottom appears to contain the keyboard inset');
  });

  testWidgets('Send and Cancel sit on screen, above the keyboard',
      (tester) async {
    await pumpWith(tester, keyboard);
    const keyboardTop = 800.0 - 340.0; // screen height in logical px - keyboard

    for (final f in [
      find.widgetWithText(FilledButton, 'Send'),
      find.widgetWithText(TextButton, 'Cancel'),
    ]) {
      expect(f, findsOneWidget);
      final r = tester.getRect(f);
      expect(r.top, greaterThanOrEqualTo(0.0));
      expect(r.bottom, lessThanOrEqualTo(keyboardTop));
    }
  });

  group('category radios', () {
    testWidgets('offers every category, defaulting to "Anything at all"',
        (tester) async {
      await pumpWith(tester, EdgeInsets.zero);

      for (final c in FeedbackCategory.values) {
        expect(find.text(c.label), findsOneWidget);
      }

      final selected = tester
          .widgetList<Radio<FeedbackCategory>>(
              find.byType(Radio<FeedbackCategory>))
          .where((r) => r.value == r.groupValue)
          .toList();
      expect(selected, hasLength(1),
          reason: 'exactly one option must be preselected');
      expect(selected.single.value, FeedbackCategory.other,
          reason: 'the form must never be blocked on picking a category');
    });

    testWidgets('tapping the label selects that category, not just the circle',
        (tester) async {
      await pumpWith(tester, EdgeInsets.zero);

      await tester.tap(find.text(FeedbackCategory.bug.label));
      await tester.pumpAndSettle();

      final selected = tester
          .widgetList<Radio<FeedbackCategory>>(
              find.byType(Radio<FeedbackCategory>))
          .firstWhere((r) => r.value == r.groupValue);
      expect(selected.value, FeedbackCategory.bug);
    });

    testWidgets('the name field no longer advertises itself as optional',
        (tester) async {
      await pumpWith(tester, EdgeInsets.zero);
      expect(find.text('Name (optional)'), findsNothing);
      expect(find.text('Your name'), findsOneWidget);
    });
  });

  testWidgets('only the fields scroll — header and actions stay pinned',
      (tester) async {
    await pumpWith(tester, keyboard);

    expect(find.byType(SingleChildScrollView), findsOneWidget,
        reason: 'the whole dialog should not be one scroll view');

    final header = tester.getRect(find.text('Send feedback'));
    final scroll = tester.getRect(find.byType(SingleChildScrollView));
    final send = tester.getRect(find.widgetWithText(FilledButton, 'Send'));

    expect(header.bottom, lessThanOrEqualTo(scroll.top),
        reason: 'header must sit above the scroll region');
    expect(scroll.bottom, lessThanOrEqualTo(send.top + 1),
        reason: 'actions must sit below the scroll region');
  });
}
