import 'package:flutter/material.dart'
    show Material, MaterialType, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/bare_input_decoration.dart';
import '../primitives/field.dart';
import '../primitives/option.dart';
import '../primitives/popup.dart';
import 'option_listbox.dart';
import 'option_picker.dart';

/// Decides whether [option] matches the text typed into a combo box.
typedef CarbonOptionFilter<T> =
    bool Function(CarbonOption<T> option, String query);

/// A single-selection option picker for choosing from a list.
///
/// Behaves like `CarbonSelect` (host-owned [value], [onChanged], never
/// substitutes an unavailable value, focus stays on the field, same keyboard
/// model) and adds host-driven list states: [loading] shows a spinner row and
/// [listErrorText] an error row inside the open list, below any options
/// already loaded. An empty list shows [emptyText]. Use `CarbonComboBox` when
/// the list is long enough to need search.
///
/// The list builds its rows lazily and scrolls past five and a half rows. A null
/// [onChanged] disables the field. The label is optional so the dropdown can
/// sit in a toolbar; supply one wherever the field is not otherwise named.
class CarbonDropdown<T> extends StatelessWidget {
  const CarbonDropdown({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.placeholder,
    this.helperText,
    this.errorText,
    this.warnText,
    this.required = false,
    this.showOptional = false,
    this.enabled = true,
    this.readOnly = false,
    this.unavailableLabel,
    this.loading = false,
    this.listErrorText,
    this.emptyText,
    this.focusNode,
    this.autofocus = false,
  });

  final List<CarbonOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String? label;
  final String? placeholder;
  final String? helperText;
  final String? errorText;
  final String? warnText;
  final bool required;
  final bool showOptional;
  final bool enabled;
  final bool readOnly;

  /// Shown in place of a [value] that none of [options] carries. Defaults to
  /// the localized `unavailableValue`.
  final String? unavailableLabel;

  /// The host is fetching options; the open list shows a loading row.
  final bool loading;

  /// The host failed to fetch options; the open list shows this message.
  final String? listErrorText;

  /// Shown when [options] is empty and nothing is loading or failed.
  /// Defaults to the localized `noResults`.
  final String? emptyText;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => CarbonOptionPicker<T>(
    options: options,
    value: value,
    onChanged: onChanged,
    label: label,
    placeholder: placeholder,
    helperText: helperText,
    errorText: errorText,
    warnText: warnText,
    required: required,
    showOptional: showOptional,
    enabled: enabled,
    readOnly: readOnly,
    unavailableLabel: unavailableLabel,
    loading: loading,
    listErrorText: listErrorText,
    emptyText: emptyText,
    focusNode: focusNode,
    autofocus: autofocus,
    arrowUpOpens: false,
    hideOutlineWhenOpen: true,
  );
}

/// A dropdown whose field is a text input that filters the list.
///
/// Typing only filters and highlights; it never commits. A value is committed
/// by choosing a row with the pointer or by pressing Enter on the highlighted
/// row, which calls [onChanged] once. The input shows the committed value's
/// label whenever the user is not editing: after a commit, and again when
/// focus leaves without one. The host owns the committed [value] and the field
/// never invents a replacement for an unavailable one.
///
/// Keyboard: Up/Down open the list and move the highlight past disabled
/// options (Alt+Down closes it); Enter commits the highlight. Escape closes
/// the list; a second Escape discards what was typed and restores the
/// committed label. Home and End stay with the text field. While typing, the
/// first enabled match is highlighted so Enter picks it, except when
/// [allowCustomValue] is on, where nothing is highlighted until an arrow key
/// moves there so Enter submits the typed text.
///
/// Free text is accepted only when [allowCustomValue] is true: Enter with no
/// highlighted row then calls [onCustomValue] with the typed text. The field
/// keeps showing the committed value until the host responds by changing
/// [value] (typically adding the option as well).
///
/// Filtering is local and case-insensitive on the label unless [filter] is
/// given; pass `(option, query) => true` and react to [onInputChanged] to
/// filter on the host (for instance from a server). [loading] and
/// [listErrorText] show a spinner or error row inside the list.
///
/// Supplied [controller] and [focusNode] stay owned by the caller. The field
/// writes to the controller only when a value is committed, when the user's
/// edit is discarded, and when [value] changes while the user is not editing,
/// and it does so after the frame so the caller's own listeners are never
/// notified mid-build. Text a supplied controller already holds when the field
/// mounts counts as the user's draft and is kept. Changes the caller makes to
/// the controller while the field is unfocused are not typing: they fire no
/// [onInputChanged] and do not mark the text as edited. Typed text and the
/// highlight survive theme and density changes. Replacing the controller
/// carries the current text to the new one. The whole field
/// toggles the list when tapped outside the text area, which is how touch
/// users reach the chevron.
class CarbonComboBox<T> extends StatefulWidget {
  const CarbonComboBox({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.placeholder,
    this.helperText,
    this.errorText,
    this.warnText,
    this.required = false,
    this.showOptional = false,
    this.enabled = true,
    this.readOnly = false,
    this.unavailableLabel,
    this.controller,
    this.focusNode,
    this.autofocus = false,
    this.filter,
    this.onInputChanged,
    this.allowCustomValue = false,
    this.onCustomValue,
    this.loading = false,
    this.listErrorText,
    this.emptyText,
    this.semanticLabel,
    this.listMinWidth,
    this.listMaxWidth,
    this.preferAbove = false,
  }) : assert(
         !allowCustomValue || onCustomValue != null,
         'allowCustomValue needs onCustomValue',
       );

