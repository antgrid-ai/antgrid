// A pure table test over composeReadiness, no ProviderContainer — modelled on
// supervisor_status_test.dart's `.values` loops so an appended enum value is
// auto-covered rather than silently unreachable in the switch.
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/checkout_readiness.dart';

const _readyTerminal = TerminalState(attach: CheckoutAttachStatus.ready);

void main() {
  group('composeReadiness — remote ladder', () {
    test('every Climbing rung reads reachingMachine', () {
      for (final rung in ConnRung.values) {
        expect(
          composeReadiness(
            isRemote: true,
            sessionResolved: true,
            status: Climbing(rung),
            terminal: _readyTerminal,
          ),
          CheckoutReadiness.reachingMachine,
          reason: 'rung=$rung',
        );
      }
    });

    test('every Blocked reason reads blocked', () {
      for (final reason in BlockReason.values) {
        expect(
          composeReadiness(
            isRemote: true,
            sessionResolved: true,
            status: Blocked(reason),
            terminal: _readyTerminal,
          ),
          CheckoutReadiness.blocked,
          reason: 'reason=$reason',
        );
      }
    });

    test('Released reads cold', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: const Released(),
          terminal: _readyTerminal,
        ),
        CheckoutReadiness.cold,
      );
    });

    test('null status reads cold', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: null,
          terminal: _readyTerminal,
        ),
        CheckoutReadiness.cold,
      );
    });
  });

  group('composeReadiness — local mode skips the ladder', () {
    test(
      'a local checkout with a resolved session and a ready terminal reads '
      'ready even with a null status',
      () {
        expect(
          composeReadiness(
            isRemote: false,
            sessionResolved: true,
            status: null,
            terminal: _readyTerminal,
          ),
          CheckoutReadiness.ready,
        );
      },
    );
  });

  group('composeReadiness — Connected, session/terminal derivation', () {
    test('sessionResolved: false reads openingSession', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: false,
          status: const Connected(),
          terminal: _readyTerminal,
        ),
        CheckoutReadiness.openingSession,
      );
    });

    test('null terminal reads openingSession', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: const Connected(),
          terminal: null,
        ),
        CheckoutReadiness.openingSession,
      );
    });

    test('attach: unknown reads loadingScreen', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: const Connected(),
          terminal: const TerminalState(attach: CheckoutAttachStatus.unknown),
        ),
        CheckoutReadiness.loadingScreen,
      );
    });

    test('attach: attaching reads loadingScreen', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: const Connected(),
          terminal: const TerminalState(
            attach: CheckoutAttachStatus.attaching,
          ),
        ),
        CheckoutReadiness.loadingScreen,
      );
    });

    test('attach: failed reads stalled', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: const Connected(),
          terminal: const TerminalState(attach: CheckoutAttachStatus.failed),
        ),
        CheckoutReadiness.stalled,
      );
    });

    test('attach: ready reads ready', () {
      expect(
        composeReadiness(
          isRemote: true,
          sessionResolved: true,
          status: const Connected(),
          terminal: _readyTerminal,
        ),
        CheckoutReadiness.ready,
      );
    });
  });
}
