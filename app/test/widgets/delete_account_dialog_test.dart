import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/delete_account_dialog.dart';

void main() {
  testWidgets('confirm is disabled until DELETE is typed', (tester) async {
    // flutter_test defaults to the android platform; the dialog is platform-
    // agnostic but keep desktop semantics deterministic.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await DeleteAccountDialog.show(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tapping the destructive button before typing DELETE does nothing.
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget); // dialog still open
    expect(result, isNull);

    // Type the confirmation word, then the button works.
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(result, isTrue);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancel returns false', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => result = await DeleteAccountDialog.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    debugDefaultTargetPlatformOverride = null;
  });
}
