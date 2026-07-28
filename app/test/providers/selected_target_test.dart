import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';

void main() {
  test('selectedRegistrationIdProvider derives the id from the target', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(selectedRegistrationIdProvider), isNull);

    c.read(selectedTargetProvider.notifier).set(const RemoteProject(
      machineUuid: 'u',
      projectId: 'p',
    ));
    expect(c.read(selectedRegistrationIdProvider), 'u.p');

    c.read(selectedTargetProvider.notifier).set(null);
    expect(c.read(selectedRegistrationIdProvider), isNull);
  });

  test('selectProject sets a LocalProject target', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    selectProjectInContainer(c, 'proj-1');
    expect(c.read(selectedTargetProvider), const LocalProject('proj-1'));
    expect(c.read(selectedRegistrationIdProvider), 'proj-1');
  });

  test('selectedRegistrationIdProvider is null without a typed target', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(selectedRegistrationIdProvider), isNull);
  });

  test('selectedRegistrationIdProvider follows typed target changes', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    c.read(selectedTargetProvider.notifier).set(const LocalProject('typed'));
    expect(c.read(selectedRegistrationIdProvider), 'typed');

    c.read(selectedTargetProvider.notifier).set(const RemoteTarget.legacy(
      'agent.project',
    ));
    expect(c.read(selectedRegistrationIdProvider), 'agent.project');
  });

  testWidgets(
    'selectProject changes typed target without stale legacy shadowing',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              return Directionality(
                textDirection: TextDirection.ltr,
                child: Column(
                  children: [
                    GestureDetector(
                      key: const Key('select'),
                      onTap: () => selectProject(ref.container, 'proj-1'),
                      child: const Text('select'),
                    ),
                    Text('${ref.watch(selectedTargetProvider)}'),
                    Text('${ref.watch(selectedRegistrationIdProvider)}'),
                  ],
                ),
              );
            },
          ),
        ),
      );

      expect(find.text('null'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('select')));
      await tester.pump();

      final element = tester.element(find.byType(Consumer));
      final container = ProviderScope.containerOf(element);
      expect(
        container.read(selectedTargetProvider),
        const LocalProject('proj-1'),
      );
      expect(container.read(selectedRegistrationIdProvider), 'proj-1');
    },
  );

  test('typed local to remote target changes registration id', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    selectProjectInContainer(c, 'local-proj');
    c.read(selectedTargetProvider.notifier).set(const RemoteTarget.legacy(
      'agent.project',
    ));

    expect(c.read(selectedRegistrationIdProvider), 'agent.project');
  });
}
