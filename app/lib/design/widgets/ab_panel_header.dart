import 'package:flutter/widgets.dart';

import '../ab_icons.dart';
import 'ab_icon_button.dart';
import 'ab_toolbar.dart';

/// Panel header. Thin wrapper over [AbToolbar.panel] for backwards
/// compatibility with existing call sites.
class AbPanelHeader extends StatelessWidget {
  const AbPanelHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.isExpanded = false,
    this.onToggleExpand,
  });

  final String title;
  final List<Widget> actions;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;

  @override
  Widget build(BuildContext context) {
    return AbToolbar.panel(
      title: title,
      actions: actions,
      trailing: onToggleExpand != null
          ? AbIconButton(
              icon: AbIcons.expand,
              onTap: onToggleExpand,
              tooltip: isExpanded ? 'Collapse' : 'Expand',
            )
          : null,
    );
  }
}
