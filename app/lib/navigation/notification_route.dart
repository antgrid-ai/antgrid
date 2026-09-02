// app/lib/navigation/notification_route.dart
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../models/recent_session_row.dart';
import '../models/session_target.dart';
import '../models/workspace_view.dart';
import '../providers/ui_attention_providers.dart' show WorkbenchSurface;
import '../util/device_id.dart';
import 'nav_location.dart';

/// What a tapped notification names — the wire shape only. Turning one into a
/// place the app can go is [resolveNotificationRoute], which refuses rather
/// than guesses.
///
/// Every field is optional because every producer names a different subset: a
/// live stream already holds the drawer entryId, a sealed push carries
/// machine + project + session, and a hook notification may name nothing but a
/// title (`sessionId` is optional on `notification:push`).
@immutable
class NotificationRoute {
  /// Pre-resolved drawer entry id, in its local-or-remote shape. Set by the
  /// in-app paths, which already know which entry the notification arrived on.
  final String? registrationId;

  /// Sealed-push path only, and null from a bridge that predates the widened
  /// payload — which is why an absent one is unroutable, never guessed at.
  final String? machineUuid;
  final String? projectId;
  final String? terminalId;
  final String? sourceMessageId;

  /// `agent` or `handler`. Anything else is treated as `agent`: an unknown kind
  /// from a newer bridge must land the user on the session, not nowhere.
  final String? kind;

  const NotificationRoute({
    this.registrationId,
    this.machineUuid,
    this.projectId,
    this.terminalId,
    this.sourceMessageId,
    this.kind,
  });

  /// Value equality is load-bearing, not a convenience: the applier dedups on
  /// it, because [sourceMessageId] is nullable by design and a route without
  /// one would otherwise have no dedup key at all.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationRoute &&
          other.registrationId == registrationId &&
          other.machineUuid == machineUuid &&
          other.projectId == projectId &&
          other.terminalId == terminalId &&
          other.sourceMessageId == sourceMessageId &&
          other.kind == kind;

  @override
  int get hashCode => Object.hash(
    registrationId,
    machineUuid,
    projectId,
    terminalId,
    sourceMessageId,
    kind,
  );

  @override
  String toString() =>
      'NotificationRoute(registrationId: $registrationId, '
      'machineUuid: $machineUuid, projectId: $projectId, '
      'terminalId: $terminalId, sourceMessageId: $sourceMessageId, '
      'kind: $kind)';
}

/// Serializes [r] for a payload slot that only carries a string — an OS
/// notification's action payload.
///
/// A null field is OMITTED, never emitted as `""`: the two mean different
/// things downstream (an empty id names no project, but would still satisfy a
/// `!= null` test), so the encoding must not be able to manufacture one.
String encodeNotificationRoute(NotificationRoute r) => jsonEncode({
  if (r.registrationId != null) 'registrationId': r.registrationId,
  if (r.machineUuid != null) 'machineUuid': r.machineUuid,
  if (r.projectId != null) 'projectId': r.projectId,
  if (r.terminalId != null) 'terminalId': r.terminalId,
  if (r.sourceMessageId != null) 'sourceMessageId': r.sourceMessageId,
  if (r.kind != null) 'kind': r.kind,
});

/// Parses a payload back into a route, or null when there is nothing to parse.
///
/// The payload arrives from the OS notification the user tapped and is applied
/// fire-and-forget, so a throw here would be an unhandled async error: anything
/// that is not a JSON object degrades to null, and a value of the wrong type
/// degrades to an absent field rather than failing the whole route.
NotificationRoute? decodeNotificationRoute(String? payload) {
  if (payload == null) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  return NotificationRoute(
    registrationId: _named(decoded['registrationId']),
    machineUuid: _named(decoded['machineUuid']),
    projectId: _named(decoded['projectId']),
    terminalId: _named(decoded['terminalId']),
    sourceMessageId: _named(decoded['sourceMessageId']),
    kind: _named(decoded['kind']),
  );
}

/// The value of a field that actually names something, or null.
///
/// Blank and absent collapse deliberately: `LocalProject('')` is a target the
/// app would try to focus, so an empty id must not survive far enough to be
/// tested for null.
String? _named(Object? value) {
  if (value is! String) return null;
  return value.trim().isEmpty ? null : value;
}

/// Resolves [route] to a place, or null when nothing can be addressed without
/// guessing.
///
/// [known] is the cached-session universe (`recentSessionsProvider`);
/// [localDeviceUuid] is this install's machine uuid, null on a platform that
/// hosts no projects — which is why locality is decided per row against that
/// uuid and never by a platform test.
NavLocation? resolveNotificationRoute(
  NotificationRoute route, {
  required List<RecentSessionRow> known,
  required String? localDeviceUuid,
}) {
  final target = _resolveTarget(
    route,
    known: known,
    localDeviceUuid: localDeviceUuid,
  );
  if (target == null) return null;
  return NavLocation(
    target: target,
    surface: WorkbenchSurface.workspace,
    // Carried whenever the route names a session; whether that session is still
    // open is the applier's question, not this one's.
    sessionId: _named(route.terminalId),
    view: _named(route.kind) == 'handler' ? WorkspaceView.handler : null,
  );
}

SessionTarget? _resolveTarget(
  NotificationRoute route, {
  required List<RecentSessionRow> known,
  required String? localDeviceUuid,
}) {
  final registrationId = _named(route.registrationId);
  if (registrationId != null) {
    // A cached row is preferred over splitting the id ourselves because the row
    // was classified against the real project list: a bare id belonging to no
    // local project is still local, and only the row knows that.
    final row = known.firstWhereOrNull(
      (r) => r.origin.registrationId == registrationId,
    );
    if (row != null) return _targetOf(row.origin);
    return _splitRegistrationId(registrationId);
  }

  final machineUuid = _named(route.machineUuid);
  final projectId = _named(route.projectId);
  if (machineUuid != null && projectId != null) {
    if (machineUuid == localDeviceUuid) return LocalProject(projectId);
    return RemoteProject(machineUuid: machineUuid, projectId: projectId);
  }

  final terminalId = _named(route.terminalId);
  if (terminalId != null) {
    // Session ids are uuids minted per session, so a hit names exactly one
    // project — but only if there IS one hit. Distinct registration ids, not
    // rows: the same session listed twice under one project is not ambiguous.
    final origins = <String, RecentOrigin>{};
    for (final row in known) {
      if (row.session.id != terminalId) continue;
      origins[row.origin.registrationId] = row.origin;
    }
    if (origins.length == 1) return _targetOf(origins.values.first);
    return null;
  }

  // Deliberately no projectId-only fallback. `computeProjectId` hashes the
  // folder path with no machine input, so the same repo checked out at the same
  // path on two machines mints the identical id — a "unique" match there is a
  // confident wrong machine. Unroutable is the honest answer.
  return null;
}

SessionTarget _targetOf(RecentOrigin origin) {
  final machineUuid = origin.machineUuid;
  if (origin.isLocal || machineUuid == null) {
    return LocalProject(origin.projectId);
  }
  return RemoteProject(machineUuid: machineUuid, projectId: origin.projectId);
}

SessionTarget _splitRegistrationId(String registrationId) {
  final machineUuid = baseDeviceUuid(registrationId);
  if (machineUuid == registrationId) return LocalProject(registrationId);
  return RemoteProject(
    machineUuid: machineUuid,
    projectId: baseProjectId(registrationId),
  );
}
