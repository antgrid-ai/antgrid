import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/focus_ring.dart';
import '../primitives/option.dart';
import 'loading.dart';

// Shared by Select, Dropdown and the combo box. Not exported: the three public
// widgets own their own API, this file only holds the popup list and the
// keyboard helpers they must agree on.

/// How many rows the list shows before it scrolls.
const int kOptionListMaxRows = 6;

/// Height of one list row.
///
/// Rows share one extent so the list can build lazily and the highlighted row
/// can be scrolled into view by arithmetic, without measuring rows that were
/// never built. The extent follows the text scaler, so enlarged text grows
/// the rows instead of clipping; labels are single-line and ellipsize.
double optionRowExtent(BuildContext context, {required bool hasDescription}) {
  final theme = CarbonTheme.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  double line(TextStyle style) =>
      scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.3);
  var content = line(theme.typography.control);
  if (hasDescription) content += line(theme.typography.helper);
  return math
      .max(theme.minTarget, content + 2 * CarbonSpacing.spacing02)
      .ceilToDouble();
}

/// Whether any option carries a description line.
bool optionsHaveDescription<T>(List<CarbonOption<T>> options) {
  for (final option in options) {
    if (option.description != null) return true;
  }
  return false;
}

/// The next enabled option from [from] stepping by [delta] (1 or -1), wrapping
/// around the ends. Returns -1 when no option is enabled. From -1, +1 lands on
/// the first enabled option and -1 on the last.
int nextEnabledIndex<T>(List<CarbonOption<T>> options, int from, int delta) {
  final count = options.length;
  if (count == 0) return -1;
  var i = from;
  if (i < 0) i = delta > 0 ? -1 : count;
  for (var step = 0; step < count; step++) {
    i = (i + delta) % count;
    if (i < 0) i += count;
    if (options[i].enabled) return i;
  }
  return -1;
}

int firstEnabledIndex<T>(List<CarbonOption<T>> options) =>
    nextEnabledIndex(options, -1, 1);

int lastEnabledIndex<T>(List<CarbonOption<T>> options) =>
    nextEnabledIndex(options, -1, -1);

/// Scrolls just enough to bring row [index] fully into view.
void revealOptionIndex(ScrollController controller, int index, double extent) {
  if (index < 0 || !controller.hasClients) return;
  final position = controller.position;
  final top = index * extent;
  final bottom = top + extent;
  if (top < position.pixels) {
    position.jumpTo(top.clamp(0, position.maxScrollExtent));
  } else if (bottom > position.pixels + position.viewportDimension) {
    position.jumpTo(
      (bottom - position.viewportDimension).clamp(0, position.maxScrollExtent),
    );
  }
}

/// Whether Enter, NumpadEnter or Space is physically down, which tells a
/// keyboard activation from a pointer or screen-reader tap inside a callback
/// that cannot tell them apart.
bool activationKeyIsDown() {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isLogicalKeyPressed(LogicalKeyboardKey.enter) ||
      keyboard.isLogicalKeyPressed(LogicalKeyboardKey.numpadEnter) ||
      keyboard.isLogicalKeyPressed(LogicalKeyboardKey.space);
}

/// Prefix typeahead: successive characters typed within a short window extend
/// one search string.
class OptionTypeahead {
  static const Duration _window = Duration(milliseconds: 800);

  String _buffer = '';
  DateTime? _last;

  void reset() {
    _buffer = '';
    _last = null;
  }

  /// The index to highlight after [character] was typed while [from] was
  /// highlighted, or -1 when nothing enabled matches.
  int match<T>(
    List<CarbonOption<T>> options,
    int from,
    String character, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final last = _last;
    if (last == null || at.difference(last) > _window) _buffer = '';
    _last = at;
    _buffer += character.toLowerCase();
    final count = options.length;
    // A single letter moves on to the next match; a longer string may keep
    // the current one.
    final start = _buffer.length == 1 ? from + 1 : math.max(from, 0);
    for (var step = 0; step < count; step++) {
      final i = (start + step) % count;
      final option = options[i];
      if (option.enabled && option.label.toLowerCase().startsWith(_buffer)) {
        return i;
      }
    }
    return -1;
  }
}

