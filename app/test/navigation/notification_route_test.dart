// app/test/navigation/notification_route_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/navigation/notification_route.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

const _localUuid = 'uuid-this-machine';

SessionEntry _session(String id, {int lastUsedAt = 0}) => SessionEntry(
  id: id,
  name: id.toUpperCase(),
  createdAt: 0,
  lastUsedAt: lastUsedAt,
  archived: false,
  running: false,
);

AbProject _localProject(String projectId) => AbProject(
  projectId: projectId,
  folder: '/repos/$projectId',
  displayName: projectId,
  hostDeviceUuid: _localUuid,
  hostMachineName: 'This Mac',
  lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(0),
);

/// One local project and one remote project, each holding a distinct session:
/// the shape that makes a terminalId lookup meaningful across two machines.
List<RecentSessionRow> _known() => buildRecentSessions(
  cached: {
    'projLocal': [_session('sess-local', lastUsedAt: 100)],
    'uuidA.projRemote': [_session('sess-remote', lastUsedAt: 200)],
  },
  locals: [_localProject('projLocal')],
  remotes: const [],
  inventory: const [],
  localDeviceLabel: 'This Mac',
);

void main() {
  group('resolveNotificationRoute', () {
    test('a bare pre-resolved registrationId is a local project', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(registrationId: 'projLocal'),
        known: _known(),
        localDeviceUuid: _localUuid,
      );
      expect(loc!.target, const LocalProject('projLocal'));
      expect(loc.surface, WorkbenchSurface.workspace);
    });

    test('a compound pre-resolved registrationId is a remote project', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(registrationId: 'uuidA.projRemote'),
        known: _known(),
        localDeviceUuid: _localUuid,
      );
      expect(
        loc!.target,
        const RemoteProject(machineUuid: 'uuidA', projectId: 'projRemote'),
      );
    });

    test('a registrationId no cached row names is still split', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(registrationId: 'uuidZ.projUnknown'),
        known: _known(),
        localDeviceUuid: _localUuid,
      );
      expect(
        loc!.target,
        const RemoteProject(machineUuid: 'uuidZ', projectId: 'projUnknown'),
      );
    });

    test('machineUuid equal to this device resolves local', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(
          machineUuid: _localUuid,
          projectId: 'projLocal',
        ),
        known: _known(),
        localDeviceUuid: _localUuid,
      );
      expect(loc!.target, const LocalProject('projLocal'));
      expect(loc.target!.registrationId, 'projLocal');
    });

    test('a foreign machineUuid resolves remote', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(machineUuid: 'uuidB', projectId: 'projB'),
        known: _known(),
        localDeviceUuid: _localUuid,
      );
      expect(
        loc!.target,
        const RemoteProject(machineUuid: 'uuidB', projectId: 'projB'),
      );
      expect(loc.target!.registrationId, 'uuidB.projB');
    });

    test('a null localDeviceUuid never makes a route local', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(machineUuid: 'uuidA', projectId: 'projRemote'),
        known: _known(),
        localDeviceUuid: null,
      );
      expect(
        loc!.target,
        const RemoteProject(machineUuid: 'uuidA', projectId: 'projRemote'),
      );
    });

    test('a terminalId matching exactly one cached row names its project', () {
      final loc = resolveNotificationRoute(
        const NotificationRoute(terminalId: 'sess-remote'),
        known: _known(),
        localDeviceUuid: _localUuid,
      );
      expect(
        loc!.target,
        const RemoteProject(machineUuid: 'uuidA', projectId: 'projRemote'),
      );
      expect(loc.sessionId, 'sess-remote');
    });

    test('a terminalId matching no cached row is unroutable', () {
      expect(
        resolveNotificationRoute(
          const NotificationRoute(terminalId: 'sess-gone'),
          known: _known(),
          localDeviceUuid: _localUuid,
        ),
        isNull,
      );
    });

    test('a terminalId matching two machines is unroutable', () {
      final known = buildRecentSessions(
        cached: {
          'uuidA.proj': [_session('sess-dup')],
          'uuidB.proj': [_session('sess-dup')],
        },
        locals: const [],
        remotes: const [],
        inventory: const [],
        localDeviceLabel: 'This Mac',
      );
      expect(
        resolveNotificationRoute(
          const NotificationRoute(terminalId: 'sess-dup'),
          known: known,
          localDeviceUuid: _localUuid,
        ),
        isNull,
      );
    });

    test('a projectId with no machineUuid and no terminalId is unroutable', () {
      expect(
        resolveNotificationRoute(
          const NotificationRoute(projectId: 'projLocal'),
          known: _known(),
          localDeviceUuid: _localUuid,
        ),
        isNull,
      );
    });

    test('a route naming nothing is unroutable', () {
      expect(
        resolveNotificationRoute(
          const NotificationRoute(sourceMessageId: 'm1', kind: 'handler'),
          known: _known(),
          localDeviceUuid: _localUuid,
        ),
        isNull,
      );
    });

    test('kind handler asks for the handler tab, agent asks for none', () {
      WorkspaceView? viewFor(String? kind) => resolveNotificationRoute(
        NotificationRoute(registrationId: 'projLocal', kind: kind),
        known: _known(),
        localDeviceUuid: _localUuid,
      )!.view;
      expect(viewFor('handler'), WorkspaceView.handler);
      expect(viewFor('agent'), isNull);
      expect(viewFor(null), isNull);
      expect(viewFor('something-new'), isNull);
    });

    test('a blank id names nothing rather than a blank project', () {
      expect(
        resolveNotificationRoute(
          const NotificationRoute(registrationId: '   '),
          known: _known(),
          localDeviceUuid: _localUuid,
        ),
        isNull,
      );
    });
  });

  group('encode/decode', () {
    const full = NotificationRoute(
      registrationId: 'uuidA.projRemote',
      machineUuid: 'uuidA',
      projectId: 'projRemote',
      terminalId: 'sess-remote',
      sourceMessageId: 'msg-1',
      kind: 'handler',
    );

    test('round-trips every field', () {
      expect(decodeNotificationRoute(encodeNotificationRoute(full)), full);
    });

    test('a null field is omitted, never encoded as an empty string', () {
      const partial = NotificationRoute(registrationId: 'projLocal');
      final json =
          jsonDecode(encodeNotificationRoute(partial)) as Map<String, dynamic>;
      expect(json.keys, ['registrationId']);
      expect(
        decodeNotificationRoute(encodeNotificationRoute(partial)),
        partial,
      );
    });

    test('an empty field decodes as absent', () {
      expect(
        decodeNotificationRoute('{"registrationId":"","kind":"agent"}'),
        const NotificationRoute(kind: 'agent'),
      );
    });

    test('a non-string field decodes as absent', () {
      expect(
        decodeNotificationRoute('{"registrationId":7,"kind":"agent"}'),
        const NotificationRoute(kind: 'agent'),
      );
    });

    test('refuses null, non-JSON and a non-object', () {
      expect(decodeNotificationRoute(null), isNull);
      expect(decodeNotificationRoute('not json'), isNull);
      expect(decodeNotificationRoute('["projLocal"]'), isNull);
      expect(decodeNotificationRoute(''), isNull);
    });

    test('equal routes share a hashCode, so a value dedup works', () {
      final again = decodeNotificationRoute(encodeNotificationRoute(full))!;
      expect(again.hashCode, full.hashCode);
      expect(full, isNot(const NotificationRoute(registrationId: 'projLocal')));
    });
  });
}
