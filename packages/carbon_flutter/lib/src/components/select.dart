import 'package:flutter/widgets.dart';

import '../primitives/option.dart';
import 'option_picker.dart';

/// A labeled form field holding one value chosen from a short list.
///
/// Use Select for a setting or form value; use `CarbonDropdown` or
/// `CarbonComboBox` to pick from a long, searchable list, and a menu for
/// commands.
///
/// The host owns the committed [value]. Choosing an option calls [onChanged];
/// the field keeps showing the old value until it is rebuilt with the new one.
/// A [value] that is not among [options] (the list is empty, loading or no
/// longer offers it) is shown as [unavailableLabel] and is never replaced by
/// another option. A null [onChanged] disables the field.
///
/// Keyboard: Enter, Space, Alt+Down or Up/Down open the list; Up/Down, Home
/// and End move the highlight past disabled options; typing a prefix jumps to
/// a match; Enter or Space commits, Escape closes without committing. Focus
/// stays on the field throughout.
///
/// A read-only select shows its value, stays focusable and never opens. Error
/// and warning text are suppressed while disabled or read-only.
class CarbonSelect<T> extends StatelessWidget {
  const CarbonSelect({
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
    this.emptyText,
    this.focusNode,
    this.autofocus = false,
  });

  final List<CarbonOption<T>> options;

  /// The committed value, or null for none. Identity is `==` on the option
  /// values.
  final T? value;

  final ValueChanged<T>? onChanged;
  final String? label;

  /// Shown while [value] is null. Defaults to the localized
  /// `selectPlaceholder`.
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

  /// Shown in the open list when [options] is empty. Defaults to the
  /// localized `noResults`.
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
    emptyText: emptyText,
    focusNode: focusNode,
    autofocus: autofocus,
  );
}