/// The list inside a Select, Dropdown or combo-box popup.
///
/// Focus stays on the field that opened the list; [activeIndex] is the
/// highlighted row (the active descendant), moved by the field's key handling
/// or by pointer hover. Rows are therefore not focus targets, which is why
/// they do not use the focusable interaction primitive.
class CarbonOptionListbox<T> extends StatelessWidget {
  const CarbonOptionListbox({
    super.key,
    required this.options,
    required this.selectedValue,
    required this.activeIndex,
    required this.keyboardActive,
    required this.onSelect,
    required this.onHover,
    required this.controller,
    required this.extent,
    this.loading = false,
    this.errorText,
    this.emptyText,
  });

  final List<CarbonOption<T>> options;
  final T? selectedValue;
  final int activeIndex;

  /// Whether the highlight came from the keyboard, which draws the focus ring
  /// on the row.
  final bool keyboardActive;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onHover;
  final ScrollController controller;
  final double extent;
  final bool loading;
  final String? errorText;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final messages = CarbonLocalizations.of(context);
    // The popup is raised one layer above its anchor; the surface matches the
    // anchor's own field fill.
    final level = math.max(1, CarbonLayer.of(context) - 1);

    Widget? status;
    if (loading) {
      status = _StatusRow(
        extent: extent,
        leading: const CarbonSpinner(),
        text: messages.loading,
        color: colors.textSecondary,
      );
    } else if (errorText != null) {
      status = _StatusRow(
        extent: extent,
        leading: CarbonIcon(CarbonIcons.errorFilled, color: colors.supportError),
        text: errorText!,
        color: colors.textError,
      );
    } else if (options.isEmpty) {
      status = _StatusRow(
        extent: extent,
        text: emptyText ?? messages.noResults,
        color: colors.textSecondary,
      );
    }

    final count = options.length + (status == null ? 0 : 1);
    final rows = math.min(count, kOptionListMaxRows);
    final border = theme.borderSubtle(level);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.field(level),
        border: Border.all(color: border, width: CarbonBorders.hairline),
      ),
      child: SizedBox(
        height: rows * extent + 2 * CarbonBorders.hairline,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: ListView.builder(
            controller: controller,
            padding: EdgeInsets.zero,
            itemExtent: extent,
            itemCount: count,
            itemBuilder: (context, i) {
              if (i >= options.length) return status!;
              return _OptionRow<T>(
                option: options[i],
                level: level,
                selected: selectedValue != null &&
                    options[i].value == selectedValue,
                active: i == activeIndex,
                keyboardActive: keyboardActive,
                onSelect: () => onSelect(i),
                onHover: () => onHover(i),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.extent,
    required this.text,
    required this.color,
    this.leading,
  });

  final double extent;
  final Widget? leading;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      label: text,
      child: ExcludeSemantics(
        child: SizedBox(
          height: extent,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: theme.controlPaddingX),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: CarbonSpacing.spacing03),
                ],
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.control.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.level,
    required this.selected,
    required this.active,
    required this.keyboardActive,
    required this.onSelect,
    required this.onHover,
  });

  final CarbonOption<T> option;
  final int level;
  final bool selected;
  final bool active;
  final bool keyboardActive;
  final VoidCallback onSelect;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final enabled = option.enabled;
    final highlighted = active && enabled;

    final Color? fill = selected && highlighted
        ? theme.layerSelectedHover(level)
        : selected
        ? theme.layerSelected(level)
        : highlighted
        ? theme.layerHover(level)
        : null;
    final textColor = enabled ? colors.textPrimary : colors.textDisabled;
    final description = option.description;

    final label = description == null
        ? option.label
        : '${option.label}, $description';

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      onTap: enabled ? onSelect : null,
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onHover: enabled && !active ? (_) => onHover() : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onSelect : null,
            child: CarbonFocusRing(
              visible: highlighted && keyboardActive,
              child: ColoredBox(
                color: fill ?? const Color(0x00000000),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: theme.controlPaddingX,
                  ),
                  child: Row(
                    children: [
                      if (option.icon != null) ...[
                        IconTheme.merge(
                          data: IconThemeData(
                            color: enabled
                                ? colors.iconPrimary
                                : colors.iconDisabled,
                            size: theme.iconSize,
                          ),
                          child: option.icon!,
                        ),
                        const SizedBox(width: CarbonSpacing.spacing03),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.typography.control.copyWith(
                                color: textColor,
                              ),
                            ),
                            if (description != null)
                              Text(
                                description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.typography.helper.copyWith(
                                  color: enabled
                                      ? colors.textSecondary
                                      : colors.textDisabled,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: CarbonSpacing.spacing03),
                        CarbonIcon(
                          CarbonIcons.checkmark,
                          color: enabled
                              ? colors.iconPrimary
                              : colors.iconDisabled,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
