import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_agent_mark.dart';
import '../../design/widgets/ab_focus_ring.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_tap_target.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/recent_session_row.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/now_ticker.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../services/control_plane_client.dart';
import '../../services/sessions_service.dart' show SessionOperationException;
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import '../agent_work_status_dot.dart';
import '../session_delete_flow.dart';
import '../session_isolation_badge.dart';

/// One row in the Recent tab: agent mark (status-badged) · session name ·
/// project · relative time · delete affordance (desktop hover).
class RecentSessionRowWidget extends ConsumerStatefulWidget {
  const RecentSessionRowWidget({
    super.key,
    required this.row,
    this.onDeleted,
    this.onOpened,
    this.surfaceColor,
  });

  final RecentSessionRow row;
  final VoidCallback? onDeleted;

  /// Fired after the row has navigated. Exists for hosts that must dismiss
  /// themselves once a row is taken — the search popup, which would otherwise
  /// stay open over the session it just opened.
  final VoidCallback? onOpened;

  /// What is painted BEHIND an unhovered row. The status badge punches itself
  /// free of the agent mark with a ring in this colour, so a value that isn't
  /// the real backdrop reads as a halo. Defaults to the New Session canvas's
  /// `bgDeepest` (see `new_session_content.dart`) — pass it explicitly if this
  /// list is ever mounted on another surface, because nothing here can detect
  /// the mismatch.
  final Color? surfaceColor;

  @override
  ConsumerState<RecentSessionRowWidget> createState() =>
      _RecentSessionRowWidgetState();
}

class _RecentSessionRowWidgetState
    extends ConsumerState<RecentSessionRowWidget> {
  bool _hovered = false;
  bool _focused = false;

  RecentSessionRow get row => widget.row;

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowMinuteProvider).value;
    final when = DateTime.fromMillisecondsSinceEpoch(row.session.lastUsedAt);
    final isMobile = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    final t = context.antgrid;
    final agentLabel = sessionAgentDisplayLabel(
      row.session,
      ref.watch(agentCatalogProvider),
    );
    final relTime = relativeTime(when, now: now);
    // Tracks the hover swap below: an unhovered row paints nothing of its own,
    // so the badge's ring has to be the SURFACE colour, but a hovered one
    // paints bgHover over it. Pinning either would show as a halo in the other
    // state. See [RecentSessionRowWidget.surfaceColor].
    final rowBg = _hovered ? t.bgHover : (widget.surfaceColor ?? t.bgDeepest);
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
    void onTap() {
      // The navigator's own context, not this row's: a host that dismisses
      // itself on open — the search popup, the search modal — unmounts this row
      // while `openRecentSession` is still awaiting, and the cold-remote path
      // it awaits needs a live context to put its dialogs and errors on. The
      // navigator outlives any one route or overlay entry. Falls back to the
      // row's own context where there is no Navigator (widget tests).
      final host = Navigator.maybeOf(context, rootNavigator: true)?.context;
      widget.onOpened?.call();
      // Detached: nothing awaits a tap handler, so an activation that rejects
      // (a bridge verb whose reply never lands) would surface as a fatal.
      detached(
        'RecentSessionRow',
        'session open failed',
        () => openRecentSession(host ?? context, ref.container, row),
      );
    }

    final content = Container(
      color: _hovered ? t.bgHover : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The desktop rail (agent · project · time · delete slot) is
          // deliberately inflexible so its right edge stays column-aligned;
          // below its minimum width fall back to the stacked layout even on
          // desktop (a narrow split pane), instead of overflowing.
          final compact = isMobile || constraints.maxWidth < 560;
          return compact
              ? _MobileLayout(
                  row: row,
                  status: status,
                  agentLabel: agentLabel,
                  relTime: relTime,
                  rowBg: rowBg,
                  onDelete: () => _deleteDetached(context, ref),
                )
              : _DesktopLayout(
                  row: row,
                  status: status,
                  agentLabel: agentLabel,
                  relTime: relTime,
                  rowBg: rowBg,
                  showDelete: _hovered || _focused,
                  onDelete: () => _deleteDetached(context, ref),
                );
        },
      ),
    );

    // FocusableActionDetector (not just MouseRegion+GestureDetector) so
    // keyboard users can Tab to a row and activate it with Enter/Space,
    // mirroring AbListRow's interactive path.
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      onShowHoverHighlight: isMobile
          ? null
          : (v) => setState(() => _hovered = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AbFocusRing(focused: _focused, child: content),
      ),
    );
  }

  /// Same boundary as `onTap`: the delete button's callback is `void`, so the
  /// confirm chain's failure has to stop here.
  void _deleteDetached(BuildContext context, WidgetRef ref) => detached(
    'RecentSessionRow',
    'session delete failed',
    () => _confirmDelete(context, ref),
  );

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    // Captured before the dialog await: a confirmed delete must still run if
    // this row was rebuilt away while the dialog was open.
    final container = ref.container;
    final result = await confirmAndDeleteSession(
      context: context,
      sessionName: row.session.name,
      checkoutKind: row.session.checkoutKind,
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
        // The ladder reports a SessionOperationException and nothing else, so
        // the two non-refusal outcomes are raised as one too — a bare `false`
        // would leave the offline case, the only one a user can act on, unsaid.
        return switch (outcome) {
          RecentSessionDeleteOutcome.deleted => true,
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
    );
    if (result == SessionDeleteResult.deleted) widget.onDeleted?.call();
  }
}

