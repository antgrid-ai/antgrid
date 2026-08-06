import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_composer_send_button.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_kbd.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_snack_bar.dart';
import '../../design/widgets/ab_text_field.dart';

// The send key moved to the design system (shared with the transcript
// composer); re-exported so existing importers keep resolving it from here.
export '../../design/widgets/ab_composer_send_button.dart'
    show ComposerSendButton;
import '../../models/agent_descriptor.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/new_session_action.dart';
import '../../providers/new_session_picker.dart';
import '../../screens/upgrade_screen.dart';
import '../../utils/platform_utils.dart';
import '../mode_segmented.dart';
import 'branch_menu.dart';
import 'environment_menu.dart';
import 'project_menu.dart';

typedef StartNewSessionCallback = Future<void> Function(
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
}) => !starting &&
    hasValidTarget &&
    (!isCustom || customCmd.trim().isNotEmpty) &&
    (!isolated || isolationReady);

/// Bottom-anchored composer for the New Session canvas.
///
/// Assembles the chip row ([EnvironmentChip] + [ProjectChip]), a multiline
/// prompt field, and the bottom control row (mode chip, gear popover, agent
/// selector, send button). Also owns the form listeners that used to live in
/// `SessionConfig` (target -> seed agent, agent -> mode default, detection ->
/// installed-agent snap) and the submit handler that used to live in
/// `NewSessionContent`'s `_SessionFooter` — both source files are deleted in
/// Phase B.
/// Minimum row slack (hint intrinsic width + trailing gap, with margin)
/// before the Enter-to-start hint is worth rendering at all.
const double _enterHintMinWidth = 96;

/// Bottom-row width below which the controls degrade: the mode segmented
/// control drops its cell icons and the agent selector's slot absorbs the
/// row slack (ellipsizing its label) instead of the desktop Enter-hint slot.
/// Degradation order is icons → hint → label; the labels never drop.
const double _composerRowRoomyMinWidth = 460;

