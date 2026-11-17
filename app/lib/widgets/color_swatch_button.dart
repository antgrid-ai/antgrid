import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

/// A tappable colour swatch. Opens a Carbon modal holding
/// `flutter_colorpicker`'s [ColorPicker]; on Apply, calls [onChanged] with the
/// picked colour.
///
/// [build]'s context must sit under a Carbon scope: the modal route takes its
/// theme and density from the presenting context.
class ColorSwatchButton extends StatelessWidget {
  const ColorSwatchButton({
    super.key,
    required this.label,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final Color color;
  final ValueChanged<Color> onChanged;

  Future<void> _open(BuildContext context) async {
    var picked = color;
    final result = await showCarbonModal<Color>(
      context,
      builder: (modalContext) => CarbonModal(
        size: CarbonModalSize.xs,
        title: 'Pick ${label.toLowerCase()}',
        body: LayoutBuilder(
          // The picker's own default is wider than a phone's modal body.
          builder: (_, constraints) => ColorPicker(
            pickerColor: picked,
            onColorChanged: (c) => picked = c,
            enableAlpha: false,
            labelTypes: const [],
            pickerAreaHeightPercent: 0.6,
            displayThumbColor: true,
            portraitOnly: true,
            colorPickerWidth: constraints.maxWidth.clamp(0, 300).toDouble(),
          ),
        ),
        actions: [
          CarbonModalAction(
            label: 'Cancel',
            kind: CarbonButtonKind.secondary,
            onPressed: () => Navigator.of(modalContext).pop(),
          ),
          CarbonModalAction(
            label: 'Apply',
            onPressed: () => Navigator.of(modalContext).pop(picked),
          ),
        ],
      ),
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final c = t.colors;
    return CarbonInteraction(
      onPressed: () => _open(context),
      label: '$label ${_hex(color)}',
      hint: 'Pick a colour',
      excludeChildSemantics: true,
      builder: (context, state, _) => CarbonFocusRing(
        visible: state.focusVisible,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: state.hovered ? c.layerHover01 : c.layer01,
            border: Border.all(color: c.borderSubtle01),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: t.minTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CarbonSpacing.spacing04,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      border: Border.all(color: c.borderStrong01),
                    ),
                    child: const SizedBox.square(dimension: 16),
                  ),
                  const SizedBox(width: CarbonSpacing.spacing03),
                  Text(
                    label,
                    style: t.typography.control.copyWith(
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(width: CarbonSpacing.spacing03),
                  Text(
                    _hex(color),
                    style: t.typography.code.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(width: CarbonSpacing.spacing03),
                  CarbonIcon(
                    CarbonIcons.edit,
                    size: 16,
                    color: c.iconSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _hex(Color c) {
  final r = (c.r * 255).round().toRadixString(16).padLeft(2, '0');
  final g = (c.g * 255).round().toRadixString(16).padLeft(2, '0');
  final b = (c.b * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${(r + g + b).toUpperCase()}';
}
