import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../providers/providers.dart';

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
/// Fired from the two attach paths (workspace_shell auto-bootstrap and
/// session_row's manual activate) — keep them calling this one gate so the
/// hydration condition can't drift between them.
void hydrateAttachedChatIfNeeded(WidgetRef ref, SessionEntry session) {
  if (session.mode != 'chat' || session.agentSessionId == null) return;
  final svc = ref.read(agentSessionServiceProvider);
  if (svc.stateFor(session.id).turns.isNotEmpty) return;
  unawaited(svc.hydrateIfNeeded(session.id));
}
