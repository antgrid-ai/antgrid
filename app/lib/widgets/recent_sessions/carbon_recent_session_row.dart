import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_agent_mark.dart';
import '../../models/agent_work_status.dart';
import '../../models/recent_session_row.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/now_ticker.dart';
import '../../providers/project_work_status.dart';
import '../../providers/session_delete_pending.dart';
import '../../providers/session_setup.dart';
import '../../util/relative_time.dart';
import '../carbon_session_badges.dart';
import '../carbon_status_dot.dart';
import '../session_delete_flow.dart' show carbonSessionDeleteDialogs;
import 'recent_session_row_actions.dart';
import 'recent_sessions_summary.dart' show RecentGroupBy;

/// One row of the Recent list: agent mark with a status dot, session name and
/// badges, project, relative time, delete.
///
/// Two lines at every width: the name, badges and time, then where it ran.
///
/// Mounted under a Carbon scope by the tab.
class CarbonRecentSessionRow extends ConsumerWidget {
  const CarbonRecentSessionRow({
    super.key,
    required this.row,
    this.groupedBy,
    this.onDeleted,
  });

  final RecentSessionRow row;

  /// The grouping whose header sits above this row, if any. The row drops
  /// whichever of machine/project that header already names.
  final RecentGroupBy? groupedBy;

  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowMinuteProvider).value;
    final when = DateTime.fromMillisecondsSinceEpoch(row.session.lastUsedAt);
    final agentLabel = sessionAgentDisplayLabel(
      row.session,
      ref.watch(agentCatalogProvider),
    );
    final relTime = relativeTime(when, now: now);
    final deleting = sessionDeleteInFlight(
      ref,
      row.origin.registrationId,
      row.session,
    );
    // The one computation site for a row's status. The group headers and the
    // summary badges read [recentSessionStatusesProvider], which is built by
    // watching THIS provider per row — so a row can't contradict the bucket it
    // sits in, and the row keeps a dependency it can be tested against.
    final status = ref.watch(
      sessionWorkStatusProvider((
        entryId: row.origin.registrationId,
        sessionId: row.session.id,
        running: row.session.running,
      )),
    );
    // The live list's answer, never `row.session.setup`: every Recent row but
    // the focused project's is served from the persisted cache, which carries
    // no setup state at all.
    final setup = ref.watch(sessionSetupProvider(row.session.id));
    final originText = recentOriginText(row.origin, groupedBy);
    final command = recentRowCommandText(row);

    final title = sessionSpokenName(
      name: row.session.name,
      status: status,
      agent: recentRowHasMark(row.session.tool) ? agentLabel : command,
      originText: originText,
      relTime: relTime,
      bypassesApprovals: row.session.approvalPolicy == 'bypass',
      isolation: sessionIsolationSpoken(row.session, setup),
      sharedWorkspace: row.session.sharedWorkspace,
      deleting: deleting,
    );

    final badges = <Widget>[
      CarbonSessionIsolationBadge(session: row.session, setup: setup),
      CarbonSessionApprovalBadge(session: row.session),
      CarbonSessionSharedWorkspaceBadge(session: row.session),
      CarbonSessionDeletingBadge(deleting: deleting),
    ];
    return CarbonContainedListRow(
      title: title,
      leading: _SessionMark(
        status: status,
        toolKey: row.session.tool,
        label: agentLabel,
        deleting: deleting,
      ),
      content: _RowContent(
        name: _SessionName(name: row.session.name),
        badges: badges,
        command: command,
        relTime: relTime,
        originText: originText,
      ),
      // A session being removed is neither focusable nor activatable:
      // opening it would attach the workspace to a checkout that is going
      // away.
      disabled: deleting,
      onPressed: () => openRecentSessionFromRow(context, ref.container, row),
      // A touch user holding a badge to read its tooltip must not also
      // open the session on release.
      cancelOnLongPress: true,
      revealActionsOnHover: true,
      actions: [
        // Kept in the tree while deleting so the row does not shift when
        // deletion starts, but offered to nobody.
        Visibility(
          visible: !deleting,
          maintainSize: true,
          maintainState: true,
          maintainAnimation: true,
          child: CarbonButton.iconOnly(
            icon: const CarbonIcon(CarbonIcons.trashCan),
            semanticLabel: 'Delete session',
            size: CarbonButtonSize.small,
            onPressed: () => deleteRecentSessionWithConfirm(
              context,
              ref.container,
              row,
              dialogs: carbonSessionDeleteDialogs,
              onDeleted: onDeleted,
            ),
          ),
        ),
      ],
    );
  }
}