/// Share of the context row a single picker label may claim before it starts
/// ellipsizing. Two of them cap out together at well under the full row, which
/// is what keeps the fixed-width worktree chip and a readable stub of the
/// branch on the line no matter how pathological the machine and project names
/// get.
const double _chipLabelCapFraction = 0.3;

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
  bool _starting = false;
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

  /// Default mode to Chat when [agent] is KNOWN to support it, else force
  /// Terminal. An unanswered capability defaults to Terminal, the mode every
  /// agent can run. Ported from `_SessionConfigState._applyModeDefault`.
  void _applyModeDefault(NewSessionAgent agent) {
    final key = newSessionAgentToolKey(agent);
    final supports = agentSupportsChatResolved(
      agent,
      wireChatCapable: ref.read(newSessionChatCapableToolsProvider).value,
      descriptor: key == null ? null : ref.read(agentCatalogProvider)[key],
    );
    ref
        .read(newSessionModeProvider.notifier)
        .set(supports == true ? 'chat' : 'terminal');
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
    starting: _starting,
    hasValidTarget: ref.read(newSessionHasValidTargetProvider),
    isCustom: ref.read(newSessionAgentProvider) == const CustomAgent(),
    customCmd: ref.read(newSessionCustomCmdProvider),
    isolated: ref.read(newSessionIsolatedProvider),
    isolationReady: ref.read(newSessionIsolationReadyProvider),
  );

  /// Ported verbatim from `_SessionFooterState.build`'s Start button `onTap`.
  Future<void> _submit() async {
    if (!_canStart) return;
    setState(() => _starting = true);
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
          if (!mounted) return;
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
      if (mounted) {
        showAbSnackBar(context, e.userMessage);
        await openUpgrade(context, ref.container);
      }
    } catch (e) {
      if (mounted) {
        showAbSnackBar(
          context,
          'Failed to start session: $e',
          duration: const Duration(seconds: 8),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
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
    ref.listen(newSessionDetectedToolsProvider, (_, next) {
      final detected = next.value;
      if (detected == null || detected.isEmpty) return;
      if (ref.read(newSessionAgentTouchedProvider)) return;
      final current = ref.read(newSessionAgentProvider);
      ref
          .read(newSessionAgentProvider.notifier)
          .set(firstInstalledAgent(detected, current));
    });
    // Keep the controller in sync with external writes to the prompt
    // provider (e.g. resetNewSessionForm clearing it on exit). Guarded on
    // inequality so user typing — which writes the same value back via
    // onChanged — doesn't reset the cursor.
    ref.listen(newSessionPromptProvider, (_, next) {
      if (_prompt.text != next) _prompt.text = next;
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
    // Reactive form of `_canStart`, built from the values already watched
    // above so the button reacts to every one of them; both go through
    // [newSessionCanStart] so the watch and read paths stay in lockstep.
    final canSend = newSessionCanStart(
      starting: _starting,
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
              //   - the worktree chip never shrinks: its label is a constant,
              //     and it is the only word the chip has.
              child: LayoutBuilder(
                builder: (context, rowConstraints) {
                  final cap = BoxConstraints(
                    maxWidth: rowConstraints.maxWidth * _chipLabelCapFraction,
                  );
                  return Row(
                    children: [
                      ConstrainedBox(
                        constraints: cap,
                        child: const EnvironmentChip(),
                      ),
                      const SizedBox(width: AbTokens.space6),
                      ConstrainedBox(
                        constraints: cap,
                        child: ProjectChip(onOpenFolder: widget.onOpenFolder),
                      ),
                      const SizedBox(width: AbTokens.space6),
                      const Flexible(child: BranchChip()),
                      const SizedBox(width: AbTokens.space6),
                      const _WorktreeChip(),
                    ],
                  );
                },
              ),
            ),
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
                  // overflowing: the segmented control drops its cell icons
                  // and the agent selector's slot takes the row slack so its
                  // label ellipsizes (see _composerRowRoomyMinWidth).
                  final roomy =
                      rowConstraints.maxWidth >= _composerRowRoomyMinWidth;
                  return Row(
                    children: [
                      _ModeSegmented(
                        supportsChat: supportsChat,
                        showIcons: roomy,
                      ),
                      const SizedBox(width: AbTokens.space8),
                      Builder(
                        builder: (gearContext) => AbIconButton(
                          key: const Key('new-session-gear-button'),
                          icon: AbIcons.settings,
                          onTap: () => _openGear(gearContext),
                        ),
                      ),
                      if (roomy && !isMobilePlatform) ...[
                        // Hardware-Enter hint — desktop only (soft keyboards
                        // have no meaningful Enter-to-send). Fades rather
                        // than pops so the row doesn't reflow as readiness
                        // changes. It lives in the row's slack (not after a
                        // Spacer) so a narrow pane drops it instead of
                        // overflowing — the invisible hint still occupies
                        // layout space.
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              if (constraints.maxWidth < _enterHintMinWidth) {
                                return const SizedBox.shrink();
                              }
                              return Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    right: AbTokens.space12,
                                  ),
                                  child: AnimatedOpacity(
                                    duration: AbTokens.motionDefault,
                                    opacity: _promptFocused && canSend ? 1 : 0,
                                    child: Row(
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
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const _AgentSelector(),
                      ] else
                        // No hint slot: hand the slack to the selector so a
                        // long agent label ellipsizes inside it (ComposerChip
                        // needs a bounded width) instead of overflowing.
                        const Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _AgentSelector(),
                          ),
                        ),
                      const SizedBox(width: AbTokens.space8),
                      ComposerSendButton(
                        key: const Key('new-session-send-button'),
                        busy: _starting,
                        onTap: canSend ? _submit : null,
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
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      key: const Key('new-session-prompt-field'),
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
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

/// Worktree opt-in, as the last term of the context row's sentence:
/// `Local · my-repo · main · worktree`.
///
/// Last on purpose — it modifies the chip before it. Switching it on re-labels
/// the branch chip to `Base: main`, which is the entire explanation of what
/// isolation does to the current selection, delivered by the row itself.
class _WorktreeChip extends ConsumerWidget {
  const _WorktreeChip();

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
      key: const Key('new-session-worktree-chip'),
      label: 'worktree',
      value: ref.watch(newSessionIsolatedProvider),
      tooltip: ready
          ? 'Give this session its own branch and working directory'
          : catalog.isLoading
          ? 'Checking this project…'
          : catalog.value?.isRepository == false
          ? 'Requires a Git repository'
          : 'Update the bridge to isolate sessions',
      onChanged: ready
          ? (next) => ref.read(newSessionIsolatedProvider.notifier).set(next)
          : null,
    );
  }
}

class _ModeSegmented extends ConsumerWidget {
  const _ModeSegmented({required this.supportsChat, this.showIcons = true});

  /// Null when neither the target machine nor the persisted catalog has
  /// described the selected agent — a third state, not a `false`.
  final bool? supportsChat;

  /// Icons are garnish (labels always render); tight rows drop them first.
  final bool showIcons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(newSessionModeProvider);
    final agent = ref.watch(newSessionAgentProvider);
    final label = newSessionAgentLabel(
      agent,
      ref.watch(newSessionDetectedToolsProvider).value,
      ref.watch(agentCatalogProvider),
    );
    final enabled = supportsChat == true;
    // Pin the DISPLAYED selection to Terminal whenever chat isn't supported,
    // rather than trusting `mode` to already carry 'terminal' — detection
    // (newSessionChatCapableToolsProvider) can resolve a frame after the
    // agent-default heuristic runs, so `mode` briefly lags the true support
    // state. The provider itself still gets corrected by the agent listener.
    final displayMode = enabled ? mode : 'terminal';
    return ModeSegmented(
      keyPrefix: 'new-session-mode',
      mode: displayMode,
      chatEnabled: enabled,
      // Longer than the mid-session toggle's "Not supported": at create time
      // the agent is still being chosen, so the string has to name it. An
      // unanswered capability says so instead of blaming the agent — and it
      // names both ways it can be unanswered, because the same null covers the
      // ordinary wait for a target's first advert and a bridge too old to send
      // one, and only the second is the user's to fix.
      chatDisabledReason: supportsChat == null
          ? "This machine hasn't said whether $label supports chat sessions — "
                'it may still be connecting, or its bridge may be too old to '
                'answer'
          : "$label doesn't support chat sessions",
      showIcons: showIcons,
      onChanged: (m) => ref.read(newSessionModeProvider.notifier).set(m),
    );
  }
}

/// Bottom-right agent-selector trigger — chip-styled port of
/// `session_config.dart`'s `_AgentDropdown` (an `AbControlBox` trigger there;
/// a [ComposerChip] here to match the environment/project chips it sits
/// beside).
class _AgentSelector extends ConsumerWidget {
  const _AgentSelector();

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
