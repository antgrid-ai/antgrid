import 'session_target.dart';

/// A value a navigation named for a screen that could not take it yet, stamped
/// with the project it was issued for.
///
/// The stamp is what makes the handover self-invalidating. Most writes come
/// from `NavController._apply`, and in-app navigation never reaches it —
/// switching projects from the drawer records history through `commit` alone —
/// so a value whose destination never mounted would otherwise sit there until
/// some other project's screen mounted and consumed it. Each drain discards a
/// stamp that is not the focused target, which is also what makes it safe for
/// an in-app caller to hand a destination over this way.
///
/// A surface-only location carries the target it overlays, not null: the
/// settings screen a `nav/settings` link opens belongs to whatever project is
/// focused underneath it.
typedef PendingNav<T extends Object> = ({SessionTarget? target, T value});
