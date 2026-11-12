import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// One choice in a [GallerySegmented] selector.
class GalleryOption<T> {
  const GalleryOption(this.id, this.value, this.label);

  /// Stable text used in widget keys, so tests can address a choice.
  final String id;
  final T value;
  final String label;
}

/// A focusable, hoverable, keyboard-operable button used by gallery chrome.
class GalleryButton extends StatefulWidget {
  const GalleryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.expanded,
  });

  final String label;
  final VoidCallback onPressed;
  final bool selected;

  /// Non-null for disclosure buttons; reported through semantics.
  final bool? expanded;

  @override
  State<GalleryButton> createState() => _GalleryButtonState();
}

class _GalleryButtonState extends State<GalleryButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final selected = widget.selected;
    final background = selected
        ? (_hovered ? colors.buttonPrimaryHover : colors.buttonPrimary)
        : (_hovered ? colors.layerHover01 : colors.layer01);
    final foreground = selected ? colors.textOnColor : colors.textPrimary;
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      selected: selected,
      expanded: widget.expanded,
      label: widget.label,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        mouseCursor: SystemMouseCursors.click,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: _focused
                  ? Border.all(color: colors.focus, width: CarbonBorders.focus)
                  : Border.all(color: theme.borderSubtle(1)),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: theme.minTarget),
              child: ColoredBox(
                color: background,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CarbonSpacing.spacing04,
                    vertical: CarbonSpacing.spacing02,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      widget.label,
                      style: theme.typography.control.copyWith(color: foreground),
                    ),
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

/// A labelled single-choice selector built from [GalleryButton]s.
class GallerySegmented<T> extends StatelessWidget {
  const GallerySegmented({
    super.key,
    required this.name,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  /// Prefix for each choice's key: `setting-<name>-<option id>`.
  final String name;
  final String label;
  final List<GalleryOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Semantics(
      container: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.typography.label.copyWith(
              color: theme.colors.textSecondary,
            ),
          ),
          const SizedBox(height: CarbonSpacing.spacing02),
          Wrap(
            spacing: CarbonSpacing.spacing01,
            runSpacing: CarbonSpacing.spacing01,
            children: [
              for (final option in options)
                GalleryButton(
                  key: ValueKey('setting-$name-${option.id}'),
                  label: option.label,
                  selected: option.value == value,
                  onPressed: () => onChanged(option.value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
