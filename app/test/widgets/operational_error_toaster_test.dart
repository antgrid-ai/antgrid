import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/operational_error_toaster.dart';
import 'package:antgrid/design/widgets/ab_toast.dart';

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
          selectedRegistrationIdProvider.overrideWith(
            (ref) => ref.watch(_focused),
          ),
          projectDisplayNameProvider.overrideWith(
            (ref, id) => const {
              'p1': 'Alpha',
              'p2': 'Beta',
              'machine-1.repo': 'Gamma',
            }[id],
          ),
        ],
        child: const MaterialApp(
          builder: abToastHostBuilder,
          home: Scaffold(body: _MountableToaster()),
        ),
      ),
    );
    return ProviderScope.containerOf(
      tester.element(find.byType(_MountableToaster)),
    );
  }

  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> clear(WidgetTester tester) async {
    clearAbToasts(tester.element(find.byType(_MountableToaster)));
    await tester.pumpAndSettle();
  }

  testWidgets('toasts every message, identical ones included', (tester) async {
    await pumpToaster(tester);

    sourceA.add(_focusedError('boom'));
    await deliver(tester);
    expect(find.text('boom'), findsOneWidget);
    await clear(tester);

    sourceA.add(_focusedError('boom'));
    await deliver(tester);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('a rebuilt source does not replay the last message', (
    tester,
  ) async {
    final container = await pumpToaster(tester);
    sourceA.add(_focusedError('from a'));
    await deliver(tester);
    await clear(tester);

    container.read(_source.notifier).set('b');
    await deliver(tester);
    sourceB.add(_focusedError('from b'));
    await deliver(tester);
    expect(find.text('from b'), findsOneWidget);
    await clear(tester);

    for (final target in ['a', 'b', 'a']) {
      container.read(_source.notifier).set(target);
      await deliver(tester);
      expect(find.text('from a'), findsNothing);
      expect(find.text('from b'), findsNothing);
    }
  });

  testWidgets('a replaced source is no longer listened to', (tester) async {
    final container = await pumpToaster(tester);
    container.read(_source.notifier).set('b');
    await deliver(tester);

    sourceA.add(_focusedError('from a'));
    await deliver(tester);
    expect(find.text('from a'), findsNothing);
  });

  testWidgets('remounting the toaster does not replay a shown message', (
    tester,
  ) async {
    final container = await pumpToaster(tester);
    sourceA.add(_focusedError('first'));
    await deliver(tester);
    await clear(tester);

    container.read(_toasterMounted.notifier).set(false);
    await deliver(tester);
    container.read(_toasterMounted.notifier).set(true);
    await deliver(tester);
    expect(find.text('first'), findsNothing);

    sourceA.add(_focusedError('second'));
    await deliver(tester);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('an error from a background project names it', (tester) async {
    await pumpToaster(tester);

    sourceA.add((entryId: 'p2', message: 'pre-commit hook failed'));
    await deliver(tester);

    expect(find.text('pre-commit hook failed'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  // A remote project's entryId is `<uuid>.<projectId>`, which no drawer row is
  // keyed by — a same-account machine is one row for all its projects.
  testWidgets('an error from a background remote project names it', (
    tester,
  ) async {
    await pumpToaster(tester);

    sourceA.add((entryId: 'machine-1.repo', message: 'stop refused'));
    await deliver(tester);

    expect(find.text('Gamma'), findsOneWidget);
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

  // Focus is read when the toast is shown: an error raised in p2 just before
  // the user switched to it is about what they are now looking at.
  testWidgets('background is judged against focus when shown', (
    tester,
  ) async {
    final container = await pumpToaster(tester);
    container.read(_focused.notifier).set('p2');

    sourceA.add((entryId: 'p2', message: 'pre-commit hook failed'));
    await deliver(tester);

    expect(find.text('pre-commit hook failed'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });
}

ProjectScoped<String> _focusedError(String message) =>
    (entryId: 'p1', message: message);

final _source = NotifierProvider<ValueController<String>, String>(
  () => ValueController('a'),
);
final _focused = NotifierProvider<ValueController<String>, String>(
  () => ValueController('p1'),
);
final _toasterMounted = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(true),
);

class _MountableToaster extends ConsumerWidget {
  const _MountableToaster();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(_toasterMounted)
      ? const OperationalErrorToaster(child: SizedBox.shrink())
      : const SizedBox.shrink();
}
