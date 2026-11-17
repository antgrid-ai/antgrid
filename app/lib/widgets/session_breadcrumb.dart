import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/widgets/ab_toast.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../models/session_entry.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/recent_sessions.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../services/pending_reply.dart' show SessionDownException;
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'carbon_session_badges.dart';
import 'carbon_session_rename_dialog.dart';

/// The agent name / session breadcrumb, with git branch pill.
///
/// Named for the row it used to live in; both its surfaces are now in
/// `agent_panel.dart` — the mobile header and the desktop `AgentBar` — kept as
/// one widget so the two cannot drift apart.
class TitleBarBreadcrumb extends ConsumerWidget {
  const TitleBarBreadcrumb({super.key, this.showBranchPill = true});

  /// False on the mobile agent-panel header (`AgentPanel`), which leaves the
  /// branch to its overflow menu's header label — a phone-width row has no
  /// space to spare for an unshrinkable sibling beside the title. Desktop's
  /// `AgentBar` keeps the default, where the pill still sits inline.
  final bool showBranchPill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalState = ref.watch(terminalStateProvider).value;
    final activeId = ref.watch(selectedRegistrationIdProvider);
    // `agent:status` is pushed per checkout and never replayed, so an ISOLATED
    // session's bundle can miss the only frame that carries the name: the
    // worktree runtime emits it while being prepared, before the session is
    // announced and the app has built that checkout's TerminalService. Falling
    // straight through to the id then renders a 16-char hash as the project.
    final agentName =
        terminalState?.agentInfo?.name ??
        (activeId == null
            ? 'Antgrid'
            : ref.watch(projectDisplayNameProvider(activeId)) ??
                  projectNameFromId(activeId));
    final gitBranch = terminalState?.gitBranch;
    final active = ref.watch(activeSessionProvider);
    return AbCarbonScope(
      child: Row(
        children: [
          Flexible(
            flex: 2,
            fit: FlexFit.loose,
            child: active == null
                ? _Segment(text: agentName, secondary: false)
                : _Path(project: agentName, session: active),
          ),
          if (active != null) ...[
            CarbonSessionIsolationBadge(
              session: active,
              // The live list's answer, never `active.setup`: the entry can come
              // from the persisted cache, which carries no setup state at all.
              setup: ref.watch(activeSessionSetupProvider),
            ),
            CarbonSessionSharedWorkspaceBadge(session: active),
          ],
          if (showBranchPill && gitBranch != null) ...[
            const SizedBox(width: CarbonSpacing.spacing03),
            // FlexFit.loose, not Expanded: the path keeps first claim on
            // slack (it has the higher flex), and this only gives up its own
            // width once the row is actually tight — a bare ConstrainedBox
            // here does not shrink with the row at all, since a non-flex Row
            // child is sized from its own content, capped but never squeezed,
            // which is what let the fixed badges above push this row into
            // overflow on a narrow agent panel. The tag's own ellipsis is what
            // turns this shrink into truncation instead of a second overflow
            // one widget down.
            Flexible(
              fit: FlexFit.loose,
              child: SessionBranchPill(maxWidth: 160),
            ),
          ],
        ],
      ),
    );
  }
}

/// Below this width per segment the path drops the project and keeps only the
/// session, which is the part the user acts on.
const double _kMinSegmentWidth = 140;

/// `project / session`. Neither segment navigates, so this is plain text and
/// not a breadcrumb: link styling would promise a click that does nothing. Only
/// the session responds, by renaming.
class _Path extends StatelessWidget {
  const _Path({required this.project, required this.session});

