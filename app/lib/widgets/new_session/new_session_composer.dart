import 'dart:async';
import 'dart:math' as math;

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_agent_mark.dart';
import '../../design/widgets/ab_toast.dart';
import '../../launcher/host_control_client.dart' show HostControlException;
import '../../models/agent_descriptor.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/new_session_action.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/new_session_start.dart';
import '../../services/sessions_service.dart' show SessionOperationException;
import '../../utils/platform_utils.dart';
import '../../util/ab_log.dart';
import '../../util/detached.dart';
import '../ab_status_helpers.dart'
    show agentsCheckingCopy, agentsUnlistedCopy, sessionRefusalCopy;
import '../carbon_confirm.dart';
import 'branch_menu.dart';
import 'branch_remote_advisory.dart';
import 'context_picker.dart';
import 'environment_menu.dart';
import 'picker_sources.dart';
import 'project_menu.dart';

typedef StartNewSessionCallback =
    Future<void> Function(
      ProviderContainer ref, {
      bool allowActiveSessions,
    });

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
  NewSessionStartAbortReason.sessionDown =>
    'The connection to the machine dropped while starting. Check that '
        "project's sessions before starting another one.",
};

/// Minimum row slack (hint intrinsic width + trailing gap, with margin)
/// before the Enter-to-start hint is worth rendering at all.
const double _enterHintMinWidth = 96;

/// The same floor for the phase status line, set lower because the two are not
/// worth the same: the hint restates a shortcut, while the phase copy is the
/// only account of a wait that can run 30s. An ellipsized stage name beats no
/// stage name, so this only has to leave room for the dot and a few characters.
const double _statusLineMinWidth = 44;

/// Row width below which the controls degrade. On the bottom row the agent
/// selector's slot absorbs the row slack (ellipsizing its label) instead of
/// the desktop Enter-hint slot, and the mode trigger drops to its glyph; the
/// agent label never drops. On touch the context row scrolls below it.
///
const double _composerRowRoomyMinWidth = 460;

/// Row width from which the send key carries its "Start" label. The label
/// needs a label's width more than the controls alone, so it has its own
/// threshold instead of raising [_composerRowRoomyMinWidth] for everything.
const double _composerRowLabelledSendMinWidth = 540;

/// Flex the phase status line claims while a start runs, against the agent
/// selector's 1. A phone's bottom row cannot seat both at their intrinsic
/// widths, and a locked selector is the one of the two with nothing left to
/// say — it gives up its slot, rather than pushing the phase off the line.
const int _statusSlotFlex = 3;

/// Share of the context row a single picker label may claim before it starts
/// ellipsizing. Two of them cap out together at well under the full row, which
/// is what keeps the isolation checkbox and a readable stub of the branch on
/// the line no matter how pathological the machine and project names get.
const double _chipLabelCapFraction = 0.3;

/// Inset of the context and control rows. Ghost triggers carry their own
/// spacing05 padding, so their glyphs land on [_textInset].
const double _rowInset = CarbonSpacing.spacing03;

/// Inset of the prompt and the branch advisory: the column the row triggers'
/// glyphs sit on.
const double _textInset = CarbonSpacing.spacing03 + CarbonSpacing.spacing05;

/// Lines the prompt grows to before it scrolls internally.
const int _promptMaxLines = 7;

