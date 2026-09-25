import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_toolbar.dart';
import '../keyboard/app_shortcuts.dart';
import '../keyboard/shortcuts_sheet.dart';
import '../navigation/back_intent.dart';

/// App settings' Keyboard shortcuts page: every binding on this platform, with
/// a filter — the list runs to dozens of rows, and the user arriving here is
/// usually after one.
///
/// A page within the settings surface rather than a pushed route: a route on
/// top would stop the app's own shortcuts (they fire only while the root route
/// is current), which is an odd thing for the shortcuts page to do.
class KeyboardShortcutsPage extends StatefulWidget {
  const KeyboardShortcutsPage({
    super.key,
    required this.onBack,
    required this.onClose,
  });

  /// Back to the settings list.
  final VoidCallback onBack;

  /// Closes settings altogether, as the list's own close button does.
  final VoidCallback onClose;

  @override
  State<KeyboardShortcutsPage> createState() => _KeyboardShortcutsPageState();
}

class _KeyboardShortcutsPageState extends State<KeyboardShortcutsPage> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final sheet = shortcutLabel(AppCommand.showShortcuts);
    // Above the settings surface's own handler, so Back returns to the list
    // before it closes settings.
    return BackHandler(
      priority: BackPriority.settingsPage,
      onBack: () {
        widget.onBack();
        return true;
      },
      child: Scaffold(
        backgroundColor: antgrid.bgDeepest,
        body: Column(
          children: [
            AbToolbar.panel(
              title: 'KEYBOARD SHORTCUTS',
              leading: AbIconButton(
                icon: AbIcons.back,
                tooltip: withShortcut('Back to settings', AppCommand.goBack),
                onTap: widget.onBack,
              ),
              actions: [
                AbIconButton(icon: AbIcons.close, onTap: widget.onClose),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AbTokens.space12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      [
                        // The modifier rule is the one thing a user cannot
                        // infer from the list: why most chords carry Shift here
                        // but not in other apps.
                        if (!isApplePlatform())
                          'App-wide shortcuts use Ctrl+Shift so plain '
                              "Ctrl+letter keys stay with the agent's terminal.",
                        'Shortcuts marked "when focused" work while that area '
                            '— a file, a panel, a dialog — has the keyboard; '
                            'the rest work anywhere, the agent terminal '
                            'included.',
                        if (sheet != null)
                          '$sheet shows this list from anywhere.',
                      ].join(' '),
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: antgrid.textMuted,
                      ),
                    ),
                    const SizedBox(height: AbTokens.space8),
                    AbSearchField(
                      controller: _controller,
                      hint: 'Filter shortcuts...',
                      debounce: null,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    ShortcutList(query: _query),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
