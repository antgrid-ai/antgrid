import 'package:flutter/widgets.dart' show AppLifecycleState;

/// Whether a terminal notification should render as an in-app overlay toast
/// (`true`) rather than an OS notification (`false`), given the app
/// [lifecycle].
///
/// Only [AppLifecycleState.resumed] — the app window focused/active —
/// shows the toast. Every other state hands off to the OS notification,
/// because the toast is painted *inside* the app window: when the app is
/// unfocused it's typically occluded by whatever the user switched to (or
/// minimized entirely), so the overlay would be invisible. The OS
/// notification is the only channel that surfaces above the foreground app.
/// (Desktop reports `inactive` when unfocused-but-visible; we deliberately
/// route that to the OS too — the common case is an occluded window, and a
/// toast nobody can see is worse than an OS banner.)
///
/// Pure function of [lifecycle] so the routing decision is unit-testable
/// without standing up the workspace screen.
bool shouldShowInAppToast(AppLifecycleState lifecycle) =>
    lifecycle == AppLifecycleState.resumed;
