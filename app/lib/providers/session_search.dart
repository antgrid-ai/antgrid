import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recent_session_row.dart';
import '../models/session_entry.dart';
import 'recent_sessions.dart';
import 'value_controller.dart';

/// The session-search query. Deliberately not persisted: a search is a
/// momentary lens, and restoring one at launch would open the app onto a
/// half-empty result popup nobody asked for.
final sessionSearchQueryProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController(''),
    );

/// Focus for the search field WHEREVER this layout mounts it — the window title
/// bar on desktop, the New Session canvas on mobile, which has no title bar.
///
/// Provider-owned rather than a field on a screen's State because Ctrl+K is
/// bound in the shell while the field lives above it. The two mount points are
/// gated on opposite sides of `kCompactBreakpoint`, so one node can never be
/// attached twice.
final sessionSearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'session-search');
  ref.onDispose(node.dispose);
  return node;
});

/// Whether [session] answers [query]. [query] must already be trimmed and
/// lowercased — callers filter whole lists with it, so normalizing per session
/// would redo that work per row.
bool sessionMatchesQuery(SessionEntry session, String query) =>
    session.name.toLowerCase().contains(query);

/// What the search popup lists: every session this device knows about, narrowed
/// to the query.
///
/// Sourced from Recent rather than the drawer because Recent is the one FLAT
/// view spanning machines and projects — a search over the drawer could only
/// hide project rows the user was already looking at, and would say nothing
/// about which session it found. Unfiltered while the query is empty, so
/// opening the popup shows the recent list as its resting state.
///
/// Inherits Recent's sourcing: the persisted session cache, overlaid with the
/// focused project's live list. No keystroke can dial a machine — an eager
/// connect-to-everything is the connection storm the drawer's lazy expansion
/// exists to avoid — so a project this device has never opened is unsearchable.
/// There is nothing here to search.
final sessionSearchResultsProvider = Provider<List<RecentSessionRow>>((ref) {
  final rows = ref.watch(recentSessionsProvider);
  final query = ref.watch(sessionSearchQueryProvider).trim().toLowerCase();
  if (query.isEmpty) return rows;
  return rows
      .where((r) => sessionMatchesQuery(r.session, query))
      .toList(growable: false);
});
