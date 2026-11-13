import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_toast.dart';
import '../models/agent_work_status.dart';
import '../models/session_entry.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../navigation/notification_route.dart' show splitRegistrationId;
import '../project/limits.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/chat_composer_drafts.dart';
import '../providers/new_session_picker.dart'
    show handoffSourceFor, handoffTargetsFor;
import '../providers/open_checkout.dart';
import '../providers/project_work_status.dart';
import '../providers/providers.dart';
import '../providers/session_delete_pending.dart';
import '../providers/session_workspace_state.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../services/control_plane_client.dart';
import '../services/pending_reply.dart' show SessionDownException;
import '../services/sessions_service.dart';
import '../util/detached.dart';
import '../util/external_open_target.dart';
import 'carbon_badge_strip.dart';
import 'carbon_session_badges.dart';
import 'carbon_session_rename_dialog.dart';
import 'carbon_status_dot.dart';
import 'drawer/drawer_metrics.dart' show kDrawerPanelWidth;
import 'drawer_entry_row.dart' show activateDrawerEntryById, ensureRemoteOnline;
import 'session_delete_flow.dart';
import 'session_fork_dialog.dart';
import 'session_isolation_badge.dart' show sessionIsIsolated;
import 'session_start_refusal.dart';

/// Diameter of the status dot on a touch surface; a pointer surface takes the
/// dot's own default.
const double _touchDotSize = 10;

/// The widest the badge cluster may grow, so the name always keeps the rest of
/// the row; a badge squeezed past its text truncates the way a Carbon tag does.
const double _badgeMaxWidth = kDrawerPanelWidth / 2;

/// Shown when a `session:start` the user explicitly asked for gets no reply.
/// One literal because the row tap and the kebab's Fork make the user the same
/// promise, and a start that is still pending must not read as a failed one.
const String _startNoAnswerMessage =
    "The agent didn't answer. If the session doesn't come up in a moment, try "
    'again.';

/// Shown when a `session:fork` gets no reply: the bridge may still be staging
/// the conversation, so the fork may yet appear.
const String _forkNoAnswerMessage =
    'The fork may still be in progress. Check the session list.';

const String _forkInFlightMessage =
    'A fork of this session is still being prepared.';

/// Sources whose fork request is still awaiting its reply, by project and
/// session. Staging can take a minute, and a second Fork in that time would
/// stage the whole conversation again and land a duplicate session.
final Set<String> _forksInFlight = <String>{};

/// One row in the sessions sub-tree of [ProjectsDrawer]. Tapping focuses the
/// session: if its parent project is not currently active, switches projects
/// first (carrying the desired session id via [pendingActiveSessionIdProvider]
/// for `_bootstrapSessions` to honour). A stopped session is started by that
/// same tap: the kebab's explicit Start is the same intent and must not answer
/// differently, so a tap that only focused would split one intent across two
/// controls. The exception is a start already queued behind an isolated
/// checkout's setup run: that one belongs to the create flow, and re-issuing it
/// here is a second start nobody asked for.
class SessionRow extends ConsumerStatefulWidget {
  final String entryId;
  final SessionEntry session;
  const SessionRow({super.key, required this.entryId, required this.session});

