import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../primitives/field.dart';
import '../primitives/interaction.dart';
import '../primitives/option.dart';
import '../primitives/popup.dart';
import 'option_listbox.dart';

/// The labeled, button-like field that opens a listbox and commits one option.
///
/// Select and Dropdown differ in their public contract, not in this
/// mechanism, so both wrap it. Not exported.
///
/// The host owns the committed [value]: choosing an option calls [onChanged]
/// and the field keeps showing the old value until the host rebuilds with the
/// new one. A [value] that is not among [options] is shown as
/// [unavailableLabel] (default: the localized `unavailableValue`) and is never
/// replaced by the field.
class CarbonOptionPicker<T> extends StatefulWidget {
  const CarbonOptionPicker({
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
    this.focusNode,
    this.autofocus = false,
    this.loading = false,
    this.listErrorText,
    this.emptyText,
    this.arrowUpOpens = true,
    this.hideOutlineWhenOpen = false,
  });

  /// Whether the field drops its focus outline while the list is open and a
  /// value is committed, as Carbon's Dropdown does (dropdown.scss:108).
  final bool hideOutlineWhenOpen;

  /// Whether ArrowUp opens a closed list. A native select does; Carbon's
  /// Dropdown ignores it until the list is open (Dropdown.tsx:574).
  final bool arrowUpOpens;

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
  final String? unavailableLabel;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool loading;
  final String? listErrorText;
  final String? emptyText;

  @override
  State<CarbonOptionPicker<T>> createState() => _CarbonOptionPickerState<T>();
}

class _CarbonOptionPickerState<T> extends State<CarbonOptionPicker<T>> {
  final CarbonPopupController _popup = CarbonPopupController();
  final ScrollController _scroll = ScrollController();
  final OptionTypeahead _typeahead = OptionTypeahead();

  // Kept for the life of the state so swapping between a supplied and an
  // owned node never disposes a node the interaction still holds.
  FocusNode? _ownedFocus;

  int _active = -1;
  bool _keyboard = false;

  List<CarbonOption<T>>? _describedSource;
  bool _hasDescription = false;

  FocusNode get _node => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  bool get _interactive =>
      widget.enabled && widget.onChanged != null && !widget.readOnly;

  bool get _enabled => widget.enabled && widget.onChanged != null;

  @override
  void initState() {
    super.initState();
    _popup.addListener(_handlePopup);
  }

