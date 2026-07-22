import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a NEEDS YOU pill when escalations pending', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(const HandlerState.initial().copyWith(
              enabled: true,
              runState: HandlerRunState.needsYou,
              pendingEscalations: 3,
            )),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: HandlerHeaderControl()),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('NEEDS YOU'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('disabled Handler shows only the configure button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(const HandlerState.initial()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: HandlerHeaderControl()),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('WATCHING'), findsNothing);
    expect(find.textContaining('NEEDS YOU'), findsNothing);
    expect(find.byType(HandlerHeaderControl), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
