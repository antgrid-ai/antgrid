// app/test/navigation/back_intent_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/navigation/back_intent.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

NavLocation _loc(String projectId) => NavLocation(
  target: LocalProject(projectId),
  surface: WorkbenchSurface.workspace,
);

void main() {
  late ProviderContainer c;
  late BackHandlerRegistry registry;

  setUp(() {
    c = ProviderContainer();
    addTearDown(c.dispose);
    registry = c.read(backHandlerRegistryProvider);
  });

  tearDown(() {
    backIntentClock = DateTime.now;
    backIntentExit = () => Future<void>.value();
  });

  group('registry dispatch', () {
    test(
      'runs handlers highest-priority first, ignoring registration order',
      () {
        final calls = <String>[];
        registry.register(
          priority: 100,
          onBack: () {
            calls.add('low');
            return false;
          },
        );
        registry.register(
          priority: 900,
          onBack: () {
            calls.add('high');
            return false;
          },
        );
        registry.register(
          priority: 500,
          onBack: () {
            calls.add('mid');
            return false;
          },
        );

        expect(registry.dispatch(), isFalse);
        expect(calls, ['high', 'mid', 'low']);
      },
    );

    test('stops at the first handler that consumes the press', () {
      var lowRan = false;
      registry.register(priority: 900, onBack: () => true);
      registry.register(
        priority: 100,
        onBack: () {
          lowRan = true;
          return true;
        },
      );

      expect(registry.dispatch(), isTrue);
      expect(lowRan, isFalse);
    });

    // The workspace panel keeps all five tabs mounted in an IndexedStack, so a
    // registration is permanent and says nothing about whether a press would do
    // anything. `hasActive` is what the title bar's chevron reads — gating it on
    // mere registration left it lit for the whole life of the route.
    test('hasActive ignores registered-but-idle handlers', () {
      var open = false;
      registry.register(
        priority: 500,
        isActive: () => open,
        onBack: () => open,
      );

      expect(registry.hasActive, isFalse);
      expect(registry.dispatch(), isFalse);

      open = true;
      expect(registry.hasActive, isTrue);
      expect(registry.dispatch(), isTrue);
    });

    test('dispatch skips an inactive handler and falls to the next', () {
      var idleRan = false;
      registry.register(
        priority: 900,
        isActive: () => false,
        onBack: () {
          idleRan = true;
          return true;
        },
      );
      registry.register(priority: 100, onBack: () => true);

      expect(registry.dispatch(), isTrue);
      expect(idleRan, isFalse);
    });

    test('unregister removes a handler', () {
      var ran = false;
      final token = registry.register(
        priority: 500,
        onBack: () {
          ran = true;
          return true;
        },
      );
      registry.unregister(token);

      expect(registry.dispatch(), isFalse);
      expect(ran, isFalse);
      expect(registry.length, 0);
    });
  });

  group('resolveBackIntent', () {
    test('a consumed handler stops before history', () {
      final nav = c.read(navControllerProvider.notifier);
      nav.commit(_loc('a'));
      nav.commit(_loc('b'));
      registry.register(priority: 500, onBack: () => true);

      expect(resolveBackIntent(c), isTrue);
      expect(c.read(navControllerProvider).current, _loc('b'));
      expect(c.read(navControllerProvider).past.length, 1);
    });

    test('declining handlers fall through to exactly one history step', () {
      final nav = c.read(navControllerProvider.notifier);
      nav.commit(_loc('a'));
      nav.commit(_loc('b'));
      registry.register(priority: 500, onBack: () => false);

      expect(resolveBackIntent(c), isTrue);
      expect(c.read(navControllerProvider).current, _loc('a'));
      expect(c.read(navControllerProvider).canForward, isTrue);
    });

    test('empty history without allowExit is a no-op', () {
      expect(resolveBackIntent(c), isFalse);
      expect(c.read(navControllerProvider).current, isNull);
      expect(c.read(backExitGateProvider), isNull);
    });

    // The single most important invariant: content pops must never touch
    // NavState, or closing a file after a back() would silently destroy the
    // forward stack (commit() clears `future`).
    test('a content pop leaves the forward stack intact', () {
      final nav = c.read(navControllerProvider.notifier);
      nav.commit(_loc('a'));
      nav.commit(_loc('b'));
      nav.back();
      expect(c.read(navControllerProvider).canForward, isTrue);

      registry.register(priority: 500, onBack: () => true);
      expect(resolveBackIntent(c), isTrue);

      expect(c.read(navControllerProvider).canForward, isTrue);
      expect(c.read(navControllerProvider).current, _loc('a'));
    });

    // focusedServiceOrNull returns null while the focused project's session is
    // unresolved; handlers decline rather than letting the façade throw.
    test('a handler that cannot resolve its service declines', () {
      final nav = c.read(navControllerProvider.notifier);
      nav.commit(_loc('a'));
      nav.commit(_loc('b'));
      registry.register(
        priority: 500,
        onBack: () {
          final service = focusedServiceOrNull(c, (s) => s.fileService);
          if (service == null) return false;
          return true;
        },
      );

      expect(resolveBackIntent(c), isTrue);
      expect(c.read(navControllerProvider).current, _loc('a'));
    });
  });

  group('exit gate', () {
    test('arms on the first exhausted press, exits on the second', () {
      var now = DateTime(2026, 1, 1, 12);
      backIntentClock = () => now;
      var exits = 0;
      backIntentExit = () async => exits++;

      expect(resolveBackIntent(c, allowExit: true), isTrue);
      expect(c.read(backExitGateProvider), now);
      expect(exits, 0);

      now = now.add(const Duration(milliseconds: 500));
      expect(resolveBackIntent(c, allowExit: true), isTrue);
      expect(c.read(backExitGateProvider), isNull);
    });

    test('re-arms instead of exiting once the window has passed', () {
      var now = DateTime(2026, 1, 1, 12);
      backIntentClock = () => now;
      backIntentExit = () async => fail('must not exit past the window');

      resolveBackIntent(c, allowExit: true);
      now = now.add(kBackExitWindow + const Duration(milliseconds: 1));
      expect(resolveBackIntent(c, allowExit: true), isTrue);
      expect(c.read(backExitGateProvider), now);
    });

    test('a consumed press in between disarms the gate', () {
      var now = DateTime(2026, 1, 1, 12);
      backIntentClock = () => now;
      backIntentExit = () async => fail('must not exit after a disarm');

      resolveBackIntent(c, allowExit: true);
      expect(c.read(backExitGateProvider), isNotNull);

      final token = registry.register(priority: 500, onBack: () => true);
      expect(resolveBackIntent(c, allowExit: true), isTrue);
      expect(c.read(backExitGateProvider), isNull);
      registry.unregister(token);

      // Back to a fresh arm, not an exit.
      expect(resolveBackIntent(c, allowExit: true), isTrue);
      expect(c.read(backExitGateProvider), now);
    });

    test('desktop (allowExit: false) never arms', () {
      backIntentExit = () async => fail('desktop must not exit');
      expect(resolveBackIntent(c), isFalse);
      expect(c.read(backExitGateProvider), isNull);
    });
  });
}
