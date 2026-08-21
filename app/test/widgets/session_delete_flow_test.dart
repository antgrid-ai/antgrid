import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart';
import 'package:antgrid/widgets/session_delete_flow.dart';

/// One recorded delete attempt — the pair the ladder is actually responsible
/// for, since force and deleteBranch destroy different things.
typedef _Attempt = ({bool? force, bool? deleteBranch});

/// A deleter that answers each attempt from [answers] in order and records what
/// it was asked. An answer is either `true`/`false` or an exception to raise.
class _Deleter {
  _Deleter(this.answers);

  final List<Object> answers;
  final attempts = <_Attempt>[];

  Future<bool> call({bool? force, bool? deleteBranch}) async {
    attempts.add((force: force, deleteBranch: deleteBranch));
    final answer = answers[attempts.length - 1];
    if (answer is Exception) throw answer;
    return answer as bool;
  }
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return ctx;
}

Future<SessionDeleteResult> _run(
  WidgetTester tester,
  BuildContext context, {
  required String checkoutKind,
  required _Deleter deleter,
  Future<void> Function(WidgetTester tester)? drive,
}) async {
  final result = confirmAndDeleteSession(
    context: context,
    sessionName: 'Fix auth bug',
    checkoutKind: checkoutKind,
    sharedBody: 'Shared-surface body.',
    delete: deleter.call,
  );
  await tester.pumpAndSettle();
  if (drive != null) await drive(tester);
  return result;
}

/// Confirms whatever dialog is open, then settles.
Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Clears a reported refusal so its dismissal timer cannot outlive the test.
Future<void> _dismissToast(WidgetTester tester) async {
  ScaffoldMessenger.of(
    tester.element(find.byType(Scaffold)),
  ).removeCurrentSnackBar();
  await tester.pumpAndSettle();
}

