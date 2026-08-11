import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';

import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon_button.dart';
import 'ab_text_field.dart';

/// Secret input with a reveal toggle.
///
/// Thin composition over [AbTextField]: it owns only the masked/revealed bit
/// and the toggle that flips it. Everything visual — the box, the border, the
/// focus treatment — stays in the primitive, so a password field lines up with
/// its neighbours by construction.
///
/// The reveal toggle is why sign-up carries no "confirm password" field. A
/// masked confirm on a phone keyboard is the worst typo trap available: it
/// catches a mistyped repeat and misses a consistently mistyped original.
/// Letting the user read what they typed catches both.
class AbPasswordField extends StatefulWidget {
  const AbPasswordField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.enabled = true,
    this.autofocus = false,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.height,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool enabled;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final double? height;

  @override
  State<AbPasswordField> createState() => _AbPasswordFieldState();
}

class _AbPasswordFieldState extends State<AbPasswordField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return AbTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hintText: widget.hintText,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: !_revealed,
      // Never let an IME rewrite a secret. See the AbTextField field docs.
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      height: widget.height ?? AbTokens.rowHeightLg,
      suffix: AbIconButton(
        // Glyph names the action, not the state: an eye while masked.
        icon: _revealed ? AbIcons.eyeClosed : AbIcons.eye,
        tone: AbIconButtonTone.muted,
        tooltip: _revealed ? 'Hide password' : 'Show password',
        onTap: widget.enabled
            ? () => setState(() => _revealed = !_revealed)
            : null,
      ),
    );
  }
}
