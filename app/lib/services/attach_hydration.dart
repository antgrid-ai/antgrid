import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../providers/providers.dart';
import 'agent_session_service.dart';

/// Backfill prior turns for a chat session with no locally cached turns on THIS
/// device — e.g. a mobile client attaching to a session desktop started earlier.
/// No-op unless the session is a chat with a captured agent session id and zero
/// cached turns, so it's safe to fire on every activation.
///
/// Pass the AUTHORITATIVE entry, never the drawer's peeked one: the peek is a
/// disk read that reports `running:false` for every session (see
/// SessionManager.readPersisted), so callers can't tell a stopped session from
/// one live on another device. They resolve that by starting it — a no-op on the
/// bridge if it was already running — and hydrating off the entry `start()`
/// returns.
///
/// Firing this after a real start is harmless: the driver's own start-time
/// replay and this pull carry identical turn/item ids, which the reducer dedups
/// (turn-start by turnId, items by upsert).
///
/// Driven from the ONE chokepoint every session activation funnels through —
/// [AgentTranscriptView.initState] (the view is keyed by session id, so a fresh
/// State mounts per active chat session). Centralised there rather than at each
/// activation call site precisely because the scattered variant kept missing
/// paths (cross-project open, nav restore), leaving sessions blank. Deferral for
/// a not-yet-established relay stream lives in [AgentSessionService.hydrateIfNeeded].
/// Returns the resolved service (or null if not ready) so the caller can pin the
/// exact instance a hydrator was registered on and call `stopHydrating` on it at
/// view dispose — `serviceWhenReady` uses `ref.watch`, which is illegal in
/// `dispose`, so the instance must be captured while the view is live.
AgentSessionService? hydrateAttachedChatIfNeeded(
  WidgetRef ref,
  SessionEntry session,
) {
  if (session.mode != 'chat' || session.agentSessionId == null) return null;
  // serviceWhenReady, not ref.read: the view fires this from a post-frame
  // callback where the project session may still be resolving — a throwing
  // read would crash the frame. A null service just means "try again next
  // mount", which the keyed-per-session view does for free.
  final svc = serviceWhenReady(ref, agentSessionServiceProvider);
  if (svc == null) return null;
  if (svc.stateFor(session.id).turns.isNotEmpty) return svc;
  unawaited(svc.hydrateIfNeeded(session.id));
  return svc;
}
