import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_focus_ring.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_tap_target.dart';
import '../../design/widgets/ab_snack_bar.dart';
import '../../models/recent_session_row.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/now_ticker.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../services/control_plane_client.dart';
import '../../util/relative_time.dart';
import '../agent_work_status_dot.dart';

/// Confirm dialog for removing a cached recent-session entry.
///
/// Wraps [AbConfirmDialog.show] with wording specific to cache deletion
/// ("cannot be undone") — distinct from live-agent deletion, which warns
/// about process termination.
Future<bool> showDeleteRecentSessionDialog(BuildContext context, String name) {
  return AbConfirmDialog.show(
    context: context,
    title: 'Delete session?',
    body: 'This permanently deletes "$name" and cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
}

/// One row in the Recent tab: status · session name · agent chip · project ·
/// relative time · delete affordance (desktop hover).
class RecentSessionRowWidget extends ConsumerStatefulWidget {
  const RecentSessionRowWidget({super.key, required this.row, this.onDeleted});

  final RecentSessionRow row;
  final VoidCallback? onDeleted;

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
    final agentLabel = sessionAgentDisplayLabel(row.session);
    final relTime = relativeTime(when, now: now);
    // Project-level attention/error (from the live advert) overlaid on this
    // session's own running flag — so a blocked/errored agent is unmistakable
    // in the list even on its idle sessions. Reads the advert map directly (not
    // projectWorkStatusProvider) since the row already owns its running flag.
    final status = recentRowStatus(
      ref.watch(
        remoteProjectStatusProvider.select((m) => m[row.origin.registrationId]),
      ),
      row.session.running,
    );
    void onTap() => openRecentSession(context, ref.container, row);

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
                  onDelete: () => _confirmDelete(context, ref),
                )
              : _DesktopLayout(
                  row: row,
                  status: status,
                  agentLabel: agentLabel,
                  relTime: relTime,
                  showDelete: _hovered || _focused,
                  onDelete: () => _confirmDelete(context, ref),
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

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    // Captured before the dialog await: a confirmed delete must still run if
    // this row was rebuilt away while the dialog was open.
    final container = ref.container;
    final confirmed = await showDeleteRecentSessionDialog(
      context,
      row.session.name,
    );
    if (!confirmed) return;
    final outcome = await deleteRecentSession(container, row);
    if (!context.mounted) return;
    switch (outcome) {
      case RecentSessionDeleteOutcome.deleted:
        widget.onDeleted?.call();
      case RecentSessionDeleteOutcome.offline:
        showAbSnackBar(
          context,
          '${row.origin.deviceName} is offline — connect to delete.',
        );
      case RecentSessionDeleteOutcome.failed:
        showAbSnackBar(context, 'Could not delete "${row.session.name}".');
    }
  }
}

/// Left inset for the mobile project line — aligns under the session name,
/// past the status dot + gap (mirrors Fleet.astro `pl-5` under the dot row).
const double _mobileProjectIndent = AbTokens.dotSizeSm + AbTokens.space12;

/// Desktop: status · name · agent · project · time on one line.
class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({
    required this.row,
    required this.status,
    required this.agentLabel,
    required this.relTime,
    required this.showDelete,
    required this.onDelete,
  });

  final RecentSessionRow row;
  final AgentWorkStatus status;
  final String agentLabel;
  final String relTime;
  final bool showDelete;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    // Two-column scan line: names anchor the left edge, metadata hugs a
    // right rail (agent · project · time) so the eye can sweep either
    // column without zig-zagging through mid-row chips.
    // Reached on a tablet too, where the touch inflation would otherwise
    // out-height the scan line the two-column layout depends on.
    return AbCompactTapTargets(
      child: Row(
        children: [
          _SessionStatus(status: status),
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
                const SizedBox(width: AbTokens.space12),
              ],
            ),
          ),
          _AgentChip(label: agentLabel),
          Text(
            '  ·  ',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: t.textDisabled,
            ),
          ),
          // Fixed cap (no flex) keeps a huge remote path from eating the name
          // column; the < 560px compact fallback above owns the too-narrow case.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: _ProjectLabel(name: _projectDisplayText(row.origin)),
          ),
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

/// Mobile: name + agent + time on the first line; project drops below,
/// indented under the session name (Fleet.astro `sm:hidden` second row).
class _MobileLayout extends StatelessWidget {
  const _MobileLayout({
    required this.row,
    required this.status,
    required this.agentLabel,
    required this.relTime,
    required this.onDelete,
  });

  final RecentSessionRow row;
  final AgentWorkStatus status;
  final String agentLabel;
  final String relTime;

  /// Always-visible trash button — mobile has no hover to reveal the desktop
  /// layout's in-place delete, and a hidden swipe gesture proved
  /// undiscoverable (and used to delete without confirmation).
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The whole row is the tap target for opening the session, so the
        // trash glyph is inline chrome — it must not set the line's height.
        AbCompactTapTargets(
          child: Row(
            children: [
              _SessionStatus(status: status),
              const SizedBox(width: AbTokens.space12),
              Expanded(child: _SessionName(name: row.session.name)),
              const SizedBox(width: AbTokens.space8),
              _AgentChip(label: agentLabel),
              const SizedBox(width: AbTokens.space8),
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

/// The row's leading work-status indicator — working (blue), attention (amber),
/// error (red), or done (green check). See [AgentWorkStatusDot].
class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.status});

  final AgentWorkStatus status;

  @override
  Widget build(BuildContext context) => AgentWorkStatusDot(status: status);
}

/// Agent label (Claude Code, Cursor, …) — a bare mono identifier, not a
/// bordered box: per-row boxes out-shouted the session names and made the
/// list read as chip soup. Mono per the font rules (agent ids are data).
class _AgentChip extends StatelessWidget {
  const _AgentChip({required this.label});

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