  final String project;
  final SessionEntry session;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final leaf = EditableSessionLeaf(session: session);
        if (constraints.maxWidth < _kMinSegmentWidth * 2) return leaf;
        final t = CarbonTheme.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Capped, not flexible: a flex share would stay reserved for a
            // short project name while the session name truncated beside the
            // empty space. longestLine shrinks the box to the text it paints.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kMinSegmentWidth),
              child: _Segment(text: project, secondary: true),
            ),
            Text(
              ' / ',
              key: const Key('breadcrumb-separator'),
              style: t.typography.body.copyWith(color: t.colors.textSecondary),
            ),
            Flexible(child: leaf),
          ],
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.text, required this.secondary});

  final String text;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      text,
      key: const Key('breadcrumb-project'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textWidthBasis: TextWidthBasis.longestLine,
      style: t.typography.body.copyWith(
        color: secondary ? t.colors.textSecondary : t.colors.textPrimary,
      ),
    );
  }
}

/// The active session's git branch tag — tap to copy. Only the inline
/// breadcrumb ([TitleBarBreadcrumb]) mounts it: the phone header drops the pill
/// (`showBranchPill: false`) and its overflow menu names the branch as a plain
/// header label, so a phone has no tap-to-copy branch. Renders nothing while
/// there is no branch to show.
class SessionBranchPill extends ConsumerWidget {
  const SessionBranchPill({super.key, this.maxWidth});

  /// Caps the pill's width when it sits beside the breadcrumb — an
  /// unshrinkable sibling would otherwise floor the title's own space on a
  /// narrow window. Null renders it at its natural width, for a slot nothing
  /// else competes with for room.
  final double? maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalState = ref.watch(terminalStateProvider).value;
    final gitBranch = terminalState?.gitBranch;
    if (gitBranch == null) return const SizedBox.shrink();

    final ahead = terminalState?.gitAhead ?? 0;
    final behind = terminalState?.gitBehind ?? 0;
    // Behind before ahead, the order every SCM status line uses.
    final label = [
      gitBranch,
      if (behind > 0) '\u2193$behind',
      if (ahead > 0) '\u2191$ahead',
    ].join(' ');
    final pill = AbCarbonScope(
      child: CarbonTag(
        key: const Key('session-branch-tag'),
        label: label,
        // Medium, not small: a small tag does not draw its leading glyph.
        icon: const CarbonIcon(CarbonIcons.branch, size: 16),
        onPressed: () =>
            detached('WindowTitleBar', 'copy branch name', () async {
              await Clipboard.setData(ClipboardData(text: gitBranch));
              if (!context.mounted) return;
              showAbToast(
                context,
                'Copied "$gitBranch"',
                duration: const Duration(seconds: 2),
              );
            }),
      ),
    );
    final width = maxWidth;
    return width == null
        ? pill
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: pill,
          );
  }
}

/// The breadcrumb leaf for the active session — tap to rename it via the
/// shared [showCarbonSessionRename] dialog (desktop and mobile alike). The active
/// session belongs to the focused project, so the commit resolves that
/// project's id up front and then routes through [warmServiceFor] — see
/// [_rename] for why the id is captured rather than re-read after the dialog.
class EditableSessionLeaf extends ConsumerStatefulWidget {
  final SessionEntry session;
  const EditableSessionLeaf({super.key, required this.session});

  @override
  ConsumerState<EditableSessionLeaf> createState() =>
      _EditableSessionLeafState();
}

class _EditableSessionLeafState extends ConsumerState<EditableSessionLeaf> {
  /// The name the user asked for while the rename is in flight, else null.
  ///
  /// Shown in place of the committed name and pulsing, which is the same shape
  /// `SessionModeControl` uses for a flip in flight (`activeSessionModeProvider`
  /// hands out the pending mode the same way): the breadcrumb reads as "being
  /// applied" without claiming it landed. A refusal clears it, so the old name
  /// comes back alongside the message rather than a wrong name sticking.
  ///
  /// Local state, not an app-wide provider like `pendingSessionModeProvider`:
  /// nothing outside this leaf renders a rename in flight, and the cost of
  /// losing it (the breadcrumb unmounted mid-rename, e.g. a panel-mode change)
  /// is a missing pulse, not a wrong name.
  String? _pendingName;