/// Name, badges and time on one line; the origin and a custom command on the
/// line below, already aligned under the name by the row's leading slot.
class _RowContent extends StatelessWidget {
  const _RowContent({
    required this.name,
    required this.badges,
    required this.command,
    required this.relTime,
    required this.originText,
  });

  final Widget name;
  final List<Widget> badges;
  final String? command;
  final String relTime;
  final String originText;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final secondary = t.typography.label.copyWith(
      color: t.colors.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: CarbonSpacing.spacing01,
      children: [
        Row(
          children: [
            // A Wrap, not a Row: on a narrow phone, or at a large text size,
            // the badges drop below the name instead of overflowing the time.
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [name, ...badges],
              ),
            ),
            const SizedBox(width: CarbonSpacing.spacing03),
            _TimeLabel(label: relTime),
          ],
        ),
        // Only a custom launch command is printed: an agent with a mark is
        // already named at the row's left edge.
        if (originText.isNotEmpty || command != null)
          Row(
            children: [
              if (originText.isNotEmpty)
                Flexible(child: _OriginLabel(text: originText)),
              if (originText.isNotEmpty && command != null)
                Text(' · ', style: secondary),
              if (command != null)
                Flexible(child: _CommandLabel(label: command!)),
            ],
          ),
      ],
    );
  }
}

class _SessionName extends StatelessWidget {
  const _SessionName({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.heading.copyWith(color: t.colors.textPrimary),
    );
  }
}

class _OriginLabel extends StatelessWidget {
  const _OriginLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.label.copyWith(color: t.colors.textSecondary),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      // Tabular so timestamps keep their width as the minute ticks over.
      style: t.typography.label.copyWith(
        color: t.colors.textSecondary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// A custom launch command, printed as-is: the one agent identity with no glyph
/// to stand in for it.
class _CommandLabel extends StatelessWidget {
  const _CommandLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.typography.code.copyWith(color: t.colors.textSecondary),
      ),
    );
  }
}

/// Who is running this session, and how it is doing: the agent mark with a
/// status dot on its corner, the way a presence dot sits on a chat avatar.
///
/// One glyph answers "who, and are they waiting on me" and leaves the lines
/// beside it free for metadata. Without a mark (a custom launch command has no registry key
/// and a monogram of `npm run dev` would be a lie) it is the bare dot, centred
/// in the same box so every row's name column starts at the same x.
class _SessionMark extends StatelessWidget {
  const _SessionMark({
    required this.status,
    required this.toolKey,
    required this.label,
    required this.deleting,
  });

  final AgentWorkStatus status;
  final String? toolKey;
  final String label;

  /// Takes over the whole glyph: identity and work status both describe an
  /// agent that is about to stop existing.
  final bool deleting;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final box = t.iconSize;
    if (deleting) {
      return SizedBox.square(
        dimension: box,
        child: Center(child: CarbonSpinner(size: box)),
      );
    }
    final tool = toolKey;
    if (!recentRowHasMark(tool)) {
      return SizedBox.square(
        dimension: box,
        child: Center(child: CarbonWorkStatusDot(status: status)),
      );
    }
    return SizedBox.square(
      dimension: box,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          CarbonTooltip(
            message: label,
            child: AbAgentMark(
              toolKey: tool!,
              label: label,
              size: box,
              color: t.colors.iconSecondary,
            ),
          ),
          // Hung off the corner rather than inset, so the dot eats as little of
          // the mark as it can. The overhang is decorative and clears the gap
          // that follows the leading slot.
          Positioned(
            right: -CarbonSpacing.spacing01,
            bottom: -CarbonSpacing.spacing01,
            child: CarbonWorkStatusDot(status: status),
          ),
        ],
      ),
    );
  }
}
