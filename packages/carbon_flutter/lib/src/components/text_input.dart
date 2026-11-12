import 'dart:math' as math;

import 'package:flutter/material.dart'
    show
        InputDecoration,
        Material,
        MaterialType,
        TextField,
        TextSelectionTheme,
        TextSelectionThemeData;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/field.dart';
import '../primitives/focus_ring.dart';
import '../primitives/interaction.dart';
import 'form.dart';

/// Carbon's field heights. Density supplies the default; an explicit size
/// never goes below the density's minimum target.
enum CarbonFieldSize {
  small(32),
  medium(40),
  large(48);

  const CarbonFieldSize(this.height);

  final double height;
}

/// The kind of editing a [CarbonTextInput] offers.
enum CarbonTextInputVariant {
  /// One line of text.
  text,

  /// One obscured line with a show/hide action and password autofill
  /// defaults.
  password,

  /// Several lines (Carbon's "text area"). Enter inserts a new line.
  multiline,
}

/// An icon action that lives inside a field, such as clear or reveal.
///
/// It has its own focus stop and its own target: at least
/// [CarbonThemeData.minTarget] wide and as tall as the field. Taps on it count
/// as inside the text field, so they do not unfocus the editable.
class CarbonFieldAction extends StatelessWidget {
  const CarbonFieldAction({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.focusNode,
  });

  /// Usually a `CarbonIcon`; it inherits the field's icon size and color.
  final Widget icon;

  /// Names the action for assistive technology.
  final String semanticLabel;

