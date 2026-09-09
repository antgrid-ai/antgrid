import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Works around a Windows-only clipboard-history quirk that breaks Ctrl+V in
/// every plain text field in the app (address bar, comment/note boxes, chat
/// composer, settings — anything built on `EditableText`).
///
/// Windows' own clipboard history (Win+V) pastes a picked entry by injecting
/// a synthetic Ctrl+V keystroke with no scancode. Flutter's Windows embedder
/// resyncs the sided-modifier state against `GetKeyState` on every event, and
/// for that injected chord it concludes the Ctrl it just delivered was never
/// really down — synthesizing a key-up for it BEFORE the `V` arrives. So
/// `HardwareKeyboard.isControlPressed` reads false for exactly the event that
/// needed it, `EditableText`'s own built-in Ctrl+V shortcut never matches,
/// and a bare "v" gets typed instead of a paste (measured on Flutter 3.44 /
/// Windows 11).
///
/// `TerminalViewWrapper` already works around this for the agent terminal
/// with its own early-key modifier mirror (see its `_realModifierState`
/// doc) — this is the same technique, generalized app-wide via
/// [ActionDispatcher] on `PasteTextIntent` instead of the terminal's raw
/// `ghostty.writeBytes`, since a plain text field has no equivalent to write
/// into directly.
///
/// Installed once, from `main()`, rather than per-widget: unlike the
/// terminal, a bare `TextField` carries no state of its own to hang a mirror
/// off, and there are far too many of them to wire individually.
class WindowsPasteFix {
  WindowsPasteFix._();

  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    FocusManager.instance.addEarlyKeyEventHandler(_handle);
  }

  static final _controlKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
  };

  /// Real (non-synthesized) down/up per Ctrl key — mirrors
  /// `TerminalViewWrapper._realModifierState`. A key ABSENT from the map means
  /// "no real event seen yet", which defers to `HardwareKeyboard` rather than
  /// asserting a released state a genuine held Ctrl would contradict.
  static final Map<LogicalKeyboardKey, bool> _realControlState = {};

  static KeyEventResult _handle(KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return KeyEventResult.ignored;
    }
    _track(event);
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyV) {
      return KeyEventResult.ignored;
    }
    final ctrl = _realControl ?? HardwareKeyboard.instance.isControlPressed;
    if (!ctrl) return KeyEventResult.ignored;

    final focusContext = primaryFocus?.context;
    if (focusContext == null) return KeyEventResult.ignored;
    const intent = PasteTextIntent(SelectionChangedCause.keyboard);
    final action = Actions.maybeFind<PasteTextIntent>(focusContext);
    if (action == null) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    // EditableText's paste action returns void even when it pastes. Only the
    // dispatcher's enabled flag can distinguish that from an unhandled event.
    final (invoked, _) = Actions.of(
      focusContext,
    ).invokeActionIfEnabled(action, intent, focusContext);
    return invoked ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  static void _track(KeyEvent event) {
    if (event.synthesized) return;
    if (!_controlKeys.contains(event.logicalKey)) return;
    _realControlState[event.logicalKey] = event is! KeyUpEvent;
  }

  static bool? get _realControl {
    var seen = false;
    for (final key in _controlKeys) {
      final down = _realControlState[key];
      if (down == true) return true;
      if (down != null) seen = true;
    }
    return seen ? false : null;
  }
}
