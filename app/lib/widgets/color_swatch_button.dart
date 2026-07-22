import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';

/// A small tappable color swatch. On tap, opens a Material dialog
/// containing `flutter_colorpicker`'s [ColorPicker]; on confirm, calls
/// [onChanged] with the picked color.
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
    Color picked = color;
    final antgrid = context.antgrid;
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: antgrid.bgSurface,
        titlePadding: abDialogTitlePadding,
        title: abDialogTitle(
          'Pick $label',
          onClose: () => Navigator.of(ctx).pop(),
        ),
        contentPadding: const EdgeInsets.fromLTRB(
          AbTokens.space16,
          AbTokens.space12,
          AbTokens.space16,
          0,
        ),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: picked,
            onColorChanged: (c) => picked = c,
            enableAlpha: false,
            labelTypes: const [],
            pickerAreaHeightPercent: 0.6,
            displayThumbColor: true,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(
          AbTokens.space16,
          0,
          AbTokens.space16,
          AbTokens.space12,
        ),
        actions: [
          AbButton(
            label: 'CANCEL',
            onTap: () => Navigator.of(ctx).pop(),
          ),
          const SizedBox(width: AbTokens.space8),
          AbButton(
            label: 'APPLY',
            onTap: () => Navigator.of(ctx).pop(picked),
          ),
        ],
      ),
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return InkWell(
      onTap: () => _open(context),
      borderRadius: AbTokens.borderRadius5,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space6,
        ),
        decoration: BoxDecoration(
          color: antgrid.bgSurface,
          border: Border.all(color: antgrid.borderDefault),
          borderRadius: AbTokens.borderRadius5,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: antgrid.borderStrong),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: antgrid.textSecondary,
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            Text(
              _hex(color),
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: antgrid.textMuted,
              ),
            ),
            const SizedBox(width: AbTokens.space4),
            Icon(Icons.edit, size: 12, color: antgrid.textMuted),
          ],
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