/// Left inset for the mobile project line — aligns under the session name,
/// past the leading mark + gap (mirrors Fleet.astro `pl-5` under the dot row).
const double _mobileProjectIndent = _leadingSize + AbTokens.space12;

/// Desktop: mark · name · project · time on one line.
class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({
    required this.row,
    required this.status,
    required this.agentLabel,
    required this.relTime,
    required this.rowBg,
    required this.showDelete,
    required this.onDelete,
  });

  final RecentSessionRow row;
  final AgentWorkStatus status;
  final String agentLabel;
  final String relTime;
  final Color rowBg;
  final bool showDelete;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Two-column scan line: names anchor the left edge, metadata hugs a
    // right rail (project · time) so the eye can sweep either column without
    // zig-zagging through mid-row chips.
    // Reached on a tablet too, where the touch inflation would otherwise
    // out-height the scan line the two-column layout depends on.
    final command = _railCommandText(row);
    return AbCompactTapTargets(
      child: Row(
        children: [
          _SessionMark(
            status: status,
            toolKey: row.session.tool,
            label: agentLabel,
            ringColor: rowBg,
          ),
          const SizedBox(width: AbTokens.space12),
          // Name + slack share the row's ONLY flexible child. A loose Flexible
          // anywhere in the rail would dump its unused allotment at the row's
          // END (RenderFlex puts leftover space after the last child), shifting
          // the rail left by a different amount per row — the times would go
          // ragged. Pooling slack here keeps the rail pinned to the right edge.
          Expanded(
            child: Row(
              children: [
                Flexible(child: _SessionName(name: row.session.name)),
                // Non-flex, so the badge is measured before the name and a long
                // name ellipsizes around it rather than pushing it off the row.
                SessionIsolationBadge(session: row.session),
                const SizedBox(width: AbTokens.space12),
              ],
            ),
          ),
          // Fixed cap (no flex) keeps a huge remote path from eating the name
          // column; the < 560px compact fallback above owns the too-narrow case.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: _ProjectLabel(name: _projectDisplayText(row.origin)),
          ),
          if (command != null) ...[
            Text(
              '  ·  ',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textDisabled,
              ),
            ),
            _CommandLabel(label: command),
          ],
          const SizedBox(width: AbTokens.space12),
          // Delete swaps IN PLACE of the time on hover (cross-fade in a
          // right-aligned Stack) instead of reserving a trailing slot — the
          // times stay truly flush with the row's right edge, and the rail
          // never shifts because the Stack's width is the wider of the two.
          Stack(
            alignment: Alignment.centerRight,
            children: [
              AnimatedOpacity(
                duration: AbTokens.motionSnap,
                opacity: showDelete ? 0 : 1,
                child: _TimeLabel(label: relTime),
              ),
              AnimatedOpacity(
                duration: AbTokens.motionSnap,
                opacity: showDelete ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !showDelete,
                  child: AbIconButton(
                    icon: AbIcons.trash,
                    tooltip: 'Delete session',
                    onTap: onDelete,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mobile: mark + name + time on the first line; project drops below,
/// indented under the session name (Fleet.astro `sm:hidden` second row).
class _MobileLayout extends StatelessWidget {
  const _MobileLayout({
    required this.row,
    required this.status,
    required this.agentLabel,
    required this.relTime,
    required this.rowBg,
    required this.onDelete,
  });

  final RecentSessionRow row;
  final AgentWorkStatus status;
  final String agentLabel;
  final String relTime;
  final Color rowBg;

  /// Always-visible trash button — mobile has no hover to reveal the desktop
  /// layout's in-place delete, and a hidden swipe gesture proved
  /// undiscoverable (and used to delete without confirmation).
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final command = _railCommandText(row);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The whole row is the tap target for opening the session, so the
        // trash glyph is inline chrome — it must not set the line's height.
        AbCompactTapTargets(
          child: Row(
            children: [
              _SessionMark(
                status: status,
                toolKey: row.session.tool,
                label: agentLabel,
                ringColor: rowBg,
              ),
              const SizedBox(width: AbTokens.space12),
              Expanded(child: _SessionName(name: row.session.name)),
              SessionIsolationBadge(session: row.session),
              const SizedBox(width: AbTokens.space8),
              // Only a custom launch command belongs on this line: an agent
              // with a mark is already named at the row's left edge, and
              // repeating it here crowds the name against the time.
              if (command != null) ...[
                _CommandLabel(label: command),
                const SizedBox(width: AbTokens.space8),
              ],
              _TimeLabel(label: relTime),
              const SizedBox(width: AbTokens.space4),
              AbIconButton(
                icon: AbIcons.trash,
                tooltip: 'Delete session',
                onTap: onDelete,
              ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space2),
        Padding(
          padding: const EdgeInsets.only(left: _mobileProjectIndent),
          // Device-prefixed like desktop: on mobile there's no other place
          // for a remote row to carry which machine it ran on.
          child: _ProjectLabel(name: _projectDisplayText(row.origin)),
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
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontMd,
        color: context.antgrid.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Remote rows prefix the project name with the origin device — the group
/// header only carries that identity when grouped "by machine", so a row
/// grouped by project/status must still show which machine it ran on itself.
String _projectDisplayText(RecentOrigin origin) {
  if (origin.isLocal) return origin.projectName;
  return '${origin.deviceName} · ${origin.projectName}';
}

class _ProjectLabel extends StatelessWidget {
  const _ProjectLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontSm,
        color: context.antgrid.textMuted,
      ),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    // Mono so the right rail's timestamps line up column-tight across rows.
    return Text(
      label,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontXs,
        color: context.antgrid.textMuted,
      ),
    );
  }
}

/// Whether this session has an agent identity worth drawing as a glyph. A
/// custom launch command has no registry key, so there is no mark to look up
/// and a monogram of `npm run dev` would be a lie.
bool _hasMark(String? toolKey) => toolKey != null && toolKey.isNotEmpty;

/// The rail's agent text, or null when there is nothing honest to print there.
///
/// Only a real custom command earns text. Don't fall back to
/// [sessionAgentDisplayLabel] here: with neither a tool nor a command that
/// helper names the DEFAULT agent, so a row we can't identify would print
/// "Claude Code" as mono data while an identical row that really is Claude Code
/// prints nothing and draws a mark instead — same agent, two presentations, one
/// of them a guess.
String? _railCommandText(RecentSessionRow row) {
  if (_hasMark(row.session.tool)) return null;
  final command = row.session.command?.trim();
  return (command != null && command.isNotEmpty) ? command : null;
}

/// Side of the leading glyph box. The mark fills all but a hair of it; the
/// badge overhangs the corner, which is why the box is squared and fixed —
/// every row's name column has to start at the same x.
const double _leadingSize = 18;

/// Who is running this session, and how it is doing — one glyph, the way a
/// presence dot sits on a chat avatar.
///
/// Identity and status ride one glyph rather than a dot at the left edge and an
/// agent out on the right rail: one leading column answers "who, and are they
/// waiting on me", and the rail stays free for metadata. Splitting them again
/// costs the rail a slot that mobile has no room for.
///
/// Without a mark ([_hasMark]) this is the bare status dot, centred in the same
/// box so the name column stays aligned, and the command text keeps its place
/// in the row instead.
class _SessionMark extends StatelessWidget {
  const _SessionMark({
    required this.status,
    required this.toolKey,
    required this.label,
    required this.ringColor,
  });

  final AgentWorkStatus status;
  final String? toolKey;
  final String label;

  /// The row's own background — see [AgentWorkStatusBadge.ringColor].
  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    final tool = toolKey;
    if (!_hasMark(tool)) {
      return SizedBox.square(
        dimension: _leadingSize,
        child: Center(child: AgentWorkStatusDot(status: status)),
      );
    }
    return SizedBox.square(
      dimension: _leadingSize,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AbTooltip(
            message: label,
            child: AbAgentMark(toolKey: tool!, label: label, size: 16),
          ),
          // Hung off the corner rather than inset, so the badge eats as little
          // of the mark as a 6px dot can be made to. The overhang is decorative
          // and clears the space12 gap that follows.
          Positioned(
            right: -2,
            bottom: -2,
            child: AgentWorkStatusBadge(status: status, ringColor: ringColor),
          ),
        ],
      ),
    );
  }
}

/// A custom launch command, printed as-is — the one agent identity with no
/// glyph to stand in for it. Mono per the font rules (commands are data).
class _CommandLabel extends StatelessWidget {
  const _CommandLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          color: context.antgrid.textSecondary,
        ),
      ),
    );
  }
}
