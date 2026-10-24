import 'package:flutter/material.dart' show InputBorder, InputDecoration, TextField;
import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_control_box.dart';

/// A multi-line text input in the Antgrid box.
///
/// [AbTextField] is single-line by construction — it fixes the box to a row
/// height and gives the inner field no `maxLines` — so every surface that wants
/// prose (a task body, a rendered agent brief the user must be able to edit
/// before it is sent) had nothing to reach for. [AbComposer] is not the answer
/// either: its controller is private and created empty, so it cannot be
/// pre-filled.
///
/// Grows from [minLines] to [maxLines] and scrolls after that, so a long body
/// never pushes its own save affordance off a sheet.
class AbMultilineField extends StatefulWidget {
  const AbMultilineField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.minLines = 3,
    this.maxLines = 10,
    this.onChanged,
    this.autofocus = false,
    this.enabled = true,
    this.mono = false,
    this.fillColor,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final bool enabled;

  /// Mono for content that is code-shaped — a rendered prompt, a diff, a path.
  /// Prose stays sans.
  final bool mono;

  final Color? fillColor;

  @override
  State<AbMultilineField> createState() => _AbMultilineFieldState();
}

class _AbMultilineFieldState extends State<AbMultilineField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocus = false;
  bool _wasFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _ownsController = widget.controller == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _wasFocused = _focusNode.hasFocus;
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(AbMultilineField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? TextEditingController();
      _ownsController = widget.controller == null;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_onFocusChanged);
      if (_ownsFocus) _focusNode.dispose();
      _focusNode = widget.focusNode ?? FocusNode();
      _ownsFocus = widget.focusNode == null;
      _wasFocused = _focusNode.hasFocus;
      _focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsController) _controller.dispose();
    if (_ownsFocus) _focusNode.dispose();
    super.dispose();
  }

  /// Repaint the border only when focus actually flips — unrelated node
  /// notifications must not fan out a rebuild of a field holding prose.
  void _onFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    if (hasFocus == _wasFocused) return;
    _wasFocused = hasFocus;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.mono
        ? AbTokens.monoStyle(fontSize: AbTokens.fontSm, height: 1.4)
        : AbTokens.sansStyle(fontSize: AbTokens.fontMd, height: 1.4);
    final box = AbControlBox(
      focused: _focusNode.hasFocus,
      fillColor: widget.fillColor,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space8,
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        onChanged: widget.onChanged,
        style: style,
        cursorColor: context.antgrid.accent,
        decoration: InputDecoration(
          isCollapsed: true,
          // AbControlBox owns fill and border; the global input theme would
          // otherwise paint a second accent outline inside this one on focus,
          // and per-state borders win over `border` alone.
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          hintText: widget.hintText,
          hintStyle: style.copyWith(color: context.antgrid.textMuted),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
    if (!widget.enabled) {
      return IgnorePointer(child: Opacity(opacity: 0.4, child: box));
    }
    return box;
  }
}