  @override
  ConsumerState<SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends ConsumerState<SessionRow> {
  // The action menu is open. It sits outside the row, so neither the pointer
  // nor focus is inside the row while it is, and the actions would hide under
  // the very menu they opened.
  bool _menuOpen = false;

  // A picked action is still running: its dialog is up or its bridge call is in
  // flight. The actions stay revealed so the context those dialogs are hosted
  // on does not unmount with the pointer.
  bool _actionBusy = false;

  // Re-entrancy latch for _activate. A cold remote project tap kicks off an
  // up-to-30s pair+promote, so a rapid double-tap would otherwise launch two
  // concurrent activations that race the selected-target save/restore in
  // `_openColdRemoteProject`.
  bool _activating = false;

  // Inline-rename state (desktop only). Non-null controller/focus iff editing.
  bool _editing = false;
  TextEditingController? _editController;
  FocusNode? _editFocus;

  // The row's own focus, so leaving the editor from the keyboard lands back on
  // the row instead of on nothing.
  final FocusNode _rowFocus = FocusNode(debugLabel: 'SessionRow');

  SessionEntry get session => widget.session;

  @override
  void dispose() {
    _editController?.dispose();
    _editFocus?.dispose();
    _rowFocus.dispose();
    super.dispose();
  }

  void _setMenuOpen(bool open) {
    if (mounted && _menuOpen != open) setState(() => _menuOpen = open);
  }

  void _setActionBusy(bool busy) {
    if (mounted && _actionBusy != busy) setState(() => _actionBusy = busy);
  }

  /// Hands focus back to the row once the editor has gone. After the frame that
  /// rebuilds the link, because the node is only attached while the link is
  /// mounted.
  void _refocusRow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rowFocus.context != null) _rowFocus.requestFocus();
    });
  }

  /// Enter inline edit mode: swap the title for a focused, pre-selected
  /// text field. Desktop only — mobile renames via the kebab dialog.
  void _enterEdit() {
    if (isMobilePlatform || _editing) return;
    _editController = TextEditingController(text: session.name);
    _editFocus = FocusNode();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _editController;
      final f = _editFocus;
      if (c == null || f == null) return;
      f.requestFocus();
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
  }

  /// Save the edited name (trimmed) if non-empty and changed, then leave
  /// edit mode. Idempotent via the [_editing] guard so the Enter →
  /// dispose → blur sequence doesn't rename twice.
  ///
  /// Routes to THIS row's project via [warmServiceFor] (warming it back if the
  /// LRU evicted it mid-edit), not the focused project. Captures the ids before
  /// [_exitEdit]/`await` so it stays correct even if the row unmounts during the
  /// warm-up.
  Future<void> _commitEdit() async {
    if (!_editing) return;
    final name = _editController?.text.trim() ?? '';
    final changed = name.isNotEmpty && name != session.name;
    final entryId = widget.entryId;
    final sessionId = session.id;
    _exitEdit();
    if (!changed) return;
    final svc = await warmServiceFor(
      ref.container,
      entryId,
      (s) => s.sessionsService,
    );
    // Awaited, not `unawaited`: a dropped reply fails this future with a
    // TimeoutException, and every caller runs this detached — an unawaited
    // rejection would have nothing to land on but the top-level error handler.
    // The row keeps showing the old name, which is the truth until the bridge
    // confirms otherwise.
    await svc?.rename(sessionId, name);
  }

  /// Both commit triggers (Enter, blur) are `void` callbacks, so the rename's
  /// failure has to be caught here or it becomes a top-level fatal.
  void _commitDetached() =>
      detached('SessionRow', 'session rename failed', _commitEdit);

  void _exitEdit() {
    // Disposing a FocusNode detaches it, and `FocusManager._markDetached`
    // removes it from `_dirtyNodes` — the very Set that
    // `applyFocusChangesIfNeeded` is ITERATING when it notifies listeners. One
    // caller is the field's own `onFocusChange`, and `detached` runs its action
    // through `Future.sync`, so the whole path down to here executes inside
    // that notification: disposing synchronously throws
    // ConcurrentModificationError and kills the app. Defer the disposal so the
    // notification unwinds first. The fields are cleared BEFORE it runs, so
    // nothing reaches a disposed node in between and `dispose()` above cannot
    // double-dispose.
    //
    // Post-frame rather than a microtask: a microtask still lands inside the
    // frame that is showing the field, so the TextField would outlive the
    // controller and focus node it is built against. The setState below is what
    // takes it down, and the callback runs after that rebuild.
    final controller = _editController;
    final focus = _editFocus;
    _editController = null;
    _editFocus = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller?.dispose();
      focus?.dispose();
    });
    if (mounted) {
      setState(() => _editing = false);
    } else {
      _editing = false;
    }
  }

  /// The leading indicator. A delete in flight owns the slot outright; otherwise
  /// the work-status dot, the same one the Recent list shows, so one session's
  /// state reads identically wherever it surfaces.
  ///
  /// At rest the dot says nothing at all: the same hollow idle ring whether the
  /// session is running or stopped. Liveness is not a status: what the row
  /// exists to report is what the agent wants from you, and a session at rest
  /// wants nothing.
  ///
  /// Working and needs-you dots pulse, which Recent's static dots do not: the
  /// drawer is the one always-visible place, and a dot that stops moving when an
  /// agent is waiting on you stops being noticed there.
  Widget _leading(
    CarbonThemeData t,
    AgentWorkStatus work, {
    required bool deleting,
  }) {
    // Outranks the dot: work status is about what a live agent is doing, and
    // this one is being taken apart.
    if (deleting) {
      return CarbonSpinner(
        key: ValueKey('session-deleting-dot-${session.id}'),
        size: t.iconSize,
      );
    }
    return CarbonWorkStatusDot(
      key: ValueKey('session-status-dot-${session.id}'),
      status: work,
      pulse:
          work == AgentWorkStatus.working || work == AgentWorkStatus.attention,
      size: t.isTouch ? _touchDotSize : null,
      // A ring shows the row's own fill (rest, hover or selected) through it.
      hollowFill: t.colors.background.withValues(alpha: 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final activeId = ref.watch(activeSessionIdProvider);
    final selected =
        ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.workspace &&
        activeId == session.id;
    final work = ref.watch(
      sessionWorkStatusProvider((
        entryId: widget.entryId,
        sessionId: session.id,
        running: session.running,
      )),
    );

    // Inline rename is offered only for running sessions whose project is
    // warm (live transport in the registry). Warm => `_commitEdit`'s
    // `projectSessionProvider(entryId)` resolves to a live SessionsService,
    // so the rename reaches the right agent with no cold-connect or silent
    // drop. Side-effect-free: reads the registry's warm set, never the
    // FutureProvider (which would warm a cold project just by being read).
    final canRename =
        session.running &&
        ref.watch(projectSessionRegistryProvider).contains(widget.entryId);

    final deleting = sessionDeleteInFlight(ref, widget.entryId, session);
    if (deleting && _editing) {
      // The rename target is going away. Leave edit mode after this frame (a
      // setState during build is illegal) and render the plain title now;
      // `_commitEdit`'s `!_editing` guard is what stops the resulting focus loss
      // from sending a rename at a dead session.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _exitEdit();
      });
    }

    if (deleting && _menuOpen) {
      // The menu unmounts with the actions and the package reports no close for
      // that, so a refused delete would otherwise leave the kebab pinned open.
      WidgetsBinding.instance.addPostFrameCallback((_) => _setMenuOpen(false));
    }

    final leading = _leading(t, work, deleting: deleting);
    if (_editing && !deleting) return _buildEditingRow(context, t, leading);

    // The live list's answer, never `session.setup`: a row for a project that
    // isn't focused is served from the persisted cache, which carries no setup
    // state at all.
    final setup = ref.watch(sessionSetupProvider(session.id));
    final handlerPending = watchSessionHandlerPending(
      ref,
      widget.entryId,
      session.id,
    );
    final lacksMemory = watchSessionStartedWithoutMemory(
      ref,
      widget.entryId,
      session,
    );

    // The link hides its content from semantics, so every badge's state has to
    // be in the name or it is silent to a screen reader.
    final spoken = sessionSpokenName(
      name: session.name,
      status: work,
      bypassesApprovals: session.approvalPolicy == 'bypass',
      isolation: sessionIsolationSpoken(session, setup),
      sharedWorkspace: session.sharedWorkspace,
      deleting: deleting,
      extras: [
        if (handlerPending > 0) 'Handler waiting on $handlerPending',
        if (lacksMemory) 'started without Memory',
      ],
    );

    return CarbonSideNavLink(
      label: spoken,
      leading: leading,
      current: selected,
      // A session being removed is neither focusable nor activatable: opening
      // it would attach the workspace to a checkout that is going away.
      disabled: deleting,
      focusNode: _rowFocus,
      // A touch user holding a badge to read its tooltip must not also open the
      // session on release.
      cancelOnLongPress: true,
      onPressed: () => detached(
        'SessionRow',
        'session activate failed',
        () => _activate(context, ref.container),
      ),
      // Desktop: double-click a running session (in any warm project) to rename
      // it inline. A single press stays instant, so wiring this on many rows
      // costs no latency.
      onDoublePressed: (isMobilePlatform || deleting || !canRename)
          ? null
          : _enterEdit,
      content: Text(session.name),
      // The badges are the row's status marks: they sit in the trailing slot the
      // session menu swaps into on hover, as every other drawer row's marks do.
      trailing: [
        CarbonBadgeStrip(
          maxWidth: _badgeMaxWidth,
          children: [
            CarbonSessionIsolationBadge(session: session, setup: setup),
            CarbonSessionApprovalBadge(session: session),
            CarbonSessionSharedWorkspaceBadge(session: session),
            CarbonSessionHandlerBadge(
              entryId: widget.entryId,
              sessionId: session.id,
            ),
            CarbonSessionMemoryRestartBadge(
              entryId: widget.entryId,
              session: session,
            ),
            CarbonSessionDeletingBadge(deleting: deleting),
          ],
        ),
      ],
      keepActionsRevealed: _menuOpen || _actionBusy,
      // Gone entirely while deleting rather than partly disabled: every item on
      // it (start/stop/rename/archive/delete, and the working-directory rows
      // pointing into a checkout that is going away) acts on a session being
      // removed.
      actions: deleting
          ? const <Widget>[]
          : [
              _SessionMenu(
                entryId: widget.entryId,
                session: session,
                rowContext: context,
                onOpenChanged: _setMenuOpen,
                onActionBusy: _setActionBusy,
              ),
            ],
    );
  }

  /// Takes the [ProviderContainer], never this row's `ref`: activating a cold
  /// remote project can run for ~30s, and the switch it triggers rebuilds the
  /// drawer (and pops it on mobile) — this row is routinely disposed before the
  /// awaits below return, and a `WidgetRef` read past that point throws.
  Future<void> _activate(BuildContext context, ProviderContainer ref) async {
    if (_activating) return;
    _activating = true;
    try {
      await _activateInner(context, ref);
    } finally {
      _activating = false;
    }
  }

  Future<void> _activateInner(
    BuildContext context,
    ProviderContainer ref,
  ) async {
    // Captured before the first await: this row is routinely disposed by the
    // switch its own tap triggers (mobile pops the drawer, a cross-project
    // activate rebuilds it), and a refusal the user asked for must not vanish
    // with it.
    final toaster = AbToaster.maybeOf(context);

    final liveId = ref.read(selectedRegistrationIdProvider);
    if (widget.entryId == liveId) {
      // Same project — local fast path. For a same-project remote `liveId`
      // is the agentDeviceId, so reconnect-on-demand uses it directly.
      if (ref.read(focusedIsRelayProvider)) {
        if (!await ensureRemoteOnline(context, ref, liveId!)) return;
      }
      // Await the session rather than reading the (throwing) façade: the drawer
      // renders THIS row from cached sessions, so a project can be focused —
      // deep link, nav back/forward, or a session invalidated by a host restart
      // or LRU evict — with no ProjectSession behind it yet. Warms it if cold.
      // 30s, not the 10s default: this is the one path that may be waiting on a
      // cold remote open rather than an already-warm project.
      final svc = await warmServiceFor(
        ref,
        liveId!,
        (s) => s.sessionsService,
        timeout: const Duration(seconds: 30),
      );
      if (svc == null) return;
      if (ref.read(selectedRegistrationIdProvider) != liveId) return;
      ref.read(activeSessionIdProvider.notifier).set(session.id);
      // A tap is an auto-start path, so it gates like the workspace bootstrap
      // does: the start queued behind an isolated checkout's setup run is the
      // create flow's own, prompt and all, and a bare re-start here is a second
      // one the user never asked for. Read live where the list has landed, and
      // fall back to the row's own copy where it has not.
      final queued = sessionStartQueued(
        ref.read(sessionSetupProvider(session.id)) ?? session.setup,
      );
      if (!session.running && !queued) {
        // The two failures end differently, and that is the whole point of
        // catching them separately: a refusal is the bridge's answer that this
        // session did NOT start, while a timeout is no answer at all.
        try {
          await svc.start(session.id, raiseRefusal: true);
        } on SessionOperationException catch (error) {
          // A refused start is the only signal this row has that its isolated
          // checkout is gone — the tap was otherwise a silent no-op. Returning
          // is part of the answer: focusing the workspace onto a session that
          // never spawned reads as the app having lost the output.
          reportStartRefusal(toaster, error);
          return;
        } on TimeoutException {
          // A dropped reply must not abandon the focus + surface + nav writes
          // below: the user asked for THIS session, and the bridge may have
          // spawned the PTY anyway (`session:updated` then reconciles the row).
          // Leaving the activeSessionId set while the surface never switches is
          // the worst of both — a tap that visibly did nothing.
          reportSessionNotice(toaster, _startNoAnswerMessage);
        } on SessionDownException {
          // Same "may still be coming up" shape as the timeout above — the
          // machine went away, not the bridge refusing.
          reportSessionNotice(toaster, _startNoAnswerMessage);
        }
        // A different project can be activated while start() is in flight. The
        // writes below (focus, surface, nav entry) all belong to THIS project,
        // so drop them rather than commit them against the new focus.
        if (ref.read(selectedRegistrationIdProvider) != liveId) return;
      }
      // Transcript hydration is driven by AgentTranscriptView.initState (the
      // single per-session chokepoint), not here — see hydrateAttachedChatIfNeeded.
      svc.focus(session.id);
      _showFocusedSessionSurface(ref);
      return;
    }
    // Cross-project — seed pending intent then switch via the drawer's
    // activate helper (handles local vs remote). If the switch fails the
    // pending must be cleared so it doesn't leak into a future unrelated
    // project open.
    ref.read(pendingActiveSessionIdProvider.notifier).set(session.id);
    final ok = await activateDrawerEntryById(context, ref, widget.entryId);
    if (!ok) {
      ref.read(pendingActiveSessionIdProvider.notifier).set(null);
      return;
    }
    _showFocusedSessionSurface(ref);
  }

  void _showFocusedSessionSurface(ProviderContainer ref) =>
      _showSessionSurface(ref, session.id);

  /// The row while its name is being edited: the link's frame, inset and
  /// leading slot, with the editor where the name was.
  ///
  /// Not the link itself: a link hides its content from semantics and sits
  /// under its press target, and an editor is neither.
  Widget _buildEditingRow(
    BuildContext context,
    CarbonThemeData t,
    Widget leading,
  ) {
    final scope = CarbonSideNavScope.of(context);
    return ColoredBox(
      color: t.colors.backgroundSelected,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: t.minTarget),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: scope.inset + scope.depth * scope.stepFor(t),
            end: scope.endInset,
          ),
          child: Row(
            children: [
              SizedBox.square(
                dimension: t.iconSize,
                child: Center(child: leading),
              ),
              const SizedBox(width: CarbonSpacing.spacing03),
              Expanded(child: _buildEditor()),
            ],
          ),
        ),
      ),
    );
  }

  /// Inline rename field. Enter (onSubmitted) and blur (onFocusChange)
  /// commit; Escape (intercepted by the wrapping [Focus]) cancels. Enter and
  /// Escape hand focus back to the row; a blur leaves it where the user put it.
  Widget _buildEditor() {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          // Escape cancels: leave edit mode without saving.
          _exitEdit();
          _refocusRow();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      onFocusChange: (hasFocus) {
        if (!hasFocus) _commitDetached();
      },
      child: CarbonTextInput(
        controller: _editController,
        focusNode: _editFocus,
        bare: true,
        semanticLabel: 'Session name',
        onSubmitted: (_) {
          _commitDetached();
          _refocusRow();
        },
      ),
    );
  }
}

