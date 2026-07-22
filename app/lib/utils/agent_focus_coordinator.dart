/// A focus setter for a single agent terminal: `setter(true)` reports focus
/// gained, `setter(false)` reports focus lost (drives DEC-1004 via the engine
/// controller's `setFocused`).
typedef AgentFocusSetter = void Function(bool focused);

/// Tracks which agent terminal is currently being viewed and toggles its
/// DEC-1004 focus accordingly. Only the viewed terminal is ever focused; when
/// the view changes (project switch, mobile page swipe, app background) the
/// previously-viewed terminal is blurred.
///
/// Terminals that are never viewed are left untouched here — they are defaulted
/// to blurred at creation, which is the state that lets a background agent's
/// notification fire.
class AgentFocusCoordinator {
  Object? _viewedKey;
  AgentFocusSetter? _viewed;

  /// Sets the currently-viewed agent terminal. [key] is a STABLE identity for
  /// the viewed terminal (e.g. its controller instance), used to dedup repeat
  /// calls — do NOT pass a method tear-off as the key, since tear-off identity
  /// is unstable in JIT. [setter] drives that terminal's focus. Pass null/null
  /// when no agent terminal is on screen / the app is backgrounded.
  void setViewed(Object? key, AgentFocusSetter? setter) {
    if (identical(_viewedKey, key)) return;
    _viewed?.call(false);
    setter?.call(true);
    _viewedKey = key;
    _viewed = setter;
  }
}
