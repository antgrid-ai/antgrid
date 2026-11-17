import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/account_machines.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/widgets/memory/memory_list.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/toast_host.dart';

const _machine = MemoryTarget.machine();

class _Catalog extends AgentCatalogNotifier {
  @override
  Map<String, AgentDescriptor> build() => const {
    'claude-code': AgentDescriptor(
      tool: 'claude-code',
      label: 'Claude Code',
      chatCapable: true,
      judgeCapable: false,
      handlerTerminal: false,
      handlerChat: false,
    ),
  };
}

final _record = {
  'id': 'm1',
  'content': 'Content of m1',
  'memory_type': 'note',
  'scope': 'project',
  'project_id': 'p1',
  'applicability': 'Windows only',
  'evidence': ['src/a.dart'],
  'source': {'actor': 'agent', 'agent_id': 'claude-code'},
  'lifecycle': 'active',
  'created_at': DateTime.now()
      .subtract(const Duration(days: 2))
      .millisecondsSinceEpoch,
  'updated_at': 1,
};

Future<Map<String, dynamic>> _answer(Map<String, dynamic> request) async =>
    switch (request['op']) {
      'status' => {
        'available': true,
        'enabled': true,
        'paused': false,
        'project_paused': false,
        'search_status': 'ready',
        'recovery_status': 'ready',
        'pending_operations': 0,
        'failed_operations': 0,
        'failures': <Object>[],
      },
      'projects' => {
        'projects': [
          {'project_id': 'p1', 'label': 'antgrid', 'memories': 1},
        ],
        'memories': 1,
        'earlier_versions': 0,
      },
      'get' => {'record': _record, 'earlier': <Object>[]},
      _ => {
        'results': [_record],
        'has_more': false,
        'total': 1,
      },
    };

