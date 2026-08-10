import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/handler_discovery.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('handlerAwayHintVisible', () {
    final t0 = DateTime(2026, 1, 1, 12);

    // Every gate open — the baseline the single-gate cases flip one at a time.
    bool visible({
      AgentWorkStatus? status = AgentWorkStatus.attention,
      DateTime? attentionSince,
      DateTime? now,
      bool sessionArmed = false,
      bool? agentObservable = true,
      bool handlerArmedOnce = false,
      bool dismissed = false,
    }) => handlerAwayHintVisible(
      status: status,
      attentionSince: attentionSince ?? t0,
      now: now ?? t0.add(kHandlerAwayHintAfter),
      sessionArmed: sessionArmed,
      agentObservable: agentObservable,
      firstRun: FirstRunState(
        handlerArmedOnce: handlerArmedOnce,
        handlerAwayHintDismissed: dismissed,
      ),
    );

    test('true at the threshold with every gate open', () {
      expect(visible(), isTrue);
      // Unknown coverage still hints: only an explicit "cannot watch" blocks.
      expect(visible(agentObservable: null), isTrue);
    });

    test('false under the threshold', () {
      expect(
        visible(
          now: t0.add(kHandlerAwayHintAfter - const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('false with no attention start', () {
      expect(
        handlerAwayHintVisible(
          status: AgentWorkStatus.attention,
          attentionSince: null,
          now: t0,
          sessionArmed: false,
          agentObservable: true,
          firstRun: const FirstRunState(),
        ),
        isFalse,
      );
    });

    test('false when the session is already armed', () {
      expect(visible(sessionArmed: true), isFalse);
    });

    test('false when the agent reports it cannot be watched', () {
      expect(visible(agentObservable: false), isFalse);
    });

    test('false once the user has ever armed', () {
      expect(visible(handlerArmedOnce: true), isFalse);
    });

    test('false once dismissed', () {
      expect(visible(dismissed: true), isFalse);
    });

    test('false when the status is not attention', () {
      expect(visible(status: AgentWorkStatus.working), isFalse);
      expect(visible(status: null), isFalse);
    });
  });

  group('handlerAwayAttentionSinceProvider', () {
    test('sets once on attention, resets on leaving it or switching session',
        () async {
      var now = DateTime(2026, 1, 1, 12);
      final container = ProviderContainer(
        overrides: [
          handlerAwayNowFnProvider.overrideWithValue(() => now),
          activeSessionIdProvider.overrideWith(
            () => ValueController<String?>(null),
          ),
          selectedRegistrationIdProvider.overrideWithValue('p1'),
          activeSessionProvider.overrideWith((_) => null),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        handlerAwayAttentionSinceProvider,
        (_, _) {},
      );
      expect(sub.read(), isNull);

      // Focus a session, then its status becomes attention → clock starts.
      container.read(activeSessionIdProvider.notifier).set('s1');
      container.read(remoteSessionStatusProvider.notifier)
          .setLocalSessionStatuses({
        'p1': {'s1': AgentWorkStatus.attention},
      });
      final started = DateTime(2026, 1, 1, 12);
      expect(sub.read(), started);

      // Repeated attention reads (a sibling's status churns) keep the original
      // timestamp even as the clock advances.
      now = DateTime(2026, 1, 1, 12, 3);
      container.read(remoteSessionStatusProvider.notifier)
          .setLocalSessionStatuses({
        'p1': {
          's1': AgentWorkStatus.attention,
          's2': AgentWorkStatus.working,
        },
      });
      expect(sub.read(), started);

      // Leaving attention resets.
      container.read(remoteSessionStatusProvider.notifier)
          .setLocalSessionStatuses({
        'p1': {'s1': AgentWorkStatus.working},
      });
      expect(sub.read(), isNull);

      // Back in attention, then focus moves to a non-blocked session → null.
      container.read(remoteSessionStatusProvider.notifier)
          .setLocalSessionStatuses({
        'p1': {'s1': AgentWorkStatus.attention},
      });
      expect(sub.read(), DateTime(2026, 1, 1, 12, 3));
      container.read(activeSessionIdProvider.notifier).set('s2');
      expect(sub.read(), isNull);
    });
  });
}
