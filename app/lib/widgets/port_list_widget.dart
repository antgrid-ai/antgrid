import 'package:flutter/material.dart';

import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/preview_models.dart';

/// Displays a list of detected dev server ports. Users tap a port to open
/// the embedded webview preview for that port.
class PortListWidget extends StatelessWidget {
  final List<PortInfo> ports;
  final int? selectedPort;
  final void Function(int) onPortSelected;

  const PortListWidget({
    super.key,
    required this.ports,
    required this.selectedPort,
    required this.onPortSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: ports.length,
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
      itemBuilder: (context, index) {
        final port = ports[index];
        final isSelected = port.port == selectedPort;
        final subtitle = port.label ?? port.processName;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AbListRow(
            leading: AbStatusDot(
              tone: isSelected ? AbStatusTone.info : AbStatusTone.disabled,
              style: isSelected ? AbDotStyle.filled : AbDotStyle.hollow,
            ),
            title: Text(
              'Port ${port.port}',
              style: AbTokens.monoStyle(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? context.antgrid.accent : context.antgrid.textPrimary,
              ),
            ),
            subtitle: subtitle != null ? Text(subtitle) : null,
            selected: isSelected,
            selectionStyle: AbRowSelection.surface,
            density: AbRowDensity.md,
            onTap: () => onPortSelected(port.port),
          ),
        );
      },
    );
  }
}
