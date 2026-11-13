import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_segmented.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/design/widgets/ab_search_field.dart';
import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/widgets/command_output_overlay.dart';
import 'package:antgrid/widgets/diff_viewer.dart';
import 'package:antgrid/widgets/carbon_choice_tile.dart';
import 'package:antgrid/widgets/session_fork_dialog.dart';

import 'test_harness.dart';

const _android = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android});
const _windows = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows});

void _phone(WidgetTester tester, {double width = 360}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

double? _fontSizeOf(InlineSpan span) {
  if (span is! TextSpan) return null;
  // Deepest wins: Text.rich wraps the code span in a root carrying the
  // ambient default size.
  for (final c in span.children ?? const <InlineSpan>[]) {
    final f = _fontSizeOf(c);
    if (f != null) return f;
  }
  return span.style?.fontSize;
}

Future<double> _diffCodeFontSize(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: DiffViewer(
            path: 'lib/a.dart',
            gitStatus: 'M',
            diff: '@@ -1,1 +1,1 @@\n-old\n+final marker = 1;\n',
            additions: 1,
            deletions: 1,
            onViewFile: () {},
            onClose: () {},
            onSendToAgent: (context, message) async {},
          ),
        ),
      ),
    ),
  );
  final rich = tester
      .widgetList<RichText>(find.byType(RichText))
      .firstWhere((r) => r.text.toPlainText().contains('marker'));
  return _fontSizeOf(rich.text)!;
}

Future<void> _openFork(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: AbCarbonScope(
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => promptSessionFork(context, isolatedSource: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('fork dialog workspace choice', () {
    testWidgets('desktop: two tiles, both inside the dialog', (tester) async {
      await _openFork(tester);
      final tiles = find.byType(CarbonChoiceTile);
      expect(tiles, findsNWidgets(2));
      final label = tester.getRect(find.text('Workspace'));
      for (final tile in tiles.evaluate()) {
        final rect = tester.getRect(find.byWidget(tile.widget));
        expect(rect.left, greaterThanOrEqualTo(label.left));
        expect(rect.height, greaterThanOrEqualTo(32));
      }
      expect(tester.takeException(), isNull);
    }, variant: _windows);

    testWidgets('phone: tiles are 44 targets and never overflow', (
      tester,
    ) async {
      _phone(tester);
      await _openFork(tester);
      final tiles = find.byType(CarbonChoiceTile);
      expect(tiles, findsNWidgets(2));
      for (final tile in tiles.evaluate()) {
        final rect = tester.getRect(find.byWidget(tile.widget));
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(rect.right, lessThanOrEqualTo(360));
      }
      expect(tester.takeException(), isNull);
    }, variant: _android);
  });

  group('diff code font follows the platform in force', () {
    testWidgets('android renders the mobile code size', (tester) async {
      expect(await _diffCodeFontSize(tester), AbTokens.fontSm);
      expect(AbTokens.fontSm, 13);
    }, variant: _android);

    testWidgets('windows after android renders the desktop code size', (
      tester,
    ) async {
      expect(AbTokens.fontSm, 12);
      expect(await _diffCodeFontSize(tester), 12);
    }, variant: _windows);
  });

  group('single-line text fields', () {
    Future<void> pumpFields(WidgetTester tester, double scale) async {
      await pumpAntgrid(
        tester,
        MediaQuery(
          data: MediaQueryData(
            size: tester.view.physicalSize,
            textScaler: TextScaler.linear(scale),
          ),
          child: const SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AbTextField(key: Key('plain')),
                SizedBox(height: 8),
                AbSearchField(key: Key('search')),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('phone: a field is a 44 target and never clips its line', (
      tester,
    ) async {
      _phone(tester, width: 320);
      for (final scale in [1.0, 1.5, 2.0]) {
        await pumpFields(tester, scale);
        for (final key in const [Key('plain'), Key('search')]) {
          final box = tester.getSize(find.byKey(key));
          expect(
            box.height,
            greaterThanOrEqualTo(AbTokens.tapTargetMin),
            reason: '$key @$scale',
          );
          final editable = find.descendant(
            of: find.byKey(key),
            matching: find.byType(EditableText),
          );
          RenderEditable? render;
          void visit(RenderObject r) {
            if (r is RenderEditable) render = r;
            r.visitChildren(visit);
          }

          visit(tester.renderObject(editable));
          final line = render!.preferredLineHeight;
          expect(
            tester.getSize(editable).height,
            greaterThanOrEqualTo(line),
            reason: '$key clips its line @$scale',
          );
        }
      }
    }, variant: _android);

    testWidgets('desktop: defaults are unchanged', (tester) async {
      await pumpFields(tester, 1.0);
      expect(tester.getSize(find.byKey(const Key('plain'))).height, 32);
      expect(
        tester.getSize(find.byKey(const Key('search'))).height,
        AbTokens.rowHeightMd,
      );
    }, variant: _windows);
  });

  group('segmented cells', () {
    Future<void> pumpSeg(WidgetTester tester) => pumpAntgrid(
      tester,
      MediaQuery(
        data: MediaQueryData(size: tester.view.physicalSize),
        child: AbSegmented<int>(
          segments: const [
            AbSegment(value: 1, label: 'Schedules'),
            AbSegment(value: 2, label: 'Runs'),
          ],
          selected: 1,
          onSelect: (_) {},
        ),
      ),
    );

    Size cell(WidgetTester tester) => tester.getSize(
      find
          .ancestor(
            of: find.text('SCHEDULES'),
            matching: find.byType(GestureDetector),
          )
          .first,
    );

    testWidgets('phone: each cell is at least 44 tall', (tester) async {
      _phone(tester);
      await pumpSeg(tester);
      expect(cell(tester).height, greaterThanOrEqualTo(AbTokens.tapTargetMin));
    }, variant: _android);

    testWidgets('desktop: cells stay compact', (tester) async {
      await pumpSeg(tester);
      expect(cell(tester).height, lessThan(AbTokens.rowHeightMd));
    }, variant: _windows);
  });

  group('command output overlay bar', () {
    Future<double> barHeight(WidgetTester tester) async {
      final controller = StreamController<CommandState>.broadcast();
      addTearDown(controller.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commandStateProvider.overrideWith((ref) => controller.stream),
            selectedRegistrationIdProvider.overrideWithValue('p'),
            focusedCheckoutIdProvider.overrideWith((ref) => 'a'),
            terminalStateProvider.overrideWith(
              (ref) => const Stream<TerminalState>.empty(),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            home: const Scaffold(
              body: Stack(children: [CommandOutputOverlay()]),
            ),
          ),
        ),
      );
      controller.add(
        CommandState(
          current: CommandExecution(
            commandName: 'test',
            projectId: 'p',
            status: CommandStatus.running,
            output: CommandOutput()..append('building'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(
          find.descendant(
            of: find.byType(CommandOutputOverlay),
            matching: find.byType(AnimatedContainer),
          ).first,
        ) + const Offset(40, 24),
      );
      await tester.pumpAndSettle();
      return tester
          .getSize(
            find.descendant(
              of: find.byType(CommandOutputOverlay),
              matching: find.byType(AnimatedContainer),
            ).first,
          )
          .height;
    }

    testWidgets('phone: the collapsed header is 44 inside its border', (tester) async {
      _phone(tester);
      expect(await barHeight(tester), AbTokens.tapTargetMin + 2);
      expect(tester.takeException(), isNull);
    }, variant: _android);

    testWidgets('desktop: the collapsed bar stays 48', (tester) async {
      expect(await barHeight(tester), 48);
      expect(tester.takeException(), isNull);
    }, variant: _windows);
  });
}
