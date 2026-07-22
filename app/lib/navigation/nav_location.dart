import 'package:flutter/foundation.dart';

import '../models/session_target.dart';
import '../providers/ui_attention_providers.dart' show WorkbenchSurface;

/// One immutable snapshot of "where the user is": which project is focused,
/// which top-level workbench surface is showing, and the active session id
/// within that project (when known). Browser-style history is a list of these.
@immutable
class NavLocation {
  final SessionTarget? target;
  final WorkbenchSurface surface;
  final String? sessionId;

  const NavLocation({this.target, required this.surface, this.sessionId});

  /// `clearSessionId: true` nulls the session; never combine it with an
  /// explicit `sessionId` value (matches the repo-wide copyWith rule).
  NavLocation copyWith({
    SessionTarget? target,
    WorkbenchSurface? surface,
    String? sessionId,
    bool clearTarget = false,
    bool clearSessionId = false,
  }) {
    assert(!(clearTarget && target != null));
    assert(!(clearSessionId && sessionId != null));
    return NavLocation(
      target: clearTarget ? null : (target ?? this.target),
      surface: surface ?? this.surface,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavLocation &&
          other.target == target &&
          other.surface == surface &&
          other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(target, surface, sessionId);

  @override
  String toString() =>
      'NavLocation(target: $target, surface: $surface, sessionId: $sessionId)';
}
