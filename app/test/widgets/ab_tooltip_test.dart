import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_tooltip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long tooltips wrap and retain their accessible label', (
    tester,
  ) async {
    const message =
        'Shared workspace — other sessions work in this directory, editing '
        'the same files and committing to the same branch.';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const Scaffold(
          body: Center(
            child: AbTooltip(
              message: message,
              triggerMode: TooltipTriggerMode.tap,
              child: Text('Workspace'),
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip(message), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Workspace')).getSemanticsData().tooltip,
      message,
    );
    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();

    final text = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == message,
    );
    expect(text, findsOneWidget);
    final size = tester.getSize(text);
    expect(size.width, lessThanOrEqualTo(280));
    expect(size.height, greaterThan(30));
    expect(tester.takeException(), isNull);
  }, semanticsEnabled: true);
}
