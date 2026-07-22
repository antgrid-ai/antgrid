// app/test/navigation/nav_controller_session_sync_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

void main() {
  test(
    'settling activeSessionId fills the null session without pushing',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final nav = c.read(navControllerProvider.notifier);

      nav.commit(
        const NavLocation(
          target: LocalProject('a'),
          surface: WorkbenchSurface.workspace,
        ),
      ); // sessionId null at commit time
      final pastLenBefore = c.read(navControllerProvider).past.length;

      // Bootstrap resolves the active session.
      c.read(activeSessionIdProvider.notifier).set('resolved');
      // Flush the scheduler so the ref.listen callback runs regardless of whether
      // Riverpod delivers it synchronously or on a microtask.
      await Future<void>.delayed(Duration.zero);

      final s = c.read(navControllerProvider);
      expect(s.current!.sessionId, 'resolved'); // null refined to resolved
      expect(s.past.length, pastLenBefore); // NO new history entry
    },
  );

  test(
    'settling activeSessionId does NOT overwrite an explicit session',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final nav = c.read(navControllerProvider.notifier);

      // A session-switch commit already carries an explicit session.
      nav.commit(
        const NavLocation(
          target: LocalProject('a'),
          surface: WorkbenchSurface.workspace,
          sessionId: 's_explicit',
        ),
      );
      c.read(activeSessionIdProvider.notifier).set('s_explicit');
      await Future<void>.delayed(Duration.zero);

      expect(c.read(navControllerProvider).current!.sessionId, 's_explicit');
    },
  );
}
