import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_adaptive_sheet.dart';
import 'ab_button.dart';
import 'ab_empty_state.dart';
import 'ab_icon.dart';
import 'ab_icon_button.dart';
import 'ab_list_row.dart';
import 'ab_search_field.dart';
import 'ab_separator.dart';

/// One choice in an [showAbSelect] surface.
class AbSelectOption<T> {
  const AbSelectOption({
    required this.value,
    required this.label,
    this.leading,
    this.detail,
    this.keywords = const [],
  });

  final T value;
  final String label;

  /// Rendered before the label — a label's colour dot, an agent mark, an
  /// avatar. Keep it to the row's glyph scale.
  final Widget? leading;

  /// Muted second line. For the thing that disambiguates two same-named rows.
  final String? detail;

  /// Extra text the filter matches on, for rows whose label is not the only
  /// way a user would name them.
  final List<String> keywords;

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (label.toLowerCase().contains(q)) return true;
    if (detail != null && detail!.toLowerCase().contains(q)) return true;
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

/// A filterable picker over [options], single- or multi-select.
///
/// [AbMenu] cannot be this: [AbMenuItem] has no selected state, no trailing
/// slot and no arbitrary child, and `showAbMenu` pops on the first pick — the
/// opposite of multi-select. It is also a fixed-width route popup with no
/// keyboard-inset handling, which on a phone loses most of itself the moment
/// the filter field takes focus.
///
/// Presentation comes from [showAbAdaptiveSheet], so this is a bottom sheet on
/// a phone (padded for the keyboard, closed by system back) and a centred
/// dialog on desktop, sharing one results list.
///
/// Returns the chosen values, or null when the sheet was dismissed — which is
/// NOT the same as an empty set, and callers must not collapse the two: empty
/// means "the user removed everything".
Future<Set<T>?> showAbSelect<T>(
  BuildContext context, {
  required String title,
  required List<AbSelectOption<T>> options,
  Set<T> selected = const {},
  bool single = false,
  String? emptyMessage,
  String filterHint = 'Filter…',
}) {
  return showAbAdaptiveSheet<Set<T>>(
    context,
    child: _AbSelectSheet<T>(
      title: title,
      options: options,
      initialSelection: selected,
      single: single,
      emptyMessage: emptyMessage,
      filterHint: filterHint,
    ),
  );
}

class _AbSelectSheet<T> extends StatefulWidget {
  const _AbSelectSheet({
    required this.title,
    required this.options,
    required this.initialSelection,
    required this.single,
    required this.filterHint,
    this.emptyMessage,
  });

  final String title;
  final List<AbSelectOption<T>> options;
  final Set<T> initialSelection;
  final bool single;
  final String filterHint;
  final String? emptyMessage;

  @override
  State<_AbSelectSheet<T>> createState() => _AbSelectSheetState<T>();
}

class _AbSelectSheetState<T> extends State<_AbSelectSheet<T>> {
  late Set<T> _selected = {...widget.initialSelection};
  String _query = '';

  /// Ceiling on the results list. Below it the sheet sizes to its rows; above
  /// it the rows scroll, so a long label set never pushes Apply off a phone.
  static const _maxListHeight = 320.0;

  void _toggle(T value) {
    setState(() {
      if (widget.single) {
        _selected = {value};
      } else if (!_selected.add(value)) {
        _selected.remove(value);
      }
    });
    // Single-select has nothing left to confirm once a row is taken.
    if (widget.single) Navigator.of(context).pop(_selected);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final visible = widget.options
        .where((o) => o.matches(_query))
        .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space12,
            AbTokens.space8,
            AbTokens.space8,
            AbTokens.space8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space12),
          child: AbSearchField(
            hint: widget.filterHint,
            autofocus: true,
            height: AbTokens.rowHeightSm,
            debounce: null,
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        const AbSeparator.horizontal(),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AbTokens.space24),
            child: AbEmptyState.compact(
              title: widget.emptyMessage ?? 'Nothing matches that filter',
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxListHeight),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: visible.length,
              itemBuilder: (context, i) {
                final option = visible[i];
                final isSelected = _selected.contains(option.value);
                return AbListRow(
                  density: AbRowDensity.md,
                  hoverable: true,
                  selected: isSelected,
                  selectionStyle: AbRowSelection.surface,
                  onTap: () => _toggle(option.value),
                  leading: SizedBox(
                    width: AbTokens.iconButtonGlyph,
                    child: AbIcon(
                      isSelected ? AbIcons.circleCheck : AbIcons.circle,
                      size: AbTokens.iconButtonGlyph,
                      color: isSelected ? palette.accent : palette.iconMuted,
                    ),
                  ),
                  title: Row(
                    children: [
                      if (option.leading != null) ...[
                        option.leading!,
                        const SizedBox(width: AbTokens.space6),
                      ],
                      Flexible(child: Text(option.label)),
                    ],
                  ),
                  subtitle: option.detail == null
                      ? null
                      : Text(option.detail!),
                );
              },
            ),
          ),
        if (!widget.single) ...[
          const AbSeparator.horizontal(),
          Padding(
            padding: const EdgeInsets.all(AbTokens.space12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AbButton(
                  label: 'Cancel',
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: AbTokens.space8),
                AbButton(
                  label: 'Apply',
                  variant: AbButtonVariant.primary,
                  onTap: () => Navigator.of(context).pop(_selected),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
