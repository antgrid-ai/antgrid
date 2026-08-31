import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_composer_send_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_cross_fade.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_kbd.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_snack_bar.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../design/widgets/ab_switch.dart';
import '../../design/widgets/ab_tooltip.dart';

// The send key moved to the design system (shared with the transcript
// composer); re-exported so existing importers keep resolving it from here.
export '../../design/widgets/ab_composer_send_button.dart'
    show ComposerSendButton;
import '../../models/agent_descriptor.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/new_session_action.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/new_session_start.dart';
import '../../screens/upgrade_screen.dart';
import '../../services/sessions_service.dart' show SessionOperationException;
import '../../utils/platform_utils.dart';
import '../../util/detached.dart';
import '../ab_status_helpers.dart' show sessionRefusalCopy;
import 'branch_menu.dart';
import 'branch_remote_advisory.dart';
import 'environment_menu.dart';
import 'project_menu.dart';

typedef StartNewSessionCallback =
    Future<void> Function(ProviderContainer ref, {bool allowActiveSessions});

/// Whether the Start/Send affordance is enabled. Single source of truth for
/// both the reactive `canSend` (built from watched values in `build`) and the
/// on-demand `_canStart` recheck at submit time — one predicate so the two
/// read/watch call sites can't drift.
bool newSessionCanStart({
  required bool starting,
  required bool hasValidTarget,
  required bool isCustom,
  required String customCmd,
  bool isolated = false,
  bool isolationReady = false,
}) =>
    !starting &&
    hasValidTarget &&
    (!isCustom || customCmd.trim().isNotEmpty) &&
    (!isolated || isolationReady);

/// What to say when a start ended without producing a session.
///
/// A completed checkout is appended to every reason rather than replacing any
/// of them: it is a second fact about the same outcome, and the one the user
/// cannot see from the form they are looking at. Without it a Stop during the
/// checkout reads as "Start cancelled." over a working tree that has moved
/// under every session in the folder.
String _abortCopy(NewSessionStartAbort abort) {
  final switched = abort.branchSwitchedTo;
  final left = switched == null
      ? ''
      : ' The folder was already switched to "$switched".';
  return '${_abortReasonCopy(abort.reason)}$left';
}

/// [NewSessionStartAbortReason.cancelled] is the user's own doing, so it reads
/// as a confirmation; the rest describe something that happened TO the start,
/// and each names what was and wasn't left behind on the machine.
String _abortReasonCopy(NewSessionStartAbortReason reason) => switch (reason) {
  NewSessionStartAbortReason.cancelled => 'Start cancelled.',
  NewSessionStartAbortReason.intentChanged =>
    'The setup changed while the session was starting, so nothing was '
        'created. Start again when the form says what you want.',
  NewSessionStartAbortReason.createRefused => 'Could not create the session.',
  NewSessionStartAbortReason.startRefused =>
    'The session was created but did not start.',
  NewSessionStartAbortReason.isolationUnavailable =>
    "This machine can't create isolated sessions — check that its Antgrid is "
        'up to date.',
  NewSessionStartAbortReason.abandonedAfterCreate =>
    'You switched projects while the session was starting, so it was created '
        'but never launched.',
  NewSessionStartAbortReason.startedAfterSwitch =>
    'You switched projects while the session was starting. It launched — find '
        'it in the project you started it from.',
  NewSessionStartAbortReason.replyTimedOut =>
    "The machine didn't answer in time. Check that project's sessions before "
        'starting another one.',
};

/// Minimum row slack (hint intrinsic width + trailing gap, with margin)
/// before the Enter-to-start hint is worth rendering at all.
const double _enterHintMinWidth = 96;

/// The same floor for the phase status line, set lower because the two are not
/// worth the same: the hint restates a shortcut, while the phase copy is the
/// only account of a wait that can run 30s. An ellipsized stage name beats no
/// stage name, so this only has to leave room for the dot and a few characters.
const double _statusLineMinWidth = 44;

/// Bottom-row width below which the controls degrade: the agent selector's
/// slot absorbs the row slack (ellipsizing its label) instead of the desktop
/// Enter-hint slot. Degradation order is hint → label; the labels never drop.
const double _composerRowRoomyMinWidth = 460;

/// Flex the phase status line claims while a start runs, against the agent
/// selector's 1. A phone's bottom row cannot seat both at their intrinsic
/// widths, and a locked selector is the one of the two with nothing left to
/// say — it sheds its label to the glyph the way a narrow context row's chips
/// do, rather than pushing the phase off the line.
const int _statusSlotFlex = 3;

/// Share of the context row a single picker label may claim before it starts
/// ellipsizing. Two of them cap out together at well under the full row, which
/// is what keeps the fixed-width isolation chip and a readable stub of the
/// branch on the line no matter how pathological the machine and project names
/// get.
const double _chipLabelCapFraction = 0.3;

/// Room the branch chip is guaranteed on the context row: enough to render its
/// glyph, its chevron and a readable stub of the ref. The row hands the branch
/// its remainder, and a fraction-only cap can leave a remainder below the
/// chip's own chrome — which is a render overflow, not a truncation.
const double _branchChipFloor = kComposerChipFullMinWidth;

/// Bottom-anchored composer for the New Session canvas.
///
/// Assembles the chip row ([EnvironmentChip] + [ProjectChip]), a multiline
/// prompt field, and the bottom control row (mode chip, gear popover, agent
/// selector, send button). Also owns the form listeners (target -> seed agent,
/// agent -> mode default, detection -> installed-agent snap) and the submit
/// handler.
class NewSessionComposer extends ConsumerStatefulWidget {
  const NewSessionComposer({
    super.key,
    required this.onOpenFolder,
    this.submit = startNewSession,
  });

  final VoidCallback onOpenFolder;

  /// Injectable seam for tests; production callers never pass this — it
  /// defaults to the real [startNewSession].
  final StartNewSessionCallback submit;

  @override
  ConsumerState<NewSessionComposer> createState() => _NewSessionComposerState();
}