/// Bottom-anchored composer for the New Session canvas.
///
/// Assembles the context row ([EnvironmentChip], [ProjectChip], [BranchChip],
/// isolation), a multiline prompt, and the bottom control row (mode, Session
/// settings, agent selector, send button). Also owns the form listeners (target -> seed agent,
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
  /// The pointer now pressing Send, if any.
  int? _sendPointer;

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
          final confirm = await showCarbonConfirm(
            context,
            title: 'Switch branch?',
            body:
                'One or more sessions in this folder are working or need you. Switching to "${e.branch}" changes the working tree for all of them.',
            confirmLabel: 'Switch & start',
          );
          if (!confirm || !mounted) return;

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
    } on SessionOperationException catch (e) {
      // The bridge's create/start refusal is already user-facing text and the
      // coded arms replace it where its wording names something the reader
      // can't act on; either beats the raw exception the generic arm prints.
      // No navigation — the user stays here with the form intact.
      if (mounted && !_endedByCancel) {
        showAbToast(
          context,
          sessionRefusalCopy(
            e.errorCode,
            e.message,
            'Could not start the session.',
          ),
          duration: const Duration(seconds: 8),
        );
      }
    } on HostControlException catch (e) {
      // A local branch checkout's refusal (e.g. DIRTY_WORKTREE — uncommitted
      // changes the switch would overwrite) is already user-facing text from
      // the bridge, naming the files in the way; showing `e.toString()`
      // instead would print the exception's type and code as if they were
      // part of the sentence.
      if (mounted && !_endedByCancel) {
        showAbToast(
          context,
          sessionRefusalCopy(e.code, e.message, 'Could not switch branch.'),
          duration: const Duration(seconds: 8),
        );
      }
    } on RpcException catch (e) {
      // Same refusal, over the remote control plane.
      if (mounted && !_endedByCancel) {
        showAbToast(
          context,
          sessionRefusalCopy(e.code, e.message, 'Could not switch branch.'),
          duration: const Duration(seconds: 8),
        );
      }
    } catch (e, stack) {
      // A start the user stopped reports the cancel and nothing else: the
      // failure it raced is not an outcome they asked about.
      if (mounted && !_endedByCancel) {
        AbLog.error(
          'NewSessionComposer',
          'session start failed',
          fields: {'error': '$e', 'stack': '$stack'},
        );
        showAbToast(
          context,
          'Couldn’t start the session. Check the selected agent and try again.',
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
    showAbToast(
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

    final t = CarbonTheme.of(context);
    final c = t.colors;
    // One "armed instrument" surface: context row, prompt and controls share a
    // single frame around a chromeless editable, and the frame — not the
    // editable — carries the state: subtle at rest, strong on hover, Carbon's
    // 2px focus colour while the prompt has focus. Painted in the foreground
    // so the thicker focus edge never shifts the content inside it.
    final frameColor = _promptFocused
        ? c.focus
        : _hovered
        ? t.borderStrong(1)
        : t.borderSubtle(1);
    final frameWidth = _promptFocused
        ? CarbonBorders.focus
        : CarbonBorders.hairline;
    const gap = SizedBox(width: CarbonSpacing.spacing03);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        color: t.layer(1),
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: frameColor, width: frameWidth),
        ),
        // The frame is a layer-1 surface, so what sits on it is one layer up.
        child: CarbonLayer(
          level: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Context row: where the session will run. Docked inside the
              // surface so environment/project read as part of the command,
              // not as detached chrome floating above it.
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  _rowInset,
                  _rowInset,
                  _rowInset,
                  0,
                ),
                // One line, always. The row is the session's target stated as
                // a sentence, and a sentence that folds reads as two unrelated
                // fragments. Every label here is data with an unbounded
                // intrinsic width (a machine name carries a device-uuid
                // suffix, a branch carries `Base: ` plus a generated name), so
                // the row has to decide what gives:
                //   - the branch takes the slack and ellipsizes, because it is
                //     the one that is long in practice and the one that stays
                //     legible truncated;
                //   - machine and project are capped at a fraction of the row
                //     so a pathological label cannot crowd the branch out, but
                //     stay intrinsic below that cap so the branch keeps the
                //     TRUE remainder — flexing all three instead would strand
                //     each one's unused share and truncate the branch early;
                //   - the isolation checkbox keeps its word until keeping it
                //     would starve the branch, then shows only its box: the
                //     word is a constant the tooltip repeats, the branch name
                //     isn't.
                // A phone cannot seat four touch-sized triggers with readable
                // labels at all, so there the line scrolls instead of
                // truncating every label to a letter.
                child: LayoutBuilder(
                  builder: (context, rowConstraints) {
                    // Guards against Infinity - Infinity = NaN below: the only
                    // production ancestor bounds this row (see
                    // new_session_content.dart's ConstrainedBox), but an
                    // unbounded one must degrade the pickers to their
                    // narrowest state rather than poison every constraint
                    // downstream.
                    final row = rowConstraints.maxWidth.isFinite
                        ? rowConstraints.maxWidth
                        : 0.0;
                    final environment = EnvironmentChip(enabled: !starting);
                    final project = ProjectChip(
                      onOpenFolder: widget.onOpenFolder,
                      enabled: !starting,
                    );
                    final branch = BranchChip(enabled: !starting);
                    final isolation = _IsolationChip(enabled: !starting);
                    if (t.isTouch && row < _composerRowRoomyMinWidth) {
                      // Unbounded inside the scroller, each picker caps its
                      // own label.
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            environment,
                            gap,
                            project,
                            gap,
                            branch,
                            gap,
                            isolation,
                          ],
                        ),
                      );
                    }
                    const gaps = CarbonSpacing.spacing03 * 3;
                    // Room the branch is guaranteed: a readable stub of the
                    // ref. A fraction-only cap can leave a remainder below the
                    // field's own chrome — which is a render overflow, not a
                    // truncation.
                    final branchFloor = contextPickerFullMinWidth(t);
                    // The cap is a fraction of the row, but never more than
                    // what is left once the branch holds its floor and the
                    // isolation checkbox its box. The fraction alone is not
                    // enough: two long labels claiming it left the branch a
                    // remainder below its own chrome.
                    final cap = math.max(
                      0.0,
                      math.min(
                        row * _chipLabelCapFraction,
                        (row - gaps - contextPickerGlyphWidth(t) - branchFloor) /
                            2,
                      ),
                    );
                    // Whatever the caps left above the branch's floor: enough
                    // for the isolation word, or it falls back to its box.
                    final isolationMax = math.max(
                      0.0,
                      row - gaps - cap * 2 - branchFloor,
                    );
                    final capBox = BoxConstraints(maxWidth: cap);
                    return Row(
                      children: [
                        ConstrainedBox(constraints: capBox, child: environment),
                        gap,
                        ConstrainedBox(constraints: capBox, child: project),
                        gap,
                        Flexible(child: branch),
                        gap,
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: isolationMax),
                          child: isolation,
                        ),
                      ],
                    );
                  },
                ),
              ),
              // Advisory about the branch named on the row above. Sits between
              // the two because it explains that row, not the prompt; it is
              // absent (zero height) in every state but a stale base. Inset to
              // the pickers' glyph column, as the prompt below is.
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: _textInset),
                child: BranchRemoteAdvisory(),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  _textInset,
                  CarbonSpacing.spacing04,
                  _textInset,
                  0,
                ),
                child: CarbonTextInput(
                  key: const Key('new-session-prompt-field'),
                  bare: true,
                  variant: CarbonTextInputVariant.multiline,
                  controller: _prompt,
                  focusNode: _promptFocus,
                  semanticLabel: 'Task prompt',
                  enabled: !isCustom,
                  readOnly: starting,
                  // Grows, then scrolls internally so a long prompt cannot
                  // squeeze the recents list above.
                  minLines: 3,
                  maxLines: _promptMaxLines,
                  placeholder: isCustom
                      ? 'Starts a terminal session — set the command in '
                            'Session settings'
                      : 'Describe a task or ask a question (optional)',
                  prefix: _PromptMarker(
                    focused: _promptFocused,
                    enabled: !isCustom,
                  ),
                  onChanged: (v) =>
                      ref.read(newSessionPromptProvider.notifier).set(v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(_rowInset),
                child: LayoutBuilder(
                  builder: (context, rowConstraints) {
                    // Tight rows (phones, narrow desktop panes) degrade before
                    // overflowing: the mode trigger drops to its glyph and the
                    // agent selector's slot takes the row slack so its label
                    // ellipsizes (see _composerRowRoomyMinWidth).
                    final roomy =
                        rowConstraints.maxWidth >= _composerRowRoomyMinWidth;
                    final labelledSend =
                        rowConstraints.maxWidth >=
                        _composerRowLabelledSendMinWidth;
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
                          glyphOnly: !roomy,
                        ),
                        gap,
                        CarbonButton.iconOnly(
                          key: const Key('new-session-gear-button'),
                          icon: const CarbonIcon(CarbonIcons.settings),
                          semanticLabel: 'Session settings',
                          onPressed: starting ? null : _openSessionSettings,
                        ),
                        if (showTrailingSlot) ...[
                          // The slot fades on READINESS (focus, canSend) so
                          // the row doesn't reflow; the hint-to-phase swap
                          // inside it is a hard cut (see the key below). It
                          // lives in the row's slack (not after a Spacer) so a
                          // narrow pane drops its content instead of
                          // overflowing — the invisible slot still occupies
                          // layout space.
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
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      end: CarbonSpacing.spacing04,
                                    ),
                                    child: KeyedSubtree(
                                      key: const Key(
                                        'new-session-trailing-slot',
                                      ),
                                      child: _SlotFade(
                                        // Re-keyed on WHICH of the two the
                                        // slot holds. The fade animates one
                                        // child, so without this the swap and
                                        // the visibility change land on the
                                        // same frame and it is the newly
                                        // substituted child that plays the
                                        // other one's animation: a start
                                        // ending with the prompt unfocused
                                        // faded the Enter hint out, text the
                                        // user never had. A new key mounts a
                                        // fresh tween already settled at its
                                        // target, so each child appears and
                                        // leaves on its own terms. The trade
                                        // is that the status line appears at
                                        // once rather than fading in — the
                                        // better half of it, on the frame
                                        // Send was pressed.
                                        key: ValueKey(progress == null),
                                        visible:
                                            starting ||
                                            (_promptFocused && canSend),
                                        child: progress == null
                                            ? Text(
                                                'Enter to start',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: t.typography.helper
                                                    .copyWith(
                                                      color: c.textHelper,
                                                    ),
                                              )
                                            : _StatusLine(
                                                label: phaseLabel(progress),
                                              ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          if (starting)
                            // A bounded slot rather than an intrinsic child:
                            // the status line took the larger share. The
                            // locked selector has nothing left to say, so a
                            // slot too narrow for a readable trigger drops it
                            // rather than push the row into an overflow.
                            // Expanded + Align, not a loose Flexible — a
                            // Flexible the trigger underfills leaves its slack
                            // AFTER the last child, unpinning the send key
                            // from the row's right edge.
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, slot) =>
                                    slot.maxWidth <
                                    _agentTriggerFloor(t)
                                    ? const SizedBox.shrink()
                                    : const Align(
                                        alignment:
                                            AlignmentDirectional.centerEnd,
                                        child: _AgentSelector(enabled: false),
                                      ),
                              ),
                            )
                          else
                            // Shares the slack with the hint rather than
                            // sizing to its label: a long agent name in a
                            // pane just past the roomy width overflowed the
                            // row. Aligned to the end so the send key stays
                            // pinned to the row's right edge.
                            const Expanded(
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: _AgentSelector(),
                              ),
                            ),
                        ] else
                          // No trailing slot: hand the slack to the selector
                          // so a long agent label ellipsizes inside it instead
                          // of overflowing.
                          const Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: _AgentSelector(),
                            ),
                          ),
                        gap,
                        // Stop is the same key in the same slot, so the send
                        // affordance keeps its test key across both; the
                        // outer key is what tells the two variants apart.
                        if (progress != null && progress.isCancellable)
                          KeyedSubtree(
                            key: const Key('new-session-stop-button'),
                            child: labelledSend
                                ? CarbonButton(
                                    key: const Key('new-session-send-button'),
                                    label: 'Stop',
                                    kind: CarbonButtonKind.danger,
                                    icon: const CarbonIcon(
                                      CarbonIcons.stopFilled,
                                    ),
                                    semanticLabel: 'Stop starting session',
                                    maxLines: 1,
                                    onPressed: () => ref
                                        .read(
                                          newSessionStartProgressProvider
                                              .notifier,
                                        )
                                        .requestCancel(),
                                  ).reservingWidthOf(stop: false)
                                : CarbonButton.iconOnly(
                                    key: const Key('new-session-send-button'),
                                    kind: CarbonButtonKind.danger,
                                    icon: const CarbonIcon(
                                      CarbonIcons.stopFilled,
                                    ),
                                    semanticLabel: 'Stop starting session',
                                    onPressed: () => ref
                                        .read(
                                          newSessionStartProgressProvider
                                              .notifier,
                                        )
                                        .requestCancel(),
                                  ),
                          )
                        else
                          Listener(
                            onPointerDown: (event) =>
                                _sendPointer = event.pointer,
                            onPointerUp: (_) => _forgetSendPress(),
                            onPointerCancel: (_) => _forgetSendPress(),
                            child: labelledSend
                                ? CarbonButton(
                                    key: const Key('new-session-send-button'),
                                    label: 'Start',
                                    kind: CarbonButtonKind.primary,
                                    icon: const CarbonIcon(CarbonIcons.send),
                                    semanticLabel: 'Start session',
                                    busy: starting,
                                    maxLines: 1,
                                    // Kept live while busy so the key keeps
                                    // its primary fill — working, not off;
                                    // `busy` swallows the press.
                                    onPressed: canSend
                                        ? _onSendPressed
                                        : (starting ? _noop : null),
                                  ).reservingWidthOf(stop: true)
                                : CarbonButton.iconOnly(
                                    key: const Key('new-session-send-button'),
                                    kind: CarbonButtonKind.primary,
                                    icon: const CarbonIcon(CarbonIcons.send),
                                    semanticLabel: 'Start session',
                                    busy: starting,
                                    // As above: live while busy.
                                    onPressed: canSend
                                        ? _onSendPressed
                                        : (starting ? _noop : null),
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
      ),
    );
  }

  /// Cleared after the release has been delivered: the tap that reads it
  /// fires later in the same dispatch.
  void _forgetSendPress() => scheduleMicrotask(() => _sendPointer = null);

  /// A popup closes on the press of a tap outside it and passes the tap on, so
  /// the tap that only meant to dismiss a picker would otherwise also start
  /// the session, with whatever the user was about to change unchanged. Asked
  /// of the popup itself rather than inferred from the route: the app shell
  /// holds the route's pop for its own back handling, so "the route cannot
  /// pop" says nothing about whether a picker was open.
  void _onSendPressed() {
    final pointer = _sendPointer;
    _sendPointer = null;
    if (pointer != null && CarbonAnchoredPopup.dismissedByPointer(pointer)) {
      return;
    }
    detached('new-session', 'start session', _submit);
  }

  void _openSessionSettings() {
    detached('new-session', 'open session settings', () async {
      await showCarbonModal<void>(
        context,
        builder: (_) => const _SessionSettingsModal(),
      );
    });
  }
}

