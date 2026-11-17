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

/// A labelled single-choice selector built from public [CarbonButton]s.
///
/// Buttons rather than a content switcher so each choice carries its own key
/// for tests and stays individually focusable at any width.
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
                Semantics(
                  selected: option.value == value,
                  child: CarbonButton(
                    key: ValueKey('setting-$name-${option.id}'),
                    label: option.label,
                    kind: option.value == value
                        ? CarbonButtonKind.primary
                        : CarbonButtonKind.tertiary,
                    size: CarbonButtonSize.small,
                    onPressed: () => onChanged(option.value),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
