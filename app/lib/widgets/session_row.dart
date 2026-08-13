import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/session_entry.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../project/limits.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart';
import '../providers/open_checkout.dart';
import '../providers/project_work_status.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../services/control_plane_client.dart';
import '../services/sessions_service.dart';
import '../util/detached.dart';
import '../util/external_open_target.dart';
import 'agent_work_status_dot.dart';
import 'drawer_entry_row.dart' show activateDrawerEntryById, ensureRemoteOnline;
import 'session_delete_flow.dart';
import 'session_isolation_badge.dart';
import 'session_rename_dialog.dart';
import 'session_start_refusal.dart';

/// One row in the sessions sub-tree of [ProjectsDrawer]. Tapping focuses the
/// session: if its parent project is not currently active, switches projects
/// first (carrying the desired session id via [pendingActiveSessionIdProvider]
/// for `_bootstrapSessions` to honour). If the session is stopped, sends
/// `session:start` — overrides multi-session spec §3's "no auto-start on
/// select" rule per the collapsible-drawer spec.
/// Fraction (-1..1) by which the status dot is shifted down within its leading
/// box to sit on the title's optical centre rather than its line-box centre.
/// ~0.45 of the 3px free half-space ≈ a 1.3px nudge — the measured gap for a
/// 14px line at 1.2 line-height.
const double _dotOpticalYBias = 0.45;

class SessionRow extends ConsumerStatefulWidget {
  final String entryId;
  final SessionEntry session;
  const SessionRow({super.key, required this.entryId, required this.session});

