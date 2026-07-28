import 'package:flutter/material.dart';

import '../ab_icons.dart';
import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_control_box.dart';
import 'ab_icon.dart';
import 'ab_icon_button.dart';

/// Single-line text input primitive for the Antgrid design system.
///
/// Owns the visual chrome (1px [context.antgrid.borderDefault] outline,
/// [AbTokens.borderRadius5], monospace text, accent cursor) and the
/// controller / focusNode lifecycle. Pass external [controller] or
/// [focusNode] to share state; when null, the widget owns and disposes
/// its own instance.
///
/// Higher-level fields ([AbSearchField], [AbUrlField], ...) compose
/// behavior on top of this primitive — keep this base feature-free
/// (no debounce, no select-all, no validation).
class AbTextField extends StatefulWidget {
  const AbTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.prefixIcon,
    this.showClearButton = false,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.onClear,
    this.autofocus = false,
    this.enabled = true,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.fillColor,
    this.height,
    this.contentPadding,
    this.prefixIconSize,
    this.prefixIconWidth,
    this.suffixSlotWidth,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;

  /// Codicon string (e.g. [AbIcons.search]). Null hides the prefix.
  final String? prefixIcon;

  /// Render a clear (close) icon button while text is non-empty and
  /// the field is enabled.
  final bool showClearButton;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;

  /// Fired after the clear button is tapped, in addition to
  /// `onChanged('')`. Wrappers use this to cancel pending debounces.
  final VoidCallback? onClear;

  final bool autofocus;
  final bool enabled;

  /// Masks input (e.g. secrets/passwords). Forwarded to the internal
  /// [TextField]. Defaults to false so existing callers are unaffected.
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  /// Background fill. Defaults to [context.antgrid.bgSurface].
  final Color? fillColor;

  /// Outer field height. Defaults to [AbTokens.rowHeightSm].
  ///
  /// This is the exact height of the visible box — the widget's own [Container]
  /// owns the border/fill at this height, so it lines up pixel-for-pixel with
  /// same-height neighbours (e.g. dropdown triggers, buttons).
  final double? height;

  /// Override for the box's inner padding. Leave null (the common case) for the
  /// default horizontal [AbTokens.space8] (text is vertically centred by
  /// [height]). Pass a value only for non-standard insets.
  final EdgeInsetsGeometry? contentPadding;

  /// Prefix icon glyph size. Defaults to [AbTokens.iconButtonGlyph].
  final double? prefixIconSize;

  /// Prefix-icon slot width. Defaults to [AbTokens.iconButtonBox] (24).
  final double? prefixIconWidth;

  /// When set, the clear button is centred inside a square slot of this width
  /// (instead of sitting flush). Pass the field [height] to give the suffix
  /// glyph the same margins on all four sides as a matching prefix slot.
  final double? suffixSlotWidth;

  @override
  State<AbTextField> createState() => _AbTextFieldState();
}

class _AbTextFieldState extends State<AbTextField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocus = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _ownsController = widget.controller == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _lastEmpty = _controller.text.isEmpty;
    _wasFocused = _focusNode.hasFocus;
    _controller.addListener(_onControllerChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(AbTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_onControllerChanged);
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? TextEditingController();
      _ownsController = widget.controller == null;
      _lastEmpty = _controller.text.isEmpty;
      _controller.addListener(_onControllerChanged);
      // setState happens implicitly via didUpdateWidget's enclosing
      // rebuild; the suffix slot reads `_controller.text.isNotEmpty`
      // directly in build, so no extra setState is needed here.
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
    _controller.removeListener(_onControllerChanged);
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsController) _controller.dispose();
    if (_ownsFocus) _focusNode.dispose();
    super.dispose();
  }

  /// Tracks only emptiness flips so we don't fan out a setState on every
  /// selection or composition tick. The actual `onChanged` callback is
  /// driven by `TextField.onChanged` directly — this listener only
  /// rebuilds the suffix-icon slot.
  bool _lastEmpty = true;
  void _onControllerChanged() {
    if (!widget.showClearButton) return;
    final isEmpty = _controller.text.isEmpty;
    if (isEmpty == _lastEmpty) return;
    _lastEmpty = isEmpty;
    setState(() {});
  }

  void _handleClear() {
    _controller.clear();
    widget.onClear?.call();
    widget.onChanged?.call('');
  }

  /// Repaints the border (accent when focused) only when focus actually
  /// flips, so unrelated [FocusNode] notifications don't fan out a rebuild.
  bool _wasFocused = false;
  void _onFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    if (hasFocus == _wasFocused) return;
    _wasFocused = hasFocus;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final showClear =
        widget.showClearButton && enabled && _controller.text.isNotEmpty;
    final effHeight = widget.height ?? AbTokens.rowHeightSm;

    // Clear button, optionally centred in a square slot of [suffixSlotWidth]
    // (matches a same-width prefix slot for equal margins on all sides).
    Widget? clearButton;
    if (showClear) {
      clearButton = AbIconButton(icon: AbIcons.close, onTap: _handleClear);
      if (widget.suffixSlotWidth != null) {
        clearButton = SizedBox(
          width: widget.suffixSlotWidth,
          child: Center(child: clearButton),
        );
      }
    }

    // [AbControlBox] owns the box: a fixed [effHeight] with the standard fill
    // and the accent-on-focus border, shared with other single-row controls
    // (e.g. dropdown triggers) so they stay aligned. The inner TextField is
    // stripped to a borderless, collapsed, zero-padding field that renders only
    // text + hint, so it sizes to its text line and is vertically centred by
    // the Row. Prefix icon and clear button are Row children (the collapsed
    // decoration doesn't support prefixes/suffixes).
    final box = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? _focusNode.requestFocus : null,
      child: AbControlBox(
        height: effHeight,
        focused: _focusNode.hasFocus,
        fillColor: widget.fillColor,
        padding: widget.contentPadding,
        child: Row(
          children: [
            if (widget.prefixIcon != null)
              SizedBox(
                width: widget.prefixIconWidth ?? AbTokens.iconButtonBox,
                child: Center(
                  child: AbIcon(
                    widget.prefixIcon!,
                    size: widget.prefixIconSize ?? AbTokens.iconButtonGlyph,
                    color: context.antgrid.textMuted,
                  ),
                ),
              ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: enabled,
                autofocus: widget.autofocus,
                obscureText: widget.obscureText,
                keyboardType: widget.keyboardType,
                textInputAction: widget.textInputAction,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                onTap: widget.onTap,
                style: AbTokens.sansStyle(),
                cursorColor: context.antgrid.accent,
                decoration: InputDecoration(
                  isCollapsed: true,
                  // [AbControlBox] owns the fill + border. The global
                  // [ThemeData.inputDecorationTheme] sets filled:true and
                  // per-state OutlineInputBorders (accent when focused);
                  // InputDecoration.applyDefaults backfills any null field
                  // from it, and per-state borders win over `border`. So every
                  // state must be explicitly neutralised here — `border:none`
                  // alone is NOT enough, or the field paints its own accent
                  // outline inside the box (double border on focus).
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  hintText: widget.hintText,
                  hintStyle: AbTokens.sansStyle(
                    color: context.antgrid.textMuted,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            ?clearButton,
          ],
        ),
      ),
    );

    // Disabled-state contract: opacity 0.4, no interaction.
    if (!enabled) {
      return IgnorePointer(child: Opacity(opacity: 0.4, child: box));
    }
    return box;
  }
}