  @override
  void didUpdateWidget(CarbonOptionPicker<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.options, oldWidget.options) && _active >= 0) {
      // The highlight follows its option, not its position, so a list that
      // reloads or re-sorts under the user never moves it onto another row.
      final previous = _active < oldWidget.options.length
          ? oldWidget.options[_active]
          : null;
      final moved = previous == null
          ? -1
          : CarbonOption.indexOfValue(widget.options, previous.value);
      _active = moved >= 0 && widget.options[moved].enabled ? moved : -1;
    }
    if (widget.focusNode != oldWidget.focusNode) {
      final previous = oldWidget.focusNode ?? _ownedFocus;
      if (previous != null && previous.hasFocus) {
        // The old node is detached by this rebuild; without a hand-over the
        // open list would be left with no keyboard owner.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _node.requestFocus();
        });
      }
    }
    if (!_interactive && _popup.isOpen) _popup.close();
  }

  @override
  void dispose() {
    _popup.removeListener(_handlePopup);
    _popup.dispose();
    _scroll.dispose();
    _ownedFocus?.dispose();
    super.dispose();
  }

  void _handlePopup() {
    if (!mounted) return;
    if (!_popup.isOpen) {
      _active = -1;
      _keyboard = false;
      _typeahead.reset();
    }
    setState(() {});
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
    final selected = CarbonOption.indexOfValue(widget.options, widget.value);
    _active = selected >= 0 && widget.options[selected].enabled
        ? selected
        : (keyboard ? firstEnabledIndex(widget.options) : -1);
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
    if (index < 0 || index >= widget.options.length) return;
    final option = widget.options[index];
    if (!option.enabled) return;
    _popup.close();
    _node.requestFocus();
    if (option.value != widget.value) widget.onChanged?.call(option.value);
  }

  void _handlePressed() {
    if (!_popup.isOpen) {
      _open(keyboard: activationKeyIsDown());
      return;
    }
    final keyboard = HardwareKeyboard.instance;
    if (_typeahead.active &&
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.space) &&
        !keyboard.isLogicalKeyPressed(LogicalKeyboardKey.enter) &&
        !keyboard.isLogicalKeyPressed(LogicalKeyboardKey.numpadEnter)) {
      // Space mid-search extends the prefix ("new york") like a native select
      // instead of committing the row the search has reached.
      final match = _typeahead.match(widget.options, _active, ' ');
      if (match >= 0) _move(match);
      return;
    }
    if (activationKeyIsDown() && _active >= 0) {
      _commit(_active);
    } else {
      _popup.close();
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_interactive) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final open = _popup.isOpen;
    final options = widget.options;

    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final down = key == LogicalKeyboardKey.arrowDown;
      if (!open) {
        if (down || widget.arrowUpOpens) {
          _open(keyboard: true);
          return KeyEventResult.handled;
        }
        // Consumed so focus stays on the toggle, as it does on the web.
        return KeyEventResult.handled;
      } else if (down && HardwareKeyboard.instance.isAltPressed) {
        _popup.close();
      } else {
        _move(nextEnabledIndex(options, _active, down ? 1 : -1));
      }
      return KeyEventResult.handled;
    }
    if (open && key == LogicalKeyboardKey.home) {
      _move(firstEnabledIndex(options));
      return KeyEventResult.handled;
    }
    if (open && key == LogicalKeyboardKey.end) {
      _move(lastEnabledIndex(options));
      return KeyEventResult.handled;
    }
    if (open && key == LogicalKeyboardKey.tab) {
      // Focus moves on; the list must not stay open behind it.
      _popup.close();
      return KeyEventResult.ignored;
    }

    final character = event.character;
    if (character != null &&
        character.trim().length == 1 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      final match = _typeahead.match(options, _active, character);
      if (match >= 0) {
        if (!open) _open(keyboard: true);
        _move(match);
        return KeyEventResult.handled;
      }
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

    // Only its resolved texts are used, so the field frame stays the single
    // owner of the "errors hide when disabled or read-only" rule.
    final probe = CarbonFieldFrame(
      label: widget.label,
      helperText: widget.helperText,
      errorText: widget.errorText,
      warnText: widget.warnText,
      required: widget.required,
      showOptional: widget.showOptional,
      enabled: enabled,
      readOnly: widget.readOnly,
      child: const SizedBox.shrink(),
    );
    final error = probe.resolvedError;
    final warning = probe.resolvedWarning;
    final helper = (widget.helperText?.isEmpty ?? true)
        ? null
        : widget.helperText;
    final message = error ?? warning ?? helper;

    final selected = CarbonOption.indexOfValue(widget.options, widget.value);
    final String text;
    if (selected >= 0) {
      text = widget.options[selected].label;
    } else if (widget.value != null) {
      text = widget.unavailableLabel ?? messages.unavailableValue;
    } else {
      text = widget.placeholder ?? messages.selectPlaceholder;
    }

    final hint = <String>[
      if (widget.required) messages.requiredField,
      ?message,
    ].join(', ');

    final extent = _extent(context);
    final anchorLevel = CarbonLayer.of(context);

    final trigger = Focus(
      onKeyEvent: _handleKey,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: CarbonInteraction(
        focusNode: _node,
        autofocus: widget.autofocus,
        requestFocusOnTap: true,
        // A read-only field stays focusable and inspectable but never opens.
        onPressed: !enabled
            ? null
            : widget.readOnly
            ? () {}
            : _handlePressed,
        label: probe.resolvedLabel(context),
        value: text,
        hint: hint.isEmpty ? null : hint,
        expanded: interactive ? open : null,
        excludeChildSemantics: true,
        builder: (context, state, _) => CarbonFieldBox(
          focused:
              state.focused &&
              !(open && widget.hideOutlineWhenOpen && widget.value != null),
          enabled: enabled,
          readOnly: widget.readOnly,
          invalid: error != null,
          warn: warning != null,
          expanded: open,
          trailing: CarbonFieldChevron(open: open, readOnly: widget.readOnly),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.typography.control.copyWith(
              // The no-selection label is text-primary in Carbon
              // (list-box.scss:453, select.scss:60); only the combo box's
              // input hint is a placeholder.
              color: enabled ? colors.textPrimary : colors.textDisabled,
            ),
          ),
        ),
      ),
    );

    return MergeSemantics(
      child: Semantics(
        isRequired: widget.required ? true : null,
        readOnly: widget.readOnly ? true : null,
        validationResult: error != null
            ? SemanticsValidationResult.invalid
            : SemanticsValidationResult.none,
        child: CarbonFieldFrame(
          label: widget.label,
          helperText: widget.helperText,
          errorText: widget.errorText,
          warnText: widget.warnText,
          required: widget.required,
          showOptional: widget.showOptional,
          enabled: enabled,
          readOnly: widget.readOnly,
          excludeTextSemantics: true,
          child: CarbonAnchoredPopup(
            controller: _popup,
            matchAnchorWidth: true,
            maxHeight: kOptionListMaxRows * extent,
            restoreFocus: _node,
            // A click on inert page space blurs a native button, so the field
            // must not keep its focus outline behind a closed list.
            onDismissed: (reason) {
              if (reason == CarbonPopupDismissReason.outsideTap) {
                _node.unfocus();
              }
            },
            popupBuilder: (context, available) => CarbonOptionListbox<T>(
              options: widget.options,
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
            child: trigger,
          ),
        ),
      ),
    );
  }
}
