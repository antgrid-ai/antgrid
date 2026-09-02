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
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_row_trailing.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/session_entry.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../project/limits.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/chat_composer_drafts.dart';
import '../providers/open_checkout.dart';
import '../providers/project_work_status.dart';
import '../providers/providers.dart';
import '../providers/session_delete_pending.dart';
import '../providers/session_workspace_state.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../services/control_plane_client.dart';
import '../services/sessions_service.dart';
import '../util/detached.dart';
import '../util/external_open_target.dart';
import 'agent_work_status_dot.dart';
import 'drawer_entry_row.dart' show activateDrawerEntryById, ensureRemoteOnline;
import 'session_delete_flow.dart';
import 'session_deleting_badge.dart';
import 'session_handler_badge.dart';
import 'session_fork_dialog.dart';
import 'session_isolation_badge.dart';
import 'session_approval_badge.dart';
import 'session_rename_dialog.dart';
import 'session_shared_workspace_badge.dart';
import 'session_start_refusal.dart';

/// Fraction (-1..1) by which the status dot is shifted down within its leading
/// box to sit on the title's optical centre rather than its line-box centre.
/// ~0.45 of the 3px free half-space ≈ a 1.3px nudge — the measured gap for a
/// 14px line at 1.2 line-height.
const double _dotOpticalYBias = 0.45;

