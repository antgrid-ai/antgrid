// app/test/navigation/nav_serialization_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/navigation/nav_serialization.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/settings_section.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

void main() {
  void roundTrips(NavLocation loc) {
    final uri = navLocationToUri(loc);
    expect(navLocationFromUri(uri), equals(loc), reason: uri.toString());
  }

  test('round-trips local target with session', () {
    roundTrips(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        sessionId: 'sess1',
      ),
    );
  });

  test('round-trips remote project target', () {
    roundTrips(
      const NavLocation(
        target: RemoteProject(machineUuid: 'm-uuid', projectId: 'proj2'),
        surface: WorkbenchSurface.workspace,
      ),
    );
  });

  test('round-trips legacy remote target', () {
    roundTrips(
      NavLocation(
        target: RemoteTarget.legacy('agent-dev-id'),
        surface: WorkbenchSurface.workspace,
        sessionId: 'sX',
      ),
    );
  });

  test('round-trips settings and devices surfaces (no target)', () {
    roundTrips(
      const NavLocation(target: null, surface: WorkbenchSurface.appSettings),
    );
    roundTrips(
      const NavLocation(target: null, surface: WorkbenchSurface.remoteDevices),
    );
  });

  test(
    'round-trips null-target workspace (defensive encoding is symmetric)',
    () {
      roundTrips(
        const NavLocation(target: null, surface: WorkbenchSurface.workspace),
      );
    },
  );

  test('round-trips a view on every project target shape', () {
    roundTrips(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        view: WorkspaceView.git,
      ),
    );
    roundTrips(
      const NavLocation(
        target: RemoteProject(machineUuid: 'm-uuid', projectId: 'proj2'),
        surface: WorkbenchSurface.workspace,
        sessionId: 'sess1',
        view: WorkspaceView.terminals,
      ),
    );
    roundTrips(
      NavLocation(
        target: RemoteTarget.legacy('agent-dev-id'),
        surface: WorkbenchSurface.workspace,
        view: WorkspaceView.handler,
      ),
    );
  });

  test('round-trips every view the workspace can show', () {
    for (final view in WorkspaceView.values) {
      roundTrips(
        NavLocation(
          target: const LocalProject('proj1'),
          surface: WorkbenchSurface.workspace,
          view: view,
        ),
      );
    }
  });

  test('unrecognised view value degrades to null, keeping the target', () {
    final loc = navLocationFromUri(
      Uri.parse('antgrid://nav/local/proj1?surface=newSession&view=bogus'),
    );
    expect(loc, isNotNull);
    expect(loc!.view, isNull);
    expect(loc.target, const LocalProject('proj1'));
    expect(loc.surface, WorkbenchSurface.newSession);
  });

  test('uri with no view param parses with a null view', () {
    final loc = navLocationFromUri(
      Uri.parse('antgrid://nav/local/proj1?surface=workspace&session=sess1'),
    );
    expect(loc, isNotNull);
    expect(loc!.view, isNull);
    expect(loc.sessionId, 'sess1');
  });

  test('surface-only locations ignore a view param', () {
    for (final seg in ['settings', 'devices', 'workspace']) {
      expect(
        navLocationFromUri(Uri.parse('antgrid://nav/$seg?view=git'))?.view,
        isNull,
        reason: seg,
      );
    }
  });

  test('a null view encodes no view param, byte-for-byte as before', () {
    final uri = navLocationToUri(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        sessionId: 'sess1',
      ),
    );
    expect(uri.queryParameters.containsKey('view'), isFalse);
    expect(
      uri.toString(),
      'antgrid://nav/local/proj1?session=sess1&surface=workspace',
    );
  });

  test('round-trips every settings section on the project-less link', () {
    for (final section in SettingsSection.values) {
      roundTrips(
        NavLocation(
          target: null,
          surface: WorkbenchSurface.appSettings,
          settingsSection: section,
        ),
      );
    }
  });

  // The settings surface overlays whatever project is focused, so a link can
  // keep the project and still name a section.
  test('round-trips a settings section alongside a project target', () {
    roundTrips(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.appSettings,
        sessionId: 'sess1',
        settingsSection: SettingsSection.privacy,
      ),
    );
    roundTrips(
      const NavLocation(
        target: RemoteProject(machineUuid: 'm-uuid', projectId: 'proj2'),
        surface: WorkbenchSurface.appSettings,
        settingsSection: SettingsSection.uiSize,
      ),
    );
  });

  test('unrecognised section value degrades to null, keeping the surface', () {
    final loc = navLocationFromUri(
      Uri.parse('antgrid://nav/settings?section=bogus'),
    );
    expect(loc, isNotNull);
    expect(loc!.settingsSection, isNull);
    expect(loc.surface, WorkbenchSurface.appSettings);
  });

  test('uri with no section param parses with a null section', () {
    final loc = navLocationFromUri(Uri.parse('antgrid://nav/settings'));
    expect(loc, isNotNull);
    expect(loc!.settingsSection, isNull);
  });

  // A section names a block of the settings screen; the other two project-less
  // segments do not mount one.
  test('devices and bare-workspace links ignore a section param', () {
    for (final seg in ['devices', 'workspace']) {
      expect(
        navLocationFromUri(
          Uri.parse('antgrid://nav/$seg?section=privacy'),
        )?.settingsSection,
        isNull,
        reason: seg,
      );
    }
  });

  test('a null section encodes no section param, byte-for-byte as before', () {
    final uri = navLocationToUri(
      const NavLocation(target: null, surface: WorkbenchSurface.appSettings),
    );
    expect(uri.hasQuery, isFalse);
    expect(uri.toString(), 'antgrid://nav/settings');
  });

  test('round-trips a file on every project target shape', () {
    roundTrips(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        view: WorkspaceView.files,
        file: 'lib/main.dart',
      ),
    );
    roundTrips(
      const NavLocation(
        target: RemoteProject(machineUuid: 'm-uuid', projectId: 'proj2'),
        surface: WorkbenchSurface.workspace,
        sessionId: 'sess1',
        view: WorkspaceView.files,
        file: 'app/lib/screens/file_explorer_screen.dart',
      ),
    );
    roundTrips(
      NavLocation(
        target: RemoteTarget.legacy('agent-dev-id'),
        surface: WorkbenchSurface.workspace,
        file: 'README.md',
      ),
    );
  });

  // Spaces, `#` and `&` all have to survive percent-encoding intact, or the
  // link opens a different file than the one it names.
  test('round-trips a file path needing percent-encoding', () {
    roundTrips(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        file: 'docs/release notes & plans/v1#2.md',
      ),
    );
  });

  // `..foo` is a legal filename; only a `..` SEGMENT climbs out of the
  // checkout.
  test('round-trips a file whose name merely starts with dots', () {
    roundTrips(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        file: '.github/workflows/..keep.yml',
      ),
    );
  });

  test('uri with no file param parses with a null file', () {
    final loc = navLocationFromUri(
      Uri.parse('antgrid://nav/local/proj1?surface=workspace&view=files'),
    );
    expect(loc, isNotNull);
    expect(loc!.file, isNull);
    expect(loc.view, WorkspaceView.files);
  });

  test('a null file encodes no file param', () {
    final uri = navLocationToUri(
      const NavLocation(
        target: LocalProject('proj1'),
        surface: WorkbenchSurface.workspace,
        view: WorkspaceView.files,
      ),
    );
    expect(uri.queryParameters.containsKey('file'), isFalse);
  });

  // A path that could climb out of the checkout is hostile input, not a stale
  // value, so unlike an unknown view/section it fails the WHOLE link rather
  // than degrading to null — otherwise a rejected path would still navigate and
  // read as a silent no-op.
  test('a traversal segment rejects the whole link', () {
    for (final path in [
      '../secrets.txt',
      '..',
      'lib/../../etc/passwd',
      'lib/..',
      'a/b/../../../c',
    ]) {
      expect(
        navLocationFromUri(
          Uri.parse(
            'antgrid://nav/local/proj1?file=${Uri.encodeQueryComponent(path)}',
          ),
        ),
        isNull,
        reason: path,
      );
    }
  });

  // A segment of only dots and whitespace names nothing, so it is refused
  // whatever it spells. An exact `..` comparison would let these through, and
  // Win32 strips trailing dots and spaces from a path component — which turns
  // `.. ` and `...` back into `..` on a Windows bridge, the same platform gap
  // the backslash rule closes.
  test('a padded traversal segment rejects the whole link', () {
    for (final path in [
      '.. /secrets.txt',
      'lib/.. /etc',
      '...',
      'lib/.../etc',
      ' ../secrets.txt',
      'lib/. ./etc',
    ]) {
      expect(
        navLocationFromUri(
          Uri.parse(
            'antgrid://nav/local/proj1?file=${Uri.encodeQueryComponent(path)}',
          ),
        ),
        isNull,
        reason: path,
      );
    }
  });

  // Uri decodes the query before we see it, so the escaped form must be checked
  // in its decoded shape or it walks straight through.
  test('a percent-encoded traversal rejects the whole link', () {
    expect(
      navLocationFromUri(
        Uri.parse('antgrid://nav/local/proj1?file=%2e%2e%2fsecrets.txt'),
      ),
      isNull,
    );
    expect(
      navLocationFromUri(
        Uri.parse('antgrid://nav/local/proj1?file=lib%2F..%2F..%2Fetc'),
      ),
      isNull,
    );
  });

  test('an absolute file path rejects the whole link', () {
    for (final path in [
      '/etc/passwd',
      '/',
      'C:/Windows/system32/config',
      r'C:\Windows\system32\config',
      r'\\server\share\x',
    ]) {
      expect(
        navLocationFromUri(
          Uri.parse(
            'antgrid://nav/local/proj1?file=${Uri.encodeQueryComponent(path)}',
          ),
        ),
        isNull,
        reason: path,
      );
    }
  });

  // A backslash is not a separator in this grammar, so a Windows traversal has
  // to be refused wholesale rather than scanned for `..` segments.
  test('a backslash anywhere in the file path rejects the whole link', () {
    for (final path in [r'lib\..\..\etc', r'lib\main.dart']) {
      expect(
        navLocationFromUri(
          Uri.parse(
            'antgrid://nav/local/proj1?file=${Uri.encodeQueryComponent(path)}',
          ),
        ),
        isNull,
        reason: path,
      );
    }
  });

  test('a blank or empty file path rejects the whole link', () {
    expect(
      navLocationFromUri(Uri.parse('antgrid://nav/local/proj1?file=')),
      isNull,
    );
    expect(
      navLocationFromUri(Uri.parse('antgrid://nav/local/proj1?file=%20%20')),
      isNull,
    );
    expect(
      navLocationFromUri(
        Uri.parse('antgrid://nav/local/proj1?file=lib//main.dart'),
      ),
      isNull,
    );
  });

  // The check sits ahead of the segment switch, so a hostile path is refused on
  // links whose destination would have ignored the file entirely.
  test('an escaping file path rejects even a surface-only link', () {
    for (final seg in ['settings', 'devices', 'workspace']) {
      expect(
        navLocationFromUri(Uri.parse('antgrid://nav/$seg?file=..%2Fsecrets')),
        isNull,
        reason: seg,
      );
    }
  });

  // A safe file on a project-less link is dropped rather than refused: there is
  // no workspace for it to name, exactly as for session and view.
  test('surface-only locations ignore a safe file param', () {
    for (final seg in ['settings', 'devices', 'workspace']) {
      expect(
        navLocationFromUri(
          Uri.parse('antgrid://nav/$seg?file=lib%2Fmain.dart'),
        )?.file,
        isNull,
        reason: seg,
      );
    }
  });

  test('non-nav host returns null', () {
    expect(
      navLocationFromUri(Uri.parse('antgrid://auth/callback?token=x')),
      isNull,
    );
  });

  test('malformed nav uri returns null', () {
    expect(navLocationFromUri(Uri.parse('antgrid://nav/local')), isNull);
    expect(navLocationFromUri(Uri.parse('antgrid://nav/bogus/x')), isNull);
  });

  test('non-antgrid scheme returns null even when host is nav', () {
    expect(navLocationFromUri(Uri.parse('https://nav/local/proj')), isNull);
    expect(navLocationFromUri(Uri.parse('evil://nav/remote/m/p')), isNull);
  });

  // `pathSegments` and `queryParameters` percent-DECODE, and an escape that is
  // not valid UTF-8 makes them throw rather than yield a bad value. The link
  // comes from the OS and is applied fire-and-forget, so a throw would surface
  // as an unhandled async error instead of a refused link.
  test('an undecodable percent-escape returns null instead of throwing', () {
    for (final raw in const [
      'antgrid://nav/%80',
      'antgrid://nav/local/%E0%A4%A',
      'antgrid://nav/local/p?file=%80',
      'antgrid://nav/settings?section=%E0%A4%A',
    ]) {
      expect(navLocationFromUri(Uri.parse(raw)), isNull, reason: raw);
    }
  });

  test('blank path segment returns null', () {
    expect(
      navLocationFromUri(
        Uri(scheme: 'antgrid', host: 'nav', pathSegments: ['local', '']),
      ),
      isNull,
    );
    expect(
      navLocationFromUri(
        Uri(scheme: 'antgrid', host: 'nav', pathSegments: ['local', '   ']),
      ),
      isNull,
    );
  });
}
