import 'package:flutter/foundation.dart';

import '../models/session_target.dart';
import '../models/settings_section.dart';
import '../models/workspace_view.dart';
import '../providers/ui_attention_providers.dart' show WorkbenchSurface;

/// One immutable snapshot of "where the user is": which project is focused,
/// which top-level workbench surface is showing, which workspace tab that
/// surface should land on, and the active session id within that project (when
/// known). Browser-style history is a list of these.
@immutable
class NavLocation {
  final SessionTarget? target;
  final WorkbenchSurface surface;
  final String? sessionId;

  /// The workspace tab to restore, or null for "whatever tab is already up".
  ///
  /// Null is the norm: only the deep-link codec names a tab, because tapping a
  /// tab deliberately records no history entry. This field is therefore part of
  /// equality but NOT of `NavController.commit`'s dedupe, which keys on
  /// target/surface/sessionId — the fields an in-app navigation site can set.
  final WorkspaceView? view;

  /// The settings block to bring into view, or null for "wherever the settings
  /// screen opens".
  ///
  /// Only meaningful while [surface] is [WorkbenchSurface.appSettings], and —
  /// like [view] — only the deep-link codec ever names one: scrolling the
  /// settings list records no history.
  final SettingsSection? settingsSection;

  /// The file for the explorer to open, or null for "leave whatever file is
  /// open alone".
  ///
  /// Relative to the focused session's CHECKOUT, never to the project path:
  /// it is handed to the checkout-scoped `FileService`, so an isolated session
  /// opens the file inside its own worktree. Like [view] and [settingsSection],
  /// only the deep-link codec names one — and because the value arrives from
  /// outside the app, `navLocationFromUri` refuses any path that could climb
  /// out of that checkout before one reaches this field.
  final String? file;

  const NavLocation({
    this.target,
    required this.surface,
    this.sessionId,
    this.view,
    this.settingsSection,
    this.file,
  });

  /// `clearSessionId`, `clearView`, `clearSettingsSection` and `clearFile` null
  /// their field; never combine one with an explicit value for the same field
  /// (matches the repo-wide copyWith rule).
  NavLocation copyWith({
    SessionTarget? target,
    WorkbenchSurface? surface,
    String? sessionId,
    WorkspaceView? view,
    SettingsSection? settingsSection,
    String? file,
    bool clearTarget = false,
    bool clearSessionId = false,
    bool clearView = false,
    bool clearSettingsSection = false,
    bool clearFile = false,
  }) {
    assert(!(clearTarget && target != null));
    assert(!(clearSessionId && sessionId != null));
    assert(!(clearView && view != null));
    assert(!(clearSettingsSection && settingsSection != null));
    assert(!(clearFile && file != null));
    return NavLocation(
      target: clearTarget ? null : (target ?? this.target),
      surface: surface ?? this.surface,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      view: clearView ? null : (view ?? this.view),
      settingsSection: clearSettingsSection
          ? null
          : (settingsSection ?? this.settingsSection),
      file: clearFile ? null : (file ?? this.file),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavLocation &&
          other.target == target &&
          other.surface == surface &&
          other.sessionId == sessionId &&
          other.view == view &&
          other.settingsSection == settingsSection &&
          other.file == file;

  @override
  int get hashCode =>
      Object.hash(target, surface, sessionId, view, settingsSection, file);

  @override
  String toString() =>
      'NavLocation(target: $target, surface: $surface, '
      'sessionId: $sessionId, view: $view, settingsSection: $settingsSection, '
      'file: $file)';
}
