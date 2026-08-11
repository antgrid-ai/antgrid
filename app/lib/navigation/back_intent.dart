import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/providers.dart';
import '../utils/platform_utils.dart';
import 'nav_controller.dart';

/// One back press unwinds ONE layer of app state.
///
/// The app is a single-route shell (MaterialApp.home), so there is no Navigator
/// stack for the system back gesture to walk — every surface below the dialogs
/// is provider or widget state. This file is the substitute stack: widgets that
/// own a dismissible state register a handler, and [resolveBackIntent] walks
/// them highest-priority first, then session/project history, then the exit
/// gate.
///
/// Escape is deliberately NOT routed through here. Escape dismisses the focused
/// thing; back unwinds the app state stack. They may share a target, never a
/// dispatcher — Escape in an empty workspace must not step project history or
/// arm the exit toast.

/// Registration priorities; higher runs first. History and the exit gate are
/// hard-coded tail steps in [resolveBackIntent] rather than registrations, so
/// no future handler can wedge itself after them.
abstract final class BackPriority {
  static const int drawer = 1000;
  static const int previewContent = 830;
  static const int fileViewer = 820;
  static const int fileSearch = 810;
  static const int gitViewer = 805;
  static const int pushedTerminal = 800;
  // Below every handler a workspace view registers, because the surface
  // CONTAINS one of those views: a back press with a file open inside it must
  // close the file, not the surface out from under it.
  static const int workspaceSurface = 700;
  static const int mobileAgentPage = 400;
}

/// How long the "press back again" arm stays valid.
const Duration kBackExitWindow = Duration(seconds: 2);

/// Test seams. The clock keeps the two-press window out of real time, and the
/// exit hook keeps `SystemNavigator.pop()` out of the test binding.
@visibleForTesting
DateTime Function() backIntentClock = DateTime.now;

@visibleForTesting
Future<void> Function() backIntentExit = () => SystemNavigator.pop();

/// Default for a handler whose owner cannot cheaply answer "is there something
/// to unwind?" — it always runs, and its `onBack` declines the press instead.
bool _alwaysActive() => true;

class _Registration {
  const _Registration(this.priority, this.isActive, this.onBack);
  final int priority;

  /// Whether this handler currently has something to unwind. Read through a
  /// closure rather than stored, so a rebuilt [BackHandler] is reflected
  /// without re-registering.
  final bool Function() isActive;
  final bool Function() onBack;
}

/// Ordered set of back handlers, keyed by opaque registration token.
///
/// A plain object behind a `Provider`, deliberately NOT a `Notifier`:
/// registration happens in `initState`, i.e. mid-build, and notifying provider
/// listeners there risks Riverpod's "rebuilt multiple times in the same frame".
/// [revision] exists only so the title bar's back chevron can enable itself,
/// and it is bumped in a microtask so it never fires inside the build phase.
class BackHandlerRegistry {
  final Map<Object, _Registration> _entries = {};

  /// Bumped (out of band) whenever the handler set OR any handler's active
  /// flag changes.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool _bumpScheduled = false;

  /// Whether any registered handler currently has something to unwind.
  ///
  /// NOT `isNotEmpty`: `WorkspacePanel` renders all five tabs in an
  /// `IndexedStack`, so every tab is mounted and registered at all times — a
  /// mere-existence test is true for the whole life of the workspace route and
  /// would light the title bar's chevron permanently.
  bool get hasActive => _entries.values.any((e) => e.isActive());

  @visibleForTesting
  int get length => _entries.length;

  Object register({
    required int priority,
    bool Function() isActive = _alwaysActive,
    required bool Function() onBack,
  }) {
    final token = Object();
    _entries[token] = _Registration(priority, isActive, onBack);
    // A handler that never unregisters silently swallows every back press from
    // then on. Nothing legitimately stacks this many at once.
    assert(
      _entries.length <= 16,
      'BackHandlerRegistry leak: ${_entries.length} live handlers',
    );
    _scheduleBump();
    return token;
  }

  void unregister(Object token) {
    if (_entries.remove(token) != null) _scheduleBump();
  }

  /// A registered handler's `active` flag flipped. Same out-of-band bump as
  /// registration — this is called from `didUpdateWidget`, i.e. mid-build.
  void noteActiveChanged() => _scheduleBump();

  /// Runs handlers highest-priority first, stopping at the first that consumes
  /// the press. Iterates a snapshot: a handler is free to dispose widgets (and
  /// therefore unregister siblings) while it runs.
  ///
  /// Inactive handlers are skipped, but every [onBack] still re-checks its own
  /// state: `isActive` is sampled at the registering widget's last build, and
  /// the press can land after that state has moved on.
  bool dispatch() {
    final entries = _entries.values.where((e) => e.isActive()).toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
    for (final entry in entries) {
      if (entry.onBack()) return true;
    }
    return false;
  }

  void _scheduleBump() {
    if (_bumpScheduled) return;
    _bumpScheduled = true;
    scheduleMicrotask(() {
      _bumpScheduled = false;
      revision.value++;
    });
  }
}

final backHandlerRegistryProvider = Provider<BackHandlerRegistry>(
  (ref) => BackHandlerRegistry(),
);

/// Armed-at timestamp for the two-press exit.
///
/// Held in the container rather than widget State because the route swap in
/// `AppShell._buildAgentRouting` can unmount whichever screen saw the first
/// press before the second one lands.
class BackExitGate extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void arm(DateTime at) => state = at;
  void disarm() => state = null;
}