  final List<CarbonOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String? label;
  final String? placeholder;
  final String? helperText;
  final String? errorText;
  final String? warnText;
  final bool required;
  final bool showOptional;
  final bool enabled;
  final bool readOnly;

  /// Shown in place of a [value] that none of [options] carries. Defaults to
  /// the localized `unavailableValue`.
  final String? unavailableLabel;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Which options match the typed text. Defaults to a case-insensitive
  /// substring match on the label.
  final CarbonOptionFilter<T>? filter;

  /// The user changed the input text, for hosts that search remotely.
  final ValueChanged<String>? onInputChanged;

  /// Lets the user submit text that matches no option.
  final bool allowCustomValue;

  /// Called with the typed text on Enter when [allowCustomValue] is true and
  /// no row is highlighted.
  final ValueChanged<String>? onCustomValue;

  final bool loading;
  final String? listErrorText;
  final String? emptyText;

  /// The field's announced name when [label] is null (Carbon's `titleText`
  /// with `hideLabel`).
  final String? semanticLabel;

  /// Bounds for the option list, which is otherwise as wide as the field. A
  /// narrow field can lift the list into Carbon's inline list box range
  /// (288 to 480) so options stay readable.
  final double? listMinWidth;
  final double? listMaxWidth;

  /// Opens the list above the field when it fits (Carbon's `direction: top`).
  final bool preferAbove;

  @override
  State<CarbonComboBox<T>> createState() => _CarbonComboBoxState<T>();
}

class _CarbonComboBoxState<T> extends State<CarbonComboBox<T>> {
  final CarbonPopupController _popup = CarbonPopupController();
  final ScrollController _scroll = ScrollController();

  TextEditingController? _ownedController;
  FocusNode? _ownedFocus;

  int _active = -1;
  bool _keyboard = false;

  // The text differs from the committed label because the user typed.
  bool _userEdited = false;
  bool _programmatic = false;
  String _lastText = '';
  DateTime? _enterHandledAt;

  List<CarbonOption<T>>? _describedSource;
  bool _hasDescription = false;

  List<CarbonOption<T>>? _filteredSource;
  String? _filteredQuery;
  CarbonOptionFilter<T>? _filteredWith;
  List<CarbonOption<T>> _filtered = const [];

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  bool get _enabled => widget.enabled && widget.onChanged != null;
  bool get _interactive => _enabled && !widget.readOnly;

  String _committedLabel() {
    final index = CarbonOption.indexOfValue(widget.options, widget.value);
    return index >= 0 ? widget.options[index].label : '';
  }

  static List<CarbonOption<V>> _filterOptions<V>(
    List<CarbonOption<V>> options,
    String query,
    CarbonOptionFilter<V>? filter,
  ) {
    if (query.isEmpty) return options;
    final match =
        filter ??
        (CarbonOption<V> o, String q) =>
            o.label.toLowerCase().contains(q.toLowerCase());
    return [
      for (final option in options)
        if (match(option, query)) option,
    ];
  }

