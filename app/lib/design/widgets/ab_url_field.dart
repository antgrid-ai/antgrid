import 'package:flutter/material.dart';

import 'ab_text_field.dart';

/// URL/address bar: submit-only, select-all-on-focus, no debounce, no clear button.
///
/// Thin wrapper over [AbTextField] — only adds select-all-on-focus.
/// The wrapper unconditionally owns (or forwards) a [FocusNode] and
/// attaches a listener; the base treats it as external and won't
/// dispose it.
class AbUrlField extends StatefulWidget {
  const AbUrlField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint = 'URL',
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String> onSubmitted;

  @override
  State<AbUrlField> createState() => _AbUrlFieldState();
}

class _AbUrlFieldState extends State<AbUrlField> {
  late FocusNode _focus;
  bool _ownsFocus = false;

  @override
  void initState() {
    super.initState();
    _focus = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(AbUrlField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _focus.removeListener(_onFocusChange);
      if (_ownsFocus) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
      _ownsFocus = widget.focusNode == null;
      _focus.addListener(_onFocusChange);
    }
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      widget.controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AbTextField(
      controller: widget.controller,
      focusNode: _focus,
      hintText: widget.hint,
      textInputAction: TextInputAction.go,
      onSubmitted: widget.onSubmitted,
    );
  }
}
