import 'dart:math' as math;

import 'package:flutter/material.dart'
    show
        AdaptiveTextSelectionToolbar,
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
import 'form.dart';
import 'loading.dart';
import 'text_input.dart';

/// Carbon search field.
///
/// A text field with a leading search icon and a clear action. It never
/// debounces, fetches or filters: the host listens to [onChanged] /
/// [onSubmitted], owns the query and results, and feeds back [busy],
/// [errorText] and [resultCount].
///
/// * [busy] swaps the search icon for a small spinner of the same size and
///   announces the localized "Loading" once. Typing and clearing stay
///   available.
/// * [resultCount] shows the localized count under the field and announces it
///   politely once per change; [errorText] replaces it.
/// * The clear action (localized "Clear search") appears while there is text.
///   It empties only this field's text, calls [onChanged] with an empty
///   string, then [onCleared], and keeps focus in the field.
///
/// ### Escape
///
/// With text in the field, Escape clears it, keeps focus in the field and is
/// consumed. With an empty field Escape is not consumed, so an enclosing
/// popup, menu or modal can handle it. Escape while an IME composition is
/// active is left to the IME.
///
/// Like [CarbonTextInput], editing is Flutter's `TextField` and needs
/// `MaterialLocalizations`; [controller] and [focusNode] are never disposed
/// unless created here.
class CarbonSearch extends StatefulWidget {
  const CarbonSearch({
    super.key,
    this.controller,
    this.focusNode,
    this.semanticLabel,
    this.placeholder,
    this.size,
    this.enabled = true,
    this.readOnly = false,
    this.busy = false,
    this.errorText,
    this.resultCount,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.onCleared,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Accessible name. Defaults to the localized "Search".
  final String? semanticLabel;

  /// Hint shown while empty. Defaults to the localized "Search".
  final String? placeholder;

  /// Null follows density.
  final CarbonFieldSize? size;

  final bool enabled;
  final bool readOnly;

  /// Host-owned pending flag.
  final bool busy;

  /// The host's error text, shown with an icon under the field.
  final String? errorText;

  /// The number of results to present, or null to show none.
  final int? resultCount;

  final bool autofocus;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Called after the clear action or Escape emptied the field.
  final VoidCallback? onCleared;

  @override
  State<CarbonSearch> createState() => _CarbonSearchState();
}

class _CarbonSearchState extends State<CarbonSearch> {
  TextEditingController? _ownedController;
  FocusNode? _ownedFocus;
  bool _focused = false;
  late bool _hasText;
  bool _toolbarShown = false;

  TextEditingController get _controller =>
      widget.controller ?? _ownedController!;
  FocusNode get _focus => widget.focusNode ?? _ownedFocus!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = TextEditingController();
    }
    if (widget.focusNode == null) {
      _ownedFocus = FocusNode(debugLabel: 'CarbonSearch');
    }
    _controller.addListener(_handleText);
    _focus.addListener(_handleFocus);
    _focused = _focus.hasFocus;
    _hasText = _controller.text.isNotEmpty;
  }