final backExitGateProvider = NotifierProvider<BackExitGate, DateTime?>(
  BackExitGate.new,
);

/// The single entry point behind system back, Alt+←, the mouse back button and
/// the title bar's back chevron. Returns whether the press was consumed.
///
/// [allowExit] is for the system back gesture only. On desktop an exhausted
/// back is a silent no-op: `SystemNavigator.pop()` there pops a route, not the
/// window, and would strand the app on an empty navigator.
bool resolveBackIntent(
  ProviderContainer ref, {
  BuildContext? toastContext,
  bool allowExit = false,
}) {
  if (ref.read(backHandlerRegistryProvider).dispatch()) {
    ref.read(backExitGateProvider.notifier).disarm();
    return true;
  }

  if (ref.read(navControllerProvider).canBack) {
    ref.read(navControllerProvider.notifier).back();
    ref.read(backExitGateProvider.notifier).disarm();
    return true;
  }

  if (!allowExit) return false;

  final now = backIntentClock();
  final armedAt = ref.read(backExitGateProvider);
  if (armedAt != null && now.difference(armedAt) <= kBackExitWindow) {
    ref.read(backExitGateProvider.notifier).disarm();
    unawaited(exitApp(ref));
    return true;
  }

  ref.read(backExitGateProvider.notifier).arm(now);
  if (toastContext != null && toastContext.mounted) {
    showAbToastOverlay(
      toastContext,
      toast: const AbToast(
        icon: AbIcons.signOut,
        title: 'Press back again to exit',
        description: 'Sessions keep running on your machine.',
      ),
      duration: kBackExitWindow,
    );
  }
  return true;
}

/// Closes the app, flushing anything that must survive it.
///
/// Public so the mobile shell's swipe-past-the-drawer prompt exits by the same
/// path as the back gate — including the [backIntentExit] test seam, without
/// which a widget test would really tear the binding down.
Future<void> exitApp(ProviderContainer ref) async {
  // SystemNavigator.pop() does not fire AppLifecycleListener.onExitRequested on
  // Android, so the flush that hook owns (app_shell.dart) has to happen here
  // too. Bounded: a stuck write must not swallow the exit.
  try {
    await ref
        .read(preferencesServiceProvider)
        .flush()
        .timeout(const Duration(seconds: 2));
  } catch (_) {
    // Best effort.
  }
  await backIntentExit();
}

/// Registers [onBack] for as long as this widget is mounted.
///
/// The only supported way to add a handler — hand-rolled register/unregister
/// pairs are how a leaked registration happens.
class BackHandler extends ConsumerStatefulWidget {
  const BackHandler({
    super.key,
    required this.priority,
    this.active = true,
    required this.onBack,
    required this.child,
  });

  final int priority;

  /// Whether there is currently something for [onBack] to unwind. Recomputed
  /// by the owner's build, which is what makes it reactive — the registry has
  /// no other way to learn that a file was opened or a search panel closed.
  ///
  /// Defaults to true for handlers whose owner cannot cheaply answer (the
  /// mobile drawer, whose open state lives in Scaffold, not in a rebuild).
  final bool active;

  /// Returns true when it consumed the press.
  final bool Function() onBack;

  final Widget child;

  @override
  ConsumerState<BackHandler> createState() => _BackHandlerState();
}

class _BackHandlerState extends ConsumerState<BackHandler> {
  late BackHandlerRegistry _registry;
  late Object _token;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(backHandlerRegistryProvider);
    _register();
  }

  void _register() {
    // Calls through `widget` so a rebuilt closure is picked up without
    // re-registering (and without capturing a stale one).
    _token = _registry.register(
      priority: widget.priority,
      isActive: () => widget.active,
      onBack: () => widget.onBack(),
    );
  }

  @override
  void didUpdateWidget(BackHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.priority != widget.priority) {
      _registry.unregister(_token);
      _register();
    } else if (oldWidget.active != widget.active) {
      // The closure already reads the new value; this only tells the chevron.
      _registry.noteActiveChanged();
    }
  }

  @override
  void dispose() {
    _registry.unregister(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Hosts the app's ONE `PopScope`, plus the desktop back/forward inputs.
///
/// Mounted at the top of `AppShell` so it covers both routes (New Session and
/// the workspace) and every `WorkspaceShell` early return alike.
///
/// `canPop` is unconditionally false. Deriving it from the live handler set
/// would mean mirroring six widget-local booleans into providers, and a stale
/// `true` for a single frame kills the app instead of closing a file. The cost
/// is Android's predictive-back preview, which the previous PopScope had
/// already given up for the common case.
class AppBackScope extends ConsumerWidget {
  const AppBackScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.read(navControllerProvider.notifier);
    void back() => resolveBackIntent(ref.container, allowExit: false);

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        resolveBackIntent(
          ref.container,
          toastContext: context,
          allowExit: isMobilePlatform,
        );
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): back,
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
              nav.forward,
          const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
              back,
          const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
              nav.forward,
        },
        child: Listener(
          onPointerDown: (event) {
            // Mouse "back"/"forward" side buttons: kBackMouseButton (8),
            // kForwardMouseButton (16). Guarded so a normal click never fires.
            if (event.buttons == kBackMouseButton) {
              back();
            } else if (event.buttons == kForwardMouseButton) {
              nav.forward();
            }
          },
          child: child,
        ),
      ),
    );
  }
}
