import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Counts how many times it was mounted, so a test can tell a rebuild from a
/// remount.
class _Probe extends StatefulWidget {
  const _Probe();

  static int inits = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.inits++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 40);
}

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final FocusNode trigger = FocusNode();
  final FocusNode other = FocusNode();

  @override
  void dispose() {
    trigger.dispose();
    other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarbonButton(
          label: 'Open',
          focusNode: trigger,
          autofocus: true,
          onPressed: () {},
        ),
        Focus(focusNode: other, child: const SizedBox(width: 20, height: 20)),
      ],
    );
  }
}

final GlobalKey<_HostState> _hostKey = GlobalKey<_HostState>();

Future<void> _pumpHost(WidgetTester tester, Size size, {
  double textScale = 1,
  CarbonThemeData? theme,
}) async {
  await pumpCarbon(
    tester,
    _Host(key: _hostKey),
    size: size,
    textScale: textScale,
    theme: theme,
  );
  await tester.pump();
}

void main() {
  setUp(() => _Probe.inits = 0);

  testWidgets('crossing the compact breakpoint keeps the dialog body mounted', (
    tester,
  ) async {
    await _pumpHost(tester, const Size(400, 800));
    unawaited(
      showCarbonModal<void>(
        _hostKey.currentContext!,
        builder: (_) =>
            const CarbonModal(title: 'Rename', body: _Probe()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_Probe.inits, 1);
    final state = tester.state(find.byType(_Probe));

    await _pumpHost(tester, const Size(800, 600));
    await tester.pump();
    expect(_Probe.inits, 1);
    expect(tester.state(find.byType(_Probe)), same(state));

    await _pumpHost(tester, const Size(400, 800));
    await tester.pump();
    expect(_Probe.inits, 1);
  });

  testWidgets('toggling the frame to full screen keeps the body mounted', (
    tester,
  ) async {
    Widget modal({required bool fullScreen}) => Center(
      child: SizedBox(
        height: 500,
        child: CarbonModalFrame(
          fullScreen: fullScreen,
          child: const CarbonModal(title: 'Rename', body: _Probe()),
        ),
      ),
    );
    await pumpCarbon(
      tester,
      modal(fullScreen: false),
      size: const Size(800, 600),
    );
    expect(_Probe.inits, 1);
    await pumpCarbon(
      tester,
      modal(fullScreen: true),
      size: const Size(800, 600),
    );
    expect(_Probe.inits, 1);
  });

  testWidgets('focus moved by the caller after pop is not taken back', (
    tester,
  ) async {
    await _pumpHost(tester, const Size(800, 600));
    final host = _hostKey.currentState!;
    host.trigger.requestFocus();
    await tester.pump();
    final result = showCarbonModal<void>(
      _hostKey.currentContext!,
      builder: (_) => const CarbonModal(title: 'Rename', body: Text('Body')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    unawaited(result.then((_) => host.other.requestFocus()));
    Navigator.of(_hostKey.currentContext!, rootNavigator: true).pop();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(host.other.hasPrimaryFocus, isTrue);
  });

  testWidgets('header and footer that exceed the height keep Save reachable', (
    tester,
  ) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(tester.view.resetViewInsets);
    await _pumpHost(
      tester,
      const Size(844, 390),
      textScale: 2,
      theme: CarbonThemeData(density: CarbonDensity.touch),
    );
    unawaited(
      showCarbonModal<void>(
        _hostKey.currentContext!,
        builder: (_) => CarbonModal(
          label: 'Project',
          title: 'Rename project',
          body: const Text('Name'),
          actions: [
            CarbonModalAction(
              label: 'Cancel',
              kind: CarbonButtonKind.secondary,
              onPressed: () {},
            ),
            CarbonModalAction(label: 'Save', onPressed: () {}),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    final save = tester.getRect(find.text('Save'));
    expect(save.bottom, lessThanOrEqualTo(390 - 200));
    expect(save.top, greaterThanOrEqualTo(0));
  });

  testWidgets('title uses the 20/28 regular heading in compact density', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      const Center(child: CarbonModal(title: 'Rename', body: Text('Body'))),
      size: const Size(800, 600),
    );
    final style = tester.widget<Text>(find.text('Rename')).style!;
    expect(style.fontSize, 20);
    expect(style.fontWeight, FontWeight.w400);
  });
}
