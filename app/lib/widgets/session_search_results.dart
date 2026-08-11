import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../providers/session_search.dart';
import 'recent_sessions/recent_session_row_widget.dart';

/// The session search's answer, without any chrome of its own.
///
/// Shared by the two surfaces that ask the question — the desktop popup and the
/// mobile full-screen modal — so the results can never differ between them,
/// only the box around them.
class SessionSearchResults extends ConsumerWidget {
  const SessionSearchResults({
    super.key,
    required this.onOpened,
    required this.surfaceColor,
    this.shrinkWrap = false,
  });

  /// Fired once a row has been taken, so the host can dismiss itself rather
  /// than stay open over the session it just opened.
  final VoidCallback onOpened;

  /// What is painted behind the rows — the badge rings are drawn in it, so a
  /// wrong value reads as a halo. See [RecentSessionRowWidget.surfaceColor].
  final Color surfaceColor;

  /// True for the popup, which is sized by its content up to a cap; false for
  /// the modal, which is handed a fixed height to fill.
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(sessionSearchResultsProvider);
    final searching = ref.watch(sessionSearchQueryProvider).trim().isNotEmpty;

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AbTokens.space16),
        child: Text(
          searching ? 'No sessions match.' : 'No recent sessions.',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: context.antgrid.textMuted,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space4),
      shrinkWrap: shrinkWrap,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        return RecentSessionRowWidget(
          key: ValueKey('${row.origin.registrationId}:${row.session.id}'),
          row: row,
          surfaceColor: surfaceColor,
          onOpened: onOpened,
        );
      },
    );
  }
}
