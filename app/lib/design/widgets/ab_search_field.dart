import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ab_icons.dart';
import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_text_field.dart';

/// Debounced text input with a search prefix icon and clear button.
///
/// Thin wrapper over [AbTextField] — only adds debounce around
/// [onChanged]. Controller/focusNode lifecycle and all visual chrome
/// live in the base.
class AbSearchField extends StatefulWidget {
  const AbSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint = 'Search...',
    this.prefixIcon = AbIcons.search,
    this.showClearButton = true,
    this.autofocus = false,
    this.debounce = const Duration(milliseconds: 300),
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.height = AbTokens.rowHeightMd,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;
  final String? prefixIcon;
  final bool showClearButton;
  final bool autofocus;
  final Duration? debounce;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;

  /// Field height. Forwarded to [AbTextField.height].
  final double height;

  @override
  State<AbSearchField> createState() => _AbSearchFieldState();
}

class _AbSearchFieldState extends State<AbSearchField> {
  Timer? _debounceTimer;

  // The base fires onChanged('') right after onClear, but consumers
  // expect clears to bypass debounce. We dispatch the empty value
  // ourselves from _onClear and skip the immediately-following base
  // notification so onChanged isn't called twice.
  bool _skipNextChange = false;

  void _onChanged(String value) {
    if (_skipNextChange) {
      _skipNextChange = false;
      return;
    }
    if (widget.debounce == null) {
      widget.onChanged?.call(value);
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce!, () {
      if (mounted) widget.onChanged?.call(value);
    });
  }

  void _onClear() {
    _debounceTimer?.cancel();
    widget.onClear?.call();
    _skipNextChange = true;
    widget.onChanged?.call('');
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Both icons sit in a [height]-wide square slot with the clear glyph's
    // size, centring them with equal margins on all four sides. The square
    // provides the inset, so the box padding is zeroed only on the side that
    // actually has an icon — a bare side keeps the standard [space8] inset so
    // text never runs flush to the border.
    final hasPrefix = widget.prefixIcon != null;
    return AbTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hintText: widget.hint,
      prefixIcon: widget.prefixIcon,
      showClearButton: widget.showClearButton,
      autofocus: widget.autofocus,
      fillColor: context.antgrid.bgDeepest,
      height: widget.height,
      prefixIconSize: AbTokens.iconButtonGlyph,
      prefixIconWidth: widget.height,
      suffixSlotWidth: widget.height,
      contentPadding: EdgeInsets.only(
        left: hasPrefix ? 0 : AbTokens.space8,
        right: widget.showClearButton ? 0 : AbTokens.space8,
      ),
      onChanged: _onChanged,
      onSubmitted: widget.onSubmitted,
      onClear: _onClear,
    );
  }
}
