import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_empty_state.dart';

/// Shown when no dev server ports are detected on the paired agent. The
/// optional [action] hosts the manual port-entry form so the user can still
/// open a preview when port detection is unavailable.
class PreviewEmptyState extends StatelessWidget {
  final Widget? action;

  const PreviewEmptyState({super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return AbEmptyState(
      icon: AbIcons.browser,
      title: 'Open a Preview',
      subtitle: 'Enter a dev server port below\nto preview it here',
      action: action,
    );
  }
}
