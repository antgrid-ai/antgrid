import 'package:flutter/widgets.dart';

import '../../design/ab_icons.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../models/memory.dart';
import '../../screens/memory_screen.dart';
import '../../util/detached.dart';

/// Opens the memory screen for one project from a drawer row.
class MemoryProjectButton extends StatelessWidget {
  const MemoryProjectButton({
    super.key,
    required this.target,
    required this.projectId,
    required this.projectName,
    this.count,
  });

  final MemoryTarget target;
  final String projectId;
  final String projectName;

  /// Null when the row cannot know it without a request (remote machines).
  final int? count;

  @override
  Widget build(BuildContext context) {
    void open() => detached(
      'Memory',
      'open failed',
      () => openMemoryScreen(context, target, projectId: projectId),
    );
    // AbIconButton has no semantic-label parameter and its Tooltip message
    // would otherwise be announced as well, so the accessible name is the
    // count-free label and is announced once.
    return Semantics(
      label: '$projectName memories',
      button: true,
      excludeSemantics: true,
      onTap: open,
      child: AbIconButton(
        icon: AbIcons.lightbulb,
        tooltip: count == null
            ? '$projectName memories'
            : '$projectName memories ($count)',
        onTap: open,
      ),
    );
  }
}
