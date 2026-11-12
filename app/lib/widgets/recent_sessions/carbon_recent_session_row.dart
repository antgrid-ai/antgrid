import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
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
import '../agent_work_status_indicator.dart';
import '../carbon_session_badges.dart';
import '../session_delete_flow.dart' show carbonSessionDeleteDialogs;
import 'recent_session_row_actions.dart';
import 'recent_sessions_summary.dart' show RecentGroupBy, workStatusLabel;

/// One row of the Recent list: agent mark with a status dot, session name and
/// badges, project, relative time, delete.
///
/// Mounted under a Carbon scope by the tab. The desktop rail and the stacked
/// layout are chosen from the row's OUTER width, measured outside the contained
/// row: the row's own padding, leading slot and actions cell eat about 84px, so
/// measuring inside would fall back to the stacked layout that much sooner than
/// the 560 the rail was designed against.
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
    final isMobile = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
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

    final title = _accessibleName(
      status: status,
      agent: recentRowHasMark(row.session.tool) ? agentLabel : command,
      originText: originText,
      relTime: relTime,
      isolation: sessionIsolationSpoken(row.session, setup),
      deleting: deleting,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = isMobile || constraints.maxWidth < kRecentRailMinWidth;
        final name = _SessionName(name: row.session.name);
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
          content: compact
              ? _StackedContent(
                  name: name,
                  badges: badges,
                  command: command,
                  relTime: relTime,
                  originText: originText,
                )
              : _RailContent(
                  name: name,
                  badges: badges,
                  command: command,
                  relTime: relTime,
                  originText: originText,
                ),
          // A session being removed is neither focusable nor activatable:
          // opening it would attach the workspace to a checkout that is going
          // away.
          disabled: deleting,
          onPressed: () =>
              openRecentSessionFromRow(context, ref.container, row),
          // A touch user holding a badge to read its tooltip must not also
          // open the session on release.
          cancelOnLongPress: true,
          revealActionsOnHover: true,
          actions: [
            // Kept in the tree while deleting so the rail does not shift when
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
      },
    );
  }

  /// The contained row excludes its content from semantics, so this title is
  /// the row's whole accessible name: everything the badges and rail say.
  String _accessibleName({
    required AgentWorkStatus status,
    required String? agent,
    required String originText,
    required String relTime,
    required String? isolation,
    required bool deleting,
  }) {
    final s = row.session;
    return [
      s.name,
      workStatusLabel(status),
      ?agent,
      if (originText.isNotEmpty) originText,
      relTime,
      if (s.approvalPolicy == 'bypass') 'bypasses approvals',
      ?isolation,
      if (s.sharedWorkspace) 'shared workspace',
      if (deleting) 'deleting',
    ].join(', ');
  }
}

/// Desktop: name and badges on the left, then project, command and time as a
/// right rail.
class _RailContent extends StatelessWidget {
  const _RailContent({
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
    return Row(
      children: [
        // Name and slack share the row's ONLY flexible child. A loose Flexible
        // anywhere in the rail would dump its unused allotment at the row's
        // END, shifting the rail left by a different amount per row. Pooling
        // slack here keeps the rail pinned to the right edge, and the badges
        // are measured before the name so a long name ellipsizes around them.
        Expanded(
          child: Row(
            children: [
              Flexible(child: name),
              ...badges,
              const SizedBox(width: CarbonSpacing.spacing04),
            ],
          ),
        ),
        // Fixed width, not a cap: every row's project text starts at the same
        // x however long the name column is.
        SizedBox(
          width: kRecentRailProjectWidth,
          child: _ProjectLabel(name: originText),
        ),
        if (command != null) ...[
          Text(
            '  ·  ',
            style: t.typography.code.copyWith(color: t.colors.textHelper),
          ),
          _CommandLabel(label: command!),
        ],
        const SizedBox(width: CarbonSpacing.spacing04),
        SizedBox(
          width: _railTimeWidth(context, _TimeLabel.style(t)),
          child: _TimeLabel(label: relTime),
        ),
      ],
    );
  }

  /// The longest relative time, measured in the style and text scale it is
  /// drawn at, so every row's time column is the same width and none of them
  /// loses its last word. A fixed width fits only one density and scale.
  static double _railTimeWidth(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: kRecentRailLongestTime, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }
}

/// Phone or narrow pane: name, badges and time on one line; the project and a
/// custom command drop below, already aligned under the name by the row's
/// leading slot.
class _StackedContent extends StatelessWidget {
  const _StackedContent({
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
        // already named at the row's left edge. It shares the second line, not
        // the first, where it and the time left the name no room on a phone.
        if (originText.isNotEmpty || command != null)
          Row(
            children: [
              if (originText.isNotEmpty)
                Flexible(child: _ProjectLabel(name: originText)),
              if (originText.isNotEmpty && command != null)
                Text(
                  '  ·  ',
                  style: _TimeLabel.style(CarbonTheme.of(context)),
                ),
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

class _ProjectLabel extends StatelessWidget {
  const _ProjectLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    // Project and machine names are data.
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.code.copyWith(color: t.colors.textSecondary),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.label});

  final String label;

  /// Mono so the right rail's timestamps line up column-tight across rows.
  static TextStyle style(CarbonThemeData t) =>
      t.typography.code.copyWith(color: t.colors.textHelper);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style(CarbonTheme.of(context)),
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
/// One glyph answers "who, and are they waiting on me" and leaves the rail free
/// for metadata. Without a mark (a custom launch command has no registry key
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
        child: Center(child: _StatusDot(status: status)),
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
            child: _StatusDot(status: status),
          ),
        ],
      ),
    );
  }
}

/// A status dot in the Carbon support colours. Not a Carbon component: the
/// indicator glyphs are too large to hang off an icon's corner. Only `done` is
/// a ring, so it stays distinguishable from the live states without relying on
/// its grey.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final AgentWorkStatus status;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final color = agentWorkStatusDotColor(t, status) ?? t.colors.iconSecondary;
    final hollow = agentWorkStatusDotHollow(status);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // A ring is filled with the surface so the mark behind it does not
          // show through.
          color: hollow ? t.layer(CarbonLayer.of(context)) : color,
          border: hollow ? Border.all(color: color) : null,
        ),
        child: const SizedBox.square(dimension: CarbonSpacing.spacing03),
      ),
    );
  }
}
