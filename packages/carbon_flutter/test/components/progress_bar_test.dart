import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _host(Widget child) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: 300, child: child),
);

final Finder _track = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_TrackPainter',
);

Size _trackSize(WidgetTester tester) => tester.getSize(_track);

RenderObject _trackRender(WidgetTester tester) => tester.renderObject(_track);

void main() {
  testWidgets('determinate bar fills its fraction of the track', (
    tester,
  ) async {
    final theme = CarbonThemeData();
    await pumpCarbon(
      tester,
      _host(const CarbonProgressBar(value: 0.5)),
      theme: theme,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      _trackRender(tester),
      paints
        ..rect(rect: const Rect.fromLTRB(0, 0, 300, 8), color: theme.colors.borderSubtle01)
        ..rect(rect: const Rect.fromLTRB(0, 0, 150, 8), color: theme.colors.interactive),
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('big is 8px and small is 4px tall', (tester) async {
    await pumpCarbon(tester, _host(const CarbonProgressBar(value: 0.2)));
    expect(_trackSize(tester).height, 8);
    await pumpCarbon(
      tester,
      _host(
        const CarbonProgressBar(value: 0.2, size: CarbonProgressBarSize.small),
      ),
    );
    expect(_trackSize(tester).height, 4);
  });

  testWidgets('indeterminate animates and stops under reduced motion', (
    tester,
  ) async {
    await pumpCarbon(tester, _host(const CarbonProgressBar()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await pumpCarbon(
      tester,
      _host(const CarbonProgressBar()),
      reduceMotion: true,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);

    final theme = CarbonThemeData();
    await pumpCarbon(
      tester,
      TickerMode(enabled: false, child: _host(const CarbonProgressBar())),
      theme: theme,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      _trackRender(tester),
      paints
        ..rect(color: theme.colors.borderSubtle01)
        ..rect(
          rect: const Rect.fromLTRB(112.5, 0, 187.5, 8),
          color: theme.colors.interactive,
        ),
    );
  });

  testWidgets('static indeterminate paints a centered band and never ticks', (
    tester,
  ) async {
    final theme = CarbonThemeData();
    await pumpCarbon(
      tester,
      _host(const CarbonProgressBar(animateIndeterminate: false)),
      theme: theme,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      _trackRender(tester),
      paints
        ..rect(color: theme.colors.borderSubtle01)
        ..rect(
          rect: const Rect.fromLTRB(112.5, 0, 187.5, 8),
          color: theme.colors.interactive,
        ),
    );
  });

  testWidgets('label, helper text and hideLabel', (tester) async {
    await pumpCarbon(
      tester,
      _host(
        const CarbonProgressBar(
          value: 0.4,
          label: 'Uploading',
          helperText: '5 of 12 files',
        ),
      ),
    );
    expect(find.text('Uploading'), findsOneWidget);
    expect(find.text('5 of 12 files'), findsOneWidget);

    await pumpCarbon(
      tester,
      _host(
        const CarbonProgressBar(
          value: 0.4,
          label: 'Uploading',
          hideLabel: true,
        ),
      ),
    );
    expect(find.text('Uploading'), findsNothing);
  });

  testWidgets('semantics name the bar and report its value', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      _host(
        const CarbonProgressBar(
          value: 0.4,
          label: 'Uploading',
          helperText: '5 of 12 files',
          hideLabel: true,
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(CarbonProgressBar)),
      matchesSemantics(
        label: 'Uploading',
        value: '40%',
        hint: '5 of 12 files',
      ),
    );

    await pumpCarbon(
      tester,
      _host(const CarbonProgressBar(label: 'Uploading')),
    );
    expect(
      tester.getSemantics(find.byType(CarbonProgressBar)),
      matchesSemantics(label: 'Uploading', value: 'Loading'),
    );
    handle.dispose();
  });

  testWidgets('finished and error fill the bar with their icon and color', (
    tester,
  ) async {
    final theme = CarbonThemeData();
    await pumpCarbon(
      tester,
      _host(
        const CarbonProgressBar(
          value: 0.1,
          label: 'Upload',
          status: CarbonProgressBarStatus.finished,
        ),
      ),
      theme: theme,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CarbonIcon), findsOneWidget);
    expect(tester.widget<CarbonIcon>(find.byType(CarbonIcon)).icon,
        CarbonIcons.checkmarkFilled);
    expect(
      _trackRender(tester),
      paints
        ..rect(color: theme.colors.borderSubtle01)
        ..rect(
          rect: const Rect.fromLTRB(0, 0, 300, 8),
          color: theme.colors.supportSuccess,
        ),
    );

    await pumpCarbon(
      tester,
      _host(
        const CarbonProgressBar(
          value: 0.1,
          label: 'Upload',
          helperText: 'Failed',
          status: CarbonProgressBarStatus.error,
        ),
      ),
      theme: theme,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<CarbonIcon>(find.byType(CarbonIcon)).icon,
        CarbonIcons.errorFilled);
    expect(
      _trackRender(tester),
      paints
        ..rect(color: theme.colors.borderSubtle01)
        ..rect(
          rect: const Rect.fromLTRB(0, 0, 300, 8),
          color: theme.colors.supportError,
        ),
    );
    expect(
      tester.widget<Text>(find.text('Failed')).style?.color,
      theme.colors.textError,
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('colors follow each of the four themes', (tester) async {
    for (final scheme in CarbonThemeScheme.values) {
      final theme = CarbonThemeData(scheme: scheme);
      await pumpCarbon(
        tester,
        _host(const CarbonProgressBar(value: 0.5)),
        theme: theme,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _trackRender(tester),
        paints
          ..rect(color: theme.colors.borderSubtle01)
          ..rect(color: theme.colors.interactive),
        reason: '$scheme',
      );
    }
  });
}
