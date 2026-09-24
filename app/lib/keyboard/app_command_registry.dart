import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_shortcuts.dart';

/// Who can act on each [AppCommand] right now.
///
/// The key handling lives above every route, but most actions belong to State
/// deep inside one — the shell's panel mode, a terminal list, a file explorer —
/// that nothing above can reach. So the owner registers a handler while it is
/// mounted ([AppCommandHandlers]) and the keyboard asks here. The same shape as
/// `BackHandler`, for the same reason.
///
/// The most recent registration offering a command wins, so a descendant
/// mounted after its ancestor (initState runs parent-first) overrides the
/// ancestor's fallback, and a null handler means "not available here" rather
/// than "swallow the key": an unavailable command's chord reaches whatever has
/// focus.
class AppCommandRegistry {
  final _entries = <_Registration>[];
  final _activeChecks = <bool Function()>[];

  Object register(Map<AppCommand, VoidCallback?> handlers) {
    final token = Object();
    _entries.add(_Registration(token, handlers));
    return token;
  }

  void update(Object token, Map<AppCommand, VoidCallback?> handlers) {
    for (final e in _entries) {
      if (identical(e.token, token)) {
        e.handlers = handlers;
        return;
      }
    }
  }

  void unregister(Object token) =>
      _entries.removeWhere((e) => identical(e.token, token));

  /// The live handler for [command], or null when nothing mounted offers it.
  VoidCallback? handlerFor(AppCommand command) {
    for (var i = _entries.length - 1; i >= 0; i--) {
      final handler = _entries[i].handlers[command];
      if (handler != null) return handler;
    }
    return null;
  }

  /// Registered by each mounted `AppShortcutScope`; global chords fire only
  /// while one of them says its route is the current one, so a chord pressed
  /// under a dialog stays with the dialog.
  void addActiveCheck(bool Function() check) => _activeChecks.add(check);
  void removeActiveCheck(bool Function() check) => _activeChecks.remove(check);

  /// The global command [event] will run, or null when the app will leave it
  /// alone.
  ///
  /// The terminal asks this before acting on a key itself. Every early
  /// key handler runs for every event whatever the others return
  /// (`FocusManager` combines their results), so claiming a chord here does not
  /// stop the terminal's own early handler from seeing it — the terminal has to
  /// step aside on its own.
  AppCommand? claims(KeyEvent event) {
    if (event is KeyUpEvent) return null;
    if (!_activeChecks.any((check) => check())) return null;
    final command = globalCommandFor(event, HardwareKeyboard.instance);
    if (command == null || handlerFor(command) == null) return null;
    return command;
  }

  /// The `FocusManager` early handler: runs a claimed command on key-down and
  /// swallows its repeats, so neither reaches the focused widget.
  KeyEventResult handleEarlyKey(KeyEvent event) {
    final command = claims(event);
    if (command == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) handlerFor(command)?.call();
    return KeyEventResult.handled;
  }
}

class _Registration {
  _Registration(this.token, this.handlers);
  final Object token;
  Map<AppCommand, VoidCallback?> handlers;
}

final appCommandRegistryProvider = Provider<AppCommandRegistry>(
  (ref) => AppCommandRegistry(),
  name: 'appCommandRegistry',
);

/// Offers [handlers] to the keyboard for as long as this widget is mounted.
///
/// Rebuilt with fresh closures on every build of its owner, which is what keeps
/// a handler reading current state; a null value withdraws that command.
class AppCommandHandlers extends ConsumerStatefulWidget {
  const AppCommandHandlers({
    super.key,
    required this.handlers,
    required this.child,
  });

  final Map<AppCommand, VoidCallback?> handlers;
  final Widget child;

  @override
  ConsumerState<AppCommandHandlers> createState() => _AppCommandHandlersState();
}

class _AppCommandHandlersState extends ConsumerState<AppCommandHandlers> {
  late final AppCommandRegistry _registry;
  late final Object _token;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(appCommandRegistryProvider);
    _token = _registry.register(widget.handlers);
  }

  @override
  void didUpdateWidget(AppCommandHandlers oldWidget) {
    super.didUpdateWidget(oldWidget);
    _registry.update(_token, widget.handlers);
  }

  @override
  void dispose() {
    _registry.unregister(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
