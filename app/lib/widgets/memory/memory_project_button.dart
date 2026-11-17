import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/memory.dart';
import '../../screens/memory_screen.dart';
import '../projects_drawer.dart' show closeDrawerIfOverlay;

/// Opens the memory screen for one project from a drawer row.
///
/// The tooltip is the accessible name, so neither carries the memory count: the
/// Memory nav row is where a count is read.
class MemoryProjectButton extends StatelessWidget {
  const MemoryProjectButton({
    super.key,
    required this.target,
    required this.projectId,
    required this.projectName,
  });

  final MemoryTarget target;
  final String projectId;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    return CarbonButton.iconOnly(
      icon: const CarbonIcon(CarbonIcons.idea),
      size: CarbonButtonSize.extraSmall,
      semanticLabel: '$projectName memories',
      onPressed: () {
        openMemoryScreen(context, target, projectId: projectId);
        closeDrawerIfOverlay(context);
      },
    );
  }
}
