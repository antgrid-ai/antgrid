import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/operational_error_toaster.dart';

import '../helpers/toast_host.dart';

void main() {
  late StreamController<ProjectScoped<String>> sourceA;
  late StreamController<ProjectScoped<String>> sourceB;

  setUp(() {
    sourceA = StreamController<ProjectScoped<String>>.broadcast();
    sourceB = StreamController<ProjectScoped<String>>.broadcast();
  });
  tearDown(() async {
    await sourceA.close();
    await sourceB.close();
  });

  // The provider hands out a new stream each time the warm set changes or a
  // session resolves; `_source` stands in for that rebuild.
  Future<ProviderContainer> pumpToaster(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          operationalErrorsProvider.overrideWith(
            (ref) =>
                ref.watch(_source) == 'a' ? sourceA.stream : sourceB.stream,
          ),
          selectedRegistrationIdProvider.overrideWith((ref) => 'p1'),
          projectDisplayNameProvider.overrideWith(
            (ref, id) => const {'p1': 'Alpha', 'p2': 'Beta'}[id],
          ),
        ],
        child: const MaterialApp(
          builder: abToastHostBuilder,
          home: Scaffold(
            body: OperationalErrorToaster(child: SizedBox.shrink()),
          ),
        ),
      ),
    );
    return ProviderScope.containerOf(
      tester.element(find.byType(OperationalErrorToaster)),
    );
  }

  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a replaced source is no longer listened to', (tester) async {
    final container = await pumpToaster(tester);
    container.read(_source.notifier).set('b');
    await deliver(tester);

    sourceA.add(_focusedError('from a'));
    await deliver(tester);
    expect(find.text('from a'), findsNothing);
  });

  testWidgets('an error from a background project names it', (tester) async {
    await pumpToaster(tester);

    sourceA.add((entryId: 'p2', message: 'pre-commit hook failed'));
    await deliver(tester);

    expect(find.text('pre-commit hook failed'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('an error from the focused project names nothing', (
    tester,
  ) async {
    await pumpToaster(tester);

    sourceA.add(_focusedError('pre-commit hook failed'));
    await deliver(tester);

    expect(find.text('pre-commit hook failed'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });
}

ProjectScoped<String> _focusedError(String message) =>
    (entryId: 'p1', message: message);

final _source = NotifierProvider<ValueController<String>, String>(
  () => ValueController('a'),
);
