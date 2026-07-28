import 'package:fleather/fleather.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import 'composer_controller.dart';
import 'composer_theme.dart';
import 'smart_enter.dart';

/// Rich prompt composer: raw FleatherEditor (never FleatherField/Toolbar —
/// Material chrome). Renders bare — border/background chrome is owned by the
/// enclosing composer surface (agent_transcript_view), which tracks
/// hover/focus on the whole instrument. Grows with content up to
/// [_maxEditorHeight], then scrolls internally.
class RichComposer extends StatefulWidget {
  const RichComposer({
    super.key,
    required this.controller,
    required this.onSend,
    this.focusNode,
    this.hintText,
    this.keyEventPrelude,
  });

  final ComposerController controller;
  final VoidCallback onSend;
  final FocusNode? focusNode;
  final String? hintText;

  /// Runs before smart-enter (the transcript's slash-suggestion nav). A
  /// non-ignored result consumes the key.
  final KeyEventResult Function(FocusNode, KeyEvent)? keyEventPrelude;

  @override
  State<RichComposer> createState() => _RichComposerState();
}

class _RichComposerState extends State<RichComposer> {
  late FocusNode _focus;
  bool _ownsFocus = false;

  // ≈8 body lines incl. line spacing + vertical padding; scrolls beyond.
  static const _maxEditorHeight = 176.0;

  @override
  void initState() {
    super.initState();
    _attachFocus();
  }

  void _attachFocus() {
    _focus = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    // The node intercepts keys BEFORE the editor's own shortcuts — same
    // pattern as the transcript's suggestion nav (see agent_transcript_view).
    _focus.onKeyEvent = _onKey;
  }

  @override
  void didUpdateWidget(RichComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _focus.onKeyEvent = null;
      if (_ownsFocus) _focus.dispose();
      _attachFocus();
    }
  }

  @override
  void dispose() {
    _focus.onKeyEvent = null;
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final prelude = widget.keyEventPrelude?.call(node, event);
    if (prelude != null && prelude != KeyEventResult.ignored) return prelude;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final action = decideEnter(
      caretLineIsPlain: widget.controller.caretLineIsPlain,
      isShift: keys.isShiftPressed,
      isCtrlOrCmd: keys.isControlPressed || keys.isMetaPressed,
      // onKeyEvent only ever fires for hardware keys; soft-keyboard Enter
      // reaches the editor directly and stays a newline.
      hasHardwareKeyboard: true,
    );
    if (action == EnterAction.send) {
      widget.onSend();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    return Stack(
      children: [
        // Fleather has no placeholder; overlay the hint while empty.
        if (widget.hintText != null)
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => widget.controller.isEmpty
                ? Padding(
                    // +space4 on top matches the paragraph block's top
                    // VerticalSpacing (composer_theme) so the hint sits on
                    // the same baseline as the first typed character.
                    padding: const EdgeInsets.only(
                      top: AbTokens.space8 + AbTokens.space4,
                      bottom: AbTokens.space8,
                    ),
                    child: IgnorePointer(
                      child: Text(
                        widget.hintText!,
                        style: AbTokens.sansStyle(color: colors.textMuted),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        FleatherTheme(
          data: buildComposerTheme(context),
          child: FleatherEditor(
            controller: widget.controller.fleather,
            focusNode: _focus,
            // Horizontal insets come from the parent surface; keeping them
            // here would double the gap after the ❯ prompt marker.
            padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
            maxHeight: _maxEditorHeight,
            scrollable: true,
            expands: false,
            textCapitalization: TextCapitalization.sentences,
          ),
        ),
      ],
    );
  }
}