Future<void> _mount(
  WidgetTester tester,
  Size size,
  Widget home, {
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) answer = _answer,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        memoryRequestProvider(_machine).overrideWithValue(answer),
        agentCatalogProvider.overrideWith(_Catalog.new),
        accountMachinesProvider.overrideWithValue(const {}),
        machinesSettlingProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        builder: abToastHostBuilder,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The names of every `Ab*` widget under the screen's Carbon scope, skipping
/// the agent mark: its logo is content imagery and builds Ab widgets of its
/// own. The pattern needs a capital after `Ab` so framework widgets such as
/// `AbsorbPointer` do not match.
List<String> _abWidgetsInScope(WidgetTester tester) {
  final found = <String>[];
  void visit(Element element) {
    final widget = element.widget;
    final name = widget.runtimeType.toString();
    if (name == 'AbAgentMark') return;
    if (RegExp(r'^Ab[A-Z]').hasMatch(name)) found.add(name);
    element.visitChildren(visit);
  }

  tester.element(find.byType(AbCarbonScope)).visitChildren(visit);
  return found;
}

void main() {
  for (final (name, size) in [
    ('wide', const Size(1280, 820)),
    ('compact', const Size(390, 844)),
  ]) {
    testWidgets('the $name screen is one Carbon scope with no Ab widget', (
      tester,
    ) async {
      await _mount(tester, size, const MemoryScreen(target: _machine));
      expect(find.text('Content of m1'), findsWidgets);
      expect(find.byType(AbCarbonScope), findsOneWidget);
      expect(_abWidgetsInScope(tester), isEmpty);
    });
  }

  testWidgets('the placeholder is its own Carbon scope with no Ab widget', (
    tester,
  ) async {
    await _mount(tester, const Size(1280, 820), const MemorySurface());
    expect(find.text('Connect a machine to manage memories'), findsOneWidget);
    expect(find.byType(AbCarbonScope), findsOneWidget);
    expect(_abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the compact placeholder is Carbon too', (tester) async {
    await _mount(tester, const Size(390, 844), const MemorySurface());
    expect(find.byType(AbCarbonScope), findsOneWidget);
    expect(_abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('header and toolbar targets are at least 44 on iOS', (
    tester,
  ) async {
    await _mount(
      tester,
      const Size(390, 844),
      const MemoryScreen(target: _machine),
    );
    void expectTarget(Finder finder, String what) {
      expect(finder, findsWidgets, reason: what);
      for (final element in finder.evaluate()) {
        final size = tester.getSize(find.byWidget(element.widget));
        expect(size.height, greaterThanOrEqualTo(44), reason: '$what height');
      }
    }

    expectTarget(
      find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Memory settings',
      ),
      'settings button',
    );
    expectTarget(
      find.byWidgetPredicate(
        (w) => w is CarbonOverflowMenu && w.semanticLabel == 'More actions',
      ),
      'more menu',
    );
    expectTarget(find.byType(CarbonSearch), 'search');
    expectTarget(find.byType(CarbonMenuButton), 'project and kind pickers');
    expectTarget(
      find.byWidgetPredicate(
        (w) => w is CarbonTag && w.label == 'Earlier versions',
      ),
      'earlier versions tag',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('toolbar labels sit on their menu text baseline', (
    tester,
  ) async {
    // The test font gives every size the same proportions, which would let
    // centred labels pass; real Plex metrics are what expose the offset.
    await tester.runAsync(() async {
      final loader = FontLoader(
        'packages/${CarbonTypography.package}/${CarbonTypography.sansFamily}',
      );
      for (final file in ['IBMPlexSans-Regular.ttf', 'IBMPlexSans-SemiBold.ttf']) {
        loader.addFont(
          rootBundle.load(
            'packages/${CarbonTypography.package}/assets/fonts/$file',
          ),
        );
      }
      await loader.load();
    });
    await _mount(
      tester,
      const Size(1280, 820),
      const MemoryScreen(target: _machine),
    );
    double baseline(Finder text) {
      final box = tester.renderObject<RenderBox>(text);
      return box.localToGlobal(Offset.zero).dy +
          box.getDryBaseline(box.constraints, TextBaseline.alphabetic)!;
    }

    for (final (label, value) in [
      ('Project', 'All projects'),
      ('Kind', 'All kinds'),
    ]) {
      expect(
        baseline(find.text(label)),
        moreOrLessEquals(baseline(find.text(value)), epsilon: 0.5),
        reason: label,
      );
    }
  });

  testWidgets('a disclosure label lines up with the section text', (
    tester,
  ) async {
    await _mount(
      tester,
      const Size(1280, 820),
      const MemoryScreen(target: _machine),
    );
    expect(
      tester.getTopLeft(find.text('Technical details')).dx,
      moreOrLessEquals(
        tester.getTopLeft(find.text('Applies when')).dx,
        epsilon: 0.5,
      ),
    );
  });
  testWidgets('phone notices scroll away with the list', (tester) async {
    const problem = '1 running session started without Memory.';
    // An iPhone SE with the keyboard up.
    await _mount(
      tester,
      const Size(375, 387),
      const MemoryScreen(target: _machine),
      answer: (request) async => switch (request['op']) {
        'status' => {
          ...await _answer(request),
          'search_status': 'unavailable',
          'recovery_status': 'cleanup_failed',
          'pending_operations': 2,
          'failed_operations': 1,
          'failures': [
            {'code': 'conflict', 'target_id': 'm1'},
          ],
          'sessions_without_memory': [
            {'project_id': 'p1', 'session_id': 's1', 'name': 'Fix the build'},
          ],
        },
        _ => await _answer(request),
      },
    );
    expect(tester.takeException(), isNull);
    expect(find.text(problem).hitTestable(), findsOne);
    expect(
      tester.getSize(find.byType(MemoryListPane)).height,
      greaterThan(CarbonSpacing.spacing09),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text(problem).hitTestable(), findsNothing);
    expect(find.text('Content of m1').hitTestable(), findsOne);
  });

  testWidgets('a phone notice stays above the empty state', (tester) async {
    await _mount(
      tester,
      const Size(375, 387),
      const MemoryScreen(target: _machine),
      answer: (request) async => switch (request['op']) {
        'status' => {
          ...await _answer(request),
          'pending_operations': 1,
        },
        'list' || 'search' => {
          'results': <Object>[],
          'has_more': false,
          'total': 0,
        },
        _ => await _answer(request),
      },
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('1 save is waiting'), findsOne);
    expect(find.text('No memories yet'), findsOne);
  });

  testWidgets('a list row names itself with what its content shows', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mount(
      tester,
      const Size(390, 844),
      const MemoryScreen(target: _machine),
    );
    // The row hides its content from semantics, so the project and agent
    // reach a screen reader only through its name.
    expect(
      find.bySemanticsLabel(RegExp(r'^Content of m1\n.*antgrid.*Claude Code')),
      findsOne,
    );
    semantics.dispose();
  });
}
