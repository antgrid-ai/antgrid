import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_empty_state.dart';

/// Shown when no dev server ports are detected on the paired agent. Opening
/// one is done from the panel's address bar above (type a port, press
/// Enter) — this state is just the message; the optional [action] hosts a
/// quick-pick row of previously-used ports, not a text entry of its own.
class PreviewEmptyState extends StatelessWidget {
  final Widget? action;

  const PreviewEmptyState({super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return AbEmptyState(
      icon: AbIcons.browser,
      title: 'Open a Preview',
      subtitle: 'Enter a dev server port above\nto preview it here',
      action: action,
    );
  }
}