void _noop() {}

extension on CarbonButton {
  /// Lays this labelled send key over an invisible, inert copy of the other
  /// one ([stop] picks which), so the slot is as wide as the wider of Start and
  /// Stop at whatever font and scale is in use, and the key keeps one width
  /// when a start begins and again when it passes the cancel boundary.
  Widget reservingWidthOf({required bool stop}) => Stack(
    alignment: AlignmentDirectional.centerEnd,
    children: [
      Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: CarbonButton(
          label: stop ? 'Stop' : 'Start',
          kind: stop ? CarbonButtonKind.danger : CarbonButtonKind.primary,
          icon: CarbonIcon(stop ? CarbonIcons.stopFilled : CarbonIcons.send),
          maxLines: 1,
        ),
      ),
      this,
    ],
  );
}

/// The shell-prompt marker before the editable: the terminal-native "type
/// here" affordance, lit while the prompt has focus.
/// The app's bundled mono family, which carries the prompt marker's glyph.
const String _promptMarkerFallback = 'JetBrains Mono NL';

class _PromptMarker extends StatelessWidget {
  const _PromptMarker({required this.focused, required this.enabled});

  final bool focused;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final c = t.colors;
    final code = t.typography.code;
    double lineHeight(TextStyle s) => (s.fontSize ?? 0) * (s.height ?? 1);
    // Seats the marker on the first line of the prompt, whose text is body
    // sized, however the density sizes the two.
    final top = math.max(
      0.0,
      (lineHeight(t.typography.body) - lineHeight(code)) / 2,
    );
    return Padding(
      padding: EdgeInsetsDirectional.only(
        top: top,
        end: CarbonSpacing.spacing03,
      ),
      child: Text(
        '❯',
        style: code.copyWith(
          // IBM Plex Mono has no U+276F; without a named fallback the platform
          // substitutes whatever font has it, or draws a missing-glyph box.
          fontFamilyFallback: const [_promptMarkerFallback],
          color: !enabled
              ? c.iconDisabled
              : focused
              ? c.interactive
              : c.iconSecondary,
        ),
      ),
    );
  }
}