void main() {
  // Three arms, not two: the bridge removes a checkout only for the kinds it
  // recognises, so a shared session, a managed one, and one this build cannot
  // name are three different promises about what deletion leaves behind.
  testWidgets('a shared session is asked about without mentioning isolation', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final deleter = _Deleter([true]);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'main',
      deleter: deleter,
      drive: (t) async {
        expect(find.text('Delete session?'), findsOneWidget);
        expect(
          find.text('Shared-surface body. This cannot be undone.'),
          findsOneWidget,
        );
        await _tap(t, 'Delete');
      },
    );
    expect(result, SessionDeleteResult.deleted);
  });

  testWidgets('a managed checkout names what deleting it removes', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'managed-worktree',
      deleter: _Deleter([true]),
      drive: (t) async {
        expect(find.text('Delete isolated session?'), findsOneWidget);
        // The surface's own body survives verbatim — this arm may only ADD what
        // a managed checkout costs, never restate what deleting one does.
        expect(find.textContaining('Shared-surface body.'), findsOneWidget);
        expect(
          find.textContaining('removes its isolated working directory'),
          findsOneWidget,
        );
        expect(find.textContaining('Its branch is kept'), findsOneWidget);
        await _tap(t, 'Delete');
      },
    );
    expect(result, SessionDeleteResult.deleted);
  });

  // The forward pin: an unknown kind still gets the isolated TITLE, because it
  // is certainly not the shared tree — but the shared BODY, because nothing in
  // the app can say what the bridge will remove for a kind it has to guess at.
  testWidgets('an unknown checkout kind claims isolation and nothing more', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'dev-container',
      deleter: _Deleter([true]),
      drive: (t) async {
        expect(find.text('Delete isolated session?'), findsOneWidget);
        expect(
          find.text('Shared-surface body. This cannot be undone.'),
          findsOneWidget,
        );
        expect(find.textContaining('isolated working directory'), findsNothing);
        await _tap(t, 'Delete');
      },
    );
    expect(result, SessionDeleteResult.deleted);
  });

  testWidgets('uncommitted changes offer force alone, never branch deletion', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final deleter = _Deleter([
      const SessionOperationException('WORKTREE_DIRTY', 'dirty'),
      true,
    ]);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'managed-worktree',
      deleter: deleter,
      drive: (t) async {
        await _tap(t, 'Delete');
        expect(
          find.text('Delete isolated session with uncommitted changes?'),
          findsOneWidget,
        );
        // Keeping the branch preserves nothing here — the work at risk was
        // never committed — so offering to delete it would be a second
        // destructive choice with no upside to weigh it against.
        expect(find.byType(AbSwitch), findsNothing);
        await _tap(t, 'Force delete');
      },
    );
    expect(result, SessionDeleteResult.deleted);
    expect(deleter.attempts, [
      // The first attempt is always non-destructive: the refusal it earns is
      // what the second question is built from.
      (force: null, deleteBranch: null),
      (force: true, deleteBranch: false),
    ]);
  });

  testWidgets('unpushed commits offer branch deletion as a separate opt-in', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final deleter = _Deleter([
      const SessionOperationException('WORKTREE_UNPUSHED', 'unpushed'),
      true,
    ]);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'managed-worktree',
      deleter: deleter,
      drive: (t) async {
        await _tap(t, 'Delete');
        expect(
          find.text('Delete isolated session with unpushed commits?'),
          findsOneWidget,
        );
        expect(
          find.text('Also delete the branch and its commits'),
          findsOneWidget,
        );
        await t.tap(find.byType(AbSwitch));
        await t.pumpAndSettle();
        await _tap(t, 'Force delete');
      },
    );
    expect(result, SessionDeleteResult.deleted);
    // deleteBranch rides its own flag: folding it into force would destroy
    // commits on the strength of an answer about the working directory.
    expect(deleter.attempts.last, (force: true, deleteBranch: true));
  });

  testWidgets('the force retry is the last one — a second refusal ends it', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final deleter = _Deleter([
      const SessionOperationException('WORKTREE_DIRTY', 'dirty'),
      const SessionOperationException('WORKTREE_DIRTY', 'still dirty'),
    ]);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'managed-worktree',
      deleter: deleter,
      drive: (t) async {
        await _tap(t, 'Delete');
        await _tap(t, 'Force delete');
      },
    );
    expect(result, SessionDeleteResult.failed);
    expect(deleter.attempts, hasLength(2));
    // A ladder that re-asked on its own refusal would loop the user through the
    // same dialog with nothing changed between rungs.
    expect(
      find.text('Delete isolated session with uncommitted changes?'),
      findsNothing,
    );
    expect(find.text('dirty'), findsNothing);
    await _dismissToast(tester);
  });

  testWidgets('a refusal with no second question is reported, not retried', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final deleter = _Deleter([
      const SessionOperationException('WORKTREE_MISSING', 'gone'),
    ]);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'managed-worktree',
      deleter: deleter,
      drive: (t) async => _tap(t, 'Delete'),
    );
    expect(result, SessionDeleteResult.failed);
    expect(deleter.attempts, hasLength(1));
    // The product copy, not the bridge's own wording — the code is the contract
    // and the message is not.
    expect(find.text(friendlyErrorCopy('WORKTREE_MISSING')!), findsOneWidget);
    expect(find.text('gone'), findsNothing);
    await _dismissToast(tester);
  });

  testWidgets('an unmapped code falls back to the bridge message', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'main',
      deleter: _Deleter([
        const SessionOperationException('DELETE_FAILED', 'Disk is on fire.'),
      ]),
      drive: (t) async => _tap(t, 'Delete'),
    );
    expect(result, SessionDeleteResult.failed);
    expect(find.text('Disk is on fire.'), findsOneWidget);
    await _dismissToast(tester);
  });

  testWidgets('cancelling the first question never reaches the deleter', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final deleter = _Deleter([true]);
    final result = await _run(
      tester,
      ctx,
      checkoutKind: 'managed-worktree',
      deleter: deleter,
      drive: (t) async => _tap(t, 'Cancel'),
    );
    expect(result, SessionDeleteResult.cancelled);
    expect(deleter.attempts, isEmpty);
  });
}
