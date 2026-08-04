import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/terminal_models.dart';
import '../services/terminal_service.dart';
import 'ab_status_helpers.dart';
import 'terminal_view_wrapper.dart';

/// Fullscreen terminal output view with a back button header. Used by both
/// [TerminalListView] (push-nav) and [ServicesListView] (view-logs).
class TerminalDetailView extends StatelessWidget {
  const TerminalDetailView({
    super.key,
    required this.tab,
    required this.terminalService,
    required this.onBack,
    this.onDelete,
  });

  final TerminalTab tab;
  final TerminalService terminalService;
  final VoidCallback onBack;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: Column(
        children: [
          SizedBox(
            height: AbTokens.statusHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
              child: Row(
                children: [
                  AbIconButton(
                    icon: AbIcons.back,
                    tooltip: 'Back',
                    onTap: onBack,
                  ),
                  const SizedBox(width: AbTokens.space8),
                  AbStatusDot(tone: sessionStateTone(tab.sessionState)),
                  const SizedBox(width: AbTokens.space8),
                  Expanded(
                    child: Text(
                      tab.name,
                      style: AbTokens.monoStyle(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onDelete != null)
                    AbIconButton(
                      icon: AbIcons.trash,
                      tooltip: 'Delete',
                      tone: AbIconButtonTone.danger,
                      onTap: onDelete,
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TerminalViewWrapper(
              tab: tab,
              terminalService: terminalService,
            ),
          ),
        ],
      ),
    );
  }
}
