import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/widgets/handler/handler_enable_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selecting Autopilot + Save returns the choice', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    HandlerConfigChoice? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showHandlerEnableSheet(
                    context,
                    enabled: false,
                    template: HandlerTemplate.watchdog,
                  );
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

    // Pick Autopilot, flip enable, save.
    await tester.tap(find.text('Autopilot'));
    await tester.pump();
    await tester.tap(find.text('Enable Handler'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.enabled, true);
    expect(result!.template, HandlerTemplate.autopilot);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('dismiss returns null', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    HandlerConfigChoice? result = const HandlerConfigChoice(
      enabled: true, template: HandlerTemplate.closer, model: null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showHandlerEnableSheet(
                    context,
                    enabled: false,
                    template: HandlerTemplate.watchdog,
                  );
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
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