  @override
  ConsumerState<SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends ConsumerState<SessionRow> {
  // Mobile has no hover — keep the kebab visible.
  late bool _hovered = isMobilePlatform;

  // Re-entrancy latch for _activate. A cold remote project tap kicks off an
  // up-to-30s pair+promote, so a rapid double-tap would otherwise launch two
  // concurrent activations that race the selected-target save/restore in
  // `_openColdRemoteProject`.
  bool _activating = false;

  // Inline-rename state (desktop only). Non-null controller/focus iff editing.
  bool _editing = false;
  TextEditingController? _editController;
  FocusNode? _editFocus;

  SessionEntry get session => widget.session;

  @override
  void dispose() {
    _editController?.dispose();
    _editFocus?.dispose();
    super.dispose();
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
    _editController?.dispose();
    _editFocus?.dispose();
    _editController = null;
    _editFocus = null;
    if (mounted) {
      setState(() => _editing = false);
    } else {
      _editing = false;
    }
  }

  AbStatusTone _tone() {
    if (session.archived) return AbStatusTone.disabled;
    if (session.running) return AbStatusTone.info;
    // Stopped: the agent-at-rest gray, dimmer than `neutral` (textSecondary),
    // so the hollow ring recedes instead of reading as a lit indicator. Not
    // `muted` — an idle agent is a lifecycle state, not de-emphasized text.
    return AbStatusTone.agentIdle;
  }

  /// The leading indicator. Work status owns the slot whenever the agent has
  /// something to say about THIS session (working / needs you / error) — it is
  /// the same dot the Recent list shows, so one session's state reads
  /// identically wherever it surfaces. Otherwise the slot
  /// falls back to plain liveness: filled = running, hollow ring = idle. The
  /// fill/outline contrast reads "on vs off" faster than a colour shift between
  /// two filled dots, so only a running session gets a solid dot.
  Widget _leadingDot(AgentWorkStatus work) {
    final key = ValueKey('session-status-dot-${session.id}');
    if (work != AgentWorkStatus.done) {
      return AgentWorkStatusDot(key: key, status: work);
    }
    return AbStatusDot(
      key: key,
      tone: _tone(),
      size: AbDotSize.sm,
      style: session.running ? AbDotStyle.filled : AbDotStyle.hollow,
    );
  }

  void _onEnter(PointerEnterEvent _) {
    if (isMobilePlatform) return;
    if (!_hovered && mounted) setState(() => _hovered = true);
  }

  void _onExit(PointerExitEvent _) {
    if (isMobilePlatform) return;
    if (_hovered && mounted) setState(() => _hovered = false);
  }

  @override
  Widget build(BuildContext context) {
    final activeId = ref.watch(activeSessionIdProvider);
    final selected = activeId == session.id;
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

    // Split the gutter: half on the outer Padding (still keeps L/R strips
    // non-hover-reactive), half inside the row as horizontalPadding so the
    // selection fill gets breathing room before the status dot without
    // shifting the dot's screen position.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: _onEnter,
        onExit: _onExit,
        child: AbListRow(
          leading: SizedBox(
            width: AbTokens.drawerLeadingSlot,
            height: AbTokens.drawerLeadingSlot,
            // Bias the dot slightly below its box centre. Row-centring lines up
            // the dot with the title's line-box centre, but the visible glyphs
            // of a fontBody line sit a hair lower (the font reserves more space
            // above the baseline than below), so a geometrically-centred dot
            // reads as too high. The small downward nudge matches the optical
            // centre of the text.
            child: Align(
              alignment: const Alignment(0, _dotOpticalYBias),
              child: _leadingDot(work),
            ),
          ),
          // Row height is anchored by the always-reserved kebab slot (taller
          // than the text line), so swapping the title for the field doesn't
          // change the height; the field expands to the full title width.
          title: _editing
              ? _buildEditor()
              : Row(
                  children: [
                    Flexible(
                      child: Text(
                        session.name,
                        style: AbTokens.sansStyle(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SessionIsolationBadge(session: session),
                  ],
                ),
          // Hover-only kebab kept in the tree (and its size reserved) so the
          // row height never jitters — including while editing, when it's
          // hidden but its slot still anchors the row's height.
          trailing: Visibility(
            visible: _hovered && !_editing,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: _SessionMenu(entryId: widget.entryId, session: session),
          ),
          selected: selected,
          selectionStyle: AbRowSelection.surface,
          hoverable: true,
          density: AbRowDensity.sm,
          horizontalPadding: AbTokens.space6,
          verticalPadding: 1,
          // Small vertical margin so adjacent rows don't touch.
          margin: const EdgeInsets.symmetric(vertical: 1),
          // Disable activation while editing so taps stay in the field.
          onTap: _editing
              ? null
              : () => detached(
                  'SessionRow',
                  'session activate failed',
                  () => _activate(context, ref.container),
                ),
          // Desktop: double-tap a running session (in any warm project) to
          // rename it inline. The row's SerialTap recognizer keeps single-tap
          // selection instant, so wiring this on many rows costs no latency.
          onDoubleTap: (isMobilePlatform || _editing || !canRename)
              ? null
              : _enterEdit,
        ),
      ),
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
    // with it. The navigator outlives any one route or overlay entry; falls back
    // to the row's own context where there is no Navigator (widget tests).
    final refusalHost =
        Navigator.maybeOf(context, rootNavigator: true)?.context ?? context;
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
      if (!session.running) {
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
          if (refusalHost.mounted) reportStartRefusal(refusalHost, error);
          return;
        } on TimeoutException {
          // A dropped reply must not abandon the focus + surface + nav writes
          // below: the user asked for THIS session, and the bridge may have
          // spawned the PTY anyway (`session:updated` then reconciles the row).
          // Leaving the activeSessionId set while the surface never switches is
          // the worst of both — a tap that visibly did nothing.
          if (refusalHost.mounted) {
            showAbSnackBar(
              refusalHost,
              "The agent didn't answer. If the session doesn't come up in a "
              'moment, try again.',
            );
          }
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

  void _showFocusedSessionSurface(ProviderContainer ref) {
    ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
    // Clear any half-filled New Session form (the user may have been on that
    // page). We reset the form directly rather than calling leaveNewSession:
    // its history commit is for genuine New-Session exits, and this path records
    // its own precise session entry just below. Calling leaveNewSession here
    // would couple correctness to the order of the two writes above.
    resetNewSessionForm(ref);
    ref
        .read(navControllerProvider.notifier)
        .commit(
          NavLocation(
            target: ref.read(selectedTargetProvider),
            surface: WorkbenchSurface.workspace,
            sessionId: session.id,
          ),
        );
  }

  /// Inline rename field. Enter (onSubmitted) and blur (onFocusChange)
  /// commit; Escape (intercepted by the wrapping [Focus]) cancels.
  ///
  /// Deliberately a borderless, collapsed field — not [AbTextField] —
  /// matching the title [Text]'s font metrics, so swapping it in keeps the
  /// row height (already anchored by the reserved kebab slot) stable while
  /// expanding to the full title width. The selected-row fill and the accent
  /// cursor signal edit mode; a bordered box (`rowHeightSm`, 32px) would grow
  /// the row. The global `inputDecorationTheme` fills + outlines fields, so
  /// every border state is neutralised here.
  Widget _buildEditor() {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          // Escape cancels: leave edit mode without saving.
          _exitEdit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      onFocusChange: (hasFocus) {
        if (!hasFocus) _commitDetached();
      },
      child: TextField(
        controller: _editController,
        focusNode: _editFocus,
        maxLines: 1,
        onSubmitted: (_) => _commitDetached(),
        style: AbTokens.sansStyle(
          height: 1.2,
          color: context.antgrid.textPrimary,
        ),
        cursorColor: context.antgrid.accent,
        cursorWidth: 1.5,
        decoration: const InputDecoration(
          isCollapsed: true,
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

enum _SessionAction { start, stop, rename, archive, delete }

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
  const _SessionMenu({required this.entryId, required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Builder(
      builder: (anchor) {
        // Explicit destiny: the menu chain awaits dialogs and bridge RPCs, and
        // an unhandled rejection from a fire-and-forget `void` call would land
        // outside any build() as a fatal.
        void open() => detached(
          'SessionRow',
          'session menu failed',
          () => _openMenu(anchor, ref.container),
        );
        // The parent row drives single/double tap through a
        // [SerialTapGestureRecognizer] that eagerly claims the gesture arena on
        // pointer-up (to keep single-tap selection instant). A plain button
        // [TapGestureRecognizer] defers to the arena sweep, so it loses that
        // race and the kebab never opened — the row's single-tap fired instead.
        // Match the row from the kebab's own (deeper) recognizer: it accepts
        // first, so the kebab wins and the row's recognizer is rejected. The
        // inner button keeps a non-null onTap for keyboard/a11y activation.
        return RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            SerialTapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  SerialTapGestureRecognizer
                >(
                  // Primary button only, matching the TapGestureRecognizer this
                  // replaces — a right-click shouldn't open the menu.
                  () => SerialTapGestureRecognizer(
                    allowedButtonsFilter: (b) => b == kPrimaryButton,
                  ),
                  (r) {
                    // Only the first tap opens; a 2nd tap (count > 1) is dropped
                    // rather than re-opening the just-opened menu.
                    r.onSerialTapUp = (d) {
                      if (d.count == 1) open();
                    };
                  },
                ),
          },
          child: AbIconButton(
            icon: AbIcons.more,
            tooltip: 'Session actions',
            onTap: open,
          ),
        );
      },
    );
  }

  Future<void> _openMenu(BuildContext anchor, ProviderContainer ref) async {
    // Working-directory rows are LOCAL-only: the checkout lives on the machine
    // hosting it, so for a relay project the window would open somewhere the
    // user is not sitting. A failed probe degrades to no rows rather than a
    // menu that never opens.
    final targets = ref.read(entryIsRelayProvider(entryId))
        ? const <ExternalOpenTarget>[]
        : await ref
              .read(externalOpenTargetsProvider.future)
              .catchError((_) => const <ExternalOpenTarget>[]);
    if (!anchor.mounted) return;
    final anchorRect = abMenuAnchorRect(anchor);
    if (anchorRect == null) return;
    final choice = await showAbMenu<_SessionMenuChoice>(
      context: anchor,
      anchorRect: anchorRect,
      width: 200,
      bounds: MenuBoundsScope.maybeOf(anchor),
      entries: [
        AbMenuItem(
          label: session.running ? 'Stop' : 'Start',
          value: _RowAction(
            session.running ? _SessionAction.stop : _SessionAction.start,
          ),
        ),
        const AbMenuItem(
          label: 'Rename',
          value: _RowAction(_SessionAction.rename),
        ),
        const AbMenuItem(
          label: 'Archive',
          value: _RowAction(_SessionAction.archive),
        ),
        if (targets.isNotEmpty) ...[
          const AbMenuDivider(),
          for (final target in targets)
            AbMenuItem(
              label: target.label,
              icon: target.icon,
              value: _OpenExternally(target),
            ),
          const AbMenuItem(
            label: 'Copy path',
            icon: AbIcons.copy,
            value: _CopyPath(),
          ),
        ],
        const AbMenuDivider(),
        const AbMenuItem(
          label: 'Delete',
          value: _RowAction(_SessionAction.delete),
          danger: true,
        ),
      ],
    );
    if (choice == null || !anchor.mounted) return;

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
  }

  Future<void> _runRowAction(
    BuildContext anchor,
    ProviderContainer ref,
    _SessionAction action,
  ) async {
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
            if (anchor.mounted) reportStartRefusal(anchor, error);
          }
        case _SessionAction.stop:
          await svc.stopSession(session.id);
        case _SessionAction.rename:
          final name = await promptSessionRename(anchor, session.name);
          if (name != null && name.trim().isNotEmpty) {
            await svc.rename(session.id, name.trim());
          }
        case _SessionAction.archive:
          await svc.archive(session.id);
          _disconnectIfEmpty(ref);
        case _SessionAction.delete:
          await _deleteSession(anchor, ref, svc);
      }
    } on TimeoutException {
      if (anchor.mounted) {
        showAbSnackBar(
          anchor,
          "The agent didn't answer. Check the connection and try again.",
        );
      }
    }
  }

  Future<void> _deleteSession(
    BuildContext context,
    ProviderContainer ref,
    SessionsService service,
  ) async {
    final capturedId = session.id;
    final result = await confirmAndDeleteSession(
      context: context,
      sessionName: session.name,
      checkoutKind: session.checkoutKind,
      sharedBody:
          'This permanently deletes "${session.name}" and terminates its agent process.',
      delete: ({force, deleteBranch}) =>
          service.delete(capturedId, force: force, deleteBranch: deleteBranch),
    );
    if (result == SessionDeleteResult.deleted) _disconnectIfEmpty(ref);
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
      ref.read(pairedAgentProvider.notifier).cancelActiveAgent();
    } else if (ref.read(selectedRegistrationIdProvider) != null) {
      ref.read(selectedTargetProvider.notifier).set(null);
    }
  }
}
