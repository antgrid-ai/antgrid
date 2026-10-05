import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_composer_send_button.dart';
import '../design/widgets/ab_prompt_field.dart';

/// The prompt box a touch terminal types into instead of the PTY.
///
/// The soft keyboard's Return goes straight to the PTY and an agent CLI's own
/// input line is a sliver on a phone, so a prompt longer than a line cannot be
/// seen while it is written. This box wears the New Session composer's surface
/// — accent border while focused, `❯` prompt, the shared send key — shows the
/// whole draft, grows with it, and types it into the terminal only on Send.
///
/// Floated, never laid out: making room for it would resize the terminal's grid
/// on every open and close, and the agent redraws its whole screen on each.
/// The draft is owned by the caller so closing the box keeps it.
class TerminalComposeBox extends StatefulWidget {
  const TerminalComposeBox({
    super.key,
    required this.draft,
    required this.focusNode,
    required this.onSend,
    required this.onDirectInput,
    this.maxLines = 10,
  });

  final TextEditingController draft;
  final FocusNode focusNode;

  /// Types [text] into the terminal and presses Enter after it.
  final void Function(String text) onSend;

  /// Closes the box and raises the raw soft keyboard onto the terminal. Only
  /// reachable while the draft is empty.
  final VoidCallback onDirectInput;

  /// Lines the field grows to before it scrolls; the host lowers it when the
  /// pane is short (the keyboard is up) so the box never runs off the top.
  final int maxLines;

  /// What one line of the draft costs, for the host's line budget and the
  /// growth cap alike. Generous against the field's real line height
  /// ([AbPromptField] sets none, so it is the sans body size times the font's
  /// own leading), so the cap never clips a row that [maxLines] promised. One
  /// constant on purpose: a budget computed from a different size than the cap
  /// hands the field lines it then cannot show.
  static const double lineHeight = AbTokens.fontBody * 1.5;

  @override
  State<TerminalComposeBox> createState() => _TerminalComposeBoxState();
}

class _TerminalComposeBoxState extends State<TerminalComposeBox> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(TerminalComposeBox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return AnimatedContainer(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(AbTokens.space10),
      decoration: BoxDecoration(
        border: Border.all(
          color: widget.focusNode.hasFocus ? p.accent : p.borderDefault,
        ),
        borderRadius: AbTokens.borderRadius8,
        color: p.bgSurface,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Pinned to the first line so the marker sits level with the cursor
            // however many lines the field grows to.
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: TerminalComposeBox.lineHeight,
                child: Center(
                  child: Text(
                    '❯',
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontMd,
                      fontWeight: FontWeight.w600,
                      color: p.accent,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            Expanded(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: TerminalComposeBox.lineHeight * widget.maxLines,
                ),
                child: AbPromptField(
                  controller: widget.draft,
                  focusNode: widget.focusNode,
                  hintText: 'Type a prompt',
                  minLines: widget.maxLines < 3 ? widget.maxLines : 3,
                ),
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.draft,
                builder: (context, value, _) {
                  final empty = value.text.isEmpty;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Typing into the box commits to Send, so the way around
                      // it is only offered while the draft is empty.
                      Semantics(
                        button: true,
                        enabled: empty,
                        label: 'Type directly in terminal',
                        child: AbIconButton(
                          icon: AbIcons.keyboard,
                          tooltip: 'Type directly in terminal',
                          boxSize: AbTokens.rowHeightXl,
                          glyphSize: AbTokens.fontLg,
                          onTap: empty ? widget.onDirectInput : null,
                        ),
                      ),
                      const SizedBox(width: AbTokens.space4),
                      Semantics(
                        button: true,
                        enabled: !empty,
                        label: 'Send',
                        child: ComposerSendButton(
                          onTap: empty ? null : () => widget.onSend(value.text),
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
}