/// The phase of a running start: a spinner and one ellipsized line, announced
/// as it changes.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        key: const Key('new-session-status-line'),
        mainAxisSize: MainAxisSize.min,
        children: [
          CarbonSpinner(color: t.colors.iconSecondary),
          const SizedBox(width: CarbonSpacing.spacing03),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: t.typography.helper.copyWith(
                color: t.colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades [child] in and out while keeping it laid out. Plain [Opacity] driven
/// by a tween composites only while the fade runs, where `AnimatedOpacity`
/// would keep a layer alive at rest.
class _SlotFade extends StatelessWidget {
  const _SlotFade({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // No `begin`: TweenAnimationBuilder seeds it from `end` on the first
      // build, so the widget mounts already settled instead of fading in.
      tween: Tween<double>(end: visible ? 1 : 0),
      duration: CarbonMotion.resolve(context, CarbonMotion.fast02),
      curve: CarbonMotion.standard,
      child: child,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
    );
  }
}

const String _isolationWord = 'Isolated';

/// The width the isolation checkbox needs to keep its word.
double _isolationWordWidth(BuildContext context, CarbonThemeData t) {
  final painter = TextPainter(
    text: TextSpan(text: _isolationWord, style: t.typography.control),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  // The checkbox seats its box and the gap before its label in under
  // spacing07.
  return CarbonSpacing.spacing07 + width;
}

/// Isolation opt-in, as the last term of the context row's sentence:
/// `Local · my-repo · main · Isolated`.
///
/// Last on purpose — it modifies the picker before it. Switching it on
/// re-labels the branch to `Base: main`, which is the entire explanation of
/// what isolation does to the current selection, delivered by the row itself.
///
/// Labelled for the OUTCOME the user is choosing, not for the git mechanism
/// that currently delivers it: the same switch is what a second isolation
/// backend would ride in on, and a user who picked "worktree" could not be told
/// afterwards that they had picked something else.
class _IsolationChip extends ConsumerWidget {
  const _IsolationChip({this.enabled = true});

  /// Handed down by the composer rather than read from the start model here,
  /// so one owner decides when the row is frozen.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same gate as [BranchChip]: with no project chosen the Git-shaped
    // controls have nothing to describe, and a dead one beside "Select
    // project…" is noise rather than discovery.
    if (ref.watch(selectedTargetProjectProvider) == null) {
      return const SizedBox.shrink();
    }

    final catalog = ref.watch(newSessionBranchCatalogProvider);
    final ready = ref.watch(newSessionIsolationReadyProvider);
    final isolated = ref.watch(newSessionIsolatedProvider);

    // The frozen arm comes FIRST: a control dead only because a start is
    // running must not blame the project's Git or the machine's bridge, and
    // must not send the reader off to update anything.
    final reason = !enabled
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
              'Antgrid is up to date';

    return LayoutBuilder(
      builder: (context, constraints) {
        final t = CarbonTheme.of(context);
        final showWord =
            constraints.maxWidth >= _isolationWordWidth(context, t);
        return KeyedSubtree(
          // The key addresses the isolation toggle, not the word printed on it.
          key: const Key('new-session-worktree-chip'),
          child: CarbonTooltip(
            message: reason,
            child: CarbonCheckbox(
              value: isolated,
              labelText: showWord ? _isolationWord : null,
              semanticLabel: showWord ? null : _isolationWord,
              onChanged: enabled && ready
                  ? (next) => ref
                        .read(newSessionIsolatedProvider.notifier)
                        .set(next ?? false)
                  : null,
            ),
          ),
        );
      },
    );
  }
}

/// Session-mode dropdown ([ Terminal v ]) — Terminal is the default for every
/// agent and Chat is opened into deliberately, so the control shows the current
/// mode and hides the alternative behind a tap rather than presenting both as
/// equals (the in-session switch keeps `ModeSegmented`).
///
/// "This agent can't do chat" is still said in place: the Chat row renders
/// greyed under a heading giving its reason instead of vanishing, so a missing
/// option and an unsupported one never look alike.
class _ModeSelector extends ConsumerWidget {
  const _ModeSelector({
    required this.supportsChat,
    this.enabled = true,
    this.glyphOnly = false,
  });

  /// Null when neither the target machine nor the persisted catalog has
  /// described the selected agent — a third state, not a `false`.
  final bool? supportsChat;

  /// See [_IsolationChip.enabled].
  final bool enabled;

  /// Shows only the mode's glyph, for a row too narrow to name it.
  final bool glyphOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CarbonTheme.of(context);
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
    // App Review rejected the iOS build under 2.2 for pre-release wording, so
    // the App Store build carries no alpha marker; other platforms keep it.
    final markChatAlpha = defaultTargetPlatform != TargetPlatform.iOS;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Always the same SizedBox, so dropping to the glyph never remounts
        // the trigger (and closes its menu).
        SizedBox(
          width: glyphOnly ? contextPickerGlyphWidth(t) : null,
          child: ContextPicker(
            key: const Key('new-session-mode-chip'),
            icon: isChat ? CarbonIcons.chat : CarbonIcons.terminal,
            label: isChat ? 'Chat' : 'Terminal',
            field: 'Session mode',
            enabled: enabled,
            entries: [
              CarbonMenuRadioGroup<String>(
                label: chatEnabled ? null : chatDisabledReason,
                value: displayMode,
                options: [
                  const CarbonOption(value: 'terminal', label: 'Terminal'),
                  CarbonOption(
                    value: 'chat',
                    label: markChatAlpha ? 'Chat (alpha)' : 'Chat',
                    enabled: chatEnabled,
                  ),
                ],
                onChanged: (picked) =>
                    ref.read(newSessionModeProvider.notifier).set(picked),
              ),
            ],
          ),
        ),
        // Carried on the trigger too, not only in the menu: once the menu is
        // closed the trigger is the only thing still saying which mode the
        // session will start in.
        if (isChat && markChatAlpha) ...[
          const SizedBox(width: CarbonSpacing.spacing02),
          const CarbonTag(
            label: 'Alpha',
            size: CarbonTagSize.small,
            color: CarbonTagColor.purple,
          ),
        ],
      ],
    );
  }
}

