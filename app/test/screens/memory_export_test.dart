import 'dart:async';
import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/widgets/file_download.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../helpers/memory_export_fixtures.dart';
import '../helpers/toast_host.dart';

const _target = MemoryTarget.machine();
const _remoteTarget = MemoryTarget.machine(machineId: 'm1');
const _saveChannel = MethodChannel('ai.radhaai.antgrid/save_file');

enum _Entry { more, settings }

Future<void> _mountExport(
  WidgetTester tester,
  MemoryRequest exportRequest, {
  String? projectId,
  List<Map<String, dynamic>>? seen,
  Size size = const Size(1280, 820),
  MemoryTarget target = _target,
  String? machineName,
  _Entry entry = _Entry.more,
  List<Map<String, dynamic>>? localSeen,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Future<Map<String, dynamic>> answer(
    Map<String, dynamic> request,
    List<Map<String, dynamic>>? log,
  ) async {
    log?.add(request);
    if (request['op'] == 'export') return exportRequest(request);
    if (request['op'] == 'status') {
      return {'available': true, 'enabled': true, 'search_status': 'ready'};
    }
    if (request['op'] == 'projects') {
      return {'projects': <Object>[], 'memories': 0};
    }
    return {'results': [], 'has_more': false, 'total': 0};
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        memoryRequestProvider(target).overrideWithValue((r) => answer(r, seen)),
        if (target != _target)
          memoryRequestProvider(
            _target,
          ).overrideWithValue((r) => answer(r, localSeen)),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        builder: abToastHostBuilder,
        home: MemoryScreen(
          target: target,
          machineName: machineName,
          initialProjectId: projectId,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  switch (entry) {
    case _Entry.more:
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CarbonOverflowMenu && w.semanticLabel == 'More actions',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export memories'));
    case _Entry.settings:
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel == 'Memory settings',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export all memories'));
  }
  // The menu or modal closes over a few frames before its action runs.
  await tester.pumpAndSettle();
}

void main() {
  final savedFiles = <Map<Object?, Object?>>[];
  var saveResult = true;
  setUp(() {
    savedFiles.clear();
    saveResult = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_saveChannel, (call) async {
          savedFiles.add(Map<Object?, Object?>.from(call.arguments as Map));
          return saveResult;
        });
  });
  tearDown(() {
    debugShareOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_saveChannel, null);
  });

  testWidgets('downloads only the complete export without transport cursors', (
    tester,
  ) async {
    final first = memoryExportRecord('old', lifecycle: 'superseded');
    final second = memoryExportRecord('new', supersedes: 'old');
    final next = Completer<Map<String, dynamic>>();
    await _mountExport(tester, (request) async {
      if (request['cursor'] == null) {
        return memoryExportPage(records: [first], cursor: 'next');
      }
      return next.future;
    });
    expect(savedFiles, isEmpty);
    next.complete(memoryExportPage(records: [second]));
    await tester.pumpAndSettle();
    expect(savedFiles, hasLength(1));
    expect(savedFiles.single['name'], 'antgrid-memory.json');
    final bytes = (savedFiles.single['bytes'] as List).cast<int>();
    expect(jsonDecode(utf8.decode(bytes)), {
      'version': 1,
      'owner_id': 'owner',
      'exported_at': 1000,
      'records': [first, second],
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a project-filtered export is scoped and named for the project', (
    tester,
  ) async {
    final seen = <Map<String, dynamic>>[];
    await _mountExport(
      tester,
      (request) async => memoryExportPage(records: [memoryExportRecord('a')]),
      projectId: 'p1',
      seen: seen,
    );
    await tester.pumpAndSettle();
    expect(savedFiles, hasLength(1));
    expect(savedFiles.single['name'], 'antgrid-memory-p1.json');
    expect(seen.where((r) => r['op'] == 'export'), isNotEmpty);
    expect(
      seen.where((r) => r['op'] == 'export').every((r) => r['project_id'] == 'p1'),
      isTrue,
    );
    expect(find.text('Saved antgrid-memory-p1.json'), findsOneWidget);
    expect(find.text('Memories exported'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a second-page refusal discards data and explains retry', (
    tester,
  ) async {
    await _mountExport(tester, (request) async {
      if (request['cursor'] == null) {
        return memoryExportPage(
          records: [memoryExportRecord('one')],
          cursor: 'next',
        );
      }
      throw const MemoryException(
        'EXPORT_CHANGED',
        'Snapshot no longer exists',
      );
    });
    await tester.pumpAndSettle();
    expect(savedFiles, isEmpty);
    expect(find.textContaining('Start the export again'), findsOneWidget);
    expect(find.textContaining('Someone edited'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('closing during pagination stops later requests and download', (
    tester,
  ) async {
    final second = Completer<Map<String, dynamic>>();
    final calls = <Map<String, dynamic>>[];
    await _mountExport(tester, (request) async {
      calls.add(request);
      if (request['cursor'] == null) {
        return memoryExportPage(
          records: [memoryExportRecord('one')],
          cursor: 'second',
        );
      }
      return second.future;
    });
    expect(calls, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    second.complete(
      memoryExportPage(records: [memoryExportRecord('two')], cursor: 'third'),
    );
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(savedFiles, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('cancelling the Android save screen shows no toast', (
    tester,
  ) async {
    saveResult = false;
    await _mountExport(
      tester,
      (request) async => memoryExportPage(records: [memoryExportRecord('a')]),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(savedFiles, hasLength(1));
    expect(find.textContaining('Saved'), findsNothing);
    expect(find.textContaining("Couldn't"), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final entry in _Entry.values) {
    testWidgets('the compact header exports once via ${entry.name}', (
      tester,
    ) async {
      await _mountExport(
        tester,
        (request) async => memoryExportPage(records: [memoryExportRecord('a')]),
        size: const Size(390, 844),
        entry: entry,
      );
      await tester.pumpAndSettle();
      expect(savedFiles, hasLength(1));
      expect(savedFiles.single['name'], 'antgrid-memory.json');
      expect(find.text('Saved antgrid-memory.json'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('a remote target exports through the remote request only', (
    tester,
  ) async {
    final remote = <Map<String, dynamic>>[];
    final local = <Map<String, dynamic>>[];
    await _mountExport(
      tester,
      (request) async => request['cursor'] == null
          ? memoryExportPage(records: [memoryExportRecord('a')], cursor: 'next')
          : memoryExportPage(records: [memoryExportRecord('b')]),
      target: _remoteTarget,
      machineName: 'Laptop',
      seen: remote,
      localSeen: local,
    );
    await tester.pumpAndSettle();
    expect(remote.where((r) => r['op'] == 'export'), hasLength(2));
    expect(local.where((r) => r['op'] == 'export'), isEmpty);
    expect(savedFiles, hasLength(1));
    await tester.pumpAndSettle(const Duration(seconds: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a banner names the machine while export pages are fetched', (
    tester,
  ) async {
    final page = Completer<Map<String, dynamic>>();
    await _mountExport(
      tester,
      (request) => page.future,
      target: _remoteTarget,
      machineName: 'Laptop',
    );
    expect(find.text('Exporting memories from Laptop…'), findsOneWidget);
    page.complete(memoryExportPage(records: [memoryExportRecord('a')]));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('Exporting memories from Laptop…'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a local export banner names no machine', (tester) async {
    final page = Completer<Map<String, dynamic>>();
    await _mountExport(tester, (request) => page.future);
    expect(find.text('Exporting memories…'), findsOneWidget);
    page.complete(memoryExportPage(records: [memoryExportRecord('a')]));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('Exporting memories…'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('iOS hands the export to the share sheet and nothing else', (
    tester,
  ) async {
    final shared = <ShareParams>[];
    debugShareOverride = (params) async {
      shared.add(params);
      return const ShareResult('x', ShareResultStatus.success);
    };
    await _mountExport(
      tester,
      (request) async => memoryExportPage(records: [memoryExportRecord('a')]),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(shared, hasLength(1));
    expect(shared.single.fileNameOverrides, ['antgrid-memory.json']);
    expect(savedFiles, isEmpty);
    expect(find.textContaining('Saved'), findsNothing);
    expect(find.textContaining("Couldn't"), findsNothing);
    expect(find.text('Memories exported'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a failing share sheet says the export was not shared', (
    tester,
  ) async {
    debugShareOverride = (params) async => throw StateError('no sheet');
    await _mountExport(
      tester,
      (request) async => memoryExportPage(records: [memoryExportRecord('a')]),
    );
    await tester.pumpAndSettle();
    expect(find.text("Couldn't share antgrid-memory.json"), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
