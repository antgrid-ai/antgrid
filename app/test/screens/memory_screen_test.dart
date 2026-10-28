import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/design/widgets/ab_confirm_dialog.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/widgets/memory/memory_error.dart';
import 'package:antgrid/widgets/memory/memory_record_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const target = MemoryTarget.project('project');
Map<String, dynamic> status({
  bool enabled = false,
  bool paused = false,
  String search = 'ready',
}) => {
  'available': true,
  'enabled': enabled,
  'paused': paused,
  'project_paused': false,
  'search_status': search,
  'recovery_status': 'ready',
  'pending_operations': 0,
};
Map<String, dynamic> record() => {
  'id': 'memory-1',
  'content': 'A useful finding',
  'memory_type': 'task_state',
  'scope': 'task',
  'project_id': 'project',
  'task_id': 'session',
  'checkout_id': 'checkout',
  'applicability': 'Windows only',
  'evidence': ['file:source'],
  'source': {'actor': 'agent', 'agent_id': 'codex'},
  'lifecycle': 'expired',
  'created_at': 1,
  'updated_at': 1,
};

Future<void> mount(
  WidgetTester tester,
  MemoryRequest request, {
  Widget? child,
  MemoryTarget viewTarget = target,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [memoryRequestProvider(viewTarget).overrideWithValue(request)],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: child ?? MemoryScreen(target: viewTarget),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one-time enable and project pause remain distinct', (
    tester,
  ) async {
    var enabled = false;
    final calls = <Map<String, dynamic>>[];
    await mount(tester, (request) async {
      calls.add(request);
      if (request['op'] == 'settings') enabled = true;
      if (request['op'] == 'status' || request['op'] == 'settings') {
        return status(enabled: enabled);
      }
      return {'results': [], 'has_more': false};
    });
    expect(find.text('Enable memory'), findsOneWidget);
    await tester.tap(find.text('Enable memory'));
    await tester.pumpAndSettle();
    expect(calls, contains(equals({'op': 'settings', 'enabled': true})));
    expect(find.text('Pause saves from this project'), findsOneWidget);
    expect(find.text('Pause all agent saves'), findsNothing);
    await tester.tap(find.byType(AbSwitch).first);
    await tester.pumpAndSettle();
    expect(calls, contains(equals({'op': 'settings', 'project_paused': true})));
  });

  testWidgets('unavailable store is not rendered as an empty result', (
    tester,
  ) async {
    final calls = <String>[];
    await mount(tester, (request) async {
      calls.add(request['op'] as String);
      return {
        'available': false,
        'error': {'code': 'UNAVAILABLE', 'message': 'Store needs recovery'},
      };
    });
    expect(calls, ['status']);
    expect(find.text('Memory unavailable'), findsOneWidget);
    expect(find.textContaining('Store needs recovery'), findsOneWidget);
    expect(find.text('No memories in this view.'), findsNothing);
  });

  testWidgets('paused profile still permits history and narrow corrections', (
    tester,
  ) async {
    final calls = <Map<String, dynamic>>[];
    await mount(tester, (request) async {
      calls.add(request);
      if (request['op'] == 'get') return {'record': record()};
      if (request['op'] == 'save') {
        throw const MemoryException(
          'CORRECTION_CONFLICT',
          'Another revision won.',
        );
      }
      return status(enabled: true, paused: true);
    }, child: const MemoryRecordDetails(target: target, id: 'memory-1'));
    expect(calls.first, {'op': 'get', 'id': 'memory-1', 'history': true});
    await tester.scrollUntilVisible(
      find.text('Correct finding'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Correct finding'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save correction'));
    await tester.tap(find.text('Save correction'));
    await tester.pumpAndSettle();
    final save = calls.last['save'] as Map;
    expect(save['scope'], 'task');
    expect(save['restrict_to_checkout'], true);
    expect(save['supersedes'], 'memory-1');
    expect(save.containsKey('task_id'), false);
    expect(find.textContaining('Correction conflict.'), findsOneWidget);
    final key = calls.last['operation_key'];
    await tester.ensureVisible(find.text('Save correction'));
    await tester.tap(find.text('Save correction'));
    await tester.pumpAndSettle();
    expect(calls.last['operation_key'], key);
  });

  testWidgets('compact layout preserves applicability and excerpt warnings', (
    tester,
  ) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, (request) async {
      if (request['op'] == 'status') return status(enabled: true);
      return {
        'results': [
          {...record(), 'excerpted': true},
        ],
        'has_more': false,
      };
    });
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.textContaining('excerpt — open'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Windows only'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed deletion hides cached content and reports incomplete cleanup',
    (tester) async {
      await mount(tester, (request) async {
        if (request['op'] == 'get') return {'record': record()};
        throw const MemoryException(
          'CLEANUP_FAILED',
          'Retry through machine recovery.',
        );
      }, child: const MemoryRecordDetails(target: target, id: 'memory-1'));
      await tester.scrollUntilVisible(
        find.text('Forget memory'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Forget memory'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AbConfirmDialog),
          matching: find.text('Forget memory'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A useful finding'), findsNothing);
      expect(find.textContaining('Cleanup failed.'), findsOneWidget);
      expect(
        find.text('Open machine Memory to retry storage cleanup.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('machine initialization failure can retry store recovery', (
    tester,
  ) async {
    var failed = true;
    final calls = <Map<String, dynamic>>[];
    await mount(tester, (request) async {
      calls.add(request);
      if (request['op'] == 'repair') failed = false;
      if (request['op'] == 'status' || request['op'] == 'repair') {
        return failed
            ? {
                'available': false,
                'error': {'code': 'UNAVAILABLE', 'message': 'Database locked'},
              }
            : status();
      }
      return {'results': [], 'has_more': false};
    }, viewTarget: const MemoryTarget.machine());
    await tester.tap(find.text('Retry store recovery'));
    await tester.pumpAndSettle();
    expect(calls, contains(equals({'op': 'repair'})));
    expect(find.text('Enable memory'), findsOneWidget);
  });

  testWidgets('invalid search keeps the query field available for correction', (
    tester,
  ) async {
    await mount(tester, (request) async {
      if (request['op'] == 'status') return status(enabled: true);
      if (request['op'] == 'search') {
        throw const MemoryException(
          'INVALID_ARGUMENT',
          'Query must contain searchable text.',
        );
      }
      return {'results': [], 'has_more': false};
    });
    await tester.enterText(find.byType(TextField), '***');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Query must contain searchable text.'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Memory unavailable'), findsNothing);
    expect(find.text('No memories in this view.'), findsNothing);
  });

  test('unknown outcome is distinct from absence and cleanup failure', () {
    expect(
      memoryErrorCopy(TimeoutException('lost'), mutation: true),
      startsWith('Outcome unknown.'),
    );
    expect(
      memoryErrorCopy(const MemoryException('CLEANUP_FAILED', 'Disk busy')),
      startsWith('Cleanup failed.'),
    );
  });
}