/// Bottom-right agent selector. Its menu rows are the target's detected tools,
/// and they arrive while the menu is open: detection can still be under way
/// when it opens, and this widget rebuilds the menu's entries as it answers.
class _AgentSelector extends ConsumerWidget {
  const _AgentSelector({this.enabled = true});

  /// See [_IsolationChip.enabled].
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(newSessionAgentProvider);
    final tools = ref.watch(newSessionDetectedToolsProvider);
    final detected = tools.value;
    final catalog = ref.watch(agentCatalogProvider);
    final status = _agentListStatus(
      tools,
      ref.watch(selectedTargetProjectProvider),
    );

    final label = newSessionAgentLabel(agent, detected, catalog);
    final t = CarbonTheme.of(context);
    return ContextPicker(
      key: const Key('new-session-agent-selector'),
      label: label,
      mark: switch (agent) {
        KnownAgent(:final toolKey) => AbAgentMark(
          toolKey: toolKey,
          label: label,
          size: t.iconSize,
          color: t.colors.iconSecondary,
        ),
        CustomAgent() => null,
      },
      field: 'Agent',
      enabled: enabled,
      entries: [
        CarbonMenuRadioGroup<NewSessionAgent>(
          // Why the list offers nothing beyond the current pick, while the
          // target has not answered or could not be asked.
          label: status,
          value: agent,
          options: [
            for (final a in _buildAgentOptions(detected, agent))
              CarbonOption(
                value: a,
                label: newSessionAgentLabel(a, detected, catalog),
              ),
          ],
          onChanged: (picked) {
            ref.read(newSessionAgentProvider.notifier).set(picked);
            ref.read(newSessionAgentTouchedProvider.notifier).set(true);
          },
        ),
      ],
    );
  }
}