/// Shown when a `session:start` the user explicitly asked for gets no reply.
/// One literal because the row tap and the kebab's Fork make the user the same
/// promise, and a start that is still pending must not read as a failed one.
const String _startNoAnswerMessage =
    "The agent didn't answer. If the session doesn't come up in a moment, try "
    'again.';

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
  // Mobile has no hover — keep the kebab visible.
  late bool _hovered = isMobilePlatform;

  // Keep kebab mounted and visible while the action menu is actively open.
  bool _menuOpen = false;

  // A collapsed kebab is unreachable without a pointer, so the row's own focus
  // highlight has to reveal it too.
  bool _focused = false;

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

  /// The leading indicator. A delete in flight owns the slot outright; then
  /// work status owns it whenever the agent has something to say about THIS
  /// session (working / needs you / error / unread) — it is the same dot the
  /// Recent list shows, so one session's state reads identically wherever it
  /// surfaces.
  ///
  /// At rest the dot says nothing at all: the same hollow idle ring whether the
  /// session is running or stopped. Running used to fill it in the accent, which
  /// on the default preset is off-white — so merely OPENING a session lit it up
  /// brighter than a session that was actually doing something, and the brightest
  /// dot in the sidebar was the one you were already looking at. Liveness is not
  /// a status: what the row exists to report is what the agent wants from you,
  /// and a session at rest wants nothing.
  Widget _leadingDot(AgentWorkStatus work, {required bool deleting}) {
    final key = ValueKey('session-status-dot-${session.id}');
    // Outranks both arms below: work status is about what a live agent is
    // doing, and this one is being taken apart.
    if (deleting) {
      return AbLoadingDot(
        key: ValueKey('session-deleting-dot-${session.id}'),
        // One step up from the status dot it replaces: the pulse spends most of
        // its cycle smaller than its nominal size, so matching dotSizeSm would
        // read as a fainter indicator than the one it took over from.
        size: AbTokens.dotSizeMd,
      );
    }
    if (work != AgentWorkStatus.done) {
      return AgentWorkStatusDot(key: key, status: work);
    }
    return AbStatusDot(
      key: key,
      // Archived is the one at-rest distinction worth drawing: it is a
      // lifecycle end, not a pause. Otherwise the agent-at-rest gray, dimmer
      // than `neutral` (textSecondary) so the ring recedes instead of reading
      // as a lit indicator — not `muted`, which is de-emphasized TEXT.
      tone: session.archived ? AbStatusTone.disabled : AbStatusTone.agentIdle,
      size: AbDotSize.sm,
      style: AbDotStyle.hollow,
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

    // The drawer's one indent step is spent here, between a project row and
    // its sessions — machine headers are bands and cost none, so this is the
    // whole depth budget of the tree.
    //
    // Split so the selection fill gets breathing room before the status dot
    // without shifting the dot's screen position: all but the last space6 sits
    // on the outer Padding (which also keeps the L/R strips non-hover-reactive),
    // and the last space6 is the row's own horizontalPadding.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerSessionIndent - AbTokens.space6,
        0,
        AbTokens.space6,
        0,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: _onEnter,
        onExit: _onExit,
        child: AbListRow(
          leadingGapOverride: AbTokens.drawerSessionLeadingGap,
          leading: SizedBox(
            width: AbTokens.drawerSessionLeadingSlot,
            height: AbTokens.drawerLeadingSlot,
            // Bias the dot slightly below its box centre. Row-centring lines up
            // the dot with the title's line-box centre, but the visible glyphs
            // of a text line sit a hair lower (the font reserves more space
            // above the baseline than below), so a geometrically-centred dot
            // reads as too high. The small downward nudge matches the optical
            // centre of the text.
            child: Align(
              alignment: const Alignment(0, _dotOpticalYBias),
              child: _leadingDot(work, deleting: deleting),
            ),
          ),
          title: (_editing && !deleting)
              ? _buildEditor()
              : Row(
                  children: [
                    Flexible(
                      child: Text(
                        session.name,
                        // The payload of the drawer, and so still its largest
                        // text — but at fontMd against the project row's
                        // fontSm, not fontBody at textPrimary, which made every
                        // session outshout the project containing it. The
                        // active row is the one thing in the panel that goes
                        // primary.
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontMd,
                          fontWeight: selected
                              ? FontWeight.w500
                              : FontWeight.normal,
                          color: selected
                              ? context.antgrid.textPrimary
                              : context.antgrid.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SessionIsolationBadge(
                      session: session,
                      // The live list's answer, never `session.setup`: a row
                      // for a project that isn't focused is served from the
                      // persisted cache, which carries no setup state at all.
                      setup: ref.watch(sessionSetupProvider(session.id)),
                    ),
                    SessionApprovalBadge(session: session),
                    SessionSharedWorkspaceBadge(session: session),
                    SessionHandlerBadge(
                      entryId: widget.entryId,
                      sessionId: session.id,
                    ),
                    SessionDeletingBadge(deleting: deleting),
                  ],
                ),
          // Hover-only kebab (always visible on mobile touch devices). Does
          // not take trailing width when unhovered, leaving the full width
          // for session titles. Kept mounted while the menu is open.
          // Hidden entirely while deleting rather than partly disabled: every
          // item on it (start/stop/rename/archive/delete, and the
          // working-directory rows pointing into a checkout that is going away)
          // acts on a session being removed.
          trailing:
              ((_hovered || _menuOpen || _focused) && !_editing && !deleting)
              ? AbRowTrailingCell(
                  child: _SessionMenu(
                    entryId: widget.entryId,
                    session: session,
                    onMenuOpened: () {
                      if (mounted) setState(() => _menuOpen = true);
                    },
                    onMenuClosed: () {
                      if (mounted) setState(() => _menuOpen = false);
                    },
                  ),
                )
              : null,
          selected: selected,
          enabled: !deleting,
          contentFloor: AbRowContentFloor.iconButton,
          onFocusChange: (v) {
            if (mounted) setState(() => _focused = v);
          },
          selectionStyle: AbRowSelection.surface,
          hoverable: true,
          density: AbRowDensity.sm,
          horizontalPadding: AbTokens.space6,
          verticalPadding: 1,
          // Small vertical margin so adjacent rows don't touch.
          margin: const EdgeInsets.symmetric(vertical: 1),
          // Disable activation while editing so taps stay in the field.
          onTap: (_editing || deleting)
              ? null
              : () => detached(
                  'SessionRow',
                  'session activate failed',
                  () => _activate(context, ref.container),
                ),
          // Desktop: double-tap a running session (in any warm project) to
          // rename it inline. The row's SerialTap recognizer keeps single-tap
          // selection instant, so wiring this on many rows costs no latency.
          onDoubleTap: (isMobilePlatform || _editing || deleting || !canRename)
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
          if (refusalHost.mounted) reportStartRefusal(refusalHost, error);
          return;
        } on TimeoutException {
          // A dropped reply must not abandon the focus + surface + nav writes
          // below: the user asked for THIS session, and the bridge may have
          // spawned the PTY anyway (`session:updated` then reconciles the row).
          // Leaving the activeSessionId set while the surface never switches is
          // the worst of both — a tap that visibly did nothing.
          if (refusalHost.mounted) {
            showAbSnackBar(refusalHost, _startNoAnswerMessage);
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

  void _showFocusedSessionSurface(ProviderContainer ref) =>
      _showSessionSurface(ref, session.id);

  /// Inline rename field. Enter (onSubmitted) and blur (onFocusChange)
  /// commit; Escape (intercepted by the wrapping [Focus]) cancels.
  ///
  /// Deliberately a borderless, collapsed field — not [AbTextField] —
  /// matching the title [Text]'s font metrics, so swapping it in keeps the
  /// row height (anchored by the row's own content floor) stable while
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
  final VoidCallback? onMenuOpened;
  final VoidCallback? onMenuClosed;

  const _SessionMenu({
    required this.entryId,
    required this.session,
    this.onMenuOpened,
    this.onMenuClosed,
  });

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
    onMenuOpened?.call();
    try {
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
      // excluded without this line being revisited. A failed probe degrades to no
      // rows rather than a menu that never opens.
      final local = await ref
          .read(entryIsLocalCheckoutProvider(entryId).future)
          .catchError((_) => false);
      final targets = local
          ? await ref
                .read(externalOpenTargetsProvider.future)
                .catchError((_) => const <ExternalOpenTarget>[])
          : const <ExternalOpenTarget>[];
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
          if (session.forkSupported)
            AbMenuItem(
              label: 'Fork session',
              value: const _RowAction(_SessionAction.fork),
              // Greyed rather than dropped: `forkSupported` answers whether the
              // AGENT can be forked, which is a permanent fact about the tool,
              // while having something to fork is a fact about this session that
              // its first turn fixes. Hiding the row for the second would teach
              // the user the tool cannot do it at all.
              //
              // What the bridge actually reads is a native conversation id or the
              // live terminal's scrollback (`captureForkTranscript`), and both
              // inputs are already on the wire — so this mirrors the precondition
              // rather than asking for it. Drift costs a refusal the branch below
              // now reports, never a silence.
              enabled: session.running || session.agentSessionId != null,
              disabledReason:
                  'This session has nothing to fork yet. Start it and let the '
                  'agent reply first.',
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
    } finally {
      onMenuClosed?.call();
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
        case _SessionAction.fork:
          final workspace = await promptSessionFork(
            anchor,
            isolatedSource: sessionIsIsolated(session),
          );
          if (workspace == null || !anchor.mounted) return;
          // Caught per-branch, per the contract above: every fork refusal the
          // bridge documents — no captured transcript yet, a conversation past
          // the handoff cap, a custom-command session, a missing checkout —
          // arrives as a typed exception carrying the bridge's own sentence,
          // and without this the menu item just appears to do nothing.
          try {
            final fork = await svc.fork(session.id, workspace: workspace);
            // An `ok` carrying no session: there is nothing to start and
            // nothing to land in, so say so rather than returning as though the
            // fork had happened. The same answer the New Session canvas treats
            // as a refused create.
            if (fork == null) {
              if (anchor.mounted) {
                reportSessionNotice(anchor, sessionForkRefusalCopy(null, null));
              }
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
              if (started == null && anchor.mounted) {
                reportSessionNotice(
                  anchor,
                  sessionStartRefusalCopy(null, null),
                );
              }
            } on SessionOperationException catch (error) {
              if (anchor.mounted) reportStartRefusal(anchor, error);
            } on TimeoutException {
              if (anchor.mounted) {
                reportSessionNotice(anchor, _startNoAnswerMessage);
              }
            }
            if (anchor.mounted) await _focusSession(anchor, ref, svc, fork.id);
          } on SessionOperationException catch (error) {
            if (anchor.mounted) {
              reportSessionNotice(
                anchor,
                sessionForkRefusalCopy(error.errorCode, error.message),
              );
            }
          }
        case _SessionAction.rename:
          final name = await promptSessionRename(anchor, session.name);
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
