import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/recent_session_row.dart';
import '../../providers/recent_sessions.dart';
import '../../providers/session_delete_pending.dart';
import '../../services/sessions_service.dart' show SessionDeleteAck, SessionOperationException;
import '../../util/detached.dart';
import '../session_delete_flow.dart';
import 'recent_sessions_summary.dart' show RecentGroupBy;

/// Below this OUTER row width a Recent row (and the starting row above them)
/// drops the one-line rail for the stacked layout, so a narrow split pane does
/// not overflow. Measured outside the contained row's padding and leading slot
/// so every row in a list switches together.
const double kRecentRailMinWidth = 560;

/// Fixed width of the desktop rail's project slot, applied as the slot's actual
/// size (not just a cap) so every row's project text starts at the same x
/// instead of trailing the name column by a variable amount.
const double kRecentRailProjectWidth = 220;

/// The longest relative time a row can show, which the Carbon rail measures
/// to size its time column.
const String kRecentRailLongestTime = '11 months ago';

/// Fixed width of the desktop rail's trailing time slot, wide enough for the
/// longest relative time ("11 months ago", 13 chars) in the mono data style.
/// Without it a row's project label shares the leftover space with the time
/// string beside it, so the rail reads as raggedly spaced from row to row.
const double kRecentRailTimeWidth = 96;

/// Where a row ran, minus whatever its group header already names: by machine
/// the project alone, by project the machine alone (nothing for a local row,
/// which never names its device), otherwise `machine · project` for remote rows.
String recentOriginText(RecentOrigin origin, RecentGroupBy? groupedBy) {
  return switch (groupedBy) {
    RecentGroupBy.machine => origin.projectName,
    RecentGroupBy.project => origin.isLocal ? '' : origin.deviceName,
    _ when origin.isLocal => origin.projectName,
    _ => '${origin.deviceName} · ${origin.projectName}',
  };
}

/// Whether this session has an agent identity worth drawing as a glyph. A
/// custom launch command has no registry key, so there is no mark to look up
/// and a monogram of `npm run dev` would be a lie.
bool recentRowHasMark(String? toolKey) => toolKey != null && toolKey.isNotEmpty;

/// The rail's agent text, or null when there is nothing honest to print there.
///
/// Only a real custom command earns text. Don't fall back to
/// `sessionAgentDisplayLabel` here: with neither a tool nor a command that
/// helper names the DEFAULT agent, so a row we can't identify would print
/// "Claude Code" as data while an identical row that really is Claude Code
/// prints nothing and draws a mark instead — same agent, two presentations, one
/// of them a guess.
String? recentRowCommandText(RecentSessionRow row) {
  if (recentRowHasMark(row.session.tool)) return null;
  final command = row.session.command?.trim();
  return (command != null && command.isNotEmpty) ? command : null;
}

/// Opens [row]'s session, the same way for every surface that lists it.
///
/// Resolves the navigator's own context rather than using [context]: a host
/// that dismisses itself on open — the search popup, the search modal — unmounts
/// its row while `openRecentSession` is still awaiting, and the cold-remote path
/// it awaits needs a live context to put its dialogs and errors on. The
/// navigator outlives any one route or overlay entry. Falls back to [context]
/// where there is no Navigator (widget tests).
///
/// Detached: nothing awaits a tap handler, so an activation that rejects (a
/// bridge verb whose reply never lands) would surface as a fatal.
void openRecentSessionFromRow(
  BuildContext context,
  ProviderContainer container,
  RecentSessionRow row, {
  VoidCallback? onOpened,
}) {
  final host = Navigator.maybeOf(context, rootNavigator: true)?.context;
  onOpened?.call();
  detached(
    'RecentSessionRow',
    'session open failed',
    () => openRecentSession(host ?? context, container, row),
  );
}

/// The delete button's callback is `void`, so the confirm chain's failure has to
/// stop here.
void deleteRecentSessionWithConfirm(
  BuildContext context,
  ProviderContainer container,
  RecentSessionRow row, {
  SessionDeleteDialogs dialogs = abSessionDeleteDialogs,
  VoidCallback? onDeleted,
}) => detached(
  'RecentSessionRow',
  'session delete failed',
  () => _confirmDelete(context, container, row, dialogs, onDeleted),
);

Future<void> _confirmDelete(
  BuildContext context,
  ProviderContainer container,
  RecentSessionRow row,
  SessionDeleteDialogs dialogs,
  VoidCallback? onDeleted,
) async {
  final markKey = sessionDeleteKey(row.origin.registrationId, row.session.id);
  final result = await confirmAndDeleteSession(
    context: context,
    dialogs: dialogs,
    sessionName: row.session.name,
    checkoutKind: row.session.checkoutKind,
    sharedWorkspace: row.session.sharedWorkspace,
    // A Recent row is a cache entry, so this surface can't promise anything
    // about a process: the session may have no agent running to terminate.
    sharedBody: 'This permanently deletes "${row.session.name}".',
    delete: ({force, deleteBranch}) async {
      final outcome = await deleteRecentSession(
        container,
        row,
        force: force,
        deleteBranch: deleteBranch,
      );
      // The ladder reports a SessionOperationException and nothing else, so the
      // two non-refusal outcomes are raised as one too — a bare `false` would
      // leave the offline case, the only one a user can act on, unsaid.
      return switch (outcome) {
        RecentSessionDeleteOutcome.deleted => SessionDeleteAck.deleted,
        RecentSessionDeleteOutcome.outcomeUnknown =>
          SessionDeleteAck.outcomeUnknown,
        RecentSessionDeleteOutcome.offline => throw SessionOperationException(
          null,
          '${row.origin.deviceName} is offline — connect to delete.',
        ),
        RecentSessionDeleteOutcome.failed => throw SessionOperationException(
          null,
          'Could not delete "${row.session.name}".',
        ),
      };
    },
    onInFlight: (inFlight) {
      final marks = container.read(sessionDeleteRequestsProvider.notifier);
      if (inFlight) {
        marks.arm(markKey);
      } else {
        marks.disarm(markKey);
      }
    },
  );
  if (result == SessionDeleteResult.deleted) onDeleted?.call();
}