/// Puts the workspace surface in front of the user on [sessionId], and records
/// it as the nav entry. Top-level so the row tap and the kebab's Fork land the
/// user in exactly the same place — a forked session the user is not looking at
/// is indistinguishable from a menu item that did nothing.
void _showSessionSurface(ProviderContainer ref, String sessionId) {
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  ref
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: ref.read(selectedTargetProvider),
          surface: WorkbenchSurface.workspace,
          sessionId: sessionId,
        ),
      );
}


enum _SessionAction { start, stop, fork, rename, archive, delete }

/// One kebab-menu outcome. Sealed rather than a flat enum because the
/// working-directory rows carry which app was picked, and because the dispatch
/// below then stays exhaustive under the compiler.
sealed class _SessionMenuChoice {
  const _SessionMenuChoice();
}

/// Acts on the session itself.
final class _RowAction extends _SessionMenuChoice {
  const _RowAction(this.action);
  final _SessionAction action;
}

/// Hands the session's working directory to an external app.
final class _OpenExternally extends _SessionMenuChoice {
  const _OpenExternally(this.target);
  final ExternalOpenTarget target;
}

final class _CopyPath extends _SessionMenuChoice {
  const _CopyPath();
}


class _SessionMenu extends ConsumerWidget {
  final String entryId;
  final SessionEntry session;

