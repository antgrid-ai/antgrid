import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/delete_account_dialog.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpOpener(
  WidgetTester tester,
  void Function(bool) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(
        body: AbCarbonScope(
          child: Builder(
            builder: (context) => Center(
              child: CarbonButton(
                label: 'open',
                onPressed: () async =>
                    onResult(await DeleteAccountDialog.show(context)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('confirm is disabled until DELETE is typed', (tester) async {
    // flutter_test defaults to the android platform; the dialog is platform-
    // agnostic but keep desktop density deterministic.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    bool? result;
    await _pumpOpener(tester, (v) => result = v);

    // Tapping the destructive button before typing DELETE does nothing.
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.byType(CarbonModal), findsOneWidget); // dialog still open
    expect(result, isNull);

    // Anything but the exact word leaves it disabled.
    await tester.enterText(find.byType(TextField), 'delete');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    // Type the confirmation word, then the button works.
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(CarbonModal), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancel returns false', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    bool? result;
    await _pumpOpener(tester, (v) => result = v);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byType(CarbonModal), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('dismissing the modal answers no', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    bool? result;
    await _pumpOpener(tester, (v) => result = v);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ),
    );
    await tester.pumpAndSettle();
    expect(result, isFalse);

    debugDefaultTargetPlatformOverride = null;
  });
}
