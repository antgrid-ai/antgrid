import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Multiline prompt input styled with the same tokened chrome as
/// [AbTextField] (which is single-line only, hence a bare field here).
/// `maxLines: null` grows with content; Enter/Shift+Enter handling lives on
/// the caller-owned [focusNode], so each host decides what a return key means
/// on its own surface.
///
/// The chromeless [InputDecoration] recipe below is the load-bearing part: a
/// missing `isCollapsed` or `contentPadding` grows Material's 48px minimum box
/// inside whatever bordered shell the host drew around this field, which no
/// test catches and which reads as a design-system violation on screen.
class AbPromptField extends StatelessWidget {
  const AbPromptField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    this.onChanged,
    this.enabled = true,
    this.readOnly = false,
    this.minLines = 3,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Dimmed AND inert — the field is not the user's to touch at all. Distinct
  /// from [readOnly], which stays fully legible.
  final bool enabled;

  /// Frozen but undimmed, unlike [enabled]: a prompt already on the wire is
  /// still the thing the user is waiting on, so it has to stay readable — and
  /// "busy" must not look like the custom-agent "this field is not yours".
  final bool readOnly;

  final String hintText;
  final ValueChanged<String>? onChanged;

  /// Opening height in lines. The host caps GROWTH with its own
  /// [ConstrainedBox]; this only decides how much room the empty field claims.
  final int minLines;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      readOnly: readOnly,
      // A caret blinking in a field that cannot take the keystroke invites
      // exactly the edit this lock exists to refuse.
      showCursor: !readOnly,
      maxLines: null,
      minLines: minLines,
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
