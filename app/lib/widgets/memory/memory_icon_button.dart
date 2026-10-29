import 'package:flutter/widgets.dart';

import '../../design/ab_icons.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../models/memory.dart';
import '../../screens/memory_screen.dart';
import '../../util/detached.dart';

/// Opens the memory screen for [target] from a drawer row.
class MemoryIconButton extends StatelessWidget {
  const MemoryIconButton({super.key, required this.target});

  final MemoryTarget target;

  @override
  Widget build(BuildContext context) => AbIconButton(
    icon: AbIcons.list,
    tooltip: target.isProject ? 'Project memory' : 'Machine memory',
    onTap: () => detached(
      'Memory',
      'open failed',
      () => openMemoryScreen(context, target),
    ),
  );
}
