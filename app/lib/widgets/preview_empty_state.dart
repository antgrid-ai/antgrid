import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_empty_state.dart';

/// Shown when no preview tab is open. Opening one is done from the panel's
/// address bar above (type a port, press Enter).
class PreviewEmptyState extends StatelessWidget {
  const PreviewEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return const AbEmptyState(
      icon: AbIcons.browser,
      title: 'Open a Preview',
      subtitle: 'Enter a dev server port above\nto preview it here',
    );
  }
}
