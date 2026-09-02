import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_composer_send_button.dart';
import '../../design/widgets/ab_prompt_field.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../transcript/composer/smart_enter.dart';
import 'handler_judge_chip.dart';
import 'handler_session_settings.dart';

/// The send key AND what pressing it means, supplied whole by the host.
///
/// A host that COLLECTS rather than sends passes none: the arm sheet's commit
/// is its own `[Arm Handler]` button, and a second key beside it would be
/// disabled on empty text while that button stayed enabled — two controls for
/// one action, disagreeing about whether the action is available. With no
/// [HandlerComposerSend] the composer renders no key at all, so nothing on
/// that surface promises a commit it does not make.
class HandlerComposerSend {
  const HandlerComposerSend({
    required this.tooltip,
    required this.semanticLabel,
    required this.onSend,
  });

  final String tooltip;

  /// [ComposerSendButton] paints a bare glyph, so the label is the only thing
  /// a screen reader has to say what this key does.
  final String semanticLabel;

  final VoidCallback onSend;
}

/// The one box the user types Handler instructions into, shared by the arm
/// sheet and the backlog drawer.
///
/// CONTROLLED: the host owns the [TextEditingController] and the send verb;
/// the composer owns focus, the Enter policy, the bordered box, the growth cap
/// and the judge chip. There is no `mode` flag, because the two hosts differ in
/// what a commit MEANS — one queues a sentence on the wire, the other holds it
/// until the arm lands — and that is supplied whole via [send] rather than
/// selected by a boolean.
///
/// The composer NEVER clears or disposes [controller]: clearing is a statement
/// that the send happened, which only the host knows (the drawer clears on a
/// sent instruction alone), and a composer that disposed it would kill the arm
/// sheet's text before its own pop could read it.
///
/// Host commentary — a duplicate-send line, a grant echo — stacks BELOW this
/// widget, outside its border: the box is the instrument, not the transcript.
class HandlerInstructionComposer extends ConsumerStatefulWidget {
  const HandlerInstructionComposer({
    super.key,
    required this.terminalId,
    required this.controller,
    required this.hintText,
    required this.judge,
    required this.onJudgeChanged,
    required this.judgeScopeNote,
    this.send,
  });

  final String terminalId;

  /// Host-owned and host-disposed.
  final TextEditingController controller;

  final String hintText;

  /// The judge that will READ what is typed here — see [HandlerJudgeChip].
  final HandlerJudgePick judge;
  final ValueChanged<HandlerJudgePick> onJudgeChanged;

  /// When a judge pick takes effect, in the host's own terms:
  /// [handlerJudgeScopeOnArm] or [handlerJudgeScopeNextPass].
  final String judgeScopeNote;

  /// Null on a host that collects rather than sends — see
  /// [HandlerComposerSend].
  final HandlerComposerSend? send;

  @override
  ConsumerState<HandlerInstructionComposer> createState() =>
      _HandlerInstructionComposerState();
}

class _HandlerInstructionComposerState
    extends ConsumerState<HandlerInstructionComposer> {
  late final FocusNode _focus;
  bool _hovered = false;
  bool _focused = false;
  bool _canSend = false;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
    // Intercepts Enter/Shift+Enter before the field's own key handling — the
    // same pattern the New Session composer and the transcript's RichComposer
    // both use.
    _focus.onKeyEvent = _onKey;
    _focus.addListener(_onFocusChanged);
    widget.controller.addListener(_onText);
    _canSend = _hasText;
  }

  @override
  void didUpdateWidget(HandlerInstructionComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
      _canSend = _hasText;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.onKeyEvent = null;
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  bool get _hasText => widget.controller.text.trim().isNotEmpty;

  void _onFocusChanged() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
  }

  /// Every keystroke passes through here, so rebuild only on the one bit the
  /// control row actually renders — whether the key is live.
  void _onText() {
    final next = _hasText;
    if (next == _canSend) return;
    setState(() => _canSend = next);
  }

  /// Enter policy, delegated to [decideEnter] so this box and the transcript
  /// composer cannot answer a return key differently.
  ///
  /// `onKeyEvent` fires for hardware keys only, so `hasHardwareKeyboard` is a
  /// fact here rather than an assumption; a plain [AbPromptField] has no
  /// document model, so no line it holds is ever anything but plain. That
  /// leaves the soft keyboard's Enter as a newline and mobile committing
  /// through the send key — which is why this field carries no
  /// `TextInputAction.send`, whose behaviour is the exact opposite.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final action = decideEnter(
      caretLineIsPlain: true,
      isShift: keyboard.isShiftPressed,
      isCtrlOrCmd: keyboard.isControlPressed || keyboard.isMetaPressed,
      hasHardwareKeyboard: true,
    );
    final send = widget.send;
    if (action == EnterAction.send && send != null && _canSend) {
      send.onSend();
      return KeyEventResult.handled;
    }
    // A send this surface cannot make falls back to the newline rather than to
    // nothing: on a host with no send key there is no commit to reach, and
    // swallowing the key would leave the field looking frozen.
    _insertNewline();
    return KeyEventResult.handled;
  }

  /// Written by hand rather than left to fall through: a hardware Enter's
  /// default multiline behaviour depends on platform text-editing shortcuts
  /// this composer should not have to depend on.
  void _insertNewline() {
    final value = widget.controller.value;
    // `isValid` only asserts the offsets are non-negative — it says nothing
    // about them fitting the text — and this controller is owned by the HOST,
    // which may have replaced the text without moving the selection. An
    // out-of-range one would make replaceRange throw from inside a key handler.
    final inRange =
        value.selection.isValid &&
        value.selection.end <= value.text.length &&
        value.selection.start <= value.selection.end;
    final selection = inRange
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, '\n'),
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final send = widget.send;
    // One "armed instrument" surface, the same focus contract as the New
    // Session composer and RichComposer: default -> strong on hover -> accent
    // while the field has focus.
    final borderColor = _focused
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
                  // Shell-prompt marker, the same "type here" affordance the
                  // New Session composer carries, so the two boxes read as one
                  // instrument.
                  Padding(
                    padding: const EdgeInsets.only(top: AbTokens.space2),
                    child: Text(
                      '❯',
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontMd,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  Expanded(
                    // Same cap as RichComposer (~8 lines): a long instruction
                    // scrolls inside the box rather than pushing the backlog
                    // list — or the arm sheet's own commit — off screen.
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 176),
                      child: AbPromptField(
                        key: const Key('handler-instruction-field'),
                        controller: widget.controller,
                        focusNode: _focus,
                        hintText: widget.hintText,
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
              child: Row(
                children: [
                  // The chip takes the row's slack so its compound label sheds
                  // inside a bounded width (ComposerChip needs one); the send
                  // key stays last and intrinsic, so no gap opens after it.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: HandlerJudgeChip(
                        terminalId: widget.terminalId,
                        judge: widget.judge,
                        onChanged: widget.onJudgeChanged,
                        scopeNote: widget.judgeScopeNote,
                      ),
                    ),
                  ),
                  if (send != null) ...[
                    const SizedBox(width: AbTokens.space8),
                    Semantics(
                      button: true,
                      enabled: _canSend,
                      label: send.semanticLabel,
                      child: AbTooltip(
                        message: send.tooltip,
                        child: ComposerSendButton(
                          key: const Key('handler-instruction-send'),
                          onTap: _canSend ? send.onSend : null,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
