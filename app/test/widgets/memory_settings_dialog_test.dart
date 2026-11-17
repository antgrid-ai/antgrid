import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/widgets/memory/memory_settings_dialog.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide Fake;

import '../helpers/toast_host.dart';
import '../screens/memory_screen_test.dart' show Fake, statusJson;

const _machine = MemoryTarget.machine();

Map<String, dynamic> _project(
  String id, {
  String? label,
  bool paused = false,
  bool cataloged = true,
}) => {
  'project_id': id,
  'label': label ?? id,
  'memories': 1,
  'paused': paused,
  'cataloged': cataloged,
};

Fake _fake({
  bool paused = false,
  List<Map<String, dynamic>>? projects,
}) => Fake(status: statusJson(paused: paused))
  ..projects = {
    'projects': projects ?? [_project('p1', label: 'antgrid')],
    'memories': 1,
  };

/// Opens the dialog the way the screen does, from a context under the scope.
Future<void> _mount(
  WidgetTester tester,
  Fake fake, {
  Size? size,
  String? machineName,
}) async {
  tester.view.physicalSize = size ?? const Size(1280, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [memoryRequestProvider(_machine).overrideWithValue(fake.call)],
      child: MaterialApp(
        theme: buildAbTheme(),
        builder: abToastHostBuilder,
        home: AbCarbonScope(
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showMemorySettings(
                  context,
                  target: _machine,
                  onExportAll: () async {},
                  machineName: machineName,
                ),
                child: const Text('open'),
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

Iterable<Map<String, dynamic>> _settings(Fake fake) => fake.ops('settings');

/// The toggle's own target: the label text is not one in Carbon.
Finder _toggle(int index) => find.descendant(
  of: find.byType(CarbonToggle).at(index),
  matching: find.byType(CarbonInteraction),
);

void main() {
  testWidgets('the paused switch sends the machine-wide setting', (
    tester,
  ) async {
    final fake = _fake();
    await _mount(tester, fake);
    expect(find.text('Memory settings'), findsOneWidget);
    await tester.tap(_toggle(0));
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {'op': 'settings', 'paused': true});
  });

  testWidgets('a project switch sends that project alone', (tester) async {
    final fake = _fake();
    await _mount(tester, fake);
    await tester.tap(_toggle(1));
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {
      'op': 'settings',
      'project_id': 'p1',
      'project_paused': true,
    });
  });

  testWidgets('the modal holds no Ab widget', (tester) async {
    await _mount(tester, _fake());
    final found = <String>[];
    void visit(Element element) {
      final name = element.widget.runtimeType.toString();
      if (name.startsWith('Ab')) found.add(name);
      element.visitChildren(visit);
    }

    tester.element(find.byType(CarbonModal)).visitChildren(visit);
    expect(found, isEmpty);
  });

  testWidgets('a removed project is not listed', (tester) async {
    final fake = _fake(
      projects: [
        _project('p1', label: 'antgrid'),
        _project('gone', cataloged: false),
      ],
    );
    await _mount(tester, fake);
    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('gone'), findsNothing);
    expect(find.byType(CarbonToggle), findsNWidgets(2));
  });

  testWidgets('a paused machine locks every project switch off', (
    tester,
  ) async {
    final fake = _fake(paused: true);
    await _mount(tester, fake);
    expect(find.text('Saving is paused for every project.'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    final machine = tester.widget<CarbonToggle>(find.byType(CarbonToggle).first);
    final project = tester.widget<CarbonToggle>(find.byType(CarbonToggle).at(1));
    expect(machine.value, isFalse);
    expect(machine.onChanged, isNotNull);
    expect(project.value, isFalse);
    expect(project.onChanged, isNull);
    await tester.tap(_toggle(1));
    await tester.pumpAndSettle();
    expect(_settings(fake), isEmpty);
  });


  testWidgets('Turn off Memory asks first, then sends enabled false', (
    tester,
  ) async {
    final fake = _fake();
    await _mount(tester, fake);
    await tester.tap(find.text('Turn off Memory'));
    await tester.pumpAndSettle();
    expect(find.text('Turn off Memory?'), findsOneWidget);
    expect(_settings(fake), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_settings(fake), isEmpty);

    await tester.tap(find.text('Turn off Memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {'op': 'settings', 'enabled': false});
  });

  testWidgets('a local dialog says "this machine" in the footer and confirm', (
    tester,
  ) async {
    final fake = _fake();
    await _mount(tester, fake);
    expect(
      find.text(
        "Memories stay on this machine. Agents treat them as notes, not instructions: your repository's own docs always win.",
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Turn off Memory'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Agents stop saving and recalling memories. Everything saved stays on this machine, and you can turn Memory back on here.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a named machine appears in the footer and confirm', (
    tester,
  ) async {
    final fake = _fake();
    await _mount(tester, fake, machineName: 'Laptop');
    expect(
      find.text(
        "Memories stay on Laptop. Agents treat them as notes, not instructions: your repository's own docs always win.",
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Turn off Memory'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Agents stop saving and recalling memories. Everything saved stays on Laptop, and you can turn Memory back on here.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a FORBIDDEN settings mutation names the remote machine', (
    tester,
  ) async {
    final fake = _fake()
      ..hook = (request) {
        if (request['op'] == 'settings') {
          throw const MemoryException('FORBIDDEN', 'denied');
        }
        return null;
      };
    await _mount(tester, fake, machineName: 'Laptop');
    await tester.tap(_toggle(0));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Remote access is off on Laptop'),
      findsOneWidget,
    );
  });


  testWidgets('a long project list scrolls and keeps the footer in view', (
    tester,
  ) async {
    const size = Size(390, 844);
    final fake = _fake(
      projects: [
        for (var i = 0; i < 30; i++)
          _project('p$i', label: 'Project number ${i.toString().padLeft(2, '0')}'),
      ],
    );
    // The substituted test font roughly doubles label widths, so a row can
    // overflow sideways here and not on a device. Vertical overflow, which is
    // what a long list would cause, still fails the test.
    final onError = FlutterError.onError;
    final overflows = <String>[];
    FlutterError.onError = (details) {
      final text = details.exception.toString();
      if (text.contains('overflowed') && text.contains('on the right')) return;
      if (text.contains('overflowed')) overflows.add(text);
      onError?.call(details);
    };
    addTearDown(() => FlutterError.onError = onError);
    await _mount(tester, fake, size: size);
    expect(tester.takeException(), isNull);
    expect(overflows, isEmpty);
    for (final label in ['Export all memories', 'Turn off Memory']) {
      final center = tester.getCenter(find.text(label));
      expect(center.dy, inInclusiveRange(0, size.height));
    }
    final last = find.text('Project number 29');
    // Starting off-screen is what proves the body scrolls rather than clips.
    expect(tester.getTopLeft(last).dy, greaterThan(size.height));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    expect(tester.getCenter(last).dy, lessThan(size.height));
    expect(
      tester.getCenter(find.text('Turn off Memory')).dy,
      inInclusiveRange(0, size.height),
    );
  });
}
