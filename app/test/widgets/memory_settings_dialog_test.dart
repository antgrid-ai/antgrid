import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/widgets/memory/memory_settings_dialog.dart';
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

/// Mounts the dialog body directly, which is what the sheet hosts.
Future<void> _mount(WidgetTester tester, Fake fake, {Size? size}) async {
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
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 560,
              child: MemorySettingsDialog(
                target: _machine,
                onExportAll: () async {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Iterable<Map<String, dynamic>> _settings(Fake fake) => fake.ops('settings');

void main() {
  testWidgets('the paused switch sends the machine-wide setting', (
    tester,
  ) async {
    final fake = _fake();
    await _mount(tester, fake);
    expect(find.text('Memory settings'), findsOneWidget);
    await tester.tap(find.byType(AbSwitch).first);
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {'op': 'settings', 'paused': true});
  });

  testWidgets('a project switch sends that project alone', (tester) async {
    final fake = _fake();
    await _mount(tester, fake);
    await tester.tap(find.byType(AbSwitch).at(1));
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {
      'op': 'settings',
      'project_id': 'p1',
      'project_paused': true,
    });
  });

  testWidgets('tapping a row label toggles it as well', (tester) async {
    final fake = _fake();
    await _mount(tester, fake);
    await tester.tap(find.text('antgrid'));
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {
      'op': 'settings',
      'project_id': 'p1',
      'project_paused': true,
    });
    fake.calls.clear();
    await tester.tap(find.text('Let agents save memories'));
    await tester.pumpAndSettle();
    expect(_settings(fake).single, {'op': 'settings', 'paused': true});
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
    expect(find.byType(AbSwitch), findsNWidgets(2));
  });

  testWidgets('a paused machine locks every project switch off', (
    tester,
  ) async {
    final fake = _fake(paused: true);
    await _mount(tester, fake);
    expect(find.text('Saving is paused for every project.'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    final machine = tester.widget<AbSwitch>(find.byType(AbSwitch).first);
    final project = tester.widget<AbSwitch>(find.byType(AbSwitch).at(1));
    expect(machine.value, isFalse);
    expect(machine.onChanged, isNotNull);
    expect(project.value, isFalse);
    expect(project.onChanged, isNull);
    await tester.tap(find.text('antgrid'));
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
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // The substituted test font roughly doubles label widths, so the footer
    // buttons overflow sideways here and not on a device. Vertical overflow,
    // which is what a long list would cause, still fails the test.
    final onError = FlutterError.onError;
    final overflows = <String>[];
    FlutterError.onError = (details) {
      final text = details.exception.toString();
      if (text.contains('overflowed') && text.contains('on the right')) return;
      if (text.contains('overflowed')) overflows.add(text);
      onError?.call(details);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryRequestProvider(_machine).overrideWithValue(fake.call),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          builder: abToastHostBuilder,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showMemorySettings(
                  context,
                  target: _machine,
                  onExportAll: () async {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(overflows, isEmpty);
    for (final label in ['Export all memories', 'Turn off Memory']) {
      final center = tester.getCenter(find.text(label));
      expect(center.dy, inInclusiveRange(0, size.height));
    }
    final last = find.text('Project number 29');
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
