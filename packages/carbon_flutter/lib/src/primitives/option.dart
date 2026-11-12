import 'package:flutter/widgets.dart';

/// One choice offered by a Select, Dropdown, Tabs or Content switcher.
///
/// [value] is the option's identity: components find, compare and commit
/// options by `value ==`, never by position or label, so a host may rebuild
/// the list (relabel, filter, reorder) without changing what is selected.
/// Values within one list must be distinct.
///
/// The option itself deliberately keeps default identity equality; compare
/// [value]s, and treat a changed [label] as a presentation change.
@immutable
class CarbonOption<T> {
  const CarbonOption({
    required this.value,
    required this.label,
    this.enabled = true,
    this.icon,
    this.description,
  });

  final T value;

  /// Visible text, and the accessible name when [icon] is shown alone.
  final String label;

  /// A disabled option is shown but can be neither focused nor committed.
  final bool enabled;

  /// Optional leading glyph; any widget, sized by the component.
  final Widget? icon;

  /// Optional secondary line for components that show one.
  final String? description;

  /// The index of the option whose [value] equals [value], or -1. Use this to
  /// resolve a committed value against a list that may no longer contain it,
  /// rather than substituting another option.
  static int indexOfValue<T>(List<CarbonOption<T>> options, T? value) {
    if (value == null) return -1;
    for (var i = 0; i < options.length; i++) {
      if (options[i].value == value) return i;
    }
    return -1;
  }

  @override
  String toString() => 'CarbonOption($value, "$label"${enabled ? '' : ', disabled'})';
}