  /// Null disables the action.
  final VoidCallback? onPressed;

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final inset = context
        .dependOnInheritedWidgetOfExactType<_ActionInset>();
    return TextFieldTapRegion(
      child: CarbonInteraction(
        onPressed: onPressed,
        focusNode: focusNode,
        label: semanticLabel,
        excludeChildSemantics: true,
        builder: (context, state, _) {
          return CarbonFocusRing(
            visible: state.focusVisible,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: theme.minTarget,
                minHeight: theme.minTarget,
              ),
              // The fill stops short of the field's outline so a hovered action
              // never hides the focus, error or warning indicator.
              child: Padding(
                padding: inset?.insets ?? EdgeInsets.zero,
                child: ColoredBox(
                  color: state.hovered
                      ? theme.layerHover(level)
                      : const Color(0x00000000),
                  child: Center(
                  widthFactor: 1,
                  child: IconTheme.merge(
                    data: IconThemeData(
                      color: state.enabled
                          ? theme.colors.iconPrimary
                          : theme.colors.iconDisabled,
                      size: theme.iconSize,
                    ),
                    child: icon,
                  ),
                ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// How far a [CarbonFieldAction]'s hover fill stays inside its field box.
class _ActionInset extends InheritedWidget {
  const _ActionInset({required this.insets, required super.child});

  final EdgeInsetsGeometry insets;

  @override
  bool updateShouldNotify(_ActionInset old) => old.insets != insets;
}

/// A [CarbonFieldBox] with [CarbonFieldAction]s flush against the end edge.
///
/// The box's own trailing action slot keeps the field's vertical padding, so
/// a full-size target would make the field taller than its density height.
/// Here the actions are laid over the end edge at the field's full height and
/// the content reserves matching room, so a 32 or 48 target fits without
/// growing the field. Shared by text input and search; selects and dropdowns
/// can use it for their own inline actions.
class CarbonActionFieldBox extends StatelessWidget {
  const CarbonActionFieldBox({
    super.key,
    required this.child,
    this.leading,
    this.trailing,
    this.actions = const <Widget>[],
    this.focused = false,
    this.enabled = true,
    this.readOnly = false,
    this.invalid = false,
    this.warn = false,
    this.minHeight,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final Widget child;
  final Widget? leading;
  final Widget? trailing;

  /// [CarbonFieldAction]s, first to last from the content toward the end
  /// edge.
  final List<Widget> actions;

  final bool focused;
  final bool enabled;
  final bool readOnly;
  final bool invalid;
  final bool warn;
  final double? minHeight;

  /// [CrossAxisAlignment.start] for multi-line content; actions then sit at
  /// the top edge.
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    // Always a Stack, even without actions: the clear action comes and goes
    // while typing, and a changing tree shape would remount the editable and
    // drop its input connection.
    // The box adds a gap before its trailing slot and the end padding after
    // it; the spacer covers whatever is left of the actions' width.
    final reserve = actions.isEmpty
        ? 0.0
        : actions.length * theme.minTarget -
              theme.controlPaddingX -
              CarbonSpacing.spacing03;
    final top = crossAxisAlignment == CrossAxisAlignment.start;
    final outline = focused || invalid || warn
        ? CarbonBorders.focus
        : CarbonBorders.hairline;
    final edge = focused || invalid || warn ? CarbonBorders.focus : 0.0;
    return Stack(
      children: <Widget>[
        CarbonFieldBox(
          leading: leading,
          trailing: reserve > 0 || trailing != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ?trailing,
                    if (reserve > 0) SizedBox(width: reserve),
                  ],
                )
              : null,
          focused: focused,
          enabled: enabled,
          readOnly: readOnly,
          invalid: invalid,
          warn: warn,
          minHeight: minHeight,
          crossAxisAlignment: crossAxisAlignment,
          child: child,
        ),
        if (actions.isNotEmpty)
          PositionedDirectional(
            end: 0,
            top: 0,
            bottom: top ? null : 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: top
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < actions.length; i++)
                  _ActionInset(
                    insets: EdgeInsetsDirectional.only(
                      top: edge,
                      bottom: outline,
                      end: i == actions.length - 1 ? edge : 0,
                    ),
                    child: actions[i],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Carbon text input: single-line, password and multi-line text.
///
/// The editing itself is Flutter's `TextField` (inside a non-visual
/// `Material`), so selection, IME composition, autofill, clipboard and
/// platform keyboards behave natively. That requires `MaterialLocalizations`
/// in the tree, as any `TextField` does.
///
/// * Label, helper, error and warning text come from [CarbonFieldFrame]. The
///   label, requiredness, helper and error are announced on the editable
///   itself. Validation is host-owned: pass [errorText] when the host decides
///   the value is invalid. It is suppressed while [readOnly] or disabled.
/// * [controller] and [focusNode] stay yours: they are created only when not
///   supplied, disposed only when created here, and swapped safely when the
///   widget is given different ones. The text is never rewritten by a
///   rebuild.
/// * [clearable] adds a clear action while there is text; password inputs
///   always get a show/hide action. Both are separate focus stops with
///   targets of 32 (compact) or 48 (touch) logical pixels and localized
///   names.
/// * [readOnly] keeps focus, selection and copy. Disabled is inert.
/// * Inside a [CarbonForm] the field registers itself, so the form's
///   controller can focus the first field showing an error.
///
/// Changing theme, density, text scale or direction keeps text, selection
/// and focus: the widget tree shape never depends on them.
class CarbonTextInput extends StatefulWidget {
  const CarbonTextInput({
    super.key,
    this.controller,
    this.focusNode,
    this.variant = CarbonTextInputVariant.text,
    this.label,
    this.placeholder,
    this.helperText,
    this.errorText,
    this.warnText,
    this.required = false,
    this.showOptional = false,
    this.enabled = true,
    this.readOnly = false,
    this.prefix,
    this.suffix,
    this.clearable = false,
    this.maxLength,
    this.showCounter = false,
    this.minLines,
    this.maxLines,
    this.size,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.autofillHints,
    this.autofocus = false,
    this.semanticLabel,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final CarbonTextInputVariant variant;

  /// The visible label. Always give a field a label or a [semanticLabel].
  final String? label;

  /// Hint shown while empty. Not a substitute for the label.
  final String? placeholder;

  final String? helperText;

  /// The host's validation error, shown with an icon in place of the helper.
  final String? errorText;

  /// A non-blocking warning, shown when there is no error.
  final String? warnText;

  /// Marks the field required (announced; never color alone).
  final bool required;

  /// Appends the localized "(optional)" to labels of non-required fields.
  final bool showOptional;

  final bool enabled;
  final bool readOnly;

  /// Shown inside the field before the text.
  final Widget? prefix;

  /// Shown inside the field after the text, before the field actions.
  final Widget? suffix;

  /// Offers a clear action while the field has text and is editable.
  final bool clearable;

  /// Enforces a character limit.
  final int? maxLength;

  /// Shows "n/max" while [maxLength] is set.
  final bool showCounter;

  /// Multi-line only: the initial height in lines (default 3).
  final int? minLines;

  /// Multi-line only: the line count after which the text scrolls. Null grows
  /// without limit.
  final int? maxLines;

  /// Null follows density.
  final CarbonFieldSize? size;

  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;

  /// Defaults to [AutofillHints.password] for the password variant.
  final Iterable<String>? autofillHints;

  final bool autofocus;

  /// Names the field when it has no [label].
  final String? semanticLabel;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;

  @override
  State<CarbonTextInput> createState() => _CarbonTextInputState();
}

class _CarbonTextInputState extends State<CarbonTextInput> {
  TextEditingController? _ownedController;
  FocusNode? _ownedFocus;
  bool _focused = false;
  bool _revealed = false;
  late bool _hasText;
  late int _length;

  TextEditingController get _controller =>
      widget.controller ?? _ownedController!;
  FocusNode get _focus => widget.focusNode ?? _ownedFocus!;

  bool get _isPassword => widget.variant == CarbonTextInputVariant.password;
  bool get _isMultiline => widget.variant == CarbonTextInputVariant.multiline;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = TextEditingController();
    }
    if (widget.focusNode == null) {
      _ownedFocus = FocusNode(debugLabel: 'CarbonTextInput');
    }
    _controller.addListener(_handleText);
    _focus.addListener(_handleFocus);
    _focused = _focus.hasFocus;
    _syncText();
  }

  @override
  void didUpdateWidget(CarbonTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      final oldController = oldWidget.controller ?? _ownedController!;
      oldController.removeListener(_handleText);
      if (widget.controller == null) {
        // Back to an owned controller: keep what the user had typed.
        _ownedController = TextEditingController.fromValue(oldController.value);
      } else if (oldWidget.controller == null) {
        _disposeAfterFrame(_ownedController!);
        _ownedController = null;
      }
      _controller.addListener(_handleText);
      _syncText();
    }
    if (oldWidget.maxLength != widget.maxLength) _syncText();
    // A disabled field offers no way to hide the text again.
    if (!widget.enabled) _revealed = false;
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      final oldFocus = oldWidget.focusNode ?? _ownedFocus!;
      oldFocus.removeListener(_handleFocus);
      if (widget.focusNode == null) {
        _ownedFocus = FocusNode(debugLabel: 'CarbonTextInput');
      } else if (oldWidget.focusNode == null) {
        _disposeAfterFrame(_ownedFocus!);
        _ownedFocus = null;
      }
      _focus.addListener(_handleFocus);
      _focused = _focus.hasFocus;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleText);
    _focus.removeListener(_handleFocus);
    _ownedController?.dispose();
    _ownedFocus?.dispose();
    super.dispose();
  }

  // The old owned object is still referenced by the child TextField until
  // this frame's build finishes, so it cannot be disposed synchronously.
  void _disposeAfterFrame(ChangeNotifier notifier) {
    SchedulerBinding.instance.addPostFrameCallback((_) => notifier.dispose());
  }

  void _syncText() {
    final text = _controller.text;
    _hasText = text.isNotEmpty;
    _length = widget.maxLength == null ? 0 : text.characters.length;
  }

  void _handleText() {
    final text = _controller.text;
    final hasText = text.isNotEmpty;
    final length = widget.maxLength == null ? 0 : text.characters.length;
    if (hasText == _hasText && length == _length) return;
    _hasText = hasText;
    _length = length;
    _rebuild();
  }

  void _handleFocus() {
    final focused = _focus.hasFocus;
    if (focused == _focused) return;
    _focused = focused;
    _rebuild();
  }

  // A host may assign controller.text while this subtree is building.
  void _rebuild() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _clear() {
    _controller.value = const TextEditingValue(
      selection: TextSelection.collapsed(offset: 0),
    );
    widget.onChanged?.call('');
    _focus.requestFocus();
  }

  int get _minLines {
    final min = widget.minLines ?? 3;
    final max = widget.maxLines;
    return max != null && min > max ? max : min;
  }

  void _toggleReveal() => setState(() => _revealed = !_revealed);

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final messages = CarbonLocalizations.of(context);
    final enabled = widget.enabled;
    final readOnly = widget.readOnly;
    final editable = enabled && !readOnly;
    final password = _isPassword;
    final multiline = _isMultiline;

    final probe = CarbonFieldFrame(
      label: widget.label,
      errorText: widget.errorText,
      warnText: widget.warnText,
      showOptional: widget.showOptional,
      enabled: enabled,
      readOnly: readOnly,
      child: const SizedBox.shrink(),
    );
    final error = probe.resolvedError;
    final warning = probe.resolvedWarning;
    final labelText = probe.resolvedLabel(context);
    final helper = widget.helperText;

    final hintParts = <String>[
      if (widget.required) messages.requiredField,
      if (error != null)
        error
      else if (warning != null)
        warning
      else if (helper != null && helper.isNotEmpty)
        helper,
    ];

    final foreground = enabled ? colors.textPrimary : colors.textDisabled;
    final controlStyle = type.control.copyWith(color: foreground);
    final maxLength = widget.maxLength;

    final textField = TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: enabled,
      readOnly: readOnly,
      autofocus: widget.autofocus,
      obscureText: password && !_revealed,
      enableSuggestions: !password,
      autocorrect: !password,
      keyboardType:
          widget.keyboardType ??
          (password
              ? TextInputType.visiblePassword
              : multiline
              ? TextInputType.multiline
              : TextInputType.text),
      textInputAction:
          widget.textInputAction ??
          (multiline ? TextInputAction.newline : null),
      textCapitalization: widget.textCapitalization,
      inputFormatters: widget.inputFormatters,
      autofillHints:
          widget.autofillHints ??
          (password ? const <String>[AutofillHints.password] : null),
      maxLength: maxLength,
      buildCounter:
          (
            context, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) => null,
      minLines: multiline ? _minLines : 1,
      maxLines: multiline ? widget.maxLines : 1,
      style: controlStyle,
      cursorColor: colors.textPrimary,
      cursorWidth: 1,
      decoration: InputDecoration.collapsed(
        hintText: widget.placeholder,
        hintStyle: type.control.copyWith(
          color: enabled ? colors.textPlaceholder : colors.textDisabled,
        ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onEditingComplete: widget.onEditingComplete,
    );

    final semanticLabel = labelText ?? widget.semanticLabel;
    final Widget semantic = Semantics(
      label: semanticLabel,
      hint: hintParts.isEmpty ? null : hintParts.join('. '),
      isRequired: widget.required ? true : null,
      validationResult: error != null
          ? SemanticsValidationResult.invalid
          : SemanticsValidationResult.none,
      child: Material(
        type: MaterialType.transparency,
        child: TextSelectionTheme(
          data: TextSelectionThemeData(
            cursorColor: colors.textPrimary,
            selectionColor: colors.highlight,
          ),
          child: textField,
        ),
      ),
    );

    Widget? counter;
    if (widget.showCounter && maxLength != null) {
      counter = ExcludeSemantics(
        child: Text(
          '$_length/$maxLength',
          style: type.helper.copyWith(
            color: enabled ? colors.textHelper : colors.textDisabled,
          ),
        ),
      );
    }

    final actions = <Widget>[
      if (widget.clearable && editable && _hasText)
        CarbonFieldAction(
          icon: const CarbonIcon(CarbonIcons.close),
          semanticLabel: messages.clear,
          onPressed: _clear,
        ),
      if (password && enabled)
        CarbonFieldAction(
          icon: CarbonIcon(
            _revealed ? CarbonIcons.viewOff : CarbonIcons.view,
          ),
          semanticLabel: _revealed
              ? messages.hidePassword
              : messages.showPassword,
          onPressed: _toggleReveal,
        ),
    ];

    Widget content = semantic;
    Widget? trailing = widget.suffix;
    if (counter != null) {
      if (multiline) {
        content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            semantic,
            Align(alignment: AlignmentDirectional.centerEnd, child: counter),
          ],
        );
      } else {
        trailing = Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ?widget.suffix,
            if (widget.suffix != null)
              const SizedBox(width: CarbonSpacing.spacing03),
            counter,
          ],
        );
      }
    }
    if (multiline) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: CarbonSpacing.spacing02),
        child: content,
      );
    }

    final height = math.max(
      widget.size?.height ?? theme.controlHeight,
      theme.minTarget,
    );

    final box = GestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      onTap: enabled ? _focus.requestFocus : null,
      child: CarbonActionFieldBox(
        focused: _focused,
        enabled: enabled,
        readOnly: readOnly,
        invalid: error != null,
        warn: warning != null,
        minHeight: height,
        crossAxisAlignment: multiline
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        leading: widget.prefix,
        trailing: trailing,
        actions: actions,
        child: content,
      ),
    );

    return CarbonFormFieldRegistrar(
      invalid: error != null,
      focusNode: _focus,
      child: CarbonFieldFrame(
        label: widget.label,
        helperText: helper,
        errorText: widget.errorText,
        warnText: widget.warnText,
        required: widget.required,
        showOptional: widget.showOptional,
        enabled: enabled,
        readOnly: readOnly,
        excludeTextSemantics: true,
        child: box,
      ),
    );
  }
}