  /// The row's own context, which outlives this menu. Delete hosts its dialogs
  /// and toasts here rather than on the trigger: arming the in-flight mark
  /// removes the menu, so a refusal arriving afterwards (uncommitted changes,
  /// unpushed commits, a held directory) would find the trigger's context
  /// unmounted and end with nothing on screen.
  final BuildContext rowContext;
  final ValueChanged<bool> onOpenChanged;
  final ValueChanged<bool> onActionBusy;

  const _SessionMenu({
    required this.entryId,
    required this.session,
    required this.rowContext,
    required this.onOpenChanged,
    required this.onActionBusy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Working-directory rows are offered only for a checkout on THIS device:
    // both resolve their path over the loopback control plane
    // (`openCheckoutIn`/`copyCheckoutPath` read `hostControlClientProvider`),
    // which can only answer about projects this machine hosts. Asked about a
    // remote machine's project it spawns a host and refuses — and the window it
    // could not open would have been on a machine the user is not sitting at.
    //
    // Gated on what the local project store holds, never on whether the id
    // looks remote: an id absent from it (a remote project, a machine, the
    // demo) loses the rows, so a source of remote entries added later is
    // excluded without this line being revisited. A probe still loading or
    // failed degrades to no rows rather than a menu that never opens.
    final local = ref.watch(entryIsLocalCheckoutProvider(entryId)).value ?? false;
    final targets = local
        ? (ref.watch(externalOpenTargetsProvider).value ??
              const <ExternalOpenTarget>[])
        : const <ExternalOpenTarget>[];

    // Each pick runs detached: the chain awaits dialogs and bridge RPCs, and an
    // unhandled rejection from a fire-and-forget `void` call would land outside
    // any build() as a fatal. The container is taken here, not read from `ref`
    // after the menu has closed.
    VoidCallback pick(_SessionMenuChoice choice) {
      final container = ref.container;
      return () => detached(
        'SessionRow',
        'session menu failed',
        () => _run(context, container, choice),
      );
    }

    return CarbonOverflowMenu(
      semanticLabel: 'Actions for ${session.name}',
      size: CarbonButtonSize.extraSmall,
      onOpenChanged: onOpenChanged,
      entries: [
        CarbonMenuItem(
          label: session.running ? 'Stop' : 'Start',
          onPressed: pick(
            _RowAction(
              session.running ? _SessionAction.stop : _SessionAction.start,
            ),
          ),
        ),
        if (session.forkSupported)
          CarbonMenuItem(
            label: 'Fork session',
            // Disabled rather than dropped: `forkSupported` answers whether the
            // AGENT can be forked, which is a permanent fact about the tool,
            // while having something to fork is a fact about this session that
            // its first turn fixes. Hiding the row for the second would teach
            // the user the tool cannot do it at all.
            //
            // What the bridge actually reads is a native conversation id or the
            // live terminal's scrollback, and both inputs are already on the
            // wire — so this mirrors the precondition rather than asking for
            // it. Drift costs a refusal the branch below reports, never a
            // silence.
            onPressed: session.running || session.agentSessionId != null
                ? pick(const _RowAction(_SessionAction.fork))
                : null,
          ),
        CarbonMenuItem(
          label: 'Rename',
          onPressed: pick(const _RowAction(_SessionAction.rename)),
        ),
        CarbonMenuItem(
          label: 'Archive',
          onPressed: pick(const _RowAction(_SessionAction.archive)),
        ),
        if (targets.isNotEmpty) ...[
          const CarbonMenuDivider(),
          for (final target in targets)
            CarbonMenuItem(
              label: target.label,
              onPressed: pick(_OpenExternally(target)),
            ),
          CarbonMenuItem(
            label: 'Copy path',
            onPressed: pick(const _CopyPath()),
          ),
        ],
        const CarbonMenuDivider(),
        CarbonMenuItem(
          label: 'Delete',
          kind: CarbonMenuItemKind.danger,
          onPressed: pick(const _RowAction(_SessionAction.delete)),
        ),
      ],
    );
  }

  Future<void> _run(
    BuildContext anchor,
    ProviderContainer ref,
    _SessionMenuChoice choice,
  ) async {
    if (!anchor.mounted) return;
    onActionBusy(true);
    try {
      // The working-directory rows resolve their path over the loopback control
      // plane, so unlike every other row they must not warm the session service.
      switch (choice) {
        case _OpenExternally(:final target):
          await openCheckoutIn(
            anchor,
            ref,
            projectId: entryId,
            checkoutId: session.checkoutId,
            target: target,
          );
        case _CopyPath():
          await copyCheckoutPath(
            anchor,
            ref,
            projectId: entryId,
            checkoutId: session.checkoutId,
          );
        case _RowAction(:final action):
          await _runRowAction(anchor, ref, action);
      }
    } finally {
      onActionBusy(false);
    }
  }

  Future<void> _runRowAction(
    BuildContext anchor,
    ProviderContainer ref,
    _SessionAction action,
  ) async {
    final toaster = AbToaster.maybeOf(anchor);
    final svc = await warmServiceFor(ref, entryId, (s) => s.sessionsService);
    if (svc == null || !anchor.mounted) return;
    // Every branch here is an explicit menu pick, so a dropped reply owes the
    // user an answer: the row keeps rendering the pre-action state (still
    // running after Stop, old name after Rename), which without this reads as a
    // menu item that did nothing. Not a claim of failure — the bridge may have
    // applied it and `session:updated` will reconcile the row. A REFUSAL is the
    // opposite case and is caught per-branch: the bridge answered, and only the
    // branch knows what its refusal means.
    try {
      switch (action) {
        case _SessionAction.start:
          // The kebab's explicit Start is the same intent as the row tap and
          // must not answer differently.
          try {
            await svc.start(session.id, raiseRefusal: true);
          } on SessionOperationException catch (error) {
            reportStartRefusal(toaster, error);
          }
        case _SessionAction.stop:
          await svc.stopSession(session.id);
        case _SessionAction.fork:
          final forkKey = '$entryId/${session.id}';
          if (_forksInFlight.contains(forkKey)) {
            reportSessionNotice(toaster, _forkInFlightMessage);
            return;
          }
          // Offered only against a bridge that said it honours `targetTool`:
          // an older one drops the key and would fork into the same agent
          // while the dialog promised another.
          final sourceTool = session.handoffSupported ? session.agentKey : null;
          // Not awaited: the dialog opens now and fills its agent menu when
          // the machine answers, which a cold host or a remote machine still
          // connecting can take seconds to do.
          final choice = await promptSessionFork(
            anchor,
            isolatedSource: sessionIsIsolated(session),
            source: sourceTool == null
                ? null
                : handoffSourceFor(ref, sourceTool),
            targets: sourceTool == null
                ? null
                : handoffTargetsFor(
                    ref,
                    splitRegistrationId(entryId),
                    sourceTool: sourceTool,
                  ),
          );
          if (choice == null || !anchor.mounted) return;
          final workspace = choice.workspace;
          final targetTool = choice.targetTool == sourceTool
              ? null
              : choice.targetTool;
          // Again after the dialog: another surface can have sent one while it
          // was open.
          if (!_forksInFlight.add(forkKey)) {
            reportSessionNotice(toaster, _forkInFlightMessage);
            return;
          }
          // Caught per-branch, per the contract above: every fork refusal the
          // bridge documents — no captured transcript yet, a conversation past
          // the handoff cap, a custom-command session, a missing checkout —
          // arrives as a typed exception carrying the bridge's own sentence,
          // and without this the menu item just appears to do nothing.
          try {
            final fork = await svc.fork(
              session.id,
              workspace: workspace,
              targetTool: targetTool,
            );
            // An `ok` carrying no session: there is nothing to start and
            // nothing to land in, so say so rather than returning as though the
            // fork had happened. The same answer the New Session canvas treats
            // as a refused create.
            if (fork == null) {
              reportSessionNotice(toaster, sessionForkRefusalCopy(null, null));
              return;
            }
            // Started before the focus switch, not after: focusing another
            // project's row remounts the shell, whose bootstrap re-lists the
            // sessions and auto-starts the one it adopts. Issuing the start
            // first puts it ahead of that list on the same stream — the
            // ordering the New Session canvas keeps, for the same reason.
            //
            // Neither failure abandons the focus below. The fork EXISTS by
            // here and is the user's; a start that was refused is a session to
            // land in and read the reason from, and one that never answered may
            // still be coming up.
            try {
              final started = await svc.start(fork.id, raiseRefusal: true);
              if (started == null) {
                reportSessionNotice(
                  toaster,
                  sessionStartRefusalCopy(null, null),
                );
              }
            } on SessionOperationException catch (error) {
              reportStartRefusal(toaster, error);
            } on TimeoutException {
              reportSessionNotice(toaster, _startNoAnswerMessage);
            } on SessionDownException {
              reportSessionNotice(toaster, _startNoAnswerMessage);
            }
            if (anchor.mounted) await _focusSession(anchor, ref, svc, fork.id);
          } on SessionOperationException catch (error) {
            reportSessionNotice(
              toaster,
              sessionForkRefusalCopy(error.errorCode, error.message),
            );
          } on TimeoutException {
            // Not a failure: staging a long conversation can outlast even the
            // extended wait, and the fork may still land. Never retried here,
            // since a second request would duplicate a large fork.
            reportSessionNotice(toaster, _forkNoAnswerMessage);
            detached('SessionRow', 'refresh after fork timeout', () async {
              await svc.requestList();
            });
          } on StateError {
            // dispose() fails every pending reply: the project was evicted or
            // demoted in the background while the bridge was still staging,
            // which can outlast both. The same unknown outcome as a timeout,
            // with no service left to refresh the list through.
            reportSessionNotice(toaster, _forkNoAnswerMessage);
          } finally {
            _forksInFlight.remove(forkKey);
          }
        case _SessionAction.rename:
          final name = await showCarbonSessionRename(anchor, session.name);
          if (name != null && name.trim().isNotEmpty) {
            await svc.rename(session.id, name.trim());
          }
        case _SessionAction.archive:
          final archived = await svc.archive(session.id);
          if (archived != null) {
            clearChatComposerDraft(ref, session.id);
            clearSessionWorkspaceState(ref, entryId, session.id);
          }
          _disconnectIfEmpty(ref);
        case _SessionAction.delete:
          if (rowContext.mounted) await _deleteSession(rowContext, ref, svc);
      }
    } on TimeoutException {
      toaster?.showMessage(
        "The agent didn't answer. Check the connection and try again.",
      );
    } on SessionDownException catch (e) {
      toaster?.showMessage(e.toString());
    }
  }

  /// Moves the user into [sessionId] in THIS row's project — the same
  /// two-branch handshake the row tap performs. A focused project is a direct
  /// write; another project's row seeds the intent and switches first, and a
  /// switch that fails has to clear that intent or it leaks into the next,
  /// unrelated project open.
  Future<void> _focusSession(
    BuildContext anchor,
    ProviderContainer ref,
    SessionsService svc,
    String sessionId,
  ) async {
    if (ref.read(selectedRegistrationIdProvider) == entryId) {
      ref.read(activeSessionIdProvider.notifier).set(sessionId);
      svc.focus(sessionId);
      _showSessionSurface(ref, sessionId);
      return;
    }
    ref.read(pendingActiveSessionIdProvider.notifier).set(sessionId);
    if (!await activateDrawerEntryById(anchor, ref, entryId)) {
      ref.read(pendingActiveSessionIdProvider.notifier).set(null);
      return;
    }
    _showSessionSurface(ref, sessionId);
  }

  Future<void> _deleteSession(
    BuildContext context,
    ProviderContainer ref,
    SessionsService service,
  ) async {
    final capturedId = session.id;
    final markKey = sessionDeleteKey(entryId, capturedId);
    final result = await confirmAndDeleteSession(
      context: context,
      dialogs: carbonSessionDeleteDialogs,
      sessionName: session.name,
      checkoutKind: session.checkoutKind,
      sharedWorkspace: session.sharedWorkspace,
      sharedBody:
          'This permanently deletes "${session.name}" and terminates its agent process.',
      delete: ({force, deleteBranch}) =>
          service.delete(capturedId, force: force, deleteBranch: deleteBranch),
      onInFlight: (inFlight) {
        final marks = ref.read(sessionDeleteRequestsProvider.notifier);
        if (inFlight) {
          marks.arm(markKey);
        } else {
          marks.disarm(markKey);
        }
      },
    );
    if (result == SessionDeleteResult.deleted) {
      clearChatComposerDraft(ref, capturedId);
      clearSessionWorkspaceState(ref, entryId, capturedId);
      _disconnectIfEmpty(ref);
    }
  }

  /// Wired here (call site) instead of as a listener on
  /// [activeSessionsProvider] because `_stopAllServices()` empties the
  /// session list synchronously during a project switch — a listener would
  /// race that and partially undo the switch.
  void _disconnectIfEmpty(ProviderContainer ref) {
    // Only the focused project's connection/selection is ours to touch — a
    // kebab action on a non-focused warm project must not disconnect the one
    // in view.
    if (entryId != ref.read(selectedRegistrationIdProvider)) return;
    if (ref.read(activeSessionsProvider).isNotEmpty) return;
    if (ref.read(focusedIsRelayProvider)) {
      ref.read(machineConnectionProvider.notifier).cancelActiveAgent();
    } else if (ref.read(selectedRegistrationIdProvider) != null) {
      ref.read(selectedTargetProvider.notifier).set(null);
    }
  }
}