  List<CarbonOption<T>> get _visible {
    final query = _userEdited ? _controller.text : '';
    if (query.isEmpty) return widget.options;
    if (identical(_filteredSource, widget.options) &&
        _filteredQuery == query &&
        _filteredWith == widget.filter) {
      return _filtered;
    }
    _filteredSource = widget.options;
    _filteredQuery = query;
    _filteredWith = widget.filter;
    return _filtered = _filterOptions(widget.options, query, widget.filter);
  }

  @override
  void initState() {
    super.initState();
    _popup.addListener(_handlePopup);
    _controller.addListener(_handleText);
    _focus.addListener(_handleFocus);
    final held = _controller.text;
    _lastText = held;
    if (widget.controller != null &&
        held.isNotEmpty &&
        held != _committedLabel()) {
      // Text the host put in its own controller is a draft, not something to
      // overwrite with the committed label.
      _userEdited = true;
    } else {
      _showCommitted();
    }
  }

  @override
  void didUpdateWidget(CarbonComboBox<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Resolved against the old options before anything below changes what is
    // visible, so the highlight can follow its option to its new position.
    CarbonOption<T>? previousActive;
    if (_active >= 0) {
      final oldVisible = _filterOptions(
        oldWidget.options,
        _userEdited ? _controller.text : '',
        oldWidget.filter,
      );
      if (_active < oldVisible.length) previousActive = oldVisible[_active];
    }
    if (widget.controller != oldWidget.controller) {
      final previous = oldWidget.controller ?? _ownedController!;
      previous.removeListener(_handleText);
      final text = previous.text;
      _controller.addListener(_handleText);
      if (_controller.text != text) {
        _lastText = _controller.text;
        _writeText(text);
      }
    }
    if (widget.focusNode != oldWidget.focusNode) {
      final previous = oldWidget.focusNode ?? _ownedFocus!;
      previous.removeListener(_handleFocus);
      _focus.addListener(_handleFocus);
      if (previous.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      }
    }
    if (!_userEdited) _showCommitted();
    final visible = _visible;
    if (!identical(widget.options, oldWidget.options) ||
        widget.filter != oldWidget.filter) {
      var moved = -1;
      if (previousActive != null) {
        moved = CarbonOption.indexOfValue(visible, previousActive.value);
      }
      if (moved >= 0 && visible[moved].enabled) {
        _active = moved;
      } else if (_userEdited && !widget.allowCustomValue) {
        // A host-filtered answer arrives after the keystroke that asked for
        // it, so the first match is picked once there is one.
        _active = firstEnabledIndex(visible);
      } else {
        _active = -1;
      }
    }
    if (_active >= visible.length ||
        (_active >= 0 && !visible[_active].enabled)) {
      _active = -1;
    }
    if (!_interactive && _popup.isOpen) _popup.close();
  }

  @override
  void dispose() {
    _popup.removeListener(_handlePopup);
    _controller.removeListener(_handleText);
    _focus.removeListener(_handleFocus);
    _popup.dispose();
    _scroll.dispose();
    _ownedController?.dispose();
    _ownedFocus?.dispose();
    super.dispose();
  }

