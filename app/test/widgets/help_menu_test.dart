import 'dart:async';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/providers/app_version.dart';
import 'package:antgrid/widgets/help_menu.dart';
import 'package:antgrid/widgets/settings/legal_notices_sheet.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens a [CarbonMenu] holding only the Help submenu, the way the account
/// footer does.
class _HelpHost extends ConsumerStatefulWidget {
  const _HelpHost({this.opened, this.shared});

  final void Function(String)? opened;
  final void Function(Rect?)? shared;

  @override
  ConsumerState<_HelpHost> createState() => _HelpHostState();
}

class _HelpHostState extends ConsumerState<_HelpHost> {
  final _controller = CarbonPopupController();
  Rect? _origin;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CarbonMenu(
      controller: _controller,
      entries: [
        helpMenu(
          context: context,
          ref: ref,
          shareOrigin: _origin,
          openUrl: (ctx, url) async {
            expect(Navigator.of(ctx).canPop(), isFalse);
            widget.opened?.call(url);
          },
          openChat: (ctx, _) async {
            expect(Navigator.of(ctx).canPop(), isFalse);
            widget.opened?.call('chat');
          },
          openLogs: (ctx, origin) async {
            expect(Navigator.of(ctx).canPop(), isFalse);
            widget.shared?.call(origin);
          },
        ),
      ],
      child: Builder(
        builder: (anchor) => GestureDetector(
          onTap: () {
            final box = anchor.findRenderObject()! as RenderBox;
            setState(() => _origin = box.localToGlobal(Offset.zero) & box.size);
            _controller.open();
          },
          child: const Text('Open'),
        ),
      ),
    );
  }
}

Future<void> _pumpHelp(
  WidgetTester tester, {
  Future<String> Function()? version,
  void Function(String)? opened,
  void Function(Rect?)? shared,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appVersionLabelProvider.overrideWith(
          (_) => version?.call() ?? Future.value('1.2.3 (456)'),
        ),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: AbCarbonScope(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _HelpHost(opened: opened, shared: shared),
            ),
          ),
        ),
      ),
    ),
  );
  await _openHelp(tester);
}

Future<void> _openHelp(WidgetTester tester) async {
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Help'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'help actions dispatch the existing destinations after dismissal',
    (tester) async {
      final opened = <String>[];
      await _pumpHelp(tester, opened: opened.add);
      final destinations = {
        'Getting started': 'https://antgrid.ai/get-started',
        'Chat with support': 'chat',
        'Support centre': 'https://antgrid.ai/support',
        'Source code': 'https://github.com/antgrid-ai/antgrid',
      };
      for (final entry in destinations.entries) {
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(opened.last, entry.value);
        // The anchor stays mounted, so a closed menu is read off its items.
        expect(find.text('Help'), findsNothing);
        await _openHelp(tester);
      }
    },
  );

  testWidgets('version resolves while Help remains open', (tester) async {
    final version = Completer<String>();
    await _pumpHelp(tester, version: () => version.future);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Version 1.2.3 (456)'), findsNothing);
    version.complete('1.2.3 (456)');
    await tester.pumpAndSettle();
    expect(find.text('Version 1.2.3 (456)'), findsOneWidget);
  });

  testWidgets('bundled legal notices open after dismissing Help', (
    tester,
  ) async {
    await _pumpHelp(tester);
    await tester.tap(find.text('Licences & notices'));
    await tester.pumpAndSettle();
    expect(find.text('Help'), findsNothing);
    expect(find.byType(LegalNoticesSheet), findsOneWidget);
    expect(
      find.textContaining('Mozilla Public License Version 2.0'),
      findsOneWidget,
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('mobile shares logs with the surviving account-menu anchor', (
      tester,
    ) async {
      Rect? origin;
      await _pumpHelp(tester, shared: (value) => origin = value);
      expect(find.text('Share logs'), findsOneWidget);
      expect(find.text('Open log folder'), findsNothing);
      await tester.tap(find.text('Share logs'));
      await tester.pumpAndSettle();
      expect(origin, isNotNull);
      expect(origin!.width, greaterThan(0));
      expect(find.text('Help'), findsNothing);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('desktop exposes Open log folder', (tester) async {
    await _pumpHelp(tester);
    expect(find.text('Open log folder'), findsOneWidget);
    expect(find.text('Share logs'), findsNothing);
  }, variant: TargetPlatformVariant.desktop());
}
