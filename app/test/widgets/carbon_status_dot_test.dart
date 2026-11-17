import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/widgets/agent_work_status_indicator.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

CarbonThemeData _white() => CarbonThemeData();
CarbonThemeData _g100() => CarbonThemeData.forBrightness(Brightness.dark);

Widget _harness(
  Widget child, {
  CarbonThemeData? theme,
  bool disableAnimations = false,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: CarbonTheme(
      data: theme ?? _white(),
      child: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

/// The decoration of the dot's painted circle.
BoxDecoration _decoration(WidgetTester tester) => tester
    .widget<DecoratedBox>(
      find.descendant(
        of: find.byType(CarbonStatusDot),
        matching: find.byType(DecoratedBox),
      ),
    )
    .decoration as BoxDecoration;

double _opacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(
        of: find.byType(CarbonStatusDot),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

/// Unmounts the tree so a pulsing dot's shared clock stops before the test
/// ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  group('CarbonWorkStatusDot colours', () {
    for (final entry in {'white': _white(), 'g100': _g100()}.entries) {
      for (final status in AgentWorkStatus.values) {
        testWidgets('${status.name} in ${entry.key}', (tester) async {
          final t = entry.value;
          await tester.pumpWidget(
            _harness(CarbonWorkStatusDot(status: status), theme: t),
          );
          final expected = agentWorkStatusDotColor(t, status)!;
          final d = _decoration(tester);
          if (status == AgentWorkStatus.done) {
            expect(d.border, isNotNull);
            expect((d.border! as Border).top.color, expected);
            expect(d.color, t.layer(1));
          } else {
            expect(d.border, isNull);
            expect(d.color, expected);
          }
        });
      }
    }
  });

  testWidgets('a hollow dot is a ring filled with the layer', (tester) async {
    final t = _g100();
    await tester.pumpWidget(
      _harness(
        CarbonLayer(
          level: 2,
          child: CarbonStatusDot(color: t.colors.iconSecondary, hollow: true),
        ),
        theme: t,
      ),
    );
    final d = _decoration(tester);
    expect(d.shape, BoxShape.circle);
    expect(d.color, t.layer(2));
    expect((d.border! as Border).top.color, t.colors.iconSecondary);
  });

  group('size', () {
    testWidgets('defaults to 8', (tester) async {
      await tester.pumpWidget(
        _harness(const CarbonStatusDot(color: Color(0xFF123456))),
      );
      expect(tester.getSize(find.byType(CarbonStatusDot)), const Size(8, 8));
    });

    testWidgets('takes an explicit size', (tester) async {
      await tester.pumpWidget(
        _harness(const CarbonStatusDot(color: Color(0xFF123456), size: 10)),
      );
      expect(tester.getSize(find.byType(CarbonStatusDot)), const Size(10, 10));
    });
  });

  group('pulse', () {
    testWidgets('animates opacity and scale', (tester) async {
      await tester.pumpWidget(
        _harness(const CarbonStatusDot(color: Color(0xFF123456), pulse: true)),
      );
      final start = _opacity(tester);
      await tester.pump(const Duration(milliseconds: 450));
      final mid = _opacity(tester);
      await tester.pump(const Duration(milliseconds: 450));
      final peak = _opacity(tester);

      expect(start, closeTo(0.45, 0.01));
      expect(mid, isNot(closeTo(start, 0.01)));
      expect(peak, closeTo(1, 0.01));
      expect(find.byType(Transform), findsWidgets);
      await _unmount(tester);
    });

    testWidgets('is static under disableAnimations', (tester) async {
      await tester.pumpWidget(
        _harness(
          const CarbonStatusDot(color: Color(0xFF123456), pulse: true),
          disableAnimations: true,
        ),
      );
      expect(find.byType(Opacity), findsNothing);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(Opacity), findsNothing);
    });

    testWidgets('is off by default', (tester) async {
      await tester.pumpWidget(
        _harness(const CarbonStatusDot(color: Color(0xFF123456))),
      );
      expect(find.byType(Opacity), findsNothing);
    });
  });

  group('semantics', () {
    testWidgets('is excluded without a label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _harness(const CarbonStatusDot(color: Color(0xFF123456))),
      );
      expect(
        find.descendant(
          of: find.byType(CarbonStatusDot),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('carries the label when given', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _harness(
          const CarbonWorkStatusDot(
            status: AgentWorkStatus.working,
            semanticLabel: 'Working',
          ),
        ),
      );
      expect(find.bySemanticsLabel('Working'), findsOneWidget);
      handle.dispose();
    });
  });

  group('CarbonLivenessDot', () {
    Future<void> pump(WidgetTester tester, DrawerLiveness l, CarbonThemeData t) =>
        tester.pumpWidget(
          _harness(
            CarbonLivenessDot(liveness: l, semanticLabel: l.name),
            theme: t,
          ),
        );

    for (final t in [_white(), _g100()]) {
      testWidgets('maps each state to its colour (${t.scheme.name})', (
        tester,
      ) async {
        await pump(tester, DrawerLiveness.connected, t);
        expect(_decoration(tester).color, t.colors.supportSuccess);

        await pump(tester, DrawerLiveness.failed, t);
        expect(_decoration(tester).color, t.colors.supportError);

        await pump(tester, DrawerLiveness.offline, t);
        final ring = _decoration(tester);
        expect((ring.border! as Border).top.color, t.colors.iconSecondary);
        expect(ring.color, t.layer(1));

        await pump(tester, DrawerLiveness.connecting, t);
        expect(_decoration(tester).color, t.colors.supportInfo);
        await _unmount(tester);
      });
    }

    testWidgets('only connecting pulses', (tester) async {
      for (final l in DrawerLiveness.values) {
        await pump(tester, l, _white());
        expect(
          find.byType(Opacity),
          l == DrawerLiveness.connecting ? findsOneWidget : findsNothing,
          reason: l.name,
        );
      }
      await _unmount(tester);
    });

    testWidgets('passes size and label through', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _harness(
          const CarbonLivenessDot(
            liveness: DrawerLiveness.connected,
            size: 10,
            semanticLabel: 'Connected',
          ),
        ),
      );
      expect(tester.getSize(find.byType(CarbonStatusDot)), const Size(10, 10));
      expect(find.bySemanticsLabel('Connected'), findsOneWidget);
      handle.dispose();
    });
  });

  group('sessionSpokenName', () {
    test('joins the facts in order', () {
      expect(
        sessionSpokenName(
          name: 'Fix auth',
          status: AgentWorkStatus.attention,
          agent: 'Claude Code',
          originText: 'antgrid on BuildBox',
          relTime: '2m',
          bypassesApprovals: true,
          isolation: 'isolated checkout',
          sharedWorkspace: true,
          deleting: true,
        ),
        'Fix auth, Needs you, Claude Code, antgrid on BuildBox, 2m, '
        'bypasses approvals, isolated checkout, shared workspace, deleting',
      );
    });

    test('skips what is null, empty or false', () {
      expect(
        sessionSpokenName(
          name: 'Fix auth',
          status: AgentWorkStatus.done,
          originText: '',
          relTime: '2m',
        ),
        'Fix auth, Done, 2m',
      );
    });

    test('appends extras last', () {
      expect(
        sessionSpokenName(
          name: 'Fix auth',
          status: AgentWorkStatus.working,
          deleting: true,
          extras: const ['Handler waiting on 2', 'started without Memory'],
        ),
        'Fix auth, Working, deleting, Handler waiting on 2, '
        'started without Memory',
      );
    });
  });
}