class _NewSessionComposerState extends ConsumerState<NewSessionComposer> {
  late final TextEditingController _prompt;
  late final FocusNode _promptFocus;
  bool _hovered = false;
  bool _promptFocused = false;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: ref.read(newSessionPromptProvider));
    _promptFocus = FocusNode();
    // Intercepts Enter/Shift+Enter before the field's own key handling —
    // same pattern as the transcript's RichComposer.
    _promptFocus.onKeyEvent = _onPromptKeyEvent;
    _promptFocus.addListener(_onPromptFocusChanged);
    // Establish the initial mode for whatever agent the form already carries
    // (e.g. re-entering New Session with a seeded agent), mirroring the
    // per-change default applied in the agent listener below. Deferred a
    // frame: Riverpod disallows writing a provider mid-build, which
    // initState counts as. Ported from `_SessionConfigState.initState`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyModeDefault(ref.read(newSessionAgentProvider));
    });
  }

  @override
  void dispose() {
    _promptFocus.onKeyEvent = null;
    _promptFocus.removeListener(_onPromptFocusChanged);
    _promptFocus.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _onPromptFocusChanged() {
    if (_promptFocus.hasFocus == _promptFocused) return;
    setState(() => _promptFocused = _promptFocus.hasFocus);
  }

  /// Point an untouched agent pick at a tool the target actually has
  /// installed. Custom and user-touched picks are left alone
  /// ([firstInstalledAgent] keeps them).
  ///
  /// Never while a start is on the wire: `startNewSession` reads the agent
  /// AFTER its awaits, so a detection landing mid-start would relabel a chip
  /// the user was told is locked and launch a tool the status line never
  /// named. The in-flight listener re-runs this once the start ends, because
  /// the suppressed detection is dropped rather than queued.
  void _snapToInstalledAgent() {
    if (ref.read(newSessionStartInFlightProvider)) return;
    if (ref.read(newSessionAgentTouchedProvider)) return;
    final detected = ref.read(newSessionDetectedToolsProvider).value;
    if (detected == null || detected.isEmpty) return;
    final current = ref.read(newSessionAgentProvider);
    ref
        .read(newSessionAgentProvider.notifier)
        .set(firstInstalledAgent(detected, current));
  }

  /// Terminal is the default for EVERY agent — the mode all of them can run,
  /// and the one chat (still alpha) has to be chosen over deliberately. A
  /// chat-capable agent no longer opts the session into chat behind the user.
  ///
  /// A pick already made survives an agent change unless the new agent can't
  /// do chat, in which case it is forced back to Terminal.
  void _applyModeDefault(NewSessionAgent agent) {
    final key = newSessionAgentToolKey(agent);
    final supports = agentSupportsChatResolved(
      agent,
      wireChatCapable: ref.read(newSessionChatCapableToolsProvider).value,
      descriptor: key == null ? null : ref.read(agentCatalogProvider)[key],
    );
    if (supports == true) return;
    ref.read(newSessionModeProvider.notifier).set('terminal');
  }

  /// Enter submits; Shift+Enter inserts a newline at the caret. Esc is left
  /// untouched here so it keeps bubbling to whatever ancestor
  /// `CallbackShortcuts` binds the canvas-leave shortcut, even while the
  /// field is focused and empty.
  ///
  /// The newline is inserted manually rather than left to fall through to
  /// the field's default key handling: a hardware Enter's default multiline
  /// behavior depends on platform-specific text-editing shortcuts that this
  /// composer shouldn't have to depend on.
  KeyEventResult _onPromptKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // Swallowed, not ignored, while a start runs: the field is read-only by
    // then, but this handler writes the controller directly, so read-only
    // alone would still let Shift+Enter edit a prompt already on the wire.
    if (ref.read(newSessionStartInFlightProvider)) {
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertPromptNewline();
      return KeyEventResult.handled;
    }
    _submit();
    return KeyEventResult.handled;
  }

  void _insertPromptNewline() {
    final value = _prompt.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final newText = value.text.replaceRange(
      selection.start,
      selection.end,
      '\n',
    );
    _prompt.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
    ref.read(newSessionPromptProvider.notifier).set(newText);
  }

  /// On-demand recheck at submit time (ref.read-based). Shares
  /// [newSessionCanStart] with the reactive `canSend` in `build` so the two
  /// can't diverge.
  bool get _canStart => newSessionCanStart(
    starting: ref.read(newSessionStartInFlightProvider),
    hasValidTarget: ref.read(newSessionHasValidTargetProvider),
    isCustom: ref.read(newSessionAgentProvider) == const CustomAgent(),
    customCmd: ref.read(newSessionCustomCmdProvider),
    isolated: ref.read(newSessionIsolatedProvider),
    isolationReady: ref.read(newSessionIsolationReadyProvider),
  );

  /// The reason [_reportAbort] last consumed. The abort reason is consume-once
  /// and the listener below can take it while `_submit` is still unwinding, so
  /// the arms that have to know whether the user pressed Stop cannot ask the
  /// provider alone.
  NewSessionStartAbort? _reportedAbort;

  /// Whether this start ended because the user asked it to. Both sources are
  /// consulted because either one may hold the answer depending on whether the
  /// listener has run yet.
  bool get _endedByCancel =>
      _reportedAbort?.reason == NewSessionStartAbortReason.cancelled ||
      ref.read(newSessionStartAbortProvider)?.reason ==
          NewSessionStartAbortReason.cancelled;

  /// Ported verbatim from `_SessionFooterState.build`'s Start button `onTap`.
  Future<void> _submit() async {
    if (!_canStart) return;
    _reportedAbort = null;
    try {
      var allowActiveSessions = false;
      while (true) {
        try {
          await widget.submit(
            ref.container,
            allowActiveSessions: allowActiveSessions,
          );
          break;
        } on ActiveSessionsBranchSwitchException catch (e) {
          if (allowActiveSessions) {
            rethrow;
          }
          // Mounted FIRST: `_endedByCancel` reads `ref`, and a WidgetRef read
          // on a State that a mid-start resize already disposed throws out of a
          // fire-and-forget `_submit()` with nowhere to land.
          if (!mounted) return;
          // A Stop press the throw outran already ended this start. Asking the
          // user to confirm a working-tree switch they just cancelled would act
          // on the opposite of what they last said.
          if (_endedByCancel) return;
          final confirm = await AbConfirmDialog.show(
            context: context,
            title: 'Switch branch?',
            body:
                'One or more sessions in this folder are working or need you. Switching to "${e.branch}" changes the working tree for all of them.',
            cancelLabel: 'Cancel',
            confirmLabel: 'Switch & start',
            destructive: false,
          );
          if (confirm != true || !mounted) return;

          final target = ref.read(selectedTargetProjectProvider);
          final selection = ref.read(newSessionBranchSelectionProvider);
          if (target == null ||
              target.id != e.targetId ||
              selection == null ||
              selection.targetId != e.targetId ||
              selection.branch != e.branch) {
            return;
          }
          allowActiveSessions = true;
        }
      }
    } on SessionLimitExceededException catch (e) {
      // A legacy relay's retired cap, not a transient failure — retrying won't
      // clear it, so say what will and show the plan the account is on.
      if (mounted && !_endedByCancel) {
        showAbSnackBar(context, e.userMessage);
        await openUpgrade(context, ref.container);
      }
    } on SessionOperationException catch (e) {
      // The bridge's create/start refusal is already user-facing text and the
      // coded arms replace it where its wording names something the reader
      // can't act on; either beats the raw exception the generic arm prints.
      // No navigation — the user stays here with the form intact.
      if (mounted && !_endedByCancel) {
        showAbSnackBar(
          context,
          sessionRefusalCopy(
            e.errorCode,
            e.message,
            'Could not start the session.',
          ),
          duration: const Duration(seconds: 8),
        );
      }
    } catch (e) {
      // A start the user stopped reports the cancel and nothing else: the
      // failure it raced is not an outcome they asked about.
      if (mounted && !_endedByCancel) {
        showAbSnackBar(
          context,
          'Failed to start session: $e',
          duration: const Duration(seconds: 8),
        );
      }
    } finally {
      // In a `finally` so the early returns above — an unconfirmed branch
      // switch, a form that drifted while the dialog was up — report like every
      // other end of a start rather than leaving the dot to just stop.
      _reportAbort();
    }
  }

  /// Say why a start ended without a session, exactly once.
  ///
  /// Driven from a listener as well as from `_submit`, because a start outlives
  /// the composer that began it: the New Session screen builds a different tree
  /// either side of the compact breakpoint, so the `_submit` continuation can
  /// resolve on a State that a resize already disposed. Whichever composer is
  /// mounted when the reason lands is the one that says it; `takeAbort`
  /// CONSUMES, so the other call is a no-op rather than a second snackbar.
  void _reportAbort() {
    // Mounted first: reading `ref` on a disposed State throws, and consuming
    // the reason there would swallow the only record of why the start ended.
    if (!mounted) return;
    final abort = ref
        .read(newSessionStartProgressProvider.notifier)
        .takeAbort();
    if (abort == null) return;
    _reportedAbort = abort;
    showAbSnackBar(
      context,
      _abortCopy(abort),
      // A cancel the user asked for is a confirmation, not something to read —
      // unless it also has to account for a checkout it could not take back.
      duration:
          abort.reason == NewSessionStartAbortReason.cancelled &&
              abort.branchSwitchedTo == null
          ? null
          : const Duration(seconds: 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Picking a project (local folder or remote) hands focus straight to the
    // prompt field so the next keystroke describes the task — the
    // composer's analogue of the old SessionConfig's name-field grab.
    ref.listen(selectedTargetProjectProvider, (previous, next) {
      if (previous?.id != next?.id) {
        ref.read(newSessionIsolatedProvider.notifier).set(false);
        ref.read(newSessionBranchSelectionProvider.notifier).set(null);
      }
      seedNewSessionAgentForTarget(ref.container, next);
      if (next != null) _promptFocus.requestFocus();
    });
    ref.listen(newSessionAgentProvider, (_, next) => _applyModeDefault(next));
    ref.listen(newSessionBypassSupportProvider, (_, next) {
      if (next == null &&
          ref.read(newSessionApprovalPolicyProvider) == 'bypass') {
        ref.read(newSessionApprovalPolicyProvider.notifier).set('default');
      }
    });
    // Re-apply the mode default EXACTLY ONCE, when the wire chat-capability
    // future FIRST resolves (loading -> has-value). This closes a startup
    // race where initState's postFrameCallback (and a target switch's agent
    // seed) can run before this data lands, defaulting off the static
    // fallback list instead of the true advert.
    //
    // The guard is load-bearing: newSessionChatCapableToolsProvider re-emits
    // on EVERY control-plane push (controlPlaneStateProvider rebuilds a fresh
    // ControlPlaneState — no `==` — on each agent:projects/agent:tools, and
    // chatCapableSetOrNull allocates a new Set each time), so a project on
    // the machine starting/stopping or a heartbeat would re-fire this. Firing
    // on every emission would silently rewrite the mode back to the agent
    // default, discarding a user's manual toggle. The has-value transition
    // fires only at first resolution: on later re-runs the FutureProvider
    // retains its previous value (copyWithPrevious), so prev.hasValue stays
    // true and this body is skipped. A later agent change gets its own correct
    // default via the agent listener above (which reads the resolved value).
    ref.listen(newSessionChatCapableToolsProvider, (prev, next) {
      if (next.hasValue && !(prev?.hasValue ?? false)) {
        _applyModeDefault(ref.read(newSessionAgentProvider));
      }
    });
    // When detection resolves, snap the (untouched) default to an installed
    // tool so the default is actually runnable. Custom and user-touched
    // picks are left alone ([firstInstalledAgent] keeps them).
    ref.listen(newSessionDetectedToolsProvider, (_, _) {
      _snapToInstalledAgent();
    });
    // Keep the controller in sync with external writes to the prompt
    // provider (e.g. resetNewSessionForm clearing it on exit). Guarded on
    // inequality so user typing — which writes the same value back via
    // onChanged — doesn't reset the cursor.
    ref.listen(newSessionPromptProvider, (_, next) {
      if (_prompt.text != next) _prompt.text = next;
    });
    // The reason lands while `startNewSession` is still unwinding, which is
    // before the `_submit` that began the start resumes — and that `_submit`
    // may belong to a composer a mid-start resize already disposed. Listening
    // here means whichever composer is mounted reports it.
    ref.listen(newSessionStartAbortProvider, (_, next) {
      if (next != null) _reportAbort();
    });
    // Flipping the prompt to readOnly closes the platform input connection on
    // a touch platform (EditableText._shouldCreateInputConnection), so the soft
    // keyboard collapses when the start begins and — because nothing dropped
    // focus — springs back up the moment the field is writable again, over a
    // form the user was not typing in and over the snackbar explaining why the
    // start ended. Dropping focus makes the close deliberate and one-way; the
    // user taps back in to retry. Desktop keeps focus, where Enter-to-start is
    // the retry.
    ref.listen(newSessionStartInFlightProvider, (previous, next) {
      if (next && previous != true && isMobilePlatform) _promptFocus.unfocus();
      // Re-run the snap the start suppressed. A detection that resolved
      // mid-start was dropped, not queued, and nothing re-delivers it: the
      // provider only re-emits on a control-plane push, which a start against a
      // LOCAL target never makes — so without this the form stays parked on an
      // agent the machine does not have.
      if (!next && previous == true) _snapToInstalledAgent();
    });

    final agent = ref.watch(newSessionAgentProvider);
    final customCmd = ref.watch(newSessionCustomCmdProvider);
    final hasValidTarget = ref.watch(newSessionHasValidTargetProvider);
    final isCustom = agent == const CustomAgent();
    // Derived bool, not the raw chat-capable future: that future re-emits a
    // fresh Set on every control-plane heartbeat, and watching it here would
    // rebuild the whole composer subtree each time. The provider only notifies
    // when the resolved value flips.
    final supportsChat = ref.watch(newSessionSupportsChatProvider);
    final isolated = ref.watch(newSessionIsolatedProvider);
    final isolationReady = ref.watch(newSessionIsolationReadyProvider);
    // The in-flight start, watched rather than held in this State: the New
    // Session screen builds a different tree either side of the compact
    // breakpoint, so a resize mid-start disposes this widget — and a local
    // flag would unlock the form while the start it was guarding ran on.
    final progress = ref.watch(newSessionStartProgressProvider);
    final starting = progress != null;
    // Reactive form of `_canStart`, built from the values already watched
    // above so the button reacts to every one of them; both go through
    // [newSessionCanStart] so the watch and read paths stay in lockstep.
    final canSend = newSessionCanStart(
      starting: starting,
      hasValidTarget: hasValidTarget,
      isCustom: isCustom,
      customCmd: customCmd,
      isolated: isolated,
      isolationReady: isolationReady,
    );

    final p = context.antgrid;
    // One "armed instrument" surface: context chips, prompt, and controls
    // share a single bordered box whose border tracks the interaction state
    // (default → strong on hover → accent while the prompt has focus), the
    // same focus contract as the transcript's RichComposer.
    final borderColor = _promptFocused
        ? p.accent
        : _hovered
        ? p.borderStrong
        : p.borderDefault;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AbTokens.motionDefault,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: AbTokens.borderRadius8,
          color: p.bgSurface,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Context row: where the session will run. Docked inside the
            // surface so environment/project read as part of the command,
            // not as detached chrome floating above it.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space10,
                AbTokens.space10,
                AbTokens.space10,
                0,
              ),
              // One line, always. The row is the session's target stated as a
              // sentence, and a sentence that folds reads as two unrelated
              // fragments. Every label here is data with an unbounded
              // intrinsic width (a machine name carries a device-uuid suffix,
              // a branch carries `Base: ` plus a generated name), so the row
              // has to decide what gives:
              //   - the branch takes the slack and ellipsizes, because it is
              //     the one that is long in practice and the one that stays
              //     legible truncated;
              //   - machine and project are capped at a fraction of the row so
              //     a pathological label cannot crowd the branch out, but stay
              //     intrinsic below that cap so the branch keeps the TRUE
              //     remainder — flexing all three instead would strand each
              //     one's unused share and truncate the branch early;
              //   - the isolation chip keeps its word until keeping it would
              //     starve the branch, then falls back to its state glyph: the
              //     word is a constant the tooltip repeats, the branch name
              //     isn't.
              child: LayoutBuilder(
                builder: (context, rowConstraints) {
                  const gaps = AbTokens.space6 * 3;
                  // Guards against Infinity - Infinity = NaN below: the only
                  // production ancestor bounds this row (see
                  // new_session_content.dart's ConstrainedBox), but an
                  // unbounded one must degrade the chips to their narrowest
                  // state rather than poison every constraint downstream.
                  final row = rowConstraints.maxWidth.isFinite
                      ? rowConstraints.maxWidth
                      : 0.0;
                  // The cap is a fraction of the row, but never more than what
                  // is left once the branch holds its floor and the isolation
                  // chip its glyph. The fraction alone is not enough: on a
                  // phone two long labels claiming it left the branch a
                  // remainder below its own chrome, which renders as an
                  // overflow, not as a truncation.
                  final cap = math.max(
                    0.0,
                    math.min(
                      row * _chipLabelCapFraction,
                      (row -
                              gaps -
                              kComposerChipGlyphWidth -
                              _branchChipFloor) /
                          2,
                    ),
                  );
                  // Whatever the caps left above the branch's floor: enough for
                  // the isolation chip's word, or it falls back to its glyph.
                  final isolationChipMax = math.max(
                    0.0,
                    row - gaps - cap * 2 - _branchChipFloor,
                  );
                  final capBox = BoxConstraints(maxWidth: cap);
                  return Row(
                    children: [
                      ConstrainedBox(
                        constraints: capBox,
                        child: EnvironmentChip(enabled: !starting),
                      ),
                      const SizedBox(width: AbTokens.space6),
                      ConstrainedBox(
                        constraints: capBox,
                        child: ProjectChip(
                          onOpenFolder: widget.onOpenFolder,
                          enabled: !starting,
                        ),
                      ),
                      const SizedBox(width: AbTokens.space6),
                      Flexible(child: BranchChip(enabled: !starting)),
                      const SizedBox(width: AbTokens.space6),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: isolationChipMax),
                        child: _IsolationChip(enabled: !starting),
                      ),
                    ],
                  );
                },
              ),
            ),
            // Advisory about the branch named on the row above. Sits between
            // the two because it explains that row, not the prompt; it is
            // absent (zero height) in every state but a stale base.
            const BranchRemoteAdvisory(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space12,
                AbTokens.space12,
                AbTokens.space12,
                AbTokens.space6,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Shell-prompt marker: the terminal-native "type here"
                  // affordance. Accent while live, dimmed with the field.
                  Padding(
                    padding: const EdgeInsets.only(top: AbTokens.space2),
                    child: Text(
                      '❯',
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontMd,
                        fontWeight: FontWeight.w600,
                        color: isCustom ? p.textDisabled : p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  Expanded(
                    // Cap growth like RichComposer (~8 lines) so a long
                    // prompt scrolls internally instead of squeezing the
                    // recents list above.
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 176),
                      child: _PromptField(
                        controller: _prompt,
                        focusNode: _promptFocus,
                        enabled: !isCustom,
                        readOnly: starting,
                        hintText: isCustom
                            ? 'Starts a terminal session — set the command in ⚙'
                            : 'Describe a task or ask a question',
                        onChanged: (v) =>
                            ref.read(newSessionPromptProvider.notifier).set(v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space10,
                0,
                AbTokens.space10,
                AbTokens.space10,
              ),
              child: LayoutBuilder(
                builder: (context, rowConstraints) {
                  // Tight rows (phones, narrow desktop panes) degrade before
                  // overflowing: the agent selector's slot takes the row slack
                  // so its label ellipsizes (see _composerRowRoomyMinWidth).
                  final roomy =
                      rowConstraints.maxWidth >= _composerRowRoomyMinWidth;
                  // The Enter hint is desktop-only (a soft keyboard has no
                  // meaningful Enter-to-send) but the phase line is not: a
                  // cold remote start is a 30s wait, and a phone is where it
                  // is most often watched. So the slot is present whenever
                  // either of the two has something to say.
                  final showTrailingSlot =
                      starting || (roomy && !isMobilePlatform);
                  return Row(
                    children: [
                      _ModeSelector(
                        supportsChat: supportsChat,
                        enabled: !starting,
                      ),
                      const SizedBox(width: AbTokens.space8),
                      Builder(
                        builder: (gearContext) => AbIconButton(
                          key: const Key('new-session-gear-button'),
                          icon: AbIcons.settings,
                          onTap: starting ? null : () => _openGear(gearContext),
                        ),
                      ),
                      if (showTrailingSlot) ...[
                        // The slot fades on READINESS (focus, canSend) so the
                        // row doesn't reflow; the hint-to-phase swap inside it
                        // is a hard cut, because AbCrossFade animates one
                        // child's opacity and not a change of child (which is
                        // also why the fade below is re-keyed per child). It
                        // lives in the row's slack (not after a Spacer) so a
                        // narrow pane drops its content instead of overflowing
                        // — the invisible slot still occupies layout space.
                        Expanded(
                          flex: starting ? _statusSlotFlex : 1,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              if (constraints.maxWidth <
                                  (starting
                                      ? _statusLineMinWidth
                                      : _enterHintMinWidth)) {
                                return const SizedBox.shrink();
                              }
                              return Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    right: AbTokens.space12,
                                  ),
                                  child: AbCrossFade(
                                    // Re-keyed on WHICH of the two the slot
                                    // holds. AbCrossFade fades one child, so
                                    // without this the swap and the visibility
                                    // change land on the same frame and it is
                                    // the newly-substituted child that plays
                                    // the other one's animation: a start ending
                                    // with the prompt unfocused faded the Enter
                                    // hint out, text the user never had. A new
                                    // key mounts a fresh tween already settled
                                    // at its target, so each child appears and
                                    // leaves on its own terms. The trade is
                                    // that the status line now appears at once
                                    // rather than fading in — the better half
                                    // of it, on the frame Send was pressed.
                                    key: ValueKey(progress == null),
                                    duration: AbTokens.motionDefault,
                                    visible:
                                        starting || (_promptFocused && canSend),
                                    child: progress == null
                                        ? Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const AbKbd('⏎'),
                                              const SizedBox(
                                                width: AbTokens.space6,
                                              ),
                                              Text(
                                                'to start',
                                                style: AbTokens.sansStyle(
                                                  fontSize: AbTokens.fontXs,
                                                  color: p.textMuted,
                                                ),
                                              ),
                                            ],
                                          )
                                        : Row(
                                            key: const Key(
                                              'new-session-status-line',
                                            ),
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              AbLoadingDot(
                                                size: AbTokens.dotSizeMd,
                                                color: p.textMuted,
                                              ),
                                              const SizedBox(
                                                width: AbTokens.space6,
                                              ),
                                              Flexible(
                                                child: Text(
                                                  phaseLabel(progress),
                                                  maxLines: 1,
                                                  softWrap: false,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: AbTokens.sansStyle(
                                                    fontSize: AbTokens.fontXs,
                                                    color: p.textSecondary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (starting)
                          // A bounded slot rather than an intrinsic child: the
                          // status line took the larger share, and the selector
                          // has to be able to shed its label to its glyph
                          // rather than push the row into an overflow. Expanded
                          // + Align, not a loose Flexible — a Flexible the chip
                          // underfills leaves its slack AFTER the last child,
                          // unpinning the send key from the row's right edge.
                          const Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: _AgentSelector(enabled: false),
                            ),
                          )
                        else
                          const _AgentSelector(),
                      ] else
                        // No trailing slot: hand the slack to the selector so
                        // a long agent label ellipsizes inside it
                        // (ComposerChip needs a bounded width) instead of
                        // overflowing.
                        const Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _AgentSelector(),
                          ),
                        ),
                      const SizedBox(width: AbTokens.space8),
                      // Stop is the same key in the same slot, so the send
                      // affordance keeps its test key across both; the outer
                      // key is what tells the two variants apart. Both carry a
                      // label: one glyph in one position means start or cancel
                      // depending on state, and ComposerSendButton paints no
                      // text to tell a screen reader or a hover which it is.
                      if (progress != null && progress.isCancellable)
                        KeyedSubtree(
                          key: const Key('new-session-stop-button'),
                          child: Semantics(
                            button: true,
                            label: 'Stop starting session',
                            child: AbTooltip(
                              message: 'Stop starting session',
                              child: ComposerSendButton(
                                key: const Key('new-session-send-button'),
                                icon: AbIcons.stop,
                                color: p.error,
                                onTap: () => ref
                                    .read(
                                      newSessionStartProgressProvider.notifier,
                                    )
                                    .requestCancel(),
                              ),
                            ),
                          ),
                        )
                      else
                        Semantics(
                          button: true,
                          enabled: canSend,
                          label: 'Start session',
                          child: ComposerSendButton(
                            key: const Key('new-session-send-button'),
                            busy: starting,
                            onTap: canSend ? _submit : null,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGear(BuildContext gearContext) async {
    final anchor = abMenuAnchorRect(gearContext);
    if (anchor == null) return;
    await showAbPanel<void>(
      context: gearContext,
      anchorRect: anchor,
      // The composer sits at the bottom of the screen, so the popover
      // should open upward toward the visible content.
      preferred: AbMenuPlacement.above,
      builder: (_) => const _GearPopoverContent(),
    );
  }
}

/// Multiline prompt input styled with the same tokened chrome as
/// [AbTextField] (which is single-line only, hence a bare field here).
/// `maxLines: null` grows with content; Enter/Shift+Enter handling lives on
/// the caller-owned [focusNode] ([_NewSessionComposerState._onPromptKeyEvent]).
class _PromptField extends StatelessWidget {
  const _PromptField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.readOnly,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;

  /// Frozen but undimmed, unlike [enabled]: a prompt already on the wire is
  /// still the thing the user is waiting on, so it has to stay readable — and
  /// "busy" must not look like the custom-agent "this field is not yours".
  final bool readOnly;

  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      key: const Key('new-session-prompt-field'),
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      readOnly: readOnly,
      // A caret blinking in a field that cannot take the keystroke invites
      // exactly the edit this lock exists to refuse.
      showCursor: !readOnly,
      maxLines: null,
      minLines: 3,
      onChanged: onChanged,
      style: AbTokens.sansStyle(color: context.antgrid.textPrimary),
      cursorColor: context.antgrid.accent,
      decoration: InputDecoration(
        isCollapsed: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        hintText: hintText,
        hintStyle: AbTokens.sansStyle(color: context.antgrid.textMuted),
        contentPadding: EdgeInsets.zero,
      ),
    );
    // Disabled-state contract: opacity 0.4, no interaction.
    if (!enabled) {
      return IgnorePointer(child: Opacity(opacity: 0.4, child: field));
    }
    return field;
  }
}

/// Isolation opt-in, as the last term of the context row's sentence:
/// `Local · my-repo · main · isolated`.
///
/// Last on purpose — it modifies the chip before it. Switching it on re-labels
/// the branch chip to `Base: main`, which is the entire explanation of what
/// isolation does to the current selection, delivered by the row itself.
///
/// Labelled for the OUTCOME the user is choosing, not for the git mechanism
/// that currently delivers it: the same switch is what a second isolation
/// backend would ride in on, and a user who picked "worktree" could not be told
/// afterwards that they had picked something else.
class _IsolationChip extends ConsumerWidget {
  const _IsolationChip({this.enabled = true});

  /// See [ComposerChip.enabled] — handed down by the composer rather than read
  /// from the start model here, so one owner decides when the row is frozen.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same gate as [BranchChip]: with no project chosen the Git-shaped chips
    // have nothing to describe, and a dead one beside "Select project…" is
    // noise rather than discovery.
    if (ref.watch(selectedTargetProjectProvider) == null) {
      return const SizedBox.shrink();
    }

    final catalog = ref.watch(newSessionBranchCatalogProvider);
    final ready = ref.watch(newSessionIsolationReadyProvider);

    return ComposerToggleChip(
      // The key addresses the isolation toggle, not the word printed on it.
      key: const Key('new-session-worktree-chip'),
      label: 'isolated',
      value: ref.watch(newSessionIsolatedProvider),
      // The frozen arm comes FIRST: a chip dead only because a start is
      // running must not blame the project's Git or the machine's bridge, and
      // must not send the reader off to update anything.
      tooltip: !enabled
          ? 'Locked while the session starts'
          : ready
          ? 'Give this session its own branch and workspace, separate from '
                'your main tree'
          : catalog.isLoading
          ? 'Checking this project…'
          : catalog.value?.isRepository == false
          ? 'Requires a Git repository'
          // Two causes collapse into this one false: the build-time
          // WORKTREE_SESSIONS_SUPPORTED kill switch, which updating cannot
          // clear, and a bridge predating the capability field, which updating
          // is the only fix for (GitBranchCatalog reads it by exclusion). So it
          // may neither promise an update works nor read as permanent.
          : 'This machine can\'t create isolated sessions — check that its '
                'Antgrid is up to date',
      onChanged: enabled && ready
          ? (next) => ref.read(newSessionIsolatedProvider.notifier).set(next)
          : null,
    );
  }
}

/// Session-mode dropdown ([ Terminal v ]) — Terminal is the default for every
/// agent and Chat is opened into deliberately, so the control shows the current
/// mode and hides the alternative behind a tap rather than presenting both as
/// equals (the in-session switch keeps `ModeSegmented`).
///
/// "This agent can't do chat" is still said in place: the Chat row renders
/// greyed WITH its reason instead of vanishing, so a missing option and an
/// unsupported one never look alike.
class _ModeSelector extends ConsumerWidget {
  const _ModeSelector({required this.supportsChat, this.enabled = true});

  /// Null when neither the target machine nor the persisted catalog has
  /// described the selected agent — a third state, not a `false`.
  final bool? supportsChat;

  /// See [ComposerChip.enabled].
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(newSessionModeProvider);
    final agent = ref.watch(newSessionAgentProvider);
    final label = newSessionAgentLabel(
      agent,
      ref.watch(newSessionDetectedToolsProvider).value,
      ref.watch(agentCatalogProvider),
    );
    final chatEnabled = supportsChat == true;
    // Pin the DISPLAYED selection to Terminal whenever chat isn't supported,
    // rather than trusting `mode` to already carry 'terminal' — detection
    // (newSessionChatCapableToolsProvider) can resolve a frame after the
    // agent-default heuristic runs, so `mode` briefly lags the true support
    // state. The provider itself still gets corrected by the agent listener.
    final displayMode = chatEnabled ? mode : 'terminal';
    final isChat = displayMode == 'chat';
    // Longer than the mid-session toggle's "Not supported": at create time the
    // agent is still being chosen, so the string has to name it. An unanswered
    // capability says so instead of blaming the agent — and it names both ways
    // it can be unanswered, because the same null covers the ordinary wait for
    // a target's first advert and a bridge too old to send one, and only the
    // second is the user's to fix.
    final chatDisabledReason = supportsChat == null
        ? "This machine hasn't said whether $label supports chat sessions — "
              'it may still be connecting, or its bridge may be too old to '
              'answer'
        : "$label doesn't support chat sessions";

    return _ModeChip(
      key: const Key('new-session-mode-chip'),
      icon: isChat ? AbIcons.comment : AbIcons.terminal,
      label: isChat ? 'Chat' : 'Terminal',
      alpha: isChat,
      enabled: enabled,
      onTap: (ctx) async {
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        final picked = await showAbMenu<String>(
          context: ctx,
          preferred: AbMenuPlacement.above,
          anchorRect: anchor,
          bounds: MenuBoundsScope.maybeOf(ctx),
          width: 220,
          entries: [
            AbMenuItem(
              key: const Key('new-session-mode-terminal'),
              label: 'Terminal',
              value: 'terminal',
              icon: displayMode == 'terminal' ? AbIcons.check : null,
            ),
            AbMenuItem(
              key: const Key('new-session-mode-chat'),
              label: 'Chat',
              value: 'chat',
              icon: displayMode == 'chat' ? AbIcons.check : null,
              badge: 'Alpha',
              badgeColor: context.antgrid.warning,
              enabled: chatEnabled,
              disabledReason: chatEnabled ? null : chatDisabledReason,
            ),
          ],
        );
        if (picked == null || picked == displayMode) return;
        ref.read(newSessionModeProvider.notifier).set(picked);
      },
    );
  }
}

/// Trigger for [_ModeSelector]: [ComposerChip]'s chrome at an intrinsic width.
///
/// Not [ComposerChip] itself — that one ellipsizes inside a bounded flex slot,
/// and this chip sits as a bare Row child whose two labels ('Chat',
/// 'Terminal') are fixed strings that never need shedding.
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    super.key,
    required this.icon,
    required this.label,
    required this.alpha,
    required this.onTap,
    this.enabled = true,
  });

  final String icon;
  final String label;

  /// Carry the ALPHA marker on the trigger too, not only on the menu row: once
  /// the menu is closed the chip is the only thing still saying which mode the
  /// session will start in.
  final bool alpha;

  final void Function(BuildContext anchorContext) onTap;

  /// See [ComposerChip.enabled] — same treatment, so the composer's two chip
  /// shapes cannot grow two dialects of "dead".
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Builder(
        builder: (ctx) {
          final p = ctx.antgrid;
          final fg = enabled ? p.textPrimary : p.textDisabled;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Stays live while disabled so the chip keeps swallowing taps
            // rather than letting them reach the row beneath it.
            onTap: () {
              if (!enabled) return;
              onTap(ctx);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space8,
                vertical: AbTokens.space4,
              ),
              decoration: BoxDecoration(
                border: Border.all(
                  color: enabled ? p.borderDefault : p.borderSubtle,
                ),
                borderRadius: AbTokens.borderRadius3,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AbIcon(icon, size: 12, color: fg),
                  const SizedBox(width: AbTokens.space6),
                  Text(
                    label,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontSm,
                      color: fg,
                    ),
                  ),
                  if (alpha) ...[
                    const SizedBox(width: AbTokens.space6),
                    AbChip.system(label: 'Alpha', color: p.warning),
                  ],
                  const SizedBox(width: AbTokens.space6),
                  AbIcon(
                    AbIcons.chevronDown,
                    size: 10,
                    color: enabled ? p.textMuted : p.textDisabled,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Bottom-right agent-selector trigger — chip-styled port of
/// `session_config.dart`'s `_AgentDropdown` (an `AbControlBox` trigger there;
/// a [ComposerChip] here to match the environment/project chips it sits
/// beside).
class _AgentSelector extends ConsumerWidget {
  const _AgentSelector({this.enabled = true});

  /// See [ComposerChip.enabled].
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(newSessionAgentProvider);
    final detected =
        ref.watch(newSessionDetectedToolsProvider).value ??
        const <String, String?>{};
    final catalog = ref.watch(agentCatalogProvider);
    final options = _buildAgentOptions(detected, catalog, agent);

    return ComposerChip(
      key: const Key('new-session-agent-selector'),
      icon: AbIcons.terminal,
      label: newSessionAgentLabel(agent, detected, catalog),
      enabled: enabled,
      onTap: (ctx) async {
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        final picked = await showAbMenu<NewSessionAgent>(
          context: ctx,
          preferred: AbMenuPlacement.above,
          anchorRect: anchor,
          bounds: MenuBoundsScope.maybeOf(ctx),
          entries: [
            for (final a in options)
              AbMenuItem(
                label: newSessionAgentLabel(a, detected, catalog),
                value: a,
                icon: a == agent ? AbIcons.check : null,
              ),
          ],
        );
        if (picked != null) {
          ref.read(newSessionAgentProvider.notifier).set(picked);
          ref.read(newSessionAgentTouchedProvider.notifier).set(true);
        }
      },
    );
  }
}

/// Build the agent menu's options from the tools detected on the target.
///
/// The options ARE the advertised tools, in the bridge's order — an agent this
/// app predates still appears, which the app-side enum this replaced could not
/// do. When [detected] is empty (detection still in flight, target not focused,
/// or an older agent without the handler) the persisted [catalog] stands in, so
/// the menu still lists the agents some bridge has described rather than a set
/// this app shipped guessing at. `Custom` is always last, and the current
/// [selected] agent is always included so the trigger never renders a hidden
/// option — which is also what keeps the menu non-empty on a cold install with
/// no catalog yet.
List<NewSessionAgent> _buildAgentOptions(
  Map<String, String?> detected,
  Map<String, AgentDescriptor> catalog,
  NewSessionAgent selected,
) {
  final keys = detected.isNotEmpty ? detected.keys : catalog.keys;
  final options = <NewSessionAgent>[
    for (final key in keys) KnownAgent(key),
    const CustomAgent(),
  ];
  if (!options.contains(selected)) return [selected, ...options];
  return options;
}

/// Gear popover content: session name, CLI args, and (custom agent only) the
/// custom command field. Owns its own controllers, syncing exactly like the
/// old `_SessionConfigState` did — guarded on inequality so user typing
/// (which writes the same value back via `onChanged`) doesn't reset the
/// cursor.
class _GearPopoverContent extends ConsumerStatefulWidget {
  const _GearPopoverContent();

  @override
  ConsumerState<_GearPopoverContent> createState() =>
      _GearPopoverContentState();
}

class _GearPopoverContentState extends ConsumerState<_GearPopoverContent> {
  late final TextEditingController _name;
  late final TextEditingController _cliArgs;
  late final TextEditingController _customCmd;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: ref.read(newSessionNameProvider));
    _cliArgs = TextEditingController(text: ref.read(newSessionCliArgsProvider));
    _customCmd = TextEditingController(
      text: ref.read(newSessionCustomCmdProvider),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _cliArgs.dispose();
    _customCmd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(newSessionNameProvider, (_, next) {
      if (_name.text != next) _name.text = next;
    });
    ref.listen(newSessionCliArgsProvider, (_, next) {
      if (_cliArgs.text != next) _cliArgs.text = next;
    });
    ref.listen(newSessionCustomCmdProvider, (_, next) {
      if (_customCmd.text != next) _customCmd.text = next;
    });

    final agent = ref.watch(newSessionAgentProvider);
    final bypassDescriptor = ref.watch(newSessionBypassSupportProvider);
    final bypass = ref.watch(newSessionApprovalPolicyProvider) == 'bypass';

    // `showAbPanel` inserts this content into the app's Overlay, above (not
    // inside) the page's Scaffold — so the AbTextFields below need their own
    // Material ancestor (transparency-only; the popup surface itself is the
    // AbMenu chrome the route already draws behind this builder).
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PanelSectionHeader('Session settings'),
          const _GearFieldLabel('Session name'),
          const SizedBox(height: AbTokens.space6),
          AbTextField(
            key: const Key('new-session-gear-name'),
            controller: _name,
            hintText: 'untitled session',
            onChanged: (v) => ref.read(newSessionNameProvider.notifier).set(v),
          ),
          const SizedBox(height: AbTokens.space12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _GearFieldLabel('YOLO / Skip approvals'),
                    Text(
                      bypassDescriptor == null
                          ? 'Not supported for this agent and mode'
                          : 'Launch this session without approval prompts',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: context.antgrid.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              AbSwitch(
                key: const Key('new-session-gear-yolo'),
                value: bypass && bypassDescriptor != null,
                semanticLabel: 'YOLO / Skip approvals',
                onChanged: bypassDescriptor == null
                    ? null
                    : (next) {
                        if (!next) {
                          ref
                              .read(newSessionApprovalPolicyProvider.notifier)
                              .set('default');
                          return;
                        }
                        detached('new-session', 'confirm YOLO mode', () async {
                          final disablesSandbox =
                              bypassDescriptor.approvalPolicyRisk ==
                              'bypasses-approvals-and-sandbox';
                          final confirmed = await AbConfirmDialog.show(
                            context: context,
                            title: 'Enable YOLO mode?',
                            body: disablesSandbox
                                ? 'This agent will bypass approval prompts and disable sandboxing for this session.'
                                : 'This agent will bypass approval prompts for this session.',
                            confirmLabel: 'Enable YOLO',
                            destructive: true,
                          );
                          if (confirmed && mounted) {
                            ref
                                .read(newSessionApprovalPolicyProvider.notifier)
                                .set('bypass');
                          }
                        });
                      },
              ),
            ],
          ),
          const SizedBox(height: AbTokens.space12),
          const _GearFieldLabel('CLI arguments'),
          const SizedBox(height: AbTokens.space6),
          AbTextField(
            key: const Key('new-session-gear-cli-args'),
            controller: _cliArgs,
            hintText: '--flag value',
            onChanged: (v) =>
                ref.read(newSessionCliArgsProvider.notifier).set(v),
          ),
          if (agent == const CustomAgent()) ...[
            const SizedBox(height: AbTokens.space12),
            const _GearFieldLabel('Custom command'),
            const SizedBox(height: AbTokens.space6),
            AbTextField(
              key: const Key('new-session-gear-custom-cmd'),
              controller: _customCmd,
              hintText: 'e.g. my-agent --serve',
              onChanged: (v) =>
                  ref.read(newSessionCustomCmdProvider.notifier).set(v),
            ),
          ],
        ],
      ),
    );
  }
}

/// A sans-style field label, matching `session_config.dart`'s `_FieldLabel`.
class _GearFieldLabel extends StatelessWidget {
  const _GearFieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        color: context.antgrid.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
