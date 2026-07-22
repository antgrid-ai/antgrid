import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/widgets/operational_error_toaster.dart';

void main() {
  Widget wrap(List<Override> overrides) => ProviderScope(
    overrides: overrides,
    child: const MaterialApp(home: Scaffold(body: OperationalErrorToaster())),
  );

  testWidgets('toasts when a git checkout error arrives', (tester) async {
    final term = StreamController<TerminalState>.broadcast();
    addTearDown(term.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith((ref) => term.stream),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
      ]),
    );

    term.add(
      const TerminalState(projectId: 'p', gitCheckoutError: 'detached HEAD'),
    );
    await tester.pump(); // deliver stream event
    await tester.pump(); // build snackbar

    // The terminal service already stores a 'Checkout failed' fallback in
    // gitCheckoutError, so the toaster surfaces the raw message directly to
    // avoid "Checkout failed: Checkout failed".
    expect(find.text('detached HEAD'), findsOneWidget);
  });

  testWidgets('does NOT re-toast the same git error on a second emission', (
    tester,
  ) async {
    final term = StreamController<TerminalState>.broadcast();
    addTearDown(term.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith((ref) => term.stream),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
      ]),
    );

    term.add(
      const TerminalState(projectId: 'p', gitCheckoutError: 'detached HEAD'),
    );
    await tester.pump();
    await tester.pump();
    // Re-emit the SAME error (e.g. the focused-state provider re-yielding
    // currentState) — must not produce a second snackbar.
    term.add(
      const TerminalState(projectId: 'p', gitCheckoutError: 'detached HEAD'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('detached HEAD'), findsOneWidget);
  });

  testWidgets('the SAME message on a different project toasts again', (
    tester,
  ) async {
    // Regression guard for the focus-switch bug: de-dup is keyed by the
    // projectId carried on the state, not the focused id. An identical message
    // owned by a different project is a distinct error and must surface.
    final term = StreamController<TerminalState>.broadcast();
    addTearDown(term.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith((ref) => term.stream),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
      ]),
    );

    term.add(const TerminalState(projectId: 'a', gitCheckoutError: 'boom'));
    await tester.pump();
    await tester.pump();
    expect(find.text('boom'), findsOneWidget);

    term.add(const TerminalState(projectId: 'b', gitCheckoutError: 'boom'));
    await tester.pump();
    await tester.pump();
    // Two distinct projects each errored with 'boom' → two snackbars queued.
    expect(find.text('boom'), findsWidgets);
  });

  testWidgets('re-toasts the same git error after it clears', (tester) async {
    final term = StreamController<TerminalState>.broadcast();
    addTearDown(term.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith((ref) => term.stream),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
      ]),
    );

    term.add(
      const TerminalState(projectId: 'p', gitCheckoutError: 'detached HEAD'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('detached HEAD'), findsOneWidget);

    // Clear the error (null gitCheckoutError, same project) — this resets the
    // per-project de-dup key. Explicitly tear down the first snackbar (its 4s
    // auto-dismiss timer is unreliable under the test clock) so the slate is
    // clean and a re-appearance unambiguously proves the recurrence re-fired
    // rather than counting a lingering first toast.
    term.add(const TerminalState(projectId: 'p'));
    await tester.pump();
    await tester.pump();
    ScaffoldMessenger.of(
      tester.element(find.byType(OperationalErrorToaster)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('detached HEAD'), findsNothing);

    // Same error recurs — must toast AGAIN because the clear reset the key.
    term.add(
      const TerminalState(projectId: 'p', gitCheckoutError: 'detached HEAD'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('detached HEAD'), findsOneWidget);
  });

  testWidgets('toasts when a session error arrives', (tester) async {
    final sess = StreamController<SessionsState>.broadcast();
    addTearDown(sess.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith(
          (ref) => const Stream<TerminalState>.empty(),
        ),
        sessionsStateProvider.overrideWith((ref) => sess.stream),
      ]),
    );

    sess.add(const SessionsState(projectId: 'p', error: 'spawn failed'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Session error: spawn failed'), findsOneWidget);
  });

  testWidgets('re-toasts an identical git op feedback when the seq advances', (
    tester,
  ) async {
    // Regression guard for the repeat-discard / repeat-commit bug: two
    // consecutive discards both carry 'Discarded changes'. De-dup is keyed by
    // the op SEQ, not the message string, so the second result (seq advanced)
    // toasts again with no intervening null transition needed.
    final tree = StreamController<FileTreeState>.broadcast();
    addTearDown(tree.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith(
          (ref) => const Stream<TerminalState>.empty(),
        ),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
        fileTreeStateProvider.overrideWith((ref) => tree.stream),
      ]),
    );

    // First discard result arrives (seq 1) — expect a toast.
    tree.add(
      const FileTreeState(
        projectId: 'p',
        gitOpFeedback: 'Discarded changes',
        gitOpFeedbackSeq: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Discarded changes'), findsOneWidget);

    // Clear the slate so a re-appearance unambiguously proves a re-fire.
    ScaffoldMessenger.of(
      tester.element(find.byType(OperationalErrorToaster)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('Discarded changes'), findsNothing);

    // Second discard result, identical message but advanced seq — toasts AGAIN.
    tree.add(
      const FileTreeState(
        projectId: 'p',
        gitOpFeedback: 'Discarded changes',
        gitOpFeedbackSeq: 2,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Discarded changes'), findsOneWidget);
  });

  testWidgets('does NOT re-toast the same git op feedback at the same seq', (
    tester,
  ) async {
    // A re-emission of the same state (e.g. a focus-switch replay) carries the
    // same seq and must not produce a duplicate toast.
    final tree = StreamController<FileTreeState>.broadcast();
    addTearDown(tree.close);
    await tester.pumpWidget(
      wrap([
        terminalStateProvider.overrideWith(
          (ref) => const Stream<TerminalState>.empty(),
        ),
        sessionsStateProvider.overrideWith(
          (ref) => const Stream<SessionsState>.empty(),
        ),
        fileTreeStateProvider.overrideWith((ref) => tree.stream),
      ]),
    );

    tree.add(
      const FileTreeState(
        projectId: 'p',
        gitOpFeedback: 'Committed abc1234',
        gitOpFeedbackSeq: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Committed abc1234'), findsOneWidget);

    tree.add(
      const FileTreeState(
        projectId: 'p',
        gitOpFeedback: 'Committed abc1234',
        gitOpFeedbackSeq: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Committed abc1234'), findsOneWidget);
  });
}