  // A supplied controller belongs to the host, whose listeners may call
  // setState; writing it while the framework is building would throw.
  void _writeText(String text) {
    if (widget.controller == null) {
      _setText(text);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.text != text) _setText(text);
    });
  }

  void _showCommitted() {
    final label = _committedLabel();
    if (_controller.text == label) return;
    if (widget.controller == null) {
      _setText(label);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userEdited) return;
      final current = _committedLabel();
      if (_controller.text != current) _setText(current);
    });
  }

  // Every write the component makes goes through here so the text listener
  // can tell it from typing.
  void _setText(String text) {
    _programmatic = true;
    try {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _lastText = text;
    } finally {
      _programmatic = false;
    }
  }

  void _handlePopup() {
    if (!mounted) return;
    if (!_popup.isOpen) {
      _active = -1;
      _keyboard = false;
    }
    setState(() {});
  }

  void _handleFocus() {
    if (!mounted) return;
    if (!_focus.hasFocus) {
      if (_popup.isOpen) _popup.close();
      _discardEdit();
    }
    setState(() {});
  }

  void _handleText() {
    if (_programmatic) return;
    final text = _controller.text;
    if (text == _lastText) return;
    _lastText = text;
    // Only a focused field has a user typing into it; anything else is the
    // host driving its own controller.
    if (!_focus.hasFocus) return;
    widget.onInputChanged?.call(text);
    if (!mounted) return;
    setState(() {
      _userEdited = true;
      _keyboard = true;
      _active = widget.allowCustomValue ? -1 : firstEnabledIndex(_visible);
    });
    if (_focus.hasFocus && _interactive && !_popup.isOpen) _popup.open();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _discardEdit() {
    if (!_userEdited) return;
    _userEdited = false;
    _setText(_committedLabel());
  }

  double _extent(BuildContext context) {
    if (!identical(_describedSource, widget.options)) {
      _describedSource = widget.options;
      _hasDescription = optionsHaveDescription(widget.options);
    }
    return optionRowExtent(context, hasDescription: _hasDescription);
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      revealOptionIndex(
        _scroll,
        _active,
        _extent(context),
        leadingRows: optionStatusRows(
          loading: widget.loading,
          errorText: widget.listErrorText,
        ),
      );
    });
  }

  void _open({required bool keyboard}) {
    if (!_interactive || _popup.isOpen) return;
    if (_userEdited) {
      _active = widget.allowCustomValue ? -1 : firstEnabledIndex(_visible);
    } else {
      final selected = CarbonOption.indexOfValue(widget.options, widget.value);
      _active = selected >= 0 && widget.options[selected].enabled
          ? selected
          : -1;
    }
    _keyboard = keyboard;
    _popup.open();
    _reveal();
  }

  void _move(int index) {
    if (index < 0) return;
    setState(() {
      _active = index;
      _keyboard = true;
    });
    _reveal();
  }

  void _commit(int index) {
    final visible = _visible;
    if (index < 0 || index >= visible.length) return;
    final option = visible[index];
    if (!option.enabled) return;
    _userEdited = false;
    _setText(option.label);
    _popup.close();
    setState(() => _active = -1);
    if (option.value != widget.value) widget.onChanged?.call(option.value);
    _reconcileAfterFrame();
  }

  void _submitCustom() {
    final text = _controller.text;
    _popup.close();
    _userEdited = false;
    widget.onCustomValue?.call(text);
    _reconcileAfterFrame();
  }

  // The host decides what is committed. If it did not take the choice, the
  // input goes back to showing the value it still holds.
  void _reconcileAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userEdited) return;
      final label = _committedLabel();
      if (_controller.text != label) _setText(label);
    });
  }

  void _expandFromSemantics() {
    if (!_interactive) return;
    _focus.requestFocus();
    _open(keyboard: false);
  }

  void _handleTap() {
    if (_interactive) _open(keyboard: false);
  }

  void _handleFieldTap() {
    if (!_interactive) return;
    _focus.requestFocus();
    if (_popup.isOpen) {
      _popup.close();
    } else {
      _open(keyboard: false);
    }
  }

  void _handleEditingComplete() {
    final handled = _enterHandledAt;
    if (handled != null &&
        DateTime.now().difference(handled) < const Duration(milliseconds: 300)) {
      return;
    }
    _submit();
  }

  // Returns whether Enter did anything, so an Enter that means nothing here is
  // left for the platform.
  bool _submit() {
    if (_popup.isOpen && _active >= 0) {
      _commit(_active);
      return true;
    }
    if (widget.allowCustomValue &&
        _userEdited &&
        _controller.text.trim().isNotEmpty) {
      _submitCustom();
      return true;
    }
    return false;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_interactive) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final open = _popup.isOpen;

    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      // Shift, Ctrl and Meta with an arrow select or move the caret in the
      // embedded text field; they are not list navigation.
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isShiftPressed ||
          keyboard.isControlPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      final down = key == LogicalKeyboardKey.arrowDown;
      if (!open) {
        _open(keyboard: true);
      } else if (down && HardwareKeyboard.instance.isAltPressed) {
        _popup.close();
      } else {
        _move(nextEnabledIndex(_visible, _active, down ? 1 : -1));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_submit()) {
        _enterHandledAt = DateTime.now();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      // An open list is closed by the popup itself; once it is closed, Escape
      // abandons the typed filter without committing anything.
      if (!open && _userEdited) {
        setState(_discardEdit);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (open && key == LogicalKeyboardKey.tab) {
      _popup.close();
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final messages = CarbonLocalizations.of(context);
    final enabled = _enabled;
    final interactive = _interactive;
    final open = _popup.isOpen;

    final probe = CarbonFieldFrame(
      label: widget.label,
      errorText: widget.errorText,
      warnText: widget.warnText,
      enabled: enabled,
      readOnly: widget.readOnly,
      child: const SizedBox.shrink(),
    );
    final error = probe.resolvedError;
    final warning = probe.resolvedWarning;

    final style = theme.typography.control.copyWith(
      color: enabled ? colors.textPrimary : colors.textDisabled,
    );
    final unavailable =
        widget.value != null &&
        CarbonOption.indexOfValue(widget.options, widget.value) < 0;
    final hint = unavailable
        ? (widget.unavailableLabel ?? messages.unavailableValue)
        : (widget.placeholder ?? messages.selectPlaceholder);

    final field = Material(
      type: MaterialType.transparency,
      child: DefaultSelectionStyle(
        cursorColor: colors.textPrimary,
        selectionColor: colors.highlight,
        child: CarbonSelectionScope(
          child: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: widget.autofocus,
          enabled: enabled,
          readOnly: widget.readOnly,
          style: style,
          cursorColor: colors.textPrimary,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          decoration: carbonBareInputDecoration(
            hintText: hint,
            hintStyle: style.copyWith(
              color: unavailable ? colors.textSecondary : colors.textPlaceholder,
            ),
          ),
          onTap: _handleTap,
          onEditingComplete: _handleEditingComplete,
          contextMenuBuilder: (_, state) =>
              carbonSelectionToolbar(theme, state),
          ),
        ),
      ),
    );

    final extent = _extent(context);
    final anchorLevel = CarbonLayer.of(context);

    Widget box = CarbonFieldBox(
      focused: _focus.hasFocus,
      enabled: enabled,
      readOnly: widget.readOnly,
      invalid: error != null,
      warn: warning != null,
      expanded: open,
      focusOutlineWidth: open && _active >= 0
          ? CarbonBorders.hairline
          : CarbonBorders.focus,
      trailing: CarbonFieldChevron(open: open, readOnly: widget.readOnly),
      child: field,
    );
    box = GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: _handleFieldTap,
      // Keeps a tap on the chevron or padding from reading as "outside" the
      // input and dropping its focus before the tap handler can use it.
      child: TextFieldTapRegion(child: box),
    );

    return MergeSemantics(
      child: CarbonFieldFrame(
        label: widget.label,
        helperText: widget.helperText,
        errorText: widget.errorText,
        warnText: widget.warnText,
        required: widget.required,
        showOptional: widget.showOptional,
        enabled: enabled,
        readOnly: widget.readOnly,
        child: Semantics(
          label: widget.label == null ? widget.semanticLabel : null,
          expanded: interactive ? open : null,
          // A TextField tap from assistive technology only requests the
          // keyboard, so expanding the list needs its own action.
          onExpand: interactive && !open ? _expandFromSemantics : null,
          onCollapse: interactive && open ? _popup.close : null,
          child: Focus(
            onKeyEvent: _handleKey,
            canRequestFocus: false,
            skipTraversal: true,
            includeSemantics: false,
            child: CarbonAnchoredPopup(
              controller: _popup,
              matchAnchorWidth: true,
              minWidth: widget.listMinWidth ?? 0,
              maxWidth: widget.listMaxWidth,
              preferAbove: widget.preferAbove,
              maxHeight: kOptionListMaxRows * extent,
              popupBuilder: (context, available) => TextFieldTapRegion(
                child: CarbonOptionListbox<T>(
                  options: _visible,
                  selectedValue: widget.value,
                  activeIndex: _active,
                  keyboardActive: _keyboard,
                  extent: _extent(context),
                  level: anchorLevel,
                  controller: _scroll,
                  loading: widget.loading,
                  errorText: widget.listErrorText,
                  emptyText: widget.emptyText,
                  onSelect: _commit,
                  onHover: (i) => setState(() {
                    _active = i;
                    _keyboard = false;
                  }),
                  onLeave: () {
                    if (mounted && _popup.isOpen) setState(() => _active = -1);
                  },
                ),
              ),
              child: box,
            ),
          ),
        ),
      ),
    );
  }
}
