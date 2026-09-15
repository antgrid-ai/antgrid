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

/// Whether the user is already reading [sessionId] — in which case NO
/// notification should fire for it, on either channel. The event is right there
/// in the transcript they're looking at; announcing it is pure noise. Anything
/// from another session still surfaces: that's the one they can't see.
///
/// All four conditions are required. The app must be focused ([lifecycle]
/// resumed — a backgrounded app shows nothing, so nothing is "already read"),
/// the workspace surface must be up ([onWorkspaceSurface] — the New Session
/// canvas or settings is not the chat), the agent panel must actually be on
/// screen ([agentSurfaceVisible]), and [sessionId] must be the active one.
///
/// [onWorkspaceSurface] and [agentSurfaceVisible] are both needed because
/// neither implies the other. On mobile the workspace surface is a two-page
/// PageView — agent | files/git/preview — so the surface being up says nothing
/// about the transcript being visible; on desktop the agent panel is usually
/// visible in the 3-zone layout, but not while a workbench surface (settings,
/// new session) or the agent bar's full-workbench view surface covers it, nor
/// while the context panel is expanded to fill the route.
///
/// A null/empty [sessionId] (a hook that carried no terminal id) matches
/// nothing and always surfaces, rather than being silently swallowed. Session
/// ids are uuids minted per session (bridge session-manager.ts), so the id alone
/// identifies the chat — no project scoping needed.
///
/// Pure so the decision is unit-testable without standing up the workspace.
bool isViewingSession({
  required String? sessionId,
  required String? activeSessionId,
  required bool onWorkspaceSurface,
  required bool agentSurfaceVisible,
  required AppLifecycleState lifecycle,
}) {
  if (sessionId == null || sessionId.isEmpty) return false;
  if (!shouldShowInAppToast(lifecycle)) return false;
  if (!onWorkspaceSurface || !agentSurfaceVisible) return false;
  return activeSessionId == sessionId;
}

/// Whether the Handler is already announcing this agent notification, so the
/// agent's own copy of it must not be surfaced a second time.
///
/// One agent question posts BOTH a `question` notification and a handler event
/// (`agents/claude-code/hooks.ts` puts the two in one invocation), and on an
/// armed slot the engine escalates every blocking prompt without judging it
/// (`isBlockingPrompt`, `handler/engine.ts`) — so the escalation carries the
/// same sentence and, unlike the notification, the escalationId that answers
/// it. The bridge drops the second delivery on the sealed push lane alone
/// (`push/push-dispatcher.ts`, gated on its own `isHandlerArmed`), deliberately:
/// the frame has to keep flowing, because the session's "needs you" dot is
/// folded from it and an ATTACHED app renders it in band. This is that same rule
/// for the in-band lane, and the two must stay in lockstep — a phone that gets
/// one buzz while backgrounded and two while attached is worse than either.
///
/// Keyed on ARMED rather than on an escalation already standing, so the answer
/// does not depend on which of the two frames the router happens to deliver
/// first.
///
/// [handlerArmed] is scoped to the notification's own project: session ids are
/// unique, but the armed set is per-project state and no other project's copy
/// can answer for this one.
bool handlerAnnouncesAgentNotification({
  required String? notificationType,
  required String? sessionId,
  required bool handlerArmed,
}) {
  if (notificationType != 'question') return false;
  if (sessionId == null || sessionId.isEmpty) return false;
  return handlerArmed;
}
