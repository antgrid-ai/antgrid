import 'dart:async';
import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_export_fixtures.dart';

const _target = MemoryTarget.project('project');
const _saveChannel = MethodChannel('ai.radhaai.antgrid/save_file');

Future<void> _mountExport(
  WidgetTester tester,
  MemoryRequest exportRequest, {
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        memoryRequestProvider(_target).overrideWithValue((request) async {
          if (request['op'] == 'export') return exportRequest(request);
          if (request['op'] == 'status') {
            return {
              'available': true,
              'enabled': true,
              'search_status': 'ready',
            };
          }
          return {'results': [], 'has_more': false};
        }),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        navigatorKey: navigatorKey,
        onGenerateInitialRoutes: navigatorKey == null
            ? null
            : (_) => [
                MaterialPageRoute<void>(
                  builder: (_) => const SizedBox.shrink(),
                ),
                PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) => const MemoryScreen(target: _target),
                  reverseTransitionDuration: const Duration(seconds: 1),
                ),
              ],
        home: navigatorKey == null ? const MemoryScreen(target: _target) : null,
        routes: navigatorKey == null
            ? const {}
            : {'/': (_) => const SizedBox.shrink()},
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Export JSON'));
  await tester.tap(find.text('Export JSON'));
  await tester.pump();
}

void main() {
  final savedFiles = <Map<Object?, Object?>>[];
  setUp(() {
    savedFiles.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_saveChannel, (call) async {
          savedFiles.add(Map<Object?, Object?>.from(call.arguments as Map));
          return true;
        });
  });
  tearDown(() {
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
    expect(find.textContaining('Correction conflict'), findsNothing);
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

  for (final continuation in [null, 'third-page']) {
    testWidgets(
      'popping during a page stops export before dismissal ends ($continuation)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
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
        }, navigatorKey: navigator);
        expect(calls, hasLength(2));
        final screen = tester.state(find.byType(MemoryScreen));
        navigator.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 1));
        expect(screen.mounted, isTrue);
        second.complete(
          memoryExportPage(
            records: [memoryExportRecord('two')],
            cursor: continuation,
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(screen.mounted, isTrue);
        expect(calls, hasLength(2));
        expect(savedFiles, isEmpty);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
