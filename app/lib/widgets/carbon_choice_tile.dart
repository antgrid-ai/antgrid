import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// One option of a single-choice setting, drawn as a Carbon selectable tile.
///
/// Each tile is its own tab stop and announces whether it is selected, so a
/// choice is never carried by the border colour alone: the selected tile also
/// carries a check mark. [preview] is painted above the label.
class CarbonChoiceTile extends StatelessWidget {
  const CarbonChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.detail,
    this.preview,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onPressed;
  final Widget? preview;

  static const double _width = 148;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final c = t.colors;
    return CarbonInteraction(
      onPressed: onPressed,
      label: label,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      excludeChildSemantics: true,
      builder: (context, state, _) {
        // DecoratedBox paints its border over the child rather than insetting
        // it, so the thicker selected rule needs no padding compensation.
        final border = selected ? 2.0 : 1.0;
        return CarbonFocusRing(
          visible: state.focusVisible,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: state.hovered ? c.layerHover01 : c.layer01,
              border: Border.all(
                color: selected ? c.borderInverse : c.borderTile01,
                width: border,
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: _width,
                maxWidth: _width,
                minHeight: t.minTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.all(CarbonSpacing.spacing04),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview case final p?) ...[
                      p,
                      const SizedBox(height: CarbonSpacing.spacing03),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: t.typography.control.copyWith(
                              color: c.textPrimary,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        // The slot is held when unselected so selecting a
                        // tile never re-wraps its label or changes its height.
                        Visibility.maintain(
                          visible: selected,
                          child: CarbonIcon(
                            CarbonIcons.checkmarkFilled,
                            size: 16,
                            color: c.iconPrimary,
                          ),
                        ),
                      ],
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: CarbonSpacing.spacing01),
                      Text(
                        detail!,
                        style: t.typography.code.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
