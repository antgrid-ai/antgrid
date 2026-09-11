// app/test/navigation/nav_controller_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/settings_section.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';

NavLocation _loc(String projectId, {String? session, WorkspaceView? view}) =>
    NavLocation(
      target: LocalProject(projectId),
      surface: WorkbenchSurface.workspace,
      sessionId: session,
      view: view,
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

  test('apply seeds pendingWorkspaceView for the shell to drain', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(_loc('a', view: WorkspaceView.git));
    expect(c.read(pendingWorkspaceViewProvider)?.value, WorkspaceView.git);
  });

  // Naming a tab in the project that is already focused is the whole point of
  // the field, so the write must not sit behind the project-switch branch.
  test('apply seeds pendingWorkspaceView without a project switch', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(_loc('a'));
    nav.applyDeepLink(_loc('a', view: WorkspaceView.preview));
    expect(c.read(pendingWorkspaceViewProvider)?.value, WorkspaceView.preview);
  });

  // The stamp is what lets a drain that runs much later tell that the value was
  // meant for somewhere else — nothing rewrites these providers when the user
  // walks away from the destination through the drawer.
  test('apply stamps the pending values with the project they are for', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(_loc('a', view: WorkspaceView.git));
    expect(
      c.read(pendingWorkspaceViewProvider)?.target,
      const LocalProject('a'),
    );
  });

  // A surface-only location overlays whatever project is focused, so the value
  // it leaves belongs to that project — not to "no project".
  test('apply stamps a surface-only location with the focused project', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(_loc('a'));
    nav.applyDeepLink(
      const NavLocation(
        target: null,
        surface: WorkbenchSurface.appSettings,
        settingsSection: SettingsSection.privacy,
      ),
    );
    expect(
      c.read(pendingSettingsSectionProvider)?.target,
      const LocalProject('a'),
    );
  });

  test('apply clears a stale pending view when the location names none', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(_loc('a', view: WorkspaceView.git));
    // A shell that was unmounted (or never mounted) leaves the view pending;
    // the next location must not inherit it.
    nav.applyDeepLink(_loc('b'));
    expect(c.read(pendingWorkspaceViewProvider), isNull);
  });

  test('back restores the view recorded with the entry', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a', view: WorkspaceView.terminals));
    nav.commit(_loc('b'));
    nav.back();
    expect(
      c.read(pendingWorkspaceViewProvider)?.value,
      WorkspaceView.terminals,
    );
  });

  // A location carrying a view is a distinct request even at the place history
  // already sits — otherwise back() could never answer it.
  test('commit records a location that names a view at the current place', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a'));
    nav.commit(_loc('a', view: WorkspaceView.git));
    expect(c.read(navControllerProvider).past.length, 1);
    expect(
      c.read(navControllerProvider).current,
      _loc('a', view: WorkspaceView.git),
    );
  });

  // The dedupe keys on the place, not on what a link asked for there: an in-app
  // re-tap names no view, and must stay the no-op it was before any link put one
  // in `current`.
  test('commit still dedupes a re-tap after a link left a view on current', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a', session: 's', view: WorkspaceView.git));
    nav.commit(_loc('a', session: 's'));
    expect(c.read(navControllerProvider).past, isEmpty);
    expect(
      c.read(navControllerProvider).current,
      _loc('a', session: 's', view: WorkspaceView.git),
    );
  });

  test('apply seeds pendingSettingsSection for the settings screen to '
      'drain', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(
      const NavLocation(
        target: null,
        surface: WorkbenchSurface.appSettings,
        settingsSection: SettingsSection.privacy,
      ),
    );
    expect(
      c.read(pendingSettingsSectionProvider)?.value,
      SettingsSection.privacy,
    );
    expect(c.read(workbenchSurfaceProvider), WorkbenchSurface.appSettings);
  });

  test('apply clears a stale pending section when the location names none', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(
      const NavLocation(
        target: null,
        surface: WorkbenchSurface.appSettings,
        settingsSection: SettingsSection.help,
      ),
    );
    // The settings screen was closed before it could drain; the next location
    // must not scroll on its behalf.
    nav.applyDeepLink(_loc('b'));
    expect(c.read(pendingSettingsSectionProvider), isNull);
  });

  test('back restores the settings section recorded with the entry', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(
      const NavLocation(
        target: null,
        surface: WorkbenchSurface.appSettings,
        settingsSection: SettingsSection.account,
      ),
    );
    nav.commit(_loc('b'));
    nav.back();
    expect(
      c.read(pendingSettingsSectionProvider)?.value,
      SettingsSection.account,
    );
  });

  test('apply seeds pendingFilePath for the explorer to drain', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(
      const NavLocation(
        target: LocalProject('a'),
        surface: WorkbenchSurface.workspace,
        view: WorkspaceView.files,
        file: 'lib/main.dart',
      ),
    );
    expect(c.read(pendingFilePathProvider)?.value, 'lib/main.dart');
    expect(c.read(pendingWorkspaceViewProvider)?.value, WorkspaceView.files);
  });

  test('apply clears a stale pending file when the location names none', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.applyDeepLink(
      const NavLocation(
        target: LocalProject('a'),
        surface: WorkbenchSurface.workspace,
        file: 'lib/main.dart',
      ),
    );
    // The explorer never mounted, so the file is still pending; the next
    // location must not open it in whatever project it lands on.
    nav.applyDeepLink(_loc('b'));
    expect(c.read(pendingFilePathProvider), isNull);
  });

  // A [NavLocation] can never ask for the agent transcript, so this write is
  // only ever the null half — and it is the half that matters: the drains run
  // in one post-frame callback with the agent's LAST, so a stamp a notification
  // route left pending would override the tab this location just named.
  test('apply drops an agent-page stamp the location did not name', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(_loc('a', view: WorkspaceView.git));
    nav.commit(_loc('b'));
    c.read(pendingAgentPageProvider.notifier).set((
      target: const LocalProject('a'),
      value: true,
    ));

    nav.back();

    expect(c.read(pendingAgentPageProvider), isNull);
    expect(c.read(pendingWorkspaceViewProvider)?.value, WorkspaceView.git);
  });

  test('back restores the file recorded with the entry', () {
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(
      const NavLocation(
        target: LocalProject('a'),
        surface: WorkbenchSurface.workspace,
        file: 'lib/main.dart',
      ),
    );
    nav.commit(_loc('b'));
    nav.back();
    expect(c.read(pendingFilePathProvider)?.value, 'lib/main.dart');
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
