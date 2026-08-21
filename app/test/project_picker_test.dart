import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/screens/project_picker_screen.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';

void main() {
  void emitTwo(FakeAgentTransport t) => t.emit('agent:projects', {
    'projects': [
      {
        'projectId': 'projA',
        'label': 'Project A',
        'path': '/work/a',
        'running': true,
      },
      {
        'projectId': 'projB',
        'label': 'Project B',
        'path': '/work/b',
        'running': false,
      },
    ],
  });

  testWidgets('renders an AbListRow per advertised project', (tester) async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);
    addTearDown(client.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: ProjectPickerScreen(client: client)),
      ),
    );
    emitTwo(t);
    await tester.pump();

    expect(find.byType(AbListRow), findsNWidgets(2));
    expect(find.text('Project A'), findsOneWidget);
    expect(find.text('Project B'), findsOneWidget);
    expect(find.text('/work/a'), findsOneWidget);
  });

  testWidgets('tapping Start on a stopped project sends project:start', (
    tester,
  ) async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);
    addTearDown(client.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: ProjectPickerScreen(client: client)),
      ),
    );
    emitTwo(t);
    await tester.pump();

    await tester.tap(find.text('Start'));
    await tester.pump();

    final sent = t.sent.firstWhere((m) => m['type'] == 'project:start');
    expect(sent['projectId'], 'projB');
  });

  testWidgets('tapping Open on a running project selects it', (tester) async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);
    addTearDown(client.dispose);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: ProjectPickerScreen(client: client)),
      ),
    );
    emitTwo(t);
    await tester.pump();

    expect(container.read(selectedRegistrationIdProvider), isNull);
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(container.read(selectedRegistrationIdProvider), 'projA');
  });

  testWidgets('a control:result error is surfaced as a banner', (tester) async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);
    addTearDown(client.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: ProjectPickerScreen(client: client)),
      ),
    );
    emitTwo(t);
    await tester.pump();

    // Agent rejects a start: { ok:false, error:{ code, message } }.
    t.emitJson({
      'type': 'control:result',
      'ok': false,
      'error': {
        'code': 'NOT_ALLOWED',
        'message': 'mobile access is disabled on this machine',
      },
    });
    await tester.pump();

    // NOT_ALLOWED gets human copy naming where the switch lives; the raw
    // code+message stays visible as the banner's detail line.
    expect(
      find.textContaining('Remote access is off on this machine'),
      findsOneWidget,
    );
    expect(
      find.text('NOT_ALLOWED: mobile access is disabled on this machine'),
      findsOneWidget,
    );
    // The list is still shown alongside the banner.
    expect(find.byType(AbListRow), findsNWidgets(2));
  });

  testWidgets('empty advertisement shows the empty state', (tester) async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);
    addTearDown(client.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: ProjectPickerScreen(client: client)),
      ),
    );
    await tester.pump();

    expect(find.text('No projects available'), findsOneWidget);
  });
}