/// The narrowest slot the agent trigger still reads in. It has no leading
/// glyph, so it needs one glyph and its gap less than a picker that has one;
/// the brand mark is dropped below that floor-plus-mark rather than raising it.
double _agentTriggerFloor(CarbonThemeData t) =>
    contextPickerFullMinWidth(t) - t.iconSize - CarbonSpacing.spacing03;

/// Why the agent menu offers nothing beyond the current pick, or null when the
/// target has answered (or there is no target to ask).
String? _agentListStatus(
  AsyncValue<Map<String, String?>?> tools,
  PickerProject? target,
) {
  if (target == null) return null;
  if (tools.hasError) {
    return target.isLocal ? agentsUnlistedCopy : 'Machine offline';
  }
  if (tools.value == null) return agentsCheckingCopy;
  return null;
}

/// Build the agent menu's options from the tools detected on the target.
///
/// The options ARE the advertised tools, in the bridge's order — an agent this
/// app predates still appears, which the app-side enum this replaced could not
/// do. Until the target has answered ([detected] null) no agent is offered
/// beyond the current pick: the persisted catalog would stand in with every
/// agent any bridge has described, installed on this machine or not. `Custom`
/// is always last, and the current [selected] agent is always included so the
/// trigger never renders a hidden option.
List<NewSessionAgent> _buildAgentOptions(
  Map<String, String?>? detected,
  NewSessionAgent selected,
) {
  final options = <NewSessionAgent>[
    for (final key in detected?.keys ?? const <String>[]) KnownAgent(key),
    const CustomAgent(),
  ];
  if (!options.contains(selected)) return [selected, ...options];
  return options;
}

