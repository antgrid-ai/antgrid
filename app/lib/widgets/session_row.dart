import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/session_entry.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../project/limits.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../services/sessions_service.dart';
import 'drawer_entry_row.dart' show activateDrawerEntryById, ensureRemoteOnline;
import 'session_rename_dialog.dart';

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
  /// Routes to THIS row's project via [sessionsServiceFor] (warming it back if
  /// the LRU evicted it mid-edit), not the focused project. Captures the ids
  /// before [_exitEdit]/`await` so it stays correct even if the row unmounts
  /// during the warm-up.
  Future<void> _commitEdit() async {
    if (!_editing) return;
    final name = _editController?.text.trim() ?? '';
    final changed = name.isNotEmpty && name != session.name;
    final entryId = widget.entryId;
    final sessionId = session.id;
    _exitEdit();
    if (!changed) return;
    final svc = await sessionsServiceFor(ref, entryId);
    if (svc != null) unawaited(svc.rename(sessionId, name));
  }

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
    if (session.running) return AbStatusTone.success;
    // Stopped: a faint gray, dimmer than `neutral` (textSecondary), so the
    // hollow ring recedes instead of reading as a lit indicator.
    return AbStatusTone.muted;
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
              // Filled dot = live, hollow ring = idle. The fill/outline
              // contrast reads "on vs off" faster than a colour shift between
              // two filled dots, so only a running session gets a solid dot.
              child: AbStatusDot(
                tone: _tone(),
                size: AbDotSize.sm,
                style: session.running ? AbDotStyle.filled : AbDotStyle.hollow,
              ),
            ),
          ),
          // Row height is anchored by the always-reserved kebab slot (taller
          // than the text line), so swapping the title for the field doesn't
          // change the height; the field expands to the full title width.
          title: _editing
              ? _buildEditor()
              : Text(
                  session.name,
                  style: AbTokens.sansStyle(),
                  overflow: TextOverflow.ellipsis,
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
          onTap: _editing ? null : () => _activate(context, ref),
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

  Future<void> _activate(BuildContext context, WidgetRef ref) async {
    if (_activating) return;
    _activating = true;
    try {
      await _activateInner(context, ref);
    } finally {
      _activating = false;
    }
  }

  Future<void> _activateInner(BuildContext context, WidgetRef ref) async {
    final liveId = ref.read(selectedRegistrationIdProvider);
    if (widget.entryId == liveId) {
      // Same project — local fast path. For a same-project remote `liveId`
      // is the agentDeviceId, so reconnect-on-demand uses it directly.
      if (ref.read(focusedIsRelayProvider)) {
        if (!await ensureRemoteOnline(context, ref, liveId!)) return;
      }
      ref.read(activeSessionIdProvider.notifier).set(session.id);
      final svc = ref.read(sessionsServiceProvider);
      if (!session.running) {
        await svc.start(session.id);
        // start() can outlive this row (drawer closes, list rebuilds); every
        // ref use below would throw on a disposed ConsumerState.
        if (!mounted) return;
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

  void _showFocusedSessionSurface(WidgetRef ref) {
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
        if (!hasFocus) _commitEdit();
      },
      child: TextField(
        controller: _editController,
        focusNode: _editFocus,
        maxLines: 1,
        onSubmitted: (_) => _commitEdit(),
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

/// Resolve the [SessionsService] for [entryId]'s project — not the focused one.
/// The drawer renders rows for non-focused warm projects too, so routing
/// through `sessionsServiceProvider` (keyed on the focused project) would send
/// the action to the wrong agent and mutate/destroy a same-id session there.
/// Warms the project if cold (a rename/kebab action is explicit intent on that
/// session); bounded by [timeout] so an unreachable agent can't hang. Returns
/// null when it can't be reached, so callers no-op rather than misroute.
Future<SessionsService?> sessionsServiceFor(
  WidgetRef ref,
  String entryId, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final ps = await ref
        .read(projectSessionProvider(entryId).future)
        .timeout(timeout);
    return ps.sessionsService;
  } catch (_) {
    return null;
  }
}

class _SessionMenu extends ConsumerWidget {
  final String entryId;
  final SessionEntry session;
  const _SessionMenu({required this.entryId, required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Builder(
      builder: (anchor) {
        void open() => _openMenu(anchor, ref);
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

  Future<void> _openMenu(BuildContext anchor, WidgetRef ref) async {
    final anchorRect = abMenuAnchorRect(anchor);
    if (anchorRect == null) return;
    final action = await showAbMenu<_SessionAction>(
      context: anchor,
      anchorRect: anchorRect,
      width: 200,
      bounds: MenuBoundsScope.maybeOf(anchor),
      entries: [
        AbMenuItem(
          label: session.running ? 'Stop' : 'Start',
          value: session.running ? _SessionAction.stop : _SessionAction.start,
        ),
        AbMenuItem(label: 'Rename', value: _SessionAction.rename),
        AbMenuItem(label: 'Archive', value: _SessionAction.archive),
        const AbMenuDivider(),
        AbMenuItem(label: 'Delete', value: _SessionAction.delete, danger: true),
      ],
    );
    if (action == null || !anchor.mounted) return;
    final svc = await sessionsServiceFor(ref, entryId);
    if (svc == null || !anchor.mounted) return;
    switch (action) {
      case _SessionAction.start:
        await svc.start(session.id);
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
        final confirmed = await AbConfirmDialog.show(
          context: anchor,
          title: 'Delete session?',
          body:
              'This permanently deletes "${session.name}" and terminates its agent process. This cannot be undone.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (confirmed) {
          await svc.delete(session.id);
          _disconnectIfEmpty(ref);
        }
    }
  }

  /// Wired here (call site) instead of as a listener on
  /// [activeSessionsProvider] because `_stopAllServices()` empties the
  /// session list synchronously during a project switch — a listener would
  /// race that and partially undo the switch.
  void _disconnectIfEmpty(WidgetRef ref) {
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
