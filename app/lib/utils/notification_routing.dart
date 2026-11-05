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

/// The headline of an alert about a session: its own title, or [taskLabel]
/// when the title is unresolved rather than blanking.
///
/// Named even for the session the user was working in: an OS banner is read
/// from another app, and with several sessions running "Task complete" alone
/// leaves the user guessing which of them finished.
String notificationHeadline({
  required String taskLabel,
  required String? sessionTitle,
}) {
  final title = sessionTitle?.trim() ?? '';
  return title.isEmpty ? taskLabel : title;
}

/// HAND-MIRRORED in `AGENT_KINDS` (`bridge/src/push/compose.ts`), which words
/// the same event when it arrives as a push instead; keep both sides in sync.
///
/// Symbols are Unicode 7.0 or older, so every supported OS has a glyph for
/// them. U+FE0F asks for the colour form; without it ⏸ and ⚠ render as
/// monochrome text.
const agentNotificationKinds = {
  'permission_request': (label: 'Permission needed', symbol: '🔐'),
  'awaiting_input': (label: 'Needs your input', symbol: '❓'),
  'question': (label: 'Agent asks', symbol: '❓'),
  'task_complete': (label: 'Task complete', symbol: '✅'),
  'idle': (label: 'Waiting for you', symbol: '⏸️'),
  'error': (label: 'Agent error', symbol: '⚠️'),
};

/// Title and body of an agent `notification:push`. The title names the session
/// and the body leads with a symbol for the kind, so both survive the narrow
/// width of an OS banner; the worded label stands in for a missing session
/// name or message.
({String title, String body}) agentNotificationText({
  required String notificationType,
  required String? message,
  required String? sessionTitle,
}) {
  final kind = agentNotificationKinds[notificationType];
  final label = kind?.label ?? 'Agent';
  final text = (message != null && message.isNotEmpty) ? message : label;
  return (
    title: notificationHeadline(taskLabel: label, sessionTitle: sessionTitle),
    body: kind == null ? text : '${kind.symbol} $text',
  );
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