/// Session settings: session name, approval policy, CLI args, and (custom
/// agent only) the custom command. Fields commit as they change, so the modal
/// has nothing to cancel. Owns its own controllers, guarded on inequality so
/// user typing (which writes the same value back via `onChanged`) doesn't reset
/// the cursor.
class _SessionSettingsModal extends ConsumerStatefulWidget {
  const _SessionSettingsModal();

  @override
  ConsumerState<_SessionSettingsModal> createState() =>
      _SessionSettingsModalState();
}

class _SessionSettingsModalState extends ConsumerState<_SessionSettingsModal> {
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

  void _confirmBypass(AgentDescriptor descriptor) {
    detached('new-session', 'confirm YOLO mode', () async {
      // Captured before the await: the confirmation is a route of its own,
      // and whatever is mounted under it when it answers, the provider
      // container is what the answer belongs to.
      final container = ref.container;
      final disablesSandbox =
          descriptor.approvalPolicyRisk == 'bypasses-approvals-and-sandbox';
      final confirmed = await showCarbonConfirm(
        context,
        title: 'Enable YOLO mode?',
        body: disablesSandbox
            ? 'This agent will bypass approval prompts and disable sandboxing for this session.'
            : 'This agent will bypass approval prompts for this session.',
        confirmLabel: 'Enable YOLO',
        danger: true,
      );
      if (confirmed) {
        container.read(newSessionApprovalPolicyProvider.notifier).set('bypass');
      }
    });
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

    final t = CarbonTheme.of(context);
    final agent = ref.watch(newSessionAgentProvider);
    final bypassDescriptor = ref.watch(newSessionBypassSupportProvider);
    final bypass = ref.watch(newSessionApprovalPolicyProvider) == 'bypass';
    const fieldGap = SizedBox(height: CarbonSpacing.spacing05);

    return CarbonModal(
      title: 'Session settings',
      size: CarbonModalSize.xs,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CarbonTextInput(
            key: const Key('new-session-gear-name'),
            controller: _name,
            label: 'Session name',
            showOptional: true,
            placeholder: 'untitled session',
            onChanged: (v) => ref.read(newSessionNameProvider.notifier).set(v),
          ),
          fieldGap,
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: CarbonToggle(
              key: const Key('new-session-gear-yolo'),
              labelText: 'YOLO / Skip approvals',
              value: bypass && bypassDescriptor != null,
              onChanged: bypassDescriptor == null
                  ? null
                  : (next) {
                      if (!next) {
                        ref
                            .read(newSessionApprovalPolicyProvider.notifier)
                            .set('default');
                        return;
                      }
                      _confirmBypass(bypassDescriptor);
                    },
            ),
          ),
          const SizedBox(height: CarbonSpacing.spacing02),
          Text(
            bypassDescriptor == null
                ? 'Not supported for this agent and mode'
                : 'Launch this session without approval prompts',
            style: t.typography.helper.copyWith(color: t.colors.textHelper),
          ),
          fieldGap,
          CarbonTextInput(
            key: const Key('new-session-gear-cli-args'),
            controller: _cliArgs,
            label: 'CLI arguments',
            showOptional: true,
            placeholder: '--flag value',
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (v) =>
                ref.read(newSessionCliArgsProvider.notifier).set(v),
          ),
          if (agent == const CustomAgent()) ...[
            fieldGap,
            CarbonTextInput(
              key: const Key('new-session-gear-custom-cmd'),
              controller: _customCmd,
              label: 'Custom command',
              required: true,
              placeholder: 'e.g. my-agent --serve',
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (v) =>
                  ref.read(newSessionCustomCmdProvider.notifier).set(v),
            ),
          ],
        ],
      ),
      actions: [
        CarbonModalAction(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