  @override
  void didUpdateWidget(CarbonSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      final oldController = oldWidget.controller ?? _ownedController!;
      oldController.removeListener(_handleText);
      if (widget.controller == null) {
        _ownedController = TextEditingController.fromValue(oldController.value);
      } else if (oldWidget.controller == null) {
        _disposeAfterFrame(_ownedController!);
        _ownedController = null;
      }
      _controller.addListener(_handleText);
      _hasText = _controller.text.isNotEmpty;
    }
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      final oldFocus = oldWidget.focusNode ?? _ownedFocus!;
      oldFocus.removeListener(_handleFocus);
      if (widget.focusNode == null) {
        _ownedFocus = FocusNode(debugLabel: 'CarbonSearch');
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

  // The child TextField still references the old owned object until this
  // frame's build finishes.
  void _disposeAfterFrame(ChangeNotifier notifier) {
    SchedulerBinding.instance.addPostFrameCallback((_) => notifier.dispose());
  }

  void _handleText() {
    final hasText = _controller.text.isNotEmpty;
    if (hasText == _hasText) return;
    _hasText = hasText;
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
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  bool get _editable => widget.enabled && !widget.readOnly;

  void _clear() {
    _controller.value = const TextEditingValue(
      selection: TextSelection.collapsed(offset: 0),
    );
    widget.onChanged?.call('');
    widget.onCleared?.call();
    _focus.requestFocus();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // An open selection toolbar owns the first Escape, as in any text field.
    if (_toolbarShown) {
      _focus.context
          ?.findAncestorStateOfType<EditableTextState>()
          ?.hideToolbar();
      return KeyEventResult.handled;
    }
    final value = _controller.value;
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    if (!_editable || value.text.isEmpty || composing) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyUpEvent) _clear();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final messages = CarbonLocalizations.of(context);
    final enabled = widget.enabled;
    final readOnly = widget.readOnly;

    final probe = CarbonFieldFrame(
      errorText: widget.errorText,
      enabled: enabled,
      readOnly: readOnly,
      child: const SizedBox.shrink(),
    );
    final error = probe.resolvedError;
    final count = widget.resultCount;
    final countText = error == null && count != null
        ? messages.resultCount(count)
        : null;

    final foreground = enabled ? colors.textPrimary : colors.textDisabled;
    final placeholder = widget.placeholder ?? messages.search;

    final textField = TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: enabled,
      readOnly: readOnly,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      style: type.control.copyWith(color: foreground),
      cursorColor: colors.textPrimary,
      cursorWidth: 1,
      decoration: InputDecoration.collapsed(
        hintText: placeholder,
        hintStyle: type.control.copyWith(
          color: enabled ? colors.textPlaceholder : colors.textDisabled,
        ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      contextMenuBuilder: (context, state) => _ToolbarPresence(
        onChanged: (shown) => _toolbarShown = shown,
        child: AdaptiveTextSelectionToolbar.editableText(
          editableTextState: state,
        ),
      ),
    );

    final editable = Semantics(
      label: widget.semanticLabel ?? messages.search,
      hint: error,
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

    final Widget leading = widget.busy
        ? Semantics(
            container: true,
            liveRegion: true,
            child: CarbonSpinner(
              size: theme.iconSize,
              semanticLabel: messages.loading,
            ),
          )
        : CarbonIcon(
            CarbonIcons.search,
            color: enabled ? colors.iconSecondary : colors.iconDisabled,
          );

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
        minHeight: height,
        leading: leading,
        actions: <Widget>[
          if (_editable && _hasText)
            CarbonFieldAction(
              icon: const CarbonIcon(CarbonIcons.close),
              semanticLabel: messages.clearSearch,
              onPressed: _clear,
            ),
        ],
        child: editable,
      ),
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: CarbonFormFieldRegistrar(
        invalid: error != null,
        focusNode: _focus,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CarbonFieldFrame(
              errorText: widget.errorText,
              enabled: enabled,
              readOnly: readOnly,
              excludeTextSemantics: true,
              child: box,
            ),
            if (countText != null) ...<Widget>[
              const SizedBox(height: CarbonSpacing.spacing02),
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(
                  countText,
                  style: type.helper.copyWith(
                    color: enabled ? colors.textHelper : colors.textDisabled,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Reports whether the selection toolbar is mounted, so the first Escape can
/// close it instead of clearing the query. EditableText exposes that state
/// only to tests.
class _ToolbarPresence extends StatefulWidget {
  const _ToolbarPresence({required this.onChanged, required this.child});

  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  State<_ToolbarPresence> createState() => _ToolbarPresenceState();
}

class _ToolbarPresenceState extends State<_ToolbarPresence> {
  @override
  void initState() {
    super.initState();
    widget.onChanged(true);
  }

  @override
  void dispose() {
    widget.onChanged(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
