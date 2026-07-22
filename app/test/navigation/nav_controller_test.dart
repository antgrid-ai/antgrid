// app/test/navigation/nav_controller_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

NavLocation _loc(String projectId, {String? session}) => NavLocation(
  target: LocalProject(projectId),
  surface: WorkbenchSurface.workspace,
  sessionId: session,
);

void main() {
  late ProviderContainer c;
  setUp(() {
    c = ProviderContainer();
    addTearDown(c.dispose);
  });

  test('commit pushes history and dedupes identical current', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a'));
    nav.commit(_loc('b'));
    nav.commit(_loc('b')); // duplicate of current -> no-op
    final s = c.read(navControllerProvider);
    expect(s.past.length, 1); // only 'a'
    expect(s.current, _loc('b'));
    expect(s.future, isEmpty);
    expect(c.read(navControllerProvider).canBack, isTrue);
    expect(c.read(navControllerProvider).canForward, isFalse);
  });

  test('back/forward move cursor and apply target+surface to providers', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a'));
    nav.commit(_loc('b'));

    nav.back();
    expect(c.read(navControllerProvider).current, _loc('a'));
    expect(c.read(selectedRegistrationIdProvider), 'a');
    expect(c.read(navControllerProvider).canForward, isTrue);

    nav.forward();
    expect(c.read(navControllerProvider).current, _loc('b'));
    expect(c.read(selectedRegistrationIdProvider), 'b');
  });

  test('apply seeds pendingActiveSessionId on a project switch', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a', session: 's_a'));
    nav.commit(_loc('b', session: 's_b'));
    nav.back(); // back to project a, session s_a
    expect(c.read(pendingActiveSessionIdProvider), 's_a');
  });

  test('commit beyond cap drops the oldest entry', () {
    final nav = c.read(navControllerProvider.notifier);
    for (var i = 0; i < kNavHistoryCap + 5; i++) {
      nav.commit(_loc('p$i'));
    }
    final s = c.read(navControllerProvider);
    expect(s.past.length, kNavHistoryCap); // capped
  });

  test('commit clears the forward stack', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a'));
    nav.commit(_loc('b'));
    nav.back(); // future = [b]
    expect(c.read(navControllerProvider).canForward, isTrue);
    nav.commit(_loc('c')); // new branch
    expect(c.read(navControllerProvider).canForward, isFalse);
    expect(c.read(navControllerProvider).future, isEmpty);
  });

  test('apply preserves the focused project for a null-target location', () {
    final nav = c.read(navControllerProvider.notifier);
    // Focus a project (applyDeepLink writes providers AND records), then
    // deep-link to a surface-only (settings) location.
    nav.applyDeepLink(_loc('proj'));
    expect(c.read(selectedRegistrationIdProvider), 'proj');
    nav.applyDeepLink(
      const NavLocation(target: null, surface: WorkbenchSurface.appSettings),
    );
    // Surface follows the link, but the project must NOT be deselected.
    expect(c.read(workbenchSurfaceProvider), WorkbenchSurface.appSettings);
    expect(c.read(selectedRegistrationIdProvider), 'proj');
  });

  test('apply clears a stale pending session on a null-session switch', () {
    final nav = c.read(navControllerProvider.notifier);
    // A prior cross-project tap leaves a pending session queued for some project.
    c.read(pendingActiveSessionIdProvider.notifier).set('s_old');
    nav.commit(_loc('a'));
    // Switch to a different project with no session (e.g. a plain back/deep
    // link). The stale pending must be cleared, not carried into b's bootstrap.
    nav.applyDeepLink(_loc('b'));
    expect(c.read(selectedRegistrationIdProvider), 'b');
    expect(c.read(pendingActiveSessionIdProvider), isNull);
  });

  test('applyDeepLink writes providers and records', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(
      const NavLocation(
        target: LocalProject('deep'),
        surface: WorkbenchSurface.workspace,
      ),
    );
    expect(c.read(selectedRegistrationIdProvider), 'deep');
    expect(
      c.read(navControllerProvider).current!.target,
      const LocalProject('deep'),
    );
  });
}
