// app/test/navigation/nav_serialization_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/navigation/nav_serialization.dart';
import 'package:antgrid/models/session_target.dart';
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
      const NavLocation(target: null, surface: WorkbenchSurface.mobileDevices),
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
