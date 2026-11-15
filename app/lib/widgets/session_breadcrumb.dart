import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_branch_pill.dart';
import '../design/widgets/ab_breadcrumb.dart';
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
import 'session_isolation_badge.dart';
import 'session_rename_dialog.dart';
import 'session_shared_workspace_badge.dart';

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
    // Leaf slot must exist for the '/' separator + leafOverride to render; the
    // string is a fallback only — the editable leaf renders the live name.
    final segments = [agentName, if (active != null) active.name];

    return Row(
      children: [
        Flexible(
          child: AbBreadcrumb(
            segments: segments,
            leafOverride: active == null
                ? null
                : EditableSessionLeaf(session: active),
          ),
        ),
        if (active != null) ...[
          SessionIsolationBadge(
            session: active,
            // The live list's answer, never `active.setup`: the entry can come
            // from the persisted cache, which carries no setup state at all.
            setup: ref.watch(activeSessionSetupProvider),
          ),
          SessionSharedWorkspaceBadge(session: active),
        ],
        if (showBranchPill && gitBranch != null) ...[
          const SizedBox(width: AbTokens.space8),
          // FlexFit.loose, not Expanded: the breadcrumb keeps first claim on
          // slack (it has the higher flex below), and this only gives up its
          // own width once the row is actually tight — a bare ConstrainedBox
          // here does not shrink with the row at all, since a non-flex Row
          // child is sized from its own content, capped but never squeezed,
          // which is what let the fixed badges above push this row into
          // overflow on a narrow agent panel. AbBranchPill's own Flexible
          // Text (see its doc) is what turns this shrink into an ellipsis
          // instead of a second overflow one widget down.
          Flexible(fit: FlexFit.loose, child: SessionBranchPill(maxWidth: 160)),
        ],
      ],
    );
  }
}

/// The active session's git branch pill — tap to copy. Only the inline
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

    final pill = AbBranchPill(
      branch: gitBranch,
      ahead: terminalState?.gitAhead ?? 0,
      behind: terminalState?.gitBehind ?? 0,
      onTap: () => detached('WindowTitleBar', 'copy branch name', () async {
        await Clipboard.setData(ClipboardData(text: gitBranch));
        if (!context.mounted) return;
        showAbToast(
          context,
          'Copied "$gitBranch"',
          duration: const Duration(seconds: 2),
        );
      }),
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
/// shared [promptSessionRename] dialog (desktop and mobile alike). The active
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

  /// Uses `State.context` and guards every post-await UI touch on `mounted`
  /// rather than taking a [BuildContext] parameter — the two are the same
  /// element here, and only the State's own flag is a valid guard for it.
  Future<void> _rename() async {
    final session = widget.session;
    final id = session.id;
    // Container and entry id captured BEFORE the dialog: the breadcrumb can be
    // rebuilt away while it is open, and a `WidgetRef` touched past that point
    // throws. The id is read here rather than after, so the rename commits
    // against the project that owned this session when the dialog opened — a
    // focus switch behind an open dialog must not retarget it at another agent.
    final container = ref.container;
    final entryId = container.read(selectedRegistrationIdProvider);
    final name = await promptSessionRename(context, session.name);
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
    // Style inherited from the breadcrumb leaf's DefaultTextStyle.
    final Widget leaf = Text(
      pending ?? widget.session.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return MouseRegion(
      // Not a click target while committing — the dialog is the only way in and
      // a second one would race the first rename.
      cursor: pending == null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: pending != null
            ? null
            : () => detached('AgentPanel', 'session rename failed', _rename),
        child: pending == null ? leaf : PulsingOpacity(child: leaf),
      ),
    );
  }
}
