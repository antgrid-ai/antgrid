// The nav console is the channel an agent drives the app through: it must parse
// the same grammar the deep links use, actually apply the location, and report
// the result in one readable payload — including when the parse fails, which is
// otherwise indistinguishable from a no-op. It must also be absent unless the
// driver entry point asked for it.
import 'dart:convert';

import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/navigation/nav_console.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/navigation/nav_serialization.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _command = ValueKey('ab.nav.command');
const _state = ValueKey('ab.nav.state');

/// Mounts the console exactly as production does — from `MaterialApp.builder`,
/// wrapping the route — so the test sees the same ambient text style and layout
/// constraints the real bar gets.
Future<ProviderContainer> _pumpConsole(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => NavConsole(child: child!),
        home: const SizedBox.expand(),
      ),
    ),
  );
  return container;
}

Map<String, dynamic> _readState(WidgetTester tester) =>
    jsonDecode(tester.widget<Text>(find.byKey(_state)).data!)
        as Map<String, dynamic>;

Future<void> _submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_command), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  setUp(() {
    kNavConsoleEnabled = true;
    addTearDown(() => kNavConsoleEnabled = false);
  });

  testWidgets('a submitted uri navigates and is reported back', (tester) async {
    final container = await _pumpConsole(tester);
    expect(_readState(tester)['location'], isNull);

    await _submit(tester, 'antgrid://nav/local/p1?surface=workspace&view=git');

    const expected = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.git,
    );
    // Round-tripped through the codec rather than string-matched: the payload's
    // contract is that it names the location in the same grammar the command
    // took, not that it spells it in a particular field order.
    final reported = _readState(tester);
    expect(
      navLocationFromUri(Uri.parse(reported['location'] as String)),
      expected,
    );
    expect(reported['last'], 'ok');
    expect(reported['canBack'], isFalse);
    expect(reported['canForward'], isFalse);
    // The location was applied, not merely echoed.
    expect(container.read(navControllerProvider).current, expected);
    expect(
      container.read(pendingWorkspaceViewProvider)?.value,
      WorkspaceView.git,
    );
  });

  testWidgets('canBack tracks history built by successive commands', (
    tester,
  ) async {
    await _pumpConsole(tester);
    await _submit(tester, 'antgrid://nav/local/p1');
    await _submit(tester, 'antgrid://nav/local/p2');

    expect(_readState(tester)['canBack'], isTrue);
    expect(_readState(tester)['canForward'], isFalse);
  });

  // A refused link must not read as a successful one that did nothing.
  testWidgets(
    'an unparseable command reports the error and does not navigate',
    (tester) async {
      final container = await _pumpConsole(tester);
      await _submit(tester, 'https://example.com/nav/local/p1');

      final reported = _readState(tester);
      expect(reported['last'], startsWith('error'));
      expect(reported['location'], isNull);
      expect(container.read(navControllerProvider).current, isNull);
    },
  );

  testWidgets('the payload carries the visible workspace tab', (tester) async {
    final container = await _pumpConsole(tester);
    expect(_readState(tester)['view'], isNull);

    container
        .read(visibleWorkspaceViewProvider.notifier)
        .set(WorkspaceView.terminals);
    await tester.pump();

    expect(_readState(tester)['view'], 'terminals');
  });

  // The driver reaches the field with `tap`, which resolves its finder through
  // `hitTestable()` and aims at the widget's centre — so a bar that collapsed to
  // nothing would be undrivable while every `enterText`-based test above kept
  // passing (`enterText` focuses the EditableText directly and never hit-tests).
  // `warnIfMissed` is the flutter_test analogue of that hit test.
  testWidgets('the command field has a tappable size', (tester) async {
    await _pumpConsole(tester);

    expect(tester.getSize(find.byKey(_command)).height, greaterThan(0));
    expect(tester.getSize(find.byKey(_command)).width, greaterThan(0));

    await tester.tap(find.byKey(_command), warnIfMissed: true);
    await tester.pump();

    final editable = find.descendant(
      of: find.byKey(_command),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
  });

  // The console shares the app with a PTY, so it may never hold focus it was
  // not given — and must give it back the moment the command is in.
  testWidgets('the field is unfocused on mount and again after submit', (
    tester,
  ) async {
    await _pumpConsole(tester);
    final editable = find.descendant(
      of: find.byKey(_command),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isFalse);

    await _submit(tester, 'antgrid://nav/local/p1');

    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isFalse);
  });

  testWidgets('the console is absent when the flag is off', (tester) async {
    kNavConsoleEnabled = false;
    await _pumpConsole(tester);

    expect(find.byKey(_command), findsNothing);
    expect(find.byKey(_state), findsNothing);
    // The app it wraps is untouched.
    expect(find.byType(SizedBox), findsWidgets);
  });
}