  /// [dialogContext] sits under the Carbon scope the dialog needs. Everything
  /// after the await uses `State.context` and guards every UI touch on `mounted`
  /// rather than taking a [BuildContext] parameter — the two are the same
  /// element here, and only the State's own flag is a valid guard for it.
  Future<void> _rename(BuildContext dialogContext) async {
    final session = widget.session;
    final id = session.id;
    // Container and entry id captured BEFORE the dialog: the breadcrumb can be
    // rebuilt away while it is open, and a `WidgetRef` touched past that point
    // throws. The id is read here rather than after, so the rename commits
    // against the project that owned this session when the dialog opened — a
    // focus switch behind an open dialog must not retarget it at another agent.
    final container = ref.container;
    final entryId = container.read(selectedRegistrationIdProvider);
    final name = await showCarbonSessionRename(dialogContext, session.name);
    if (name == null || name == session.name) return;
    // The asked-for name goes up the moment the dialog closes and comes down in
    // the `finally` below, so every outcome ends with the breadcrumb telling the
    // truth: on success the `session:updated` push has already made
    // [widget.session] carry it (the swap back is invisible), and on a refusal
    // or a dropped reply the committed name returns alongside the message.
    // Guarded on `mounted` in both directions rather than bailing: a rename the
    // user confirmed still commits when the breadcrumb was rebuilt away behind
    // the dialog — it just has nowhere to show a pulse.
    if (mounted) setState(() => _pendingName = name);
    try {
      await _commit(container, entryId, id, name);
    } finally {
      if (mounted) setState(() => _pendingName = null);
    }
  }

  Future<void> _commit(
    ProviderContainer container,
    String? entryId,
    String id,
    String name,
  ) async {
    // Resolved AFTER the dialog, and WARMED: the project can transiently
    // re-resolve while the dialog is open (transport reconnect, auth cascade),
    // which makes `sessionsServiceProvider` throw and the synchronous
    // `focusedServiceOrNull` answer null — dropping a rename the user already
    // confirmed. Warming waits that window out instead.
    final svc = entryId == null
        ? null
        : await warmServiceFor(container, entryId, (s) => s.sessionsService);
    // Surfaced to the user, not to the top-level error handler: the tap that
    // got us here discards this future, so a dropped reply (TimeoutException
    // after the service's 15s bound) escaping here is a fatal crash. The
    // breadcrumb still reads the old name, so say why — and the two failures get
    // different copy, since nothing is sent when the project never warms and
    // blaming the agent for not answering would describe a round trip that
    // never happened.
    void report(String reason) {
      if (mounted) {
        showAbToast(context, "Couldn't rename the session — $reason");
      }
    }

    if (svc == null) {
      AbLog.error(
        'AgentPanel',
        'session rename skipped: project did not warm',
        fields: {'sessionId': id, 'entryId': entryId},
      );
      report("couldn't reach this project. Try again in a moment.");
      return;
    }
    try {
      await svc.rename(id, name);
    } on TimeoutException {
      report("the agent didn't answer. Check the connection and try again.");
    } on SessionDownException catch (e) {
      report(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingName;
    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          final t = CarbonTheme.of(context);
          final Widget leaf = Text(
            pending ?? widget.session.name,
            key: const Key('breadcrumb-session'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.typography.body.copyWith(color: t.colors.textPrimary),
          );
          return MouseRegion(
            // Not a click target while committing — the dialog is the only way
            // in and a second one would race the first rename.
            cursor: pending == null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: pending != null
                  ? null
                  : () => detached(
                      'AgentPanel',
                      'session rename failed',
                      () => _rename(context),
                    ),
              // The line box alone is under the touch floor; the extra height
              // is hit-testable because the detector is opaque.
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: t.minTarget),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: pending == null ? leaf : PulsingOpacity(child: leaf),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
